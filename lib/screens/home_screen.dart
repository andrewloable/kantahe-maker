import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../app_dirs.dart';
import '../autofill.dart';
import '../cdp.dart';
import '../fs_retry.dart';
import '../jobs.dart';
import '../karmp3_open.dart';
import '../karmp3_read.dart';
import '../mp3_info.dart';
import '../project.dart';
import '../spotify_link.dart';
import '../tools.dart' show ToolPaths;
import '../widgets/brand_header.dart';
import '../youtube_link.dart';
import '../youtube_rank.dart';
import '../youtube_search.dart';
import '../ytdlp.dart';
import 'pick_files.dart';
import 'settings_screen.dart';
import 'song_screen.dart';
import 'tools_dialog.dart';

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

/// What the Home screen needs from [searchYoutube]: the videos YouTube finds for a query.
typedef YoutubeSearcher =
    Future<List<YoutubeResult>> Function(
      String query, {
      Future<void>? cancel,
      void Function(CdpBrowser browser)? onBrowser,
      void Function(String status)? onStatus,
    });

/// What the Home screen needs from [downloadWithYtDlp]: the MP3 of a YouTube video, saved in
/// a folder, made with the installed [tools].
typedef AudioDownloader =
    Future<File> Function(
      String url,
      Directory into, {
      required ToolPaths tools,
      void Function(String status, int? received, int? total)? onStatus,
      Future<void>? cancel,
    });

/// What the Home screen needs from [readYtDlpInfo]: a YouTube video's info, read with the
/// installed [tools].
typedef VideoInfoReader =
    Future<YoutubeVideo> Function(String url, {required ToolPaths tools, Future<void>? cancel});

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
    this.ensureToolsFn,
    this.youtubeSearch,
    this.audioDownloader,
    this.videoInfo,
    this.autofill,
    this.readClipboard,
    this.onLog,
    this.pickKarMp3,
  });

  /// The folder that holds one sub-folder per song.
  final Future<Directory> Function()? projectsRoot;

  /// Asks the user for an audio or video file; null if they cancel.
  final Future<String?> Function()? pickFile;

  /// Asks the user for a .karmp3 file to open; null if they cancel.
  final Future<String?> Function()? pickKarMp3;

  /// Opens a song. (The song screen replaces the placeholder default.)
  final void Function(BuildContext context, Directory dir)? onOpen;
  final WidgetBuilder? settingsBuilder;
  final DateTime Function()? now;

  /// Reads a pasted Spotify link; null means [findSpotifyTrack].
  final Future<SpotifyTrack> Function(String link)? spotifyFinder;

  /// Gives the installed tools, asking the user to download them first when they are
  /// missing; null (the user said "Not now") means no song from a link. Null means
  /// [ensureTools].
  final Future<ToolPaths?> Function(BuildContext context)? ensureToolsFn;

  /// Searches YouTube for the song; null means [searchYoutube].
  final YoutubeSearcher? youtubeSearch;

  /// Gets the MP3 of a YouTube video; null means [downloadWithYtDlp].
  final AudioDownloader? audioDownloader;

  /// Reads a YouTube video's title, channel and length; null means [readYtDlpInfo].
  final VideoInfoReader? videoInfo;

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

  /// "Open .karmp3": makes a new song from the karaoke file the user picks (the file itself is
  /// not touched), then opens it like any song.
  Future<void> _openKarMp3() async {
    final String? path;
    try {
      path = await (widget.pickKarMp3 ?? pickKarMp3File)();
    } catch (e) {
      _showError('Could not open the file dialog: $e');
      return;
    }
    if (path == null) return;
    final Directory dir;
    try {
      final (made, id) = await _makeSongDir();
      dir = made;
      await openKarMp3(path, dir, id: id);
    } on KarMp3Exception catch (e) {
      // "Could not read <file>: ..." already names the file; the others do not.
      _showError(
        e.message.startsWith('Could not read')
            ? e.message
            : 'Could not open ${p.basename(path)}: ${e.message}',
      );
      return;
    } catch (e) {
      _showError('Could not open ${p.basename(path)}: $e');
      return;
    }
    if (!mounted) return;
    _reload();
    (widget.onOpen ?? _defaultOpen)(context, dir);
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
      path = await (widget.pickFile ?? pickAudioFile)();
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

  static const _noMatch =
      'No official YouTube upload found for this song. Choose an MP3 file, or try again.';

  Future<List<YoutubeResult>> _search(
    String query, {
    Future<void>? cancel,
    void Function(CdpBrowser browser)? onBrowser,
    void Function(String status)? onStatus,
  }) => searchYoutube(
    query,
    cancel: cancel,
    onBrowser: onBrowser,
    onStatus: onStatus,
    onLog: _log,
  );

  Future<File> _download(
    String url,
    Directory into, {
    required ToolPaths tools,
    void Function(String status, int? received, int? total)? onStatus,
    Future<void>? cancel,
  }) => downloadWithYtDlp(
    url,
    into,
    ytDlp: tools.ytDlp!,
    ffmpegDir: p.dirname(tools.ffmpeg),
    onStatus: onStatus,
    cancel: cancel,
    onJob: jobs.track,
    onLog: _log,
  );

  Future<YoutubeVideo> _videoInfo(
    String url, {
    required ToolPaths tools,
    Future<void>? cancel,
  }) => readYtDlpInfo(url, ytDlp: tools.ytDlp!, cancel: cancel, onJob: jobs.track);

  static Future<String?> _clipboard() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  static const _maxClipboardLink = 10000;

  /// The robot icon: makes sure the tools are installed (the download needs yt-dlp and
  /// ffmpeg), asks for a Spotify link, then does everything else by itself.
  Future<void> _newFromSpotify() async {
    // A second click while the first is still starting (or its dialog is open) does nothing.
    if (_robotBusy) return;
    _robotBusy = true;
    try {
      await _robotFlow();
    } finally {
      _robotBusy = false;
    }
  }

  bool _robotBusy = false;

  Future<void> _robotFlow() async {
    final tools = await (widget.ensureToolsFn ?? ensureTools)(context);
    if (tools == null || !mounted) return;
    var initial = '';
    try {
      final text = (await (widget.readClipboard ?? _clipboard)())?.trim() ?? '';
      // A text this long is no song link; looking through it could take a while.
      if (text.length <= _maxClipboardLink && _isSongLink(text)) initial = text;
    } catch (_) {
      // No clipboard: the box starts empty.
    }
    if (!mounted) return;
    // A YouTube link from the clipboard needs no choice: the download starts at once.
    final autoStart = initial.isNotEmpty && _youtubeIn(initial) != null;
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
          autoStart: autoStart,
          onStart: (link) => unawaited(_spotifyFlow(link, job, tools)),
        );
      },
    );
  }

  /// Link to song: read the link, find the song's official upload on YouTube and get its MP3
  /// while the details and lyrics are looked up, and only then make the song. When the
  /// search or the download fails the user may choose a file instead (the details and
  /// lyrics are kept), try again, or give up.
  Future<void> _spotifyFlow(String link, _SpotifyJob job, ToolPaths tools) async {
    Directory? temp;
    final audio = Completer<double?>();
    SpotifyTrack? track;
    // A YouTube link: its own video is downloaded (no search), and its info gives the song.
    final youtube = _youtubeIn(link);
    YoutubeVideo? video;
    Future<AutofillResult>? lookups;
    _log('flow start (${youtube != null ? 'youtube link' : spotifyTrackId(link) != null ? 'track link' : 'short link'})');

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
          path = await (widget.pickFile ?? pickAudioFile)();
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
          if (track == null) {
            if (youtube != null) {
              job.workingOn('Reading the YouTube video...');
              final v = await (widget.videoInfo ?? _videoInfo)(
                youtube,
                tools: tools,
                cancel: job.cancel.future,
              );
              if (job.cancelled) return;
              final song = songFromYoutube(v);
              video = v;
              track = SpotifyTrack(id: v.id, title: song.title, artist: song.artist, seconds: v.seconds);
            } else {
              job.workingOn('Reading the Spotify link...');
              final reading = (widget.spotifyFinder ?? findSpotifyTrack)(link);
              unawaited(reading.then((_) {}, onError: (Object _) {}));
              track = await Future.any<SpotifyTrack?>([
                reading,
                job.cancel.future.then((_) => null),
              ]);
              if (track == null || job.cancelled) return;
            }
            _log('link read: "${track.title}" by "${track.artist}", ${track.seconds.toStringAsFixed(1)} s');
          }
          lookups ??= (widget.autofill ??
              (t, a) => autofillFromSpotify(t, a, onLog: _log))(track, audio.future);
          temp ??= await Directory.systemTemp.createTemp('kantahe_dl');
          final String url;
          if (video != null) {
            url = video.url;
          } else {
            job.workingOn('Searching YouTube...');
            _log('search starts');
            final results = await (widget.youtubeSearch ?? _search)(
              '${track.artist} ${track.title}',
              cancel: job.cancel.future,
              onBrowser: jobs.track,
              onStatus: job.workingOn,
            );
            if (job.cancelled) return;
            final best = rankYoutubeResults(
              results,
              title: track.title,
              artist: track.artist,
              seconds: track.seconds,
            );
            if (best == null) {
              _log('no fitting video among ${results.length}');
              if (await failed(_noMatch)) return;
              continue;
            }
            _log('picked video ${best.videoId} of ${results.length}');
            url = best.url;
          }
          job.workingOn('Downloading the audio...');
          _log('download starts');
          final file = await (widget.audioDownloader ?? _download)(
            url,
            temp,
            tools: tools,
            onStatus: job.progress,
            cancel: job.cancel.future,
          );
          // A cancel that came as the download finished still means no song.
          if (job.cancelled) return;
          final seconds = await mp3FileSeconds(file.path);
          _log('download finished: ${file.lengthSync()} bytes, '
              '${seconds == null ? 'length unknown' : '${seconds.toStringAsFixed(1)} s'}');
          if (!audio.isCompleted) audio.complete(seconds);
          job.workingOn('Creating the song...');
          await _createSpotifySong(await lookups, job, copyFrom: file.path);
          return;
        } on YoutubeSearchException catch (e) {
          if (e.message == 'Cancelled' || job.cancelled) return;
          if (await failed(e.message)) return;
        } on YtDlpException catch (e) {
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
    // Cancel stays possible while the lookups finish ("Creating the song..."): then no song.
    if (job.cancelled) {
      _log('cancelled before the song was made');
      return;
    }
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
            tooltip: 'New song from a Spotify or YouTube link',
            onPressed: _newFromSpotify,
            child: const Icon(Icons.smart_toy_outlined),
          ),
          const SizedBox(width: 12),
          FloatingActionButton.extended(
            key: const ValueKey('open-karmp3'),
            heroTag: 'open-karmp3',
            onPressed: _openKarMp3,
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Open .karmp3'),
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
              child: Text(
                'No songs yet. Click "New song" to start, or "Open .karmp3" to edit a karaoke file.',
              ),
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

bool _isSpotifyLink(String text) => spotifyTrackId(text) != null || spotifyShortLink(text) != null;

/// The YouTube video link in [text], unless it holds a Spotify link (that one wins).
String? _youtubeIn(String text) => _isSpotifyLink(text) ? null : youtubeVideoUrl(text);

/// Whether [text] holds a link the robot can start from.
bool _isSongLink(String text) => _isSpotifyLink(text) || youtubeVideoUrl(text) != null;

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
    this.autoStart = false,
  });

  final _SpotifyJob job;
  final String initialText;
  final void Function(String link) onStart;

  /// Start with [initialText] at once, without waiting for Download.
  final bool autoStart;

  @override
  State<_SpotifyDialog> createState() => _SpotifyDialogState();
}

class _SpotifyDialogState extends State<_SpotifyDialog> {
  static const notice =
      'The song is downloaded from YouTube with yt-dlp. For a Spotify link, a Chrome or Edge '
      'window opens minimized for a few seconds to search YouTube for the official video. '
      'Use it only for songs you have the right to use.';

  late final _link = TextEditingController(text: widget.initialText);

  @override
  void initState() {
    super.initState();
    if (widget.autoStart) WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  bool get _valid => _isSongLink(_link.text);

  void _start() {
    if (!mounted || !_valid || widget.job.working) return;
    widget.job.workingOn(
      _youtubeIn(_link.text) != null ? 'Reading the YouTube video...' : 'Reading the Spotify link...',
    );
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
          title: const Text('New song from a link'),
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
                      labelText: 'Spotify or YouTube link',
                      hintText: 'Paste a Spotify or YouTube song link',
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
