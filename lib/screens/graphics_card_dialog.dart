import 'dart:io';

import 'package:flutter/material.dart';

import '../app_dirs.dart';
import '../tool_pins.dart';
import '../tools.dart';

/// Installs the graphics card support of audio-separator, reporting output lines.
typedef GraphicsInstaller = Future<void> Function(void Function(String line) onLine);

/// Installs it for real: audio-separator again with the DirectML extra, which needs the
/// tools to be downloaded already.
Future<void> installGraphicsSupport(void Function(String line) onLine) async {
  final (os, _) = parseHost(Platform.version);
  final dir = await appToolsDir();
  final status = toolStatus(dir, os, Platform.environment);
  final uv = status['uv'];
  if (uv == null || status['audio-separator'] == null) {
    throw StateError('Download the tools first (Download / repair tools), then try again.');
  }
  await installSeparator(uv, dir, os,
      ffmpeg: status['ffmpeg'], graphicsCard: true, onLine: onLine);
}

/// Asks whether to download the graphics card support (nothing is downloaded before the
/// user clicks Download), does it, and returns whether it is installed. [install] can be
/// replaced in tests.
Future<bool> showGraphicsCardDialog(
  BuildContext context, {
  GraphicsInstaller? install,
}) async {
  final done = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _GraphicsCardDialog(install: install ?? installGraphicsSupport),
  );
  return done == true;
}

enum _Phase { ask, working, failed }

class _GraphicsCardDialog extends StatefulWidget {
  final GraphicsInstaller install;
  const _GraphicsCardDialog({required this.install});

  @override
  State<_GraphicsCardDialog> createState() => _GraphicsCardDialogState();
}

class _GraphicsCardDialogState extends State<_GraphicsCardDialog> {
  static const _maxLogLines = 200;

  _Phase _phase = _Phase.ask;
  final List<String> _log = [];
  String _error = '';

  void _onLine(String line) {
    if (!mounted) return;
    setState(() {
      _log.add(line);
      if (_log.length > _maxLogLines) _log.removeAt(0);
    });
  }

  Future<void> _start() async {
    setState(() {
      _phase = _Phase.working;
      _log.clear();
      _error = '';
    });
    try {
      await widget.install(_onLine);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_phase == _Phase.working
          ? 'Downloading graphics card support'
          : 'Use the graphics card?'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: switch (_phase) {
              _Phase.ask => [
                  const Text('Splitting the vocals on the graphics card is much faster. It works '
                      'with NVIDIA, AMD and Intel graphics cards and needs a download first. '
                      'Nothing is downloaded until you click Download. If the graphics card '
                      'cannot be used for a song, the processor is used instead.'),
                  const SizedBox(height: 8),
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('DirectML support for audio-separator'),
                    subtitle: Text('Source: pypi.org  ·  ~${approxSizeMb['graphics card']} MB'
                        '  ·  License: MIT / BSD'),
                  ),
                ],
              _Phase.working => [
                  const Text('Installing. This can take a few minutes.'),
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(),
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
                                style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
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
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Not now')),
            FilledButton(onPressed: _start, child: const Text('Download')),
          ],
        _Phase.working => const [],
        _Phase.failed => [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Close')),
            FilledButton(onPressed: _start, child: const Text('Retry')),
          ],
      },
    );
  }
}
