import 'dart:io';

import 'package:flutter/material.dart';

import '../app_dirs.dart';
import '../fs_retry.dart';
import '../tools.dart';
import 'tools_dialog.dart';

/// The command that opens [path] in the system file manager (a program and its
/// arguments; never run through a shell).
List<String> openFolderCommand(HostOs os, String path) => switch (os) {
      HostOs.macos => ['open', path],
      HostOs.windows => ['explorer', path],
      HostOs.linux => ['xdg-open', path],
    };

/// The name shown for a key of [toolStatus].
String toolLabel(String key) => key == 'model' ? 'Vocal-removal model' : key;

/// The downloaded tools: where each one is, and buttons to download or repair them,
/// open their folder and delete them. Everything that touches the machine can be
/// replaced in tests.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.status,
    this.repair,
    this.openFolder,
    this.deleteTools,
  });

  final Future<Map<String, String?>> Function()? status;
  final Future<void> Function(BuildContext context)? repair;
  final Future<void> Function()? openFolder;
  final Future<void> Function()? deleteTools;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Future<Map<String, String?>> _status = _loadStatus();

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
            'vocal-removal model that this app downloaded. Programs installed elsewhere on '
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
