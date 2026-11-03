import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../app_dirs.dart';
import '../autofill.dart';
import '../cdp.dart';
import '../fs_retry.dart';
import '../jobs.dart';
import '../mp3_info.dart';
import '../project.dart';
import '../spotify_link.dart';
import '../spotsaver.dart';
import '../widgets/brand_header.dart';
import '../windows_dialogs.dart';
import 'settings_screen.dart';
import 'song_screen.dart';

/// One folder of the song list; [project] is null when its project.json cannot be read.
class _Entry {
  final Directory dir;
  final SongProject? project;
  const _Entry(this.dir, this.project);

  String get id => p.basename(dir.path);

  String get title {
    final p0 = project;
    if (p0 == null) return 'Unreadable project';
    if (p0.title.trim().isNotEmpty && p0.artist.trim().isNotEmpty) {
      return '${p0.title.trim()} - ${p0.artist.trim()}';
    }
    return p.basename(p0.inputPath);
  }
}

/// What the Home screen needs from [downloadWithSpotsaver]: the MP3 of a Spotify link, saved
/// in a folder.
typedef SpotifyDownloader =
    Future<File> Function(
      String link,
      Directory into, {
      void Function(String status, int? received, int? total)? onStatus,
      Future<void>? cancel,
      void Function(CdpBrowser browser)? onBrowser,
    });

/// The song list. The seams (everything that touches the machine) have real defaults
/// and can be replaced in tests.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.projectsRoot,
    this.pickFile,
    this.onOpen,
    this.settingsBuilder,
    this.now,
    this.spotifyFinder,
    this.downloader,
    this.autofill,
    this.readClipboard,
    this.onLog,
  });

  /// The folder that holds one sub-folder per song.
  final Future<Directory> Function()? projectsRoot;

  /// Asks the user for an audio or video file; null if they cancel.
  final Future<String?> Function()? pickFile;

  /// Opens a song. (The song screen replaces the placeholder default.)
  final void Function(BuildContext context, Directory dir)? onOpen;
  final WidgetBuilder? settingsBuilder;
  final DateTime Function()? now;

  /// Reads a pasted Spotify link; null means [findSpotifyTrack].
  final Future<SpotifyTrack> Function(String link)? spotifyFinder;

  /// Gets the MP3 of a Spotify link; null means [downloadWithSpotsaver].
  final SpotifyDownloader? downloader;

  /// Looks up composer, lyricist and lyrics of a Spotify track; null means
  /// [autofillFromSpotify].
  final Future<AutofillResult> Function(
    SpotifyTrack track,
    Future<double?> audioSeconds,
  )?
  autofill;

  /// The text on the clipboard; null means the system clipboard.
  final Future<String?> Function()? readClipboard;

  /// Gets the debug log lines of the Spotify flow; null means [debugPrint] (the console of
  /// "flutter run"). The lines never hold song text.
  final void Function(String line)? onLog;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _mediaTypes = XTypeGroup(
    label: 'Audio or video',
    extensions: ['mp3', 'mp4', 'm4a', 'mkv', 'webm', 'wav', 'flac'],
  );

  late Future<List<_Entry>> _entries = _load();

  Future<Directory> _root() => (widget.projectsRoot ?? appProjectsRoot)();

  Future<List<_Entry>> _load() async {
    final dirs = await listProjectDirs(await _root());
    return [for (final dir in dirs) _Entry(dir, await _tryLoad(dir))];
  }

  Future<SongProject?> _tryLoad(Directory dir) async {
    try {
      return await SongProject.load(dir);
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  void _reload() {
    setState(() {
      _entries = _load();
    });
  }

  Future<String?> _defaultPick() async {
    // Windows: a dialog of its own process, see windows_dialogs.dart.
    if (Platform.isWindows) {
      return showWindowsDialog(
        label: _mediaTypes.label!,
        extensions: _mediaTypes.extensions!,
      );
    }
    return (await openFile(acceptedTypeGroups: const [_mediaTypes]))?.path;
  }

  void _defaultOpen(BuildContext context, Directory dir) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => SongScreen(dir: dir)))
        .then((_) {
          if (mounted) _reload(); // the title and artist may have changed
        });
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// The folder (not created yet) and id for a new song.
  Future<(Directory, String)> _makeSongDir() async {
    final root = await _root();
    // Ids are timestamps to the second; never overwrite a song made in the same second.
    final base = newProjectId((widget.now ?? DateTime.now)());
    var id = base;
    for (var n = 2; Directory(p.join(root.path, id)).existsSync(); n++) {
      id = '$base-$n';
    }
    return (Directory(p.join(root.path, id)), id);
  }

  Future<void> _newSong() async {
    final String? path;
    try {
      path = await (widget.pickFile ?? _defaultPick)();
    } catch (e) {
      _showError('Could not open the file dialog: $e');
      return;
    }
    if (path == null) return;
    final Directory dir;
    try {
      final (made, id) = await _makeSongDir();
      dir = made;
      await SongProject(id: id, inputPath: path).save(dir);
    } catch (e) {
      _showError('Could not create the song: $e');
      return;
    }
    if (!mounted) return;
    _reload();
    (widget.onOpen ?? _defaultOpen)(context, dir);
  }

  // ------------------------------------------------------- song from a Spotify link

  void _log(String line) => (widget.onLog ?? debugPrint)('[spotify] $line');

  Future<File> _download(
    String link,
    Directory into, {
    void Function(String status, int? received, int? total)? onStatus,
    Future<void>? cancel,
    void Function(CdpBrowser browser)? onBrowser,
  }) => downloadWithSpotsaver(
    link,
    into,
    onStatus: onStatus,
    cancel: cancel,
    onBrowser: onBrowser,
    onLog: _log,
  );

  static Future<String?> _clipboard() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  /// The robot icon: asks for a Spotify link, then does everything else by itself.
  Future<void> _newFromSpotify() async {
    var initial = '';
    try {
      final text = (await (widget.readClipboard ?? _clipboard)())?.trim() ?? '';
      if (spotifyTrackId(text) != null || spotifyShortLink(text) != null) {
        initial = text;
      }
    } catch (_) {
      // No clipboard: the box starts empty.
    }
    if (!mounted) return;
    final job = _SpotifyJob();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        job.closeDialog = () {
          if (job.closed) return;
          job.closed = true;
          Navigator.of(dialogContext).pop();
        };
        return _SpotifyDialog(
          job: job,
          initialText: initial,
          onStart: (link) => unawaited(_spotifyFlow(link, job)),
        );
      },
    );
  }

  /// Link to song: read the link, get the MP3 while the details and lyrics are looked up,
  /// and only then make the song. When the download fails the user may choose a file
  /// instead (the details and lyrics are kept), try again, or give up.
  Future<void> _spotifyFlow(String link, _SpotifyJob job) async {
    Directory? temp;
    final audio = Completer<double?>();
    SpotifyTrack? track;
    Future<AutofillResult>? lookups;
    _log('flow start (${spotifyTrackId(link) != null ? 'track link' : 'short link'})');

    /// Shows [message] with the user's choices; true when the flow is over.
    Future<bool> failed(String message) async {
      while (true) {
        _log('failed: $message');
        final choice = await job.fail(message, canChoose: track != null);
        _log('user chose: $choice');
        if (choice == 'again') return false;
        if (choice != 'choose') return true;
        final String? path;
        try {
          path = await (widget.pickFile ?? _defaultPick)();
        } catch (e) {
          message = 'Could not open the file dialog: $e';
          continue;
        }
        if (path == null) continue;
        _log('user picked a file: ${p.basename(path)}');
        if (!audio.isCompleted) audio.complete(await mp3FileSeconds(path));
        job.workingOn('Creating the song...');
        try {
          await _createSpotifySong(await lookups!, job, inputPath: path);
          return true;
        } catch (e) {
          message = 'Could not create the song: $e';
        }
      }
    }

    try {
      while (!job.cancelled) {
        try {
          job.workingOn('Reading the Spotify link...');
          if (track == null) {
            final reading = (widget.spotifyFinder ?? findSpotifyTrack)(link);
            unawaited(reading.then((_) {}, onError: (Object _) {}));
            track = await Future.any<SpotifyTrack?>([
              reading,
              job.cancel.future.then((_) => null),
            ]);
            if (track == null || job.cancelled) return;
            _log('link read: "${track.title}" by "${track.artist}", ${track.seconds.toStringAsFixed(1)} s');
          }
          lookups ??= (widget.autofill ??
              (t, a) => autofillFromSpotify(t, a, onLog: _log))(track, audio.future);
          temp ??= await Directory.systemTemp.createTemp('kantahe_dl');
          _log('download starts');
          final file = await (widget.downloader ?? _download)(
            link,
            temp,
            onStatus: job.progress,
            cancel: job.cancel.future,
            onBrowser: jobs.track,
          );
          final seconds = await mp3FileSeconds(file.path);
          _log('download finished: ${file.lengthSync()} bytes, '
              '${seconds == null ? 'length unknown' : '${seconds.toStringAsFixed(1)} s'}');
          if (!audio.isCompleted) audio.complete(seconds);
          job.workingOn('Creating the song...');
          await _createSpotifySong(await lookups, job, copyFrom: file.path);
          return;
        } on SpotsaverException catch (e) {
          if (e.message == 'Cancelled' || job.cancelled) return;
          if (await failed(e.message)) return;
        } catch (e, stack) {
          if (job.cancelled) return;
          _log('unexpected ${e.runtimeType}: $e\n$stack');
          if (await failed('$e')) return;
        }
      }
    } finally {
      _log('flow over${job.cancelled ? ' (cancelled)' : ''}');
      if (!audio.isCompleted) audio.complete(null);
      if (temp != null) deleteQuietly(temp);
      job.closeDialog();
    }
  }

  /// Makes the song folder, with the downloaded MP3 copied into it ([copyFrom]) or pointing
  /// at the file the user chose ([inputPath]), and the details and lyrics from [result].
  /// Closes the dialog, then opens the song.
  Future<void> _createSpotifySong(
    AutofillResult result,
    _SpotifyJob job, {
    String? copyFrom,
    String? inputPath,
  }) async {
    final (dir, id) = await _makeSongDir();
    await dir.create(recursive: true);
    var input = inputPath;
    if (copyFrom != null) {
      input = p.join(dir.path, 'download.mp3');
      await File(copyFrom).copy(input);
    }
    final text = [for (final l in result.lines) l.$2].join('\n');
    final project = SongProject(id: id, inputPath: input!)
      ..title = result.title
      ..artist = result.artist
      ..composer = result.composer
      ..lyricist = result.lyricist;
    if (result.lines.isNotEmpty) {
      project.setLyrics(text);
      if (result.timingSource == 'lrclib') {
        project.times = [for (final l in result.lines) l.$1];
        project.wordTimes = List.filled(result.lines.length, null);
        project.timingSource = 'lrclib';
      }
    }
    await project.save(dir);
    _log('song created: $id, ${result.lines.length} lyric lines, source ${project.timingSource}');
    // The dialog goes first: it is below the song screen once that is open.
    job.closeDialog();
    if (!mounted) return;
    _reload();
    (widget.onOpen ?? _defaultOpen)(context, dir);
    if (result.note.isNotEmpty) _showError(result.note);
  }

  Future<void> _confirmDelete(_Entry entry) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this song project?'),
        content: Text(
          '"${entry.title}" and its audio files will be removed from this '
          'computer. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await retryBusy(() async {
        if (entry.dir.existsSync()) await entry.dir.delete(recursive: true);
      });
    } catch (e) {
      _showError('Could not delete the song: $e');
    }
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const BrandHeader(),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder:
                    widget.settingsBuilder ?? (_) => const SettingsScreen(),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton(
            key: const ValueKey('new-from-spotify'),
            heroTag: 'new-from-spotify',
            tooltip: 'New song from a Spotify link',
            onPressed: _newFromSpotify,
            child: const Icon(Icons.smart_toy_outlined),
          ),
          const SizedBox(width: 12),
          FloatingActionButton.extended(
            heroTag: 'new-song',
            onPressed: _newSong,
            icon: const Icon(Icons.add),
            label: const Text('New song'),
          ),
        ],
      ),
      body: FutureBuilder<List<_Entry>>(
        future: _entries,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Could not read your songs: ${snapshot.error}'),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _reload, child: const Text('Retry')),
                ],
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final entries = snapshot.data!;
          if (entries.isEmpty) {
            return const Center(
              child: Text('No songs yet. Click "New song" to start.'),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              for (final e in entries)
                ListTile(
                  key: ValueKey('project-${e.id}'),
                  title: Text(e.title),
                  subtitle: Text(e.id),
                  onTap: () => (widget.onOpen ?? _defaultOpen)(context, e.dir),
                  trailing: IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _confirmDelete(e),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// What the Spotify dialog shows and what the user chose, for the flow to read.
class _SpotifyJob extends ChangeNotifier {
  /// What the dialog shows: the link box, the progress, or a failure with choices.
  bool working = false, failure = false;
  String status = '';
  int? received, total;
  String message = '';
  bool canChoose = false;

  /// Completes when the user cancels; the download gets it as its cancel future.
  final cancel = Completer<void>();
  Completer<String>? _choice;

  /// Pops the dialog, once; set by the dialog's builder.
  void Function() closeDialog = () {};
  bool closed = false;

  bool get cancelled => cancel.isCompleted;

  void workingOn(String text) {
    working = true;
    failure = false;
    status = text;
    received = total = null;
    notifyListeners();
  }

  void progress(String text, int? receivedBytes, int? totalBytes) {
    status = text;
    received = receivedBytes;
    total = totalBytes;
    notifyListeners();
  }

  /// Shows [text] with the buttons and waits for the click: 'again', 'choose' or 'cancel'.
  Future<String> fail(String text, {required bool canChoose}) {
    working = false;
    failure = true;
    message = text;
    this.canChoose = canChoose;
    final choice = _choice = Completer<String>();
    notifyListeners();
    return choice.future;
  }

  void choose(String what) {
    final choice = _choice;
    if (choice != null && !choice.isCompleted) choice.complete(what);
  }

  void giveUp() {
    if (!cancel.isCompleted) cancel.complete();
    choose('cancel');
    status = 'Cancelling...';
    notifyListeners();
  }
}

/// The robot icon's dialog: the link, the notice, then progress, then (when something
/// fails) the way on.
class _SpotifyDialog extends StatefulWidget {
  const _SpotifyDialog({
    required this.job,
    required this.initialText,
    required this.onStart,
  });

  final _SpotifyJob job;
  final String initialText;
  final void Function(String link) onStart;

  @override
  State<_SpotifyDialog> createState() => _SpotifyDialogState();
}

class _SpotifyDialogState extends State<_SpotifyDialog> {
  static const notice =
      'The song is converted from a YouTube video by spotsaver.net, a service not '
      'connected to Spotify or to Kantahe Maker, in a Chrome or Edge window that opens minimized for a few seconds. '
      'Use it only for songs you have the right to use.';

  late final _link = TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  bool get _valid =>
      spotifyTrackId(_link.text) != null || spotifyShortLink(_link.text) != null;

  void _start() {
    if (!_valid) return;
    widget.job.workingOn('Reading the Spotify link...');
    widget.onStart(_link.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    return ListenableBuilder(
      listenable: job,
      builder: (context, _) {
        final fraction = job.received != null && job.total != null && job.total! > 0
            ? job.received! / job.total!
            : null;
        return AlertDialog(
          key: const ValueKey('spotify-dialog'),
          title: const Text('New song from a Spotify link'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!job.working && !job.failure) ...[
                  TextField(
                    key: const ValueKey('spotify-dialog-link'),
                    controller: _link,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Spotify link',
                      hintText: 'Paste a Spotify song link',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _start(),
                  ),
                  const SizedBox(height: 12),
                  Text(notice, style: Theme.of(context).textTheme.bodySmall),
                ] else if (job.working) ...[
                  Text(job.status, key: const ValueKey('spotify-dialog-status')),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: fraction),
                ] else
                  Text(job.message),
              ],
            ),
          ),
          actions: [
            if (job.failure && job.canChoose)
              TextButton(
                key: const ValueKey('spotify-dialog-choose'),
                onPressed: () => job.choose('choose'),
                child: const Text('Choose an MP3 instead'),
              ),
            if (job.failure)
              TextButton(
                key: const ValueKey('spotify-dialog-again'),
                onPressed: () => job.choose('again'),
                child: const Text('Try again'),
              ),
            TextButton(
              key: const ValueKey('spotify-dialog-cancel'),
              // Before the flow starts there is nothing to wait for.
              onPressed: job.working || job.failure
                  ? (job.cancelled ? null : job.giveUp)
                  : job.closeDialog,
              child: const Text('Cancel'),
            ),
            if (!job.working && !job.failure)
              FilledButton(
                key: const ValueKey('spotify-dialog-download'),
                onPressed: _valid ? _start : null,
                child: const Text('Download'),
              ),
          ],
        );
      },
    );
  }
}
