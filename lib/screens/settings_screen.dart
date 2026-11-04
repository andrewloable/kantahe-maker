import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../ai_timing.dart';
import '../app_dirs.dart';
import '../fs_retry.dart';
import '../settings.dart';
import '../tools.dart';
import 'graphics_card_dialog.dart';
import 'tools_dialog.dart';

/// The command that opens [path] in the system file manager (a program and its
/// arguments; never run through a shell).
List<String> openFolderCommand(HostOs os, String path) => switch (os) {
      HostOs.macos => ['open', path],
      HostOs.windows => ['explorer', path],
      HostOs.linux => ['xdg-open', path],
    };

/// The name shown for a key of [toolStatus].
String toolLabel(String key) => key == 'model' ? 'Vocal-splitting model' : key;

/// The graphics card switch for vocal splitting, and the downloaded tools: where each one
/// is, and buttons to download or repair them, open their folder and delete them.
/// Everything that touches the machine can be replaced in tests.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.status,
    this.repair,
    this.openFolder,
    this.deleteTools,
    this.showGraphicsCard,
    this.loadSettings,
    this.saveSettings,
    this.hasGraphicsSupport,
    this.installGraphics,
    this.verifyCloudflare,
  });

  final Future<Map<String, String?>> Function()? status;
  final Future<void> Function(BuildContext context)? repair;
  final Future<void> Function()? openFolder;
  final Future<void> Function()? deleteTools;

  /// Whether the graphics card switch is shown; null means on Windows only (DirectML).
  final bool? showGraphicsCard;
  final Future<AppSettings> Function()? loadSettings;
  final Future<void> Function(AppSettings settings)? saveSettings;

  /// Whether the graphics card support is downloaded already.
  final Future<bool> Function()? hasGraphicsSupport;

  /// Downloads the graphics card support (asking first); true when it is installed.
  final Future<bool> Function(BuildContext context)? installGraphics;

  /// Tests an account ID and token with Cloudflare, throwing why not; null means the real test.
  final Future<void> Function(String accountId, String token)? verifyCloudflare;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Future<Map<String, String?>> _status = _loadStatus();
  AppSettings _settings = const AppSettings();
  final _account = TextEditingController();
  final _token = TextEditingController();
  String _cfStatus = '';
  bool _cfBusy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSettings());
  }

  @override
  void dispose() {
    _account.dispose();
    _token.dispose();
    super.dispose();
  }

  bool get _useGraphicsCard => _settings.useGraphicsCard;

  bool get _showGraphicsCard =>
      widget.showGraphicsCard ?? parseHost(Platform.version).$1 == HostOs.windows;

  Future<void> _loadSettings() async {
    try {
      final settings = await (widget.loadSettings ?? _defaultLoadSettings)();
      if (!mounted) return;
      setState(() => _settings = settings);
      _account.text = settings.cloudflareAccountId;
      _token.text = settings.cloudflareToken;
    } catch (_) {
      // The defaults stay.
    }
  }

  /// Saves the two values, then tests them with Cloudflare and saves the result: the AI
  /// button of the Timing step appears only when the test passed for exactly these values.
  Future<void> _saveCloudflare() async {
    final save = widget.saveSettings ?? _defaultSaveSettings;
    var next = _settings.copyWith(
      cloudflareAccountId: _account.text.trim(),
      cloudflareToken: _token.text.trim(),
      cloudflareVerified: false,
    );
    setState(() {
      _cfBusy = true;
      _cfStatus = next.hasCloudflare ? 'Testing with Cloudflare...' : '';
    });
    String status;
    try {
      await save(next);
      if (!next.hasCloudflare) {
        status = 'Cloudflare AI is off: it needs both the account ID and the API token.';
      } else {
        try {
          await (widget.verifyCloudflare ?? _defaultVerify)(
            next.cloudflareAccountId,
            next.cloudflareToken,
          );
          next = next.copyWith(cloudflareVerified: true);
          await save(next);
          status = 'Saved. Cloudflare AI works: "Auto-time with AI" is now in the Timing step.';
        } on AiTimingException catch (e) {
          status = 'Saved, but the test failed: ${e.message} The "Auto-time with AI" button '
              'stays hidden.';
        } catch (e) {
          status = 'Saved, but the test failed: $e The "Auto-time with AI" button stays hidden.';
        }
      }
    } catch (e) {
      // The token is never part of the message: it comes from the file system.
      status = 'Could not save: $e';
    }
    if (!mounted) return;
    setState(() {
      _settings = next;
      _cfBusy = false;
      _cfStatus = status;
    });
  }

  static Future<void> _defaultVerify(String accountId, String token) =>
      verifyCloudflare(accountId: accountId, token: token);

  static Future<AppSettings> _defaultLoadSettings() async =>
      readSettings(await appSettingsFile());

  static Future<void> _defaultSaveSettings(AppSettings settings) async =>
      writeSettings(await appSettingsFile(), settings);

  static Future<bool> _defaultHasGraphicsSupport() async =>
      separatorHasGraphicsSupport(await appToolsDir());

  /// Turning it on first downloads the support when it is not there; the switch stays off
  /// when that is declined or fails. Turning it off only stops using it.
  Future<void> _setGraphicsCard(bool on) async {
    try {
      if (on && !await (widget.hasGraphicsSupport ?? _defaultHasGraphicsSupport)()) {
        if (!mounted) return;
        final installed = await (widget.installGraphics ?? showGraphicsCardDialog)(context);
        if (!installed) return;
      }
      final next = _settings.copyWith(useGraphicsCard: on);
      await (widget.saveSettings ?? _defaultSaveSettings)(next);
      if (mounted) setState(() => _settings = next);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    if (mounted) _refresh();
  }

  Future<Map<String, String?>> _loadStatus() => (widget.status ?? _defaultStatus)();

  void _refresh() {
    setState(() {
      _status = _loadStatus();
    });
  }

  static Future<Map<String, String?>> _defaultStatus() async {
    final (os, _) = parseHost(Platform.version);
    return toolStatus(await appToolsDir(), os, Platform.environment);
  }

  static Future<void> _defaultRepair(BuildContext context) async {
    await ensureTools(context);
  }

  static Future<void> _defaultOpenFolder() async {
    final dir = await appToolsDir();
    await Directory(dir.root).create(recursive: true);
    final (os, _) = parseHost(Platform.version);
    final command = openFolderCommand(os, dir.root);
    // explorer.exe exits with 1 even when it worked, so the exit code is not checked.
    await Process.run(command.first, command.sublist(1));
  }

  static Future<void> _defaultDeleteTools() async {
    final dir = Directory((await appToolsDir()).root);
    await retryBusy(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
  }

  /// Runs a button's action, shows what went wrong, and reads the status again.
  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    if (mounted) _refresh();
  }

  Future<void> _confirmDelete() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete the downloaded tools?'),
        content: const Text('This removes ffmpeg, uv, Python, audio-separator and the '
            'vocal-splitting model that this app downloaded. Programs installed elsewhere on '
            'this computer are not touched. You can download everything again at any time.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (yes == true) await _run(widget.deleteTools ?? _defaultDeleteTools);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_showGraphicsCard) ...[
            Text('Vocal splitting', style: Theme.of(context).textTheme.titleMedium),
            SwitchListTile(
              key: const ValueKey('graphics-card'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Use the graphics card'),
              subtitle: const Text('Much faster on most computers. The first time it downloads '
                  'about 650 MB more. If the graphics card cannot be used, the processor is '
                  'used instead. Off by default.'),
              value: _useGraphicsCard,
              onChanged: _setGraphicsCard,
            ),
            const SizedBox(height: 16),
          ],
          Text('Cloudflare AI (automatic timing)', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('Used by "Auto-time with AI" in the Timing step. Find the account ID on '
              'the Cloudflare dashboard home page, and make an API token with the "Workers AI" '
              'permission. The vocals of a song are sent to Cloudflare only after you confirm, '
              'each time. The token is kept in this computer\'s settings file.'),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('cf-account'),
            controller: _account,
            decoration: const InputDecoration(labelText: 'Account ID', isDense: true),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('cf-token'),
            controller: _token,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'API token', isDense: true),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              key: const ValueKey('cf-save'),
              onPressed: _cfBusy ? null : _saveCloudflare,
              child: const Text('Save and test'),
            ),
          ),
          if (_cfStatus.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_cfStatus, key: const ValueKey('cf-status')),
          ],
          const SizedBox(height: 16),
          Text('Tools', style: Theme.of(context).textTheme.titleMedium),
          FutureBuilder<Map<String, String?>>(
            future: _status,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text('Could not read the tool status: ${snapshot.error}'),
                );
              }
              if (!snapshot.hasData) {
                return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: LinearProgressIndicator());
              }
              return Column(
                children: [
                  for (final entry in snapshot.data!.entries)
                    ListTile(
                      dense: true,
                      leading: Icon(
                          entry.value != null ? Icons.check_circle : Icons.error_outline,
                          color: entry.value != null ? Colors.green : Colors.orange),
                      title: Text(toolLabel(entry.key)),
                      subtitle: Text(entry.value ?? 'Missing'),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: () =>
                    _run(() => (widget.repair ?? _defaultRepair)(context)),
                icon: const Icon(Icons.download),
                label: const Text('Download / repair tools'),
              ),
              OutlinedButton.icon(
                onPressed: () => _run(widget.openFolder ?? _defaultOpenFolder),
                icon: const Icon(Icons.folder_open),
                label: const Text('Open tools folder'),
              ),
              OutlinedButton.icon(
                onPressed: _confirmDelete,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete downloaded tools'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
