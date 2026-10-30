import 'dart:io';

import 'package:flutter/material.dart';
import '../app_dirs.dart';
import '../tool_pins.dart';
import '../tools.dart';

/// Finds the installed tools, or null if something is missing.
typedef Resolver = Future<ToolPaths?> Function();

/// Installs what is missing, reporting output lines and download progress.
typedef Installer = Future<void> Function(
  void Function(String line) onLine,
  void Function(String file, int received, int? total) onProgress,
);

/// One thing the consent dialog says it will download.
class ToolItem {
  final String name, source, license;
  final int sizeMb;
  const ToolItem(this.name, this.source, this.sizeMb, this.license);
}

/// The four downloads, with where they come from, how big they are and their license.
/// The ffmpeg and uv hosts come from the pinned URLs for this computer.
List<ToolItem> toolItems(HostOs os, HostArch arch) {
  final downloads = downloadsFor(os, arch);
  String host(String member) => Uri.parse(
          downloads.firstWhere((d) => d.member.startsWith(member)).url)
      .host;
  return [
    ToolItem('ffmpeg and ffprobe', host('ffmpeg'), approxSizeMb['ffmpeg']!,
        toolLicenses['ffmpeg']!),
    ToolItem('uv (Python manager)', host('uv'), approxSizeMb['uv']!,
        toolLicenses['uv']!),
    ToolItem(
        'Python and audio-separator',
        'pypi.org',
        approxSizeMb['python+audio-separator']!,
        '${toolLicenses['Python']} / ${toolLicenses['audio-separator']}'),
    ToolItem('Vocal-removal model (UVR)', 'github.com (UVR models)',
        approxSizeMb['model']!, toolLicenses['UVR model']!),
  ];
}

Future<ToolPaths?> defaultResolve() async {
  final (os, _) = parseHost(Platform.version);
  return resolve(await appToolsDir(), os, Platform.environment);
}

Future<void> defaultInstall(
  void Function(String line) onLine,
  void Function(String file, int received, int? total) onProgress,
) async {
  final (os, arch) = parseHost(Platform.version);
  await installTools(await appToolsDir(), os, arch,
      onLine: onLine, onProgress: onProgress);
}

/// Returns the tools if they are installed. Otherwise asks the user whether to
/// download them. Nothing is downloaded before the user clicks Download; "Not now"
/// returns null. [resolve] and [install] can be replaced in tests.
Future<ToolPaths?> ensureTools(
  BuildContext context, {
  Resolver? resolve,
  Installer? install,
}) async {
  final find = resolve ?? defaultResolve;
  final found = await find();
  if (found != null) return found;
  if (!context.mounted) return null;
  return showDialog<ToolPaths>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        _ToolsDialog(resolve: find, install: install ?? defaultInstall),
  );
}

enum _Phase { ask, working, failed }

class _ToolsDialog extends StatefulWidget {
  final Resolver resolve;
  final Installer install;
  const _ToolsDialog({required this.resolve, required this.install});

  @override
  State<_ToolsDialog> createState() => _ToolsDialogState();
}

class _ToolsDialogState extends State<_ToolsDialog> {
  static const _maxLogLines = 200;

  late final List<ToolItem> _items = () {
    final (os, arch) = parseHost(Platform.version);
    return toolItems(os, arch);
  }();
  _Phase _phase = _Phase.ask;
  String _file = '';
  int _received = 0;
  int? _total;
  final List<String> _log = [];
  String _error = '';

  void _onLine(String line) {
    if (!mounted) return;
    setState(() {
      _log.add(line);
      if (_log.length > _maxLogLines) _log.removeAt(0);
    });
  }

  void _onProgress(String file, int received, int? total) {
    if (!mounted) return;
    setState(() {
      _file = file;
      _received = received;
      _total = total;
    });
  }

  Future<void> _start() async {
    setState(() {
      _phase = _Phase.working;
      _file = '';
      _received = 0;
      _total = null;
      _log.clear();
      _error = '';
    });
    try {
      await widget.install(_onLine, _onProgress);
      final paths = await widget.resolve();
      if (!mounted) return;
      if (paths != null) {
        Navigator.of(context).pop(paths);
      } else {
        _fail('The download finished but some tools are still missing.');
      }
    } catch (e) {
      if (mounted) _fail(e.toString());
    }
  }

  void _fail(String message) => setState(() {
        _phase = _Phase.failed;
        _error = message;
      });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Download required tools?'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: switch (_phase) {
              _Phase.ask => [
                  const Text('Nothing is downloaded until you click Download. '
                      'Everything goes into one folder you can delete in Settings. '
                      'Tools already on this computer are used instead of being '
                      'downloaded again.'),
                  const SizedBox(height: 8),
                  for (final item in _items)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(item.name),
                      subtitle: Text('Source: ${item.source}  ·  ~${item.sizeMb} MB'
                          '  ·  License: ${item.license}'),
                    ),
                ],
              _Phase.working => [
                  Text(_file),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: _total == null || _total == 0 ? null : _received / _total!,
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 160,
                    // reverse: the view stays at the bottom, on the newest line.
                    child: SingleChildScrollView(
                      reverse: true,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final line in _log)
                            Text(line,
                                style: const TextStyle(
                                    fontFamily: 'monospace', fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                ],
              _Phase.failed => [SelectableText(_error)],
            },
          ),
        ),
      ),
      actions: switch (_phase) {
        _Phase.ask => [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Not now')),
            FilledButton(onPressed: _start, child: const Text('Download')),
          ],
        _Phase.working => const [],
        _Phase.failed => [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close')),
            FilledButton(onPressed: _start, child: const Text('Retry')),
          ],
      },
    );
  }
}
