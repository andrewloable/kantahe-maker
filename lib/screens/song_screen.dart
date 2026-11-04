import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../ai_timing.dart';
import '../app_dirs.dart';
import '../autofill.dart';
import '../export.dart';
import '../fs_retry.dart';
import '../jobs.dart';
import '../karmp3.dart' show LrcLine, karMp3Name;
import '../lyrics_lookup.dart';
import '../mp3_info.dart';
import '../pipeline.dart';
import '../preview.dart';
import '../project.dart';
import '../settings.dart';
import '../song_info.dart';
import '../spotify_link.dart';
import '../tools.dart';
import '../windows_dialogs.dart';
import '../wizard.dart';
import 'pick_files.dart';
import 'preview_dialog.dart';
import 'tap_screen.dart';
import 'lyrics_search_panel.dart';
import 'song_info_panel.dart';
import 'tools_dialog.dart';

/// The command that shows [path] in the system file manager (a program and its
/// arguments; never run through a shell).
List<String> revealCommand(HostOs os, String path) => switch (os) {
  HostOs.macos => ['open', '-R', path],
  HostOs.windows => ['explorer', '/select,$path'],
  HostOs.linux => ['xdg-open', p.dirname(path)],
};

/// The height below which the timing step scrolls: the tap screen needs about 300 px.
const _minTapHeight = 360.0;

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

/// One song from its input file to an exported .karmp3, as a wizard with one step on
/// screen at a time (see [WizardStep]): reads the song, splits the vocals in the
/// background, takes the details, the lyrics and the taps, and exports. Everything that
/// touches the machine can be replaced in tests.
class SongScreen extends StatefulWidget {
  const SongScreen({
    super.key,
    required this.dir,
    this.ensureToolsFn,
    this.importFn,
    this.separateFn,
    this.durationFn,
    this.sourceFromStemsFn,
    this.pickAudio,
    this.saveLocation,
    this.revealFile,
    this.createPlayer,
    this.lyricsFinder,
    this.songInfoFinder,
    this.songInfoDetailsFn,
    this.tagsFn,
    this.spotifyFinder,
    this.autofill,
    this.loadSettingsFn,
    this.aiTranscribeFn,
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

  /// Makes source.mp3 of a song opened from a .karmp3 by mixing its stems; null means
  /// [makeSourceFromStems].
  final Future<void> Function(
    ToolPaths tools,
    Directory work,
    void Function(String line) onLine,
  )?
  sourceFromStemsFn;

  /// Asks the user for another audio or video file for an opened song; null if they cancel.
  /// Null means the real file dialog.
  final Future<String?> Function()? pickAudio;

  /// Asks where to save the file; null if the user cancels.
  final Future<String?> Function(String suggestedName)? saveLocation;
  final Future<void> Function(String path)? revealFile;
  final TapPlayer Function()? createPlayer;

  /// Looks lyrics up; null means LRCLIB.
  final LyricsFinder? lyricsFinder;

  /// Looks song info up; null means MusicBrainz.
  final SongInfoFinder? songInfoFinder;

  /// The composer and lyricist of a found recording; null means MusicBrainz.
  final Future<({String composer, String lyricist})> Function(
    String recordingId,
  )?
  songInfoDetailsFn;

  /// Reads the title and artist from the input's tags; null means [readTags].
  final Future<({String title, String artist})> Function(
    ToolPaths tools,
    String input,
  )?
  tagsFn;

  /// Reads the song a pasted Spotify link points to; null means [findSpotifyTrack].
  final Future<SpotifyTrack> Function(String link)? spotifyFinder;

  /// Looks up what a Spotify track allows (composer, lyricist, lyrics); null means
  /// [autofillFromSpotify]. The future is the length of the song's audio, null if unknown.
  final Future<AutofillResult> Function(
    SpotifyTrack track,
    Future<double?> audioSeconds,
  )?
  autofill;

  /// Reads the settings (the Cloudflare keys); null means the settings file.
  final Future<AppSettings> Function()? loadSettingsFn;

  /// Sends the audio to the AI and returns the heard words; null means Cloudflare Nova-3.
  final Future<List<HeardWord>> Function(Uint8List audio, AppSettings settings)? aiTranscribeFn;

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

  /// Bumped when the AI replaces the timing, so the tap screen starts again from it.
  int _tapGeneration = 0;
  bool _aiBusy = false;

  /// Cloudflare is set up and was tested working (Settings), so the AI button is shown.
  bool _aiReady = false;

  _Stage _stage = _Stage.checking;
  String _error = '';
  String _lastLine = '';
  bool _hasSource = false;
  bool _hasInstrumental = false;

  /// work/vocals.mp3 exists. Songs separated by version 1.0.x do not have it.
  bool _hasVocals = false;
  ToolPaths? _tools;

  /// The length of the song's audio, measured once the tools and the source are known.
  Future<double?>? _audioLength;
  CancellableJob? _job;
  bool _exporting = false;

  /// Where the last export of this visit was written, for "Show in folder".
  String? _exportedPath;

  /// "Exported" or "Saved", for the line under the Export buttons.
  String _exportedVerb = 'Exported';
  WizardStep _step = WizardStep.song;

  /// The title and artist of the last automatic lyrics search, so coming back to the
  /// Lyrics step does not search the same thing again.
  String? _lastAutoSearch;

  /// The same for the song info search on the Details step.
  String? _lastInfoSearch;

  /// The recording whose composer and lyricist are being fetched after a pick.
  String? _loadingInfoId;

  /// The Spotify link box of the Details step; the link is never saved.
  final _spotifyLink = TextEditingController();

  /// The text the last Spotify lookup was started for, so the same text does not start
  /// another one by itself, and whether one is running.
  String? _spotifyUsed;
  bool _spotifyBusy = false;

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
    _spotifyLink.dispose();
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
    // A song opened from a .karmp3 has no source file to split from, so source.mp3 (the song
    // for the Timing step) is all it needs; a normal song needs source.wav too.
    _hasSource =
        File(_file('source.mp3')).existsSync() &&
        (project.audioFromKarmp3 || File(_file('source.wav')).existsSync());
    _hasInstrumental = File(_file('instrumental.mp3')).existsSync();
    _hasVocals = File(_file('vocals.mp3')).existsSync();
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
      _step = openingStep(_facts);
    });
    unawaited(_refreshAiReady());
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

  /// Reads the song and splits the vocals, doing only what is not done yet.
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
    if (_hasSource) _measureAudio(tools);

    if (_project!.audioFromKarmp3) {
      // The stems are the ones in the .karmp3: nothing is read from a source file and
      // nothing is split. Only source.mp3 may be missing (a file with vocals has no
      // original audio), and that is mixed from the two stems.
      if (!_hasInstrumental) {
        _setStage(
          _Stage.importFailed,
          error: 'The audio of this song is missing',
        );
        return;
      }
      if (!_hasSource) {
        _setStage(_Stage.importing);
        try {
          await (widget.sourceFromStemsFn ?? _defaultSourceFromStems)(
            tools,
            widget.dir,
            _onLine,
          );
        } catch (e) {
          _setStage(_Stage.importFailed, error: '$e');
          return;
        }
        if (!mounted) return;
        setState(() => _hasSource = true);
        _measureAudio(tools);
      }
      _setStage(_Stage.ready);
      return;
    }

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
      _measureAudio(tools);
      unawaited(_prefillFromTags(tools));
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
      _hasVocals = File(_file('vocals.mp3')).existsSync();
      _setStage(_Stage.ready);
      // Someone waiting on the vocals step goes on to the next step that needs them; a
      // user who opened another step is left where they are.
      if (mounted && _step == WizardStep.vocals) {
        setState(() => _step = openingStep(_facts));
      }
    } on SeparationCancelled {
      _restoreFlagsFromDisk();
      _setStage(_Stage.cancelled);
    } catch (e) {
      _restoreFlagsFromDisk();
      _setStage(_Stage.separationFailed, error: '$e');
    } finally {
      if (identical(_job, job)) _job = null;
    }
  }

  /// "Replace the audio...": asks for another audio or video file, tells the user what will
  /// happen, and then reads and splits it as for a new song. The details, lyrics and times
  /// stay; the stems that came with the .karmp3 are deleted.
  Future<void> _pickReplacement() async {
    final String? path;
    try {
      path = await (widget.pickAudio ?? pickAudioFile)();
    } catch (e) {
      _showMessage('Could not open the file dialog: $e');
      return;
    }
    if (path == null || !mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Replace the audio?'),
        content: Text(
          'The song is read from ${p.basename(path!)} and split again (this takes a few '
          'minutes). The details, lyrics and times stay; if the new audio starts or ends '
          'differently, re-tap in Timing.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('replace-audio-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('replace-audio-go'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final project = _project!;
    project.inputPath = path;
    project.audioFromKarmp3 = false;
    project.separator = null;
    try {
      await project.save(widget.dir);
    } catch (e) {
      _showMessage('Could not save: $e');
      return;
    }
    for (final name in ['source.mp3', 'source.wav', 'instrumental.mp3', 'vocals.mp3']) {
      deleteQuietly(File(_file(name)));
    }
    if (!mounted) return;
    setState(() {
      _hasSource = false;
      _hasInstrumental = false;
      _hasVocals = false;
      _audioLength = null;
      _exportedPath = null;
      _step = WizardStep.song;
    });
    unawaited(_runAudio());
  }

  /// Starts measuring the audio (once); the lyrics results are ranked by it. A failure
  /// leaves the length unknown, so the results keep their order.
  // ponytail: only measured when the tools are known this session; a song reopened later is
  // ranked by name only (finding the tools could open the download dialog from the Lyrics step).
  void _measureAudio(ToolPaths tools) {
    _audioLength ??= Future<double?>(() async {
      try {
        return await (widget.durationFn ?? durationSeconds)(
          tools,
          _file('source.mp3'),
        );
      } catch (_) {
        return null;
      }
    });
  }

  /// After a vocal splitting that did not finish: an instrumental made earlier (when the
  /// removal was run again) still counts.
  void _restoreFlagsFromDisk() {
    _hasInstrumental = File(_file('instrumental.mp3')).existsSync();
    _hasVocals = File(_file('vocals.mp3')).existsSync();
  }

  /// For a song made by an older version, which has no vocals.mp3.
  void _runVocalSplittingAgain() {
    setState(() => _hasInstrumental = false);
    unawaited(_runAudio());
  }

  /// Fills a blank title or artist from the file's tags. A typed value is never
  /// replaced, and a failure is ignored: the tags only save some typing.
  Future<void> _prefillFromTags(ToolPaths tools) async {
    final project = _project!;
    bool blank(String s) => oneLine(s).isEmpty;
    if (!blank(project.title) && !blank(project.artist)) return;
    final ({String title, String artist}) tags;
    try {
      tags = await (widget.tagsFn ?? readTags)(tools, project.inputPath);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final title = blank(project.title) && tags.title.isNotEmpty;
    final artist = blank(project.artist) && tags.artist.isNotEmpty;
    if (!title && !artist) return;
    setState(() {
      if (title) _controllers['title']!.text = project.title = tags.title;
      if (artist) _controllers['artist']!.text = project.artist = tags.artist;
    });
    _saveNow();
  }

  static Future<void> _defaultImport(
    ToolPaths t,
    String input,
    Directory work,
    void Function(String) onLine,
  ) => importSong(t, input, work, onLine: onLine);

  static Future<void> _defaultSourceFromStems(
    ToolPaths t,
    Directory work,
    void Function(String) onLine,
  ) => makeSourceFromStems(t, work, onLine: onLine);

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

  // ------------------------------------------------------------------- wizard

  WizardFacts get _facts => WizardFacts(
    project: _project!,
    hasSource: _hasSource,
    hasInstrumental: _hasInstrumental,
    separating: _stage == _Stage.separating,
  );

  void _goTo(WizardStep step) {
    // Typing not saved yet is saved now, so the tap screen gets the new lyric lines
    // before it can be tapped.
    if (_savePending) _saveNow();
    setState(() => _step = step);
    // Settings may have changed since the song was opened.
    if (step == WizardStep.timing) unawaited(_refreshAiReady());
  }

  // ------------------------------------------------------------------- export

  Future<String?> _defaultSaveLocation(String suggestedName) async {
    // Windows: a dialog of its own process, see windows_dialogs.dart.
    if (Platform.isWindows) {
      return showWindowsDialog(
        label: 'Karaoke',
        extensions: const ['karmp3'],
        suggestedName: suggestedName,
      );
    }
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

  /// The suggested name of the exported file.
  static String _fileName(SongProject project) =>
      '${karMp3Name(number: project.number, artist: oneLine(project.artist), title: oneLine(project.title))}.karmp3';

  Future<void> _export() async {
    final project = _project!;
    setState(() => _exporting = true);
    try {
      final chosen = await (widget.saveLocation ?? _defaultSaveLocation)(
        _fileName(project),
      );
      if (chosen == null || chosen.trim().isEmpty) return;
      final dest = exportDestination(chosen, _fileName(project));
      if (!mounted) return;
      await _writeTo(dest, 'Exported');
    } catch (e) {
      _showMessage('Export failed: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// "Preview": plays the song as the export would make it (the song folder's own MP3s) with
  /// the lyrics moving at the times the export writes. Nothing is written.
  Future<void> _showPreview() async {
    final project = _project!;
    final List<LrcLine> lines;
    try {
      lines = previewLines(project);
    } on StateError catch (e) {
      _showMessage('Preview is not possible yet: ${e.message}');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => PreviewDialog(
        title: '${oneLine(project.title)} - ${oneLine(project.artist)}',
        lines: lines,
        instrumentalPath: _file('instrumental.mp3'),
        vocalsPath: project.includeVocals ? _file('vocals.mp3') : null,
        createPlayer: widget.createPlayer,
      ),
    );
  }

  /// "Save over" the file, for a song opened from a .karmp3: after the user confirms, writes the
  /// edited song to the same path, without a Save dialog. The file is replaced only when the
  /// new one is complete (writeKarMp3 writes ".part" and renames), so a failure leaves the old
  /// file as it was; the opened file's audio was copied into the song folder when it was
  /// opened, so nothing reads it meanwhile.
  Future<void> _saveOver() async {
    final path = _project!.karmp3Path!;
    final name = p.basename(path);
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Replace $name?'),
        content: const Text(
          'The file is replaced by the edited song. This cannot be undone.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('save-over-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('save-over-go'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    if (!Directory(p.dirname(path)).existsSync()) {
      _showMessage('The folder of $name is gone; use Export as...');
      return;
    }
    setState(() => _exporting = true);
    try {
      await _writeTo(path, 'Saved');
    } catch (e) {
      _showMessage('Save failed: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Writes the .karmp3 of the song to [dest] and says so ([verb] is "Exported" or "Saved").
  /// Throws what exportKarMp3 throws; the caller shows it.
  Future<void> _writeTo(String dest, String verb) async {
    final project = _project!;
    // The song length comes from ffprobe, which may not be known yet when a finished
    // song was opened.
    final tools = _tools ?? await (widget.ensureToolsFn ?? ensureTools)(context);
    if (!mounted) return;
    if (tools == null) {
      _showMessage('Tools are needed to read the song length.');
      return;
    }
    _tools = tools;
    final instrumental = _file('instrumental.mp3');
    final seconds = await (widget.durationFn ?? durationSeconds)(tools, instrumental);
    await exportKarMp3(project, widget.dir, dest, durationSeconds: seconds);
    if (!mounted) return;
    setState(() {
      _exportedPath = dest;
      _exportedVerb = verb;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$verb ${p.basename(dest)}'),
        // A snackbar with an action stays until dismissed unless persist is off.
        persist: false,
        duration: const Duration(seconds: 3),
        showCloseIcon: true,
        action: SnackBarAction(
          label: 'Show',
          onPressed: () => unawaited((widget.revealFile ?? _defaultReveal)(dest)),
        ),
      ),
    );
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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _project?.audioFromKarmp3 == true
                  ? 'Preparing the song for timing...'
                  : 'Reading the song...',
            ),
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
          ],
        );
      case _Stage.separating:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Splitting vocals...'),
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
            Text('Vocal splitting finished'),
          ],
        );
      case _Stage.importFailed:
        return _problem(
          _project?.audioFromKarmp3 == true
              ? 'Could not prepare the song for timing: $_error'
              : 'Could not read the song: $_error',
          'Retry',
        );
      case _Stage.separationFailed:
        return _problem('Vocal splitting failed: $_error', 'Retry');
      case _Stage.cancelled:
        return _problem('Vocal splitting was cancelled', 'Start again');
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

  /// Puts the lyrics the user picked into the lyrics box, asking first when the box
  /// holds lyrics already.
  Future<void> _pickLyrics(LyricsCandidate picked) async {
    if (_controllers['lyrics']!.text.trim().isNotEmpty) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Replace the current lyrics?'),
          content: const Text(
            'The lyrics in the box are replaced by the ones you picked.',
          ),
          actions: [
            TextButton(
              key: const ValueKey('lyrics-keep'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep'),
            ),
            FilledButton(
              key: const ValueKey('lyrics-replace'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (replace != true || !mounted) return;
    }
    if (picked.synced.isEmpty) {
      _controllers['lyrics']!.text = picked.lyrics;
      _edited((p0) {
        p0.setLyrics(picked.lyrics);
        p0.timingSource = 'tapped';
      });
      return;
    }
    // Lyrics with times: the lines come from the timed version, and so do the times.
    final text = picked.synced.map((l) => l.$2).join('\n');
    _controllers['lyrics']!.text = text;
    _edited((p0) {
      p0.setLyrics(text);
      p0.times = [for (final l in picked.synced) l.$1];
      p0.wordTimes = List.filled(picked.synced.length, null);
      p0.timingSource = 'lrclib';
    });
  }

  /// What the song info search asks for: the typed title and artist, or what the file
  /// name suggests while there is no title yet.
  ({String title, String artist}) _infoQuery(SongProject project) =>
      oneLine(project.title).isNotEmpty
      ? (title: project.title, artist: project.artist)
      : queryFromFileName(project.inputPath);

  Widget _infoPanel(SongProject project) {
    final query = _infoQuery(project);
    // Searches by itself once per query, as the Lyrics step does.
    final key = '${oneLine(query.title)}|${oneLine(query.artist)}';
    final autoSearch = key != _lastInfoSearch;
    if (autoSearch) _lastInfoSearch = key;
    return SongInfoPanel(
      title: query.title,
      artist: query.artist,
      finder: widget.songInfoFinder ?? findSongInfo,
      onPicked: (picked) => unawaited(_pickSongInfo(picked)),
      autoSearch: autoSearch,
      loadingId: _loadingInfoId,
    );
  }

  /// Takes the title and artist of the match the user picked, then the composer and
  /// lyricist where those fields are blank. Without the second part (a failed lookup)
  /// the title and artist still stay.
  Future<void> _pickSongInfo(SongInfoCandidate picked) async {
    _controllers['title']!.text = picked.title;
    _controllers['artist']!.text = picked.artist;
    _edited((p0) {
      p0.title = picked.title;
      p0.artist = picked.artist;
    });
    setState(() => _loadingInfoId = picked.recordingId);
    try {
      final credits = await (widget.songInfoDetailsFn ?? songInfoDetails)(
        picked.recordingId,
      );
      if (!mounted) return;
      final project = _project!;
      final composer =
          oneLine(project.composer).isEmpty && credits.composer.isNotEmpty;
      final lyricist =
          oneLine(project.lyricist).isEmpty && credits.lyricist.isNotEmpty;
      if (composer) _controllers['composer']!.text = credits.composer;
      if (lyricist) _controllers['lyricist']!.text = credits.lyricist;
      _edited((p0) {
        if (composer) p0.composer = credits.composer;
        if (lyricist) p0.lyricist = credits.lyricist;
      });
    } catch (e) {
      _showMessage('Could not get the composer and lyricist: $e');
    } finally {
      if (mounted) setState(() => _loadingInfoId = null);
    }
  }

  /// The Spotify link box and its button, above the song info search.
  Widget _spotifyBox() => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('spotify-link'),
                controller: _spotifyLink,
                decoration: const InputDecoration(
                  labelText: 'Spotify link (optional)',
                  hintText: 'Paste a Spotify song link',
                  border: OutlineInputBorder(),
                ),
                onChanged: _spotifyChanged,
                onSubmitted: (_) => _spotifyGet(),
              ),
            ),
            const SizedBox(width: 8),
            if (_spotifyBusy)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  key: ValueKey('spotify-loading'),
                  strokeWidth: 2,
                ),
              ),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('spotify-get'),
              onPressed: _spotifyBusy ? null : _spotifyGet,
              child: const Text('Get details'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Fills in the details and lyrics from the link (open.spotify.com, '
          'musicbrainz.org, lrclib.net). The audio still comes from your file.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );

  bool _hasSpotifyLink(String text) =>
      spotifyTrackId(text) != null || spotifyShortLink(text) != null;

  /// Pasting a link starts the lookup by itself, once for each text.
  void _spotifyChanged(String text) {
    if (_spotifyBusy || !_hasSpotifyLink(text) || text.trim() == _spotifyUsed) {
      return;
    }
    unawaited(_spotifyRun(text));
  }

  /// The button (and Enter): runs the lookup again, also for the same text.
  void _spotifyGet() {
    final text = _spotifyLink.text;
    if (text.trim().isEmpty || _spotifyBusy) return;
    if (!_hasSpotifyLink(text)) {
      _showMessage('Paste a Spotify song link (open.spotify.com/track/...)');
      return;
    }
    unawaited(_spotifyRun(text));
  }

  Future<void> _spotifyRun(String text) async {
    _spotifyUsed = text.trim();
    setState(() => _spotifyBusy = true);
    try {
      final track = await (widget.spotifyFinder ?? findSpotifyTrack)(text);
      if (!mounted) return;
      final length = await mp3FileSeconds(_file('source.mp3'));
      if (!mounted) return;
      final result = await (widget.autofill ?? autofillFromSpotify)(
        track,
        Future.value(length),
      );
      if (!mounted) return;
      _applySpotify(result);
    } catch (e) {
      _showMessage('Spotify: $e');
    } finally {
      if (mounted) setState(() => _spotifyBusy = false);
    }
  }

  /// Title and artist are replaced (the user pasted the link on purpose); composer, lyricist
  /// and lyrics are filled only where they are blank, so nothing typed is lost.
  void _applySpotify(AutofillResult r) {
    final project = _project!;
    bool blank(String s) => oneLine(s).isEmpty;
    final composer = blank(project.composer) && r.composer.isNotEmpty;
    final lyricist = blank(project.lyricist) && r.lyricist.isNotEmpty;
    final lyrics = _controllers['lyrics']!.text.trim().isEmpty && r.lines.isNotEmpty;
    final text = [for (final l in r.lines) l.$2].join('\n');
    _controllers['title']!.text = r.title;
    _controllers['artist']!.text = r.artist;
    if (composer) _controllers['composer']!.text = r.composer;
    if (lyricist) _controllers['lyricist']!.text = r.lyricist;
    if (lyrics) _controllers['lyrics']!.text = text;
    _edited((p0) {
      p0.title = r.title;
      p0.artist = r.artist;
      if (composer) p0.composer = r.composer;
      if (lyricist) p0.lyricist = r.lyricist;
      if (lyrics) {
        p0.setLyrics(text);
        if (r.timingSource == 'lrclib') {
          p0.times = [for (final l in r.lines) l.$1];
          p0.wordTimes = List.filled(r.lines.length, null);
          p0.timingSource = 'lrclib';
        } else {
          p0.timingSource = 'tapped';
        }
      }
    });
    _showMessage(
      r.note.isEmpty
          ? 'Filled in from Spotify'
          : 'Filled in from Spotify. ${r.note}',
    );
  }

  Widget _lyricsStep(SongProject project) {
    // Searches by itself once per title and artist, and only for an empty box.
    final searchKey = '${oneLine(project.title)}|${oneLine(project.artist)}';
    final autoSearch =
        project.lyricLines().isEmpty && searchKey != _lastAutoSearch;
    if (autoSearch) _lastAutoSearch = searchKey;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LyricsSearchPanel(
          title: project.title,
          artist: project.artist,
          finder: (t, a) async {
            final found = await (widget.lyricsFinder ?? findLyrics)(t, a);
            return rankLyrics(found, t, a, seconds: await _audioLength);
          },
          onPicked: (picked) => unawaited(_pickLyrics(picked)),
          autoSearch: autoSearch,
        ),
        const SizedBox(height: 16),
        _field(
          'lyrics',
          'One lyric line per line',
          (p0, t) => p0.setLyrics(t),
          minLines: 6,
          maxLines: 12,
        ),
      ],
    );
  }

  Widget _timing(SongProject project) {
    if (!_hasSource) {
      return const Text(
        'The song is not ready yet; tapping starts once it has been read.',
      );
    }
    if (_tapLines.isEmpty) {
      return const Text('Add the lyrics above, then tap them here.');
    }
    final blockers = timingBlockers(project);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    blockers.isEmpty
                        ? 'All ${project.lyricLines().length} lines tapped'
                        : blockers.first,
                    key: const ValueKey('timing-status'),
                  ),
                  if (project.timingSource.startsWith('lrclib'))
                    const Text(
                      'These times came with the lyrics from lrclib.net. Play the song and tap again where a line is off.',
                      key: ValueKey('timing-from-lrclib'),
                    ),
                ],
              ),
            ),
            if (_aiReady) ...[
              const SizedBox(width: 12),
              OutlinedButton.icon(
                key: const ValueKey('ai-time'),
                onPressed: _aiBusy ? null : () => unawaited(_autoTime()),
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Auto-time with AI'),
              ),
            ],
          ],
        ),
        if (_aiBusy) const LinearProgressIndicator(key: ValueKey('ai-busy')),
        const SizedBox(height: 8),
        Expanded(child: _tapScreen(project)),
      ],
    );
  }

  static Future<AppSettings> _defaultLoadSettings() async =>
      readSettings(await appSettingsFile());

  static Future<List<HeardWord>> _defaultTranscribe(Uint8List audio, AppSettings settings) =>
      transcribeWords(
        audio,
        accountId: settings.cloudflareAccountId,
        token: settings.cloudflareToken,
      );

  /// Reads the settings to see whether the AI button may be shown. A missing or unreadable
  /// settings file means no.
  Future<void> _refreshAiReady() async {
    bool ready;
    try {
      ready = (await (widget.loadSettingsFn ?? _defaultLoadSettings)()).cloudflareReady;
    } catch (_) {
      ready = false;
    }
    if (mounted && ready != _aiReady) setState(() => _aiReady = ready);
  }

  /// "Auto-time with AI": sends the vocals (after the user agrees) to Cloudflare, shows what
  /// was heard and, if the user agrees again, replaces the timing of all lines.
  Future<void> _autoTime() async {
    final project = _project;
    if (project == null || _aiBusy) return;
    AppSettings settings;
    try {
      settings = await (widget.loadSettingsFn ?? _defaultLoadSettings)();
    } catch (_) {
      settings = const AppSettings();
    }
    if (!mounted) return;
    if (!settings.cloudflareReady) {
      setState(() => _aiReady = false);
      _showMessage('Cloudflare AI is not set up: save and test it in Settings first.');
      return;
    }
    final vocals = _hasVocals;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('ai-consent'),
        title: const Text('Send the audio to Cloudflare?'),
        content: Text(
          vocals
              ? 'The vocals of this song will be sent to Cloudflare Workers AI (Deepgram Nova-3), '
                  'which listens to them and says when each word starts.'
              : 'This song has no separate vocals, so the whole song will be sent to Cloudflare '
                  'Workers AI (Deepgram Nova-3). It works best with the vocals alone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('ai-send'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Send and time'),
          ),
        ],
      ),
    );
    if (agreed != true || !mounted) return;
    final lines = project.lyricLines();
    setState(() => _aiBusy = true);
    try {
      final bytes = await File(_file(vocals ? 'vocals.mp3' : 'source.mp3')).readAsBytes();
      final heard = await (widget.aiTranscribeFn ?? _defaultTranscribe)(bytes, settings);
      final first = alignLyrics(lines, heard);
      final missing = findMissingWords(lines, heard);
      if (!mounted) return;
      setState(() => _aiBusy = false);
      final chosen = await _reviewAi(first, missing);
      if (chosen == null || !mounted) return;
      if (!listEquals(lines, project.lyricLines())) {
        _showMessage('The lyrics changed meanwhile; nothing was applied.');
        return;
      }
      final newLines = withMissingWords(lines, chosen);
      final result = alignLyrics(newLines, heard);
      project.setLyrics(newLines.join('\n'));
      project.times = List.of(result.times);
      project.wordTimes = [for (final w in result.wordTimes) w == null ? null : List.of(w)];
      project.timingSource = 'ai';
      setState(() => _tapGeneration++);
      _saveNow();
      _showMessage('Timed ${result.matched} of ${result.total} words');
    } on AiTimingException catch (e) {
      _showMessage(e.message);
    } catch (e) {
      _showMessage('Automatic timing failed: $e');
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  /// What the AI found, with the missing words it proposes (all ticked). The ticked ones, or
  /// null if the user cancels.
  Future<List<MissingWords>?> _reviewAi(AiTiming found, List<MissingWords> missing) {
    final ticked = List.filled(missing.length, true);
    return showDialog<List<MissingWords>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          key: const ValueKey('ai-review'),
          title: const Text('Apply the AI timing?'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Found ${found.matched} of ${found.total} lyric words in the vocals. '
                      'The times of all lines are replaced, and put '
                      '${(aiLeadSeconds * 1000).round()} ms earlier than sung so singers have '
                      'time to react.'),
                  if (found.unheardLines.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      'No word of ${found.unheardLines.length == 1 ? 'line' : 'lines'} '
                      '${found.unheardLines.map((l) => l + 1).join(', ')} was heard in the '
                      'vocals; the times of ${found.unheardLines.length == 1 ? 'that line are' : 'those lines are'} '
                      'only guesses.',
                    ),
                  ],
                  if (missing.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text('The vocals have words the lyrics do not. Add them?'),
                    for (var i = 0; i < missing.length; i++)
                      CheckboxListTile(
                        key: ValueKey('ai-add-$i'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: ticked[i],
                        onChanged: (v) => setLocal(() => ticked[i] = v ?? false),
                        title: Text(missing[i].text),
                        subtitle: Text(
                          missing[i].wordIndex == 0
                              ? 'as a new line, at ${stampLabel(missing[i].start)}'
                              : 'inside line ${missing[i].line + 1}, at ${stampLabel(missing[i].start)}',
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            FilledButton(
              key: const ValueKey('ai-apply'),
              onPressed: () => Navigator.of(context).pop([
                for (var i = 0; i < missing.length; i++)
                  if (ticked[i]) missing[i],
              ]),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tapScreen(SongProject project) {
    return TapScreen(
      key: ValueKey('${_tapLines.join('\n')}#$_tapGeneration'),
      lines: _tapLines,
      sourcePath: _file('source.mp3'),
      instrumentalPath: _hasInstrumental ? _file('instrumental.mp3') : null,
      initialTimes: project.times,
      initialWordTimes: project.wordTimes,
      initialOffset: project.offset,
      createPlayer: widget.createPlayer,
      onWordTimesChanged: (wordTimes) {
        if (!listEquals(_tapLines, project.lyricLines())) return;
        setState(() {
          project.wordTimes = wordTimes;
          if (project.timingSource == 'ai') project.timingSource = 'ai+tapped';
        });
        _saveNow();
      },
      onChanged: (times, offset) {
        // A tap in the moment between typing and the screen catching up would be
        // matched to the wrong lines: leave it out.
        if (!listEquals(_tapLines, project.lyricLines())) return;
        setState(() {
          project.times = List.of(times);
          project.offset = offset;
          if (project.timingSource == 'lrclib') {
            project.timingSource = 'lrclib+tapped';
          } else if (project.timingSource == 'ai') {
            project.timingSource = 'ai+tapped';
          }
        });
        _saveNow();
      },
    );
  }

  Widget _exportStep(SongProject project, WizardFacts facts) {
    final ready = exportBlockers(
      project,
      instrumentalReady: _hasInstrumental,
      vocalsReady: _hasVocals,
    ).isEmpty;
    // The box is ticked but this song has no vocals file: say why, and offer a fix.
    final needsRerun =
        project.includeVocals &&
        !_hasVocals &&
        _hasInstrumental &&
        _stage != _Stage.separating;
    final exported = _exportedPath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'File name: ${_fileName(project)}',
          key: const ValueKey('export-name'),
        ),
        const SizedBox(height: 12),
        // Each thing still missing, with the way to it.
        for (final step in WizardStep.values.take(WizardStep.export.index))
          if (!stepDone(step, facts))
            Row(
              children: [
                Expanded(
                  child: Text(
                    step == WizardStep.vocals && facts.separating
                        ? 'Split vocals: still running'
                        : '${stepLabel(step)}: not finished',
                  ),
                ),
                TextButton(
                  key: ValueKey('fix-${step.name}'),
                  onPressed: () => _goTo(step),
                  child: Text('Go to ${stepLabel(step)}'),
                ),
              ],
            ),
        const SizedBox(height: 8),
        CheckboxListTile(
          key: const ValueKey('export-vocals'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: project.includeVocals,
          onChanged: (value) =>
              _edited((p0) => p0.includeVocals = value ?? false),
          title: const Text('Include the vocals'),
          subtitle: const Text(
            'A separate, smaller MP3 (48 kbps, mono) so a player can turn the vocals on and off.',
          ),
        ),
        if (needsRerun) ...[
          const Text(
            "This song's vocals were not kept: its vocal splitting ran in an older version. Run it again to include them.",
            key: ValueKey('vocals-missing'),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              key: const ValueKey('vocals-rerun'),
              onPressed: _runVocalSplittingAgain,
              child: const Text('Run vocal splitting again'),
            ),
          ),
        ],
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const ValueKey('export-preview'),
          onPressed: ready && !_exporting ? _showPreview : null,
          icon: const Icon(Icons.play_circle_outline),
          label: const Text('Preview'),
        ),
        const SizedBox(height: 8),
        if (project.karmp3Path != null) ...[
          FilledButton(
            key: const ValueKey('export-save-over'),
            onPressed: ready && !_exporting ? _saveOver : null,
            child: Text('Save over ${p.basename(project.karmp3Path!)}'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const ValueKey('export-as'),
            onPressed: ready && !_exporting ? _export : null,
            child: const Text('Export as...'),
          ),
        ] else
          FilledButton(
            onPressed: ready && !_exporting ? _export : null,
            child: const Text('Export .karmp3'),
          ),
        if (exported != null) ...[
          const SizedBox(height: 16),
          Text(
            '$_exportedVerb ${p.basename(exported)}',
            key: const ValueKey('export-done'),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                key: const ValueKey('export-show'),
                onPressed: () =>
                    unawaited((widget.revealFile ?? _defaultReveal)(exported)),
                child: const Text('Show in folder'),
              ),
              FilledButton(
                key: const ValueKey('wizard-finish'),
                onPressed: () => unawaited(Navigator.of(context).maybePop()),
                child: const Text('Back to songs'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _stepItem(WizardStep step, WizardFacts facts) {
    final scheme = Theme.of(context).colorScheme;
    final current = step == _step;
    final open = canEnter(step, facts);
    return InkWell(
      key: ValueKey('step-${step.name}'),
      onTap: open ? () => _goTo(step) : null,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: current
                  ? scheme.primary
                  : scheme.surfaceContainerHighest,
              foregroundColor: current
                  ? scheme.onPrimary
                  : scheme.onSurfaceVariant,
              child: Text(
                '${step.index + 1}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              stepLabel(step),
              style: TextStyle(
                fontWeight: current ? FontWeight.bold : null,
                color: open ? null : scheme.outline,
              ),
            ),
            if (stepDone(step, facts)) ...[
              const SizedBox(width: 4),
              const Icon(Icons.check_circle, size: 16, color: Colors.green),
            ],
          ],
        ),
      ),
    );
  }

  /// Vocal splitting runs behind the other steps; this line says how it is going.
  Widget? _vocalsStatus() {
    if (_step == WizardStep.vocals) return null;
    final text = switch (_stage) {
      _Stage.separating => 'Splitting vocals... you can keep working',
      _Stage.separationFailed => 'Vocal splitting failed',
      _Stage.cancelled => 'Vocal splitting was cancelled',
      _ => null,
    };
    if (text == null) return null;
    return Container(
      key: const ValueKey('vocals-status'),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(text)),
          TextButton(
            key: const ValueKey('vocals-status-show'),
            onPressed: () => _goTo(WizardStep.vocals),
            child: const Text('Show'),
          ),
        ],
      ),
    );
  }

  Widget _stepContent(SongProject project) {
    Widget scroll(List<Widget> children) =>
        ListView(padding: const EdgeInsets.all(16), children: children);
    switch (_step) {
      case WizardStep.song:
        return scroll([
          if (project.audioFromKarmp3) ...[
            Text('Opened from ${p.basename(project.karmp3Path ?? project.inputPath)}'),
            const SizedBox(height: 4),
            Text(
              'The audio is the one in the file; your changes are saved with Export.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ] else
            Text('File: ${p.basename(project.inputPath)}'),
          const SizedBox(height: 12),
          if (project.audioFromKarmp3) ...[
            OutlinedButton(
              key: const ValueKey('replace-audio'),
              // Not while something is being read or mixed.
              onPressed: _stage == _Stage.checking || _stage == _Stage.importing
                  ? null
                  : _pickReplacement,
              child: const Text('Replace the audio...'),
            ),
            const SizedBox(height: 12),
          ],
          if (_hasSource)
            const Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green),
                SizedBox(width: 8),
                Text('Audio ready'),
              ],
            )
          else
            _audio(),
        ]);
      case WizardStep.vocals:
        return scroll([_audio()]);
      case WizardStep.details:
        return scroll([
          _spotifyBox(),
          _infoPanel(project),
          const SizedBox(height: 16),
          _field('title', 'Title (required)', (p0, t) => p0.title = t),
          _field('artist', 'Artist (required)', (p0, t) => p0.artist = t),
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
          _field('composer', 'Composer (optional)', (p0, t) => p0.composer = t),
          _field('lyricist', 'Lyricist (optional)', (p0, t) => p0.lyricist = t),
        ]);
      case WizardStep.lyrics:
        return scroll([_lyricsStep(project)]);
      case WizardStep.timing:
        // No scrolling: the tap screen gets all the height there is, unless the
        // window is too small for it.
        return LayoutBuilder(
          builder: (context, constraints) =>
              constraints.maxHeight >= _minTapHeight
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: _timing(project),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    height: _minTapHeight,
                    child: _timing(project),
                  ),
                ),
        );
      case WizardStep.export:
        return scroll([_exportStep(project, _facts)]);
    }
  }

  Widget _wizard(SongProject project) {
    final facts = _facts;
    final status = _vocalsStatus();
    final index = _step.index;
    final next = index + 1 < WizardStep.values.length
        ? WizardStep.values[index + 1]
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final step in WizardStep.values) _stepItem(step, facts),
            ],
          ),
        ),
        const Divider(),
        ?status,
        Expanded(child: _stepContent(project)),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              OutlinedButton(
                key: const ValueKey('wizard-back'),
                onPressed: index > 0
                    ? () => _goTo(WizardStep.values[index - 1])
                    : null,
                child: const Text('Back'),
              ),
              const Spacer(),
              if (next != null)
                FilledButton(
                  key: const ValueKey('wizard-next'),
                  onPressed: canEnter(next, facts) ? () => _goTo(next) : null,
                  child: const Text('Next'),
                ),
            ],
          ),
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
          : _wizard(project),
    );
  }
}
