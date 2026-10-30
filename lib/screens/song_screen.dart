import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../export.dart';
import '../jobs.dart';
import '../karmp3.dart' show karMp3Name;
import '../pipeline.dart';
import '../project.dart';
import '../tools.dart';
import 'tap_screen.dart';
import 'tools_dialog.dart';

/// The command that shows [path] in the system file manager (a program and its
/// arguments; never run through a shell).
List<String> revealCommand(HostOs os, String path) => switch (os) {
  HostOs.macos => ['open', '-R', path],
  HostOs.windows => ['explorer', '/select,$path'],
  HostOs.linux => ['xdg-open', p.dirname(path)],
};

enum _Stage {
  checking,
  toolsNeeded,
  importing,
  separating,
  ready,
  importFailed,
  separationFailed,
  cancelled,
}

/// One song from its input file to an exported .karmp3: reads the song, removes the
/// vocals in the background, takes the lyrics and the taps, and exports. Everything that
/// touches the machine can be replaced in tests.
class SongScreen extends StatefulWidget {
  const SongScreen({
    super.key,
    required this.dir,
    this.ensureToolsFn,
    this.importFn,
    this.separateFn,
    this.durationFn,
    this.saveLocation,
    this.revealFile,
    this.createPlayer,
    this.saveDelay = const Duration(milliseconds: 500),
  });

  /// The song's folder (project.json and the audio files).
  final Directory dir;
  final Future<ToolPaths?> Function(BuildContext context)? ensureToolsFn;
  final Future<void> Function(
    ToolPaths tools,
    String input,
    Directory work,
    void Function(String line) onLine,
  )?
  importFn;
  final CancellableJob Function(
    ToolPaths tools,
    Directory work,
    void Function(String line) onLine,
  )?
  separateFn;
  final Future<double> Function(ToolPaths tools, String file)? durationFn;

  /// Asks where to save the file; null if the user cancels.
  final Future<String?> Function(String suggestedName)? saveLocation;
  final Future<void> Function(String path)? revealFile;
  final TapPlayer Function()? createPlayer;

  /// How long typing pauses before it is saved.
  final Duration saveDelay;

  @override
  State<SongScreen> createState() => _SongScreenState();
}

class _SongScreenState extends State<SongScreen> {
  SongProject? _project;
  Object? _loadError;
  final _controllers = <String, TextEditingController>{};
  Timer? _saveTimer;
  bool _savePending = false;
  List<String> _tapLines = const [];

  _Stage _stage = _Stage.checking;
  String _error = '';
  String _lastLine = '';
  bool _hasSource = false;
  bool _hasInstrumental = false;
  ToolPaths? _tools;
  CancellableJob? _job;
  bool _exporting = false;

  String _file(String name) => p.join(widget.dir.path, name);

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void dispose() {
    _job?.cancel();
    _saveTimer?.cancel();
    // Whatever was typed in the last moment is not lost.
    if (_savePending) {
      unawaited(_project?.save(widget.dir).catchError((Object _) {}));
    }
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ------------------------------------------------------------------ loading

  Future<void> _open() async {
    final SongProject project;
    try {
      project = await SongProject.load(widget.dir);
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
      return;
    }
    if (!mounted) return;
    _hasSource =
        File(_file('source.mp3')).existsSync() &&
        File(_file('source.wav')).existsSync();
    _hasInstrumental = File(_file('instrumental.mp3')).existsSync();
    for (final entry in {
      'lyrics': project.lyrics,
      'title': project.title,
      'artist': project.artist,
      'number': project.number?.toString() ?? '',
      'composer': project.composer,
      'lyricist': project.lyricist,
    }.entries) {
      _controllers[entry.key] = TextEditingController(text: entry.value);
    }
    setState(() {
      _project = project;
      _tapLines = project.lyricLines();
    });
    unawaited(_runAudio());
  }

  // -------------------------------------------------------------------- audio

  void _setStage(_Stage stage, {String error = ''}) {
    if (!mounted) return;
    setState(() {
      _stage = stage;
      _error = error;
    });
  }

  void _onLine(String line) {
    if (!mounted || line.trim().isEmpty) return;
    setState(() => _lastLine = line.trim());
  }

  /// Reads the song and removes the vocals, doing only what is not done yet.
  Future<void> _runAudio() async {
    if (_hasSource && _hasInstrumental) {
      _setStage(_Stage.ready);
      return;
    }
    _setStage(_Stage.checking);
    final tools =
        _tools ?? await (widget.ensureToolsFn ?? ensureTools)(context);
    if (!mounted) return;
    if (tools == null) {
      _setStage(_Stage.toolsNeeded);
      return;
    }
    _tools = tools;

    if (!_hasSource) {
      _setStage(_Stage.importing);
      try {
        await (widget.importFn ?? _defaultImport)(
          tools,
          _project!.inputPath,
          widget.dir,
          _onLine,
        );
      } on ImportException catch (e) {
        _setStage(_Stage.importFailed, error: e.message);
        return;
      } catch (e) {
        _setStage(_Stage.importFailed, error: '$e');
        return;
      }
      if (!mounted) return;
      setState(() => _hasSource = true);
    }

    if (_hasInstrumental) {
      _setStage(_Stage.ready);
      return;
    }
    _lastLine = '';
    _setStage(_Stage.separating);
    final job = (widget.separateFn ?? _defaultSeparate)(
      tools,
      widget.dir,
      _onLine,
    );
    _job = job;
    jobs.track(job);
    try {
      await job.done;
      _hasInstrumental = true;
      _setStage(_Stage.ready);
    } on SeparationCancelled {
      _setStage(_Stage.cancelled);
    } catch (e) {
      _setStage(_Stage.separationFailed, error: '$e');
    } finally {
      if (identical(_job, job)) _job = null;
    }
  }

  static Future<void> _defaultImport(
    ToolPaths t,
    String input,
    Directory work,
    void Function(String) onLine,
  ) => importSong(t, input, work, onLine: onLine);

  static CancellableJob _defaultSeparate(
    ToolPaths t,
    Directory work,
    void Function(String) onLine,
  ) => separate(t, work, onLine: onLine);

  // ------------------------------------------------------------------- saving

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _savePending = true;
    _saveTimer = Timer(widget.saveDelay, _saveNow);
  }

  void _saveNow() {
    _saveTimer?.cancel();
    _savePending = false;
    final project = _project;
    if (project == null) return;
    // The tap screen is rebuilt for the new lines only now, not at every keystroke.
    final lines = project.lyricLines();
    if (mounted && !listEquals(lines, _tapLines)) {
      setState(() => _tapLines = lines);
    }
    project
        .save(widget.dir)
        .catchError((Object e) => _showMessage('Could not save: $e'));
  }

  void _edited(void Function(SongProject p) change) {
    change(_project!);
    setState(() {});
    _scheduleSave();
  }

  // ------------------------------------------------------------------- export

  Future<String?> _defaultSaveLocation(String suggestedName) async {
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Karaoke', extensions: ['karmp3']),
      ],
    );
    return location?.path;
  }

  Future<void> _defaultReveal(String path) async {
    final (os, _) = parseHost(Platform.version);
    final command = revealCommand(os, path);
    // explorer.exe exits with 1 even when it worked, so the exit code is not checked.
    await Process.run(command.first, command.sublist(1));
  }

  Future<void> _export() async {
    final project = _project!;
    setState(() => _exporting = true);
    try {
      final name =
          '${karMp3Name(number: project.number, artist: oneLine(project.artist), title: oneLine(project.title))}.karmp3';
      final chosen = await (widget.saveLocation ?? _defaultSaveLocation)(name);
      if (chosen == null) return;
      final dest = chosen.toLowerCase().endsWith('.karmp3')
          ? chosen
          : '$chosen.karmp3';
      if (!mounted) return;
      // The song length comes from ffprobe, which may not be known yet when a finished
      // song was opened.
      final tools =
          _tools ?? await (widget.ensureToolsFn ?? ensureTools)(context);
      if (!mounted) return;
      if (tools == null) {
        _showMessage('Tools are needed to read the song length.');
        return;
      }
      _tools = tools;
      final instrumental = _file('instrumental.mp3');
      final seconds = await (widget.durationFn ?? durationSeconds)(
        tools,
        instrumental,
      );
      await exportKarMp3(project, widget.dir, dest, durationSeconds: seconds);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Exported ${p.basename(dest)}'),
          action: SnackBarAction(
            label: 'Show',
            onPressed: () =>
                unawaited((widget.revealFile ?? _defaultReveal)(dest)),
          ),
        ),
      );
    } catch (e) {
      _showMessage('Export failed: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // --------------------------------------------------------------------- view

  String get _appBarTitle {
    final project = _project;
    if (project == null) return p.basename(widget.dir.path);
    if (project.title.trim().isNotEmpty && project.artist.trim().isNotEmpty) {
      return '${project.title.trim()} - ${project.artist.trim()}';
    }
    return p.basename(project.inputPath);
  }

  Widget _card(String title, Widget child) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          child,
        ],
      ),
    ),
  );

  Widget _audio() {
    switch (_stage) {
      case _Stage.checking:
        return const Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('Checking the tools...'),
          ],
        );
      case _Stage.toolsNeeded:
        return Row(
          children: [
            const Expanded(child: Text('Tools are needed to continue')),
            FilledButton(
              onPressed: () => unawaited(_runAudio()),
              child: const Text('Get tools'),
            ),
          ],
        );
      case _Stage.importing:
        return const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Reading the song...'),
            SizedBox(height: 8),
            LinearProgressIndicator(),
          ],
        );
      case _Stage.separating:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Removing vocals...'),
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Text(
              _lastLine,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => _job?.cancel(),
              child: const Text('Cancel'),
            ),
          ],
        );
      case _Stage.ready:
        return const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green),
            SizedBox(width: 8),
            Text('Vocal removal finished'),
          ],
        );
      case _Stage.importFailed:
        return _problem('Could not read the song: $_error', 'Retry');
      case _Stage.separationFailed:
        return _problem('Vocal removal failed: $_error', 'Retry');
      case _Stage.cancelled:
        return _problem('Vocal removal was cancelled', 'Start again');
    }
  }

  Widget _problem(String message, String button) => Row(
    children: [
      Expanded(child: SelectableText(message)),
      const SizedBox(width: 12),
      FilledButton(
        onPressed: () => unawaited(_runAudio()),
        child: Text(button),
      ),
    ],
  );

  Widget _field(
    String key,
    String label,
    void Function(SongProject p, String text) apply, {
    int minLines = 1,
    int maxLines = 1,
    List<TextInputFormatter>? formatters,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: ValueKey(key),
      controller: _controllers[key],
      minLines: minLines,
      maxLines: maxLines,
      inputFormatters: formatters,
      keyboardType: keyboard,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      onChanged: (text) => _edited((project) => apply(project, text)),
    ),
  );

  Widget _timing(SongProject project) {
    if (!_hasSource) {
      return const Text(
        'The song is not ready yet; tapping starts once it has been read.',
      );
    }
    if (_tapLines.isEmpty) {
      return const Text('Add the lyrics above, then tap them here.');
    }
    return SizedBox(
      height: 560,
      child: TapScreen(
        key: ValueKey(_tapLines.join('\n')),
        lines: _tapLines,
        sourcePath: _file('source.mp3'),
        instrumentalPath: _hasInstrumental ? _file('instrumental.mp3') : null,
        initialTimes: project.times,
        initialWordTimes: project.wordTimes,
        initialOffset: project.offset,
        createPlayer: widget.createPlayer,
        onWordTimesChanged: (wordTimes) {
          if (!listEquals(_tapLines, project.lyricLines())) return;
          setState(() => project.wordTimes = wordTimes);
          _saveNow();
        },
        onChanged: (times, offset) {
          // A tap in the moment between typing and the screen catching up would be
          // matched to the wrong lines: leave it out.
          if (!listEquals(_tapLines, project.lyricLines())) return;
          setState(() {
            project.times = List.of(times);
            project.offset = offset;
          });
          _saveNow();
        },
      ),
    );
  }

  Widget _exportCard(SongProject project) {
    final blockers = exportBlockers(
      project,
      instrumentalReady: _hasInstrumental,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final b in blockers) Text('• $b'),
        if (blockers.isNotEmpty) const SizedBox(height: 8),
        FilledButton(
          onPressed: blockers.isEmpty && !_exporting ? _export : null,
          child: const Text('Export .karmp3'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final project = _project;
    return Scaffold(
      appBar: AppBar(title: Text(_appBarTitle)),
      body: _loadError != null
          ? Center(
              child: SelectableText('Could not open this song: $_loadError'),
            )
          : project == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _card('Audio', _audio()),
                _card(
                  'Lyrics',
                  _field(
                    'lyrics',
                    'One lyric line per line',
                    (p0, t) => p0.setLyrics(t),
                    minLines: 6,
                    maxLines: 12,
                  ),
                ),
                _card('Timing', _timing(project)),
                _card(
                  'Song details',
                  Column(
                    children: [
                      _field(
                        'title',
                        'Title (required)',
                        (p0, t) => p0.title = t,
                      ),
                      _field(
                        'artist',
                        'Artist (required)',
                        (p0, t) => p0.artist = t,
                      ),
                      _field(
                        'number',
                        'Songbook number (optional)',
                        (p0, t) => p0.number = int.tryParse(t),
                        formatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(9),
                        ],
                        keyboard: TextInputType.number,
                      ),
                      _field(
                        'composer',
                        'Composer (optional)',
                        (p0, t) => p0.composer = t,
                      ),
                      _field(
                        'lyricist',
                        'Lyricist (optional)',
                        (p0, t) => p0.lyricist = t,
                      ),
                    ],
                  ),
                ),
                _card('Export', _exportCard(project)),
              ],
            ),
    );
  }
}
