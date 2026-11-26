// yt-dlp, the program that downloads a YouTube video's audio: the argument lists the app
// runs it with, readers for what it prints (a video's info as JSON, progress lines), and
// running it (readYtDlpInfo, downloadWithYtDlp) so that a cancel or a time limit kills it
// and the ffmpeg it starts. Pure Dart: no Flutter imports.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'export.dart' show oneLine;
import 'fs_retry.dart';
import 'jobs.dart';
import 'mp3_info.dart';
import 'pipeline.dart' show killProcessTree;
import 'tools.dart' show ProcessFailure, runLogged;

class YtDlpException implements Exception {
  final String message;
  const YtDlpException(this.message);
  @override
  String toString() => message;
}

/// One YouTube video, as yt-dlp describes it.
class YoutubeVideo {
  final String id, url, title, channel;

  /// The length of the video.
  final double seconds;

  /// YouTube Music's song name and artist, when YouTube has them (often missing).
  final String? track, artist;

  const YoutubeVideo({
    required this.id,
    required this.url,
    required this.title,
    required this.channel,
    required this.seconds,
    this.track,
    this.artist,
  });
}

/// Arguments that print one video's info as JSON. The link comes after `--`, so it is
/// never read as an option.
List<String> ytDlpInfoArgs(String url) => [
  '--no-config',
  '--dump-single-json',
  '--no-playlist',
  '--skip-download',
  '--',
  url,
];

/// Arguments that download the audio of [url] as [outDir]/download.mp3, made by the ffmpeg
/// in [ffmpegDir]. Progress comes as lines `KM downloaded total estimate` (see
/// [parseYtDlpProgress]).
List<String> ytDlpAudioArgs(String url, String outDir, String ffmpegDir) => [
  '--no-config',
  '--no-playlist',
  '--newline',
  '--progress-template',
  'download:KM %(progress.downloaded_bytes)s %(progress.total_bytes)s '
      '%(progress.total_bytes_estimate)s',
  '-f',
  'bestaudio/best',
  '-x',
  '--audio-format',
  'mp3',
  '--audio-quality',
  '0',
  '--ffmpeg-location',
  ffmpegDir,
  '-o',
  p.join(outDir, 'download.%(ext)s'),
  '--',
  url,
];

const _unexpected = YtDlpException('Unexpected answer from yt-dlp');

/// The video in yt-dlp's `--dump-single-json` output. Throws [YtDlpException] when the
/// answer is not what this was written for, never returns made-up data.
YoutubeVideo parseYtDlpInfo(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    throw _unexpected;
  }
  if (decoded is! Map) throw _unexpected;
  final data = decoded;
  String? text(String key) {
    final v = data[key];
    if (v is! String) return null;
    final t = oneLine(v);
    return t.isEmpty ? null : t;
  }

  final id = text('id'), title = text('title'), duration = data['duration'];
  if (id == null || title == null || duration is! num) throw _unexpected;
  return YoutubeVideo(
    id: id,
    url: text('webpage_url') ?? 'https://www.youtube.com/watch?v=$id',
    title: title,
    channel: text('channel') ?? text('uploader') ?? '',
    seconds: duration.toDouble(),
    track: text('track'),
    artist: text('artist'),
  );
}

/// The bytes received so far and the expected total (null when unknown) from one of the
/// progress lines [ytDlpAudioArgs] asks for, or null for any other line. yt-dlp writes NA
/// for a value it does not know; the estimate stands in for an unknown total.
({int received, int? total})? parseYtDlpProgress(String line) {
  final parts = line.trim().split(RegExp(r'\s+'));
  if (parts.length != 4 || parts[0] != 'KM') return null;
  final received = int.tryParse(parts[1]);
  if (received == null) return null;
  final total = int.tryParse(parts[2]) ?? double.tryParse(parts[3])?.round();
  return (received: received, total: total);
}

// ------------------------------------------------------------------- running it

const _cancelled = YtDlpException('Cancelled');
const _tooLong = YtDlpException('yt-dlp took too long. Try again later.');
const _noMp3 = YtDlpException('yt-dlp did not make an MP3');
const _killGrace = Duration(seconds: 2);

/// A running yt-dlp, for the app's job list (jobs.track) so that closing the window ends
/// it. [done] completes when the program has exited, however it ended.
class YtDlpJob implements CancellableJob {
  YtDlpJob._(this._process, this._onCancel) {
    done = _process.exitCode.then((_) {
      _exited = true;
    });
  }

  final Process _process;
  final void Function() _onCancel;
  bool _exited = false;

  /// Whether [cancel] killed the program.
  bool get killed => _killed;
  bool _killed = false;

  @override
  late final Future<void> done;

  /// Kills yt-dlp and everything it started (ffmpeg). Does nothing once it has exited: its
  /// pid may belong to another program by then.
  @override
  void cancel() {
    if (_exited) return;
    _onCancel();
    _killed = true;
    unawaited(killProcessTree(_process, _killGrace));
  }
}

/// The line that explains a failure: the last "ERROR:" line without that word, or else
/// the last line yt-dlp printed.
String _reason(List<String> lines, int exitCode) {
  for (final line in lines.reversed) {
    final t = line.trim();
    if (t.startsWith('ERROR:')) return t.substring(6).trim();
  }
  for (final line in lines.reversed) {
    if (line.trim().isNotEmpty) return line.trim();
  }
  return 'exit code $exitCode';
}

/// Runs yt-dlp with [args], passing each output line to [onLine]. A completed [cancel],
/// [YtDlpJob.cancel] or the [timeout] kills it. Throws [YtDlpException]: 'Cancelled', the
/// time-limit message, or yt-dlp's own reason when it fails.
Future<void> _run(
  String ytDlp,
  List<String> args, {
  required Duration timeout,
  Future<void>? cancel,
  void Function(CancellableJob job)? onJob,
  void Function(String line)? onLine,
  void Function(String step)? log,
}) async {
  var cancelled = false, timedOut = false, over = false;
  Process? running;
  void kill() {
    final proc = running;
    if (proc != null) unawaited(killProcessTree(proc, _killGrace));
  }

  unawaited(cancel?.then((_) {
    // A cancel after the run (the caller's cancel outlives it) kills nothing: the old
    // pid may belong to another program by now.
    if (over) return;
    log?.call('cancel requested');
    cancelled = true;
    kill();
  }, onError: (Object _) {}));
  final timer = Timer(timeout, () {
    log?.call('time limit of ${timeout.inSeconds}s reached');
    timedOut = true;
    kill();
  });
  final lines = <String>[];
  try {
    await runLogged(
      ytDlp,
      args,
      onLine: (line) {
        lines.add(line);
        if (lines.length > 50) lines.removeAt(0);
        onLine?.call(line);
      },
      onStart: (proc) {
        running = proc;
        // runLogged may still wait for output after the exit: no kill from then on.
        unawaited(proc.exitCode.then((_) {
          if (identical(running, proc)) running = null;
        }));
        log?.call('started, pid ${proc.pid}');
        onJob?.call(YtDlpJob._(proc, () => cancelled = true));
        // A cancel or the time limit may have come while the program was starting.
        if (cancelled || timedOut) kill();
      },
    );
  } on ProcessFailure catch (e) {
    if (cancelled) throw _cancelled;
    if (timedOut) throw _tooLong;
    log?.call('failed with exit code ${e.exitCode}');
    throw YtDlpException('yt-dlp could not download this video: ${_reason(lines, e.exitCode)}');
  } on ProcessException catch (e) {
    throw YtDlpException('Could not start yt-dlp: ${e.message}');
  } finally {
    over = true;
    running = null;
    timer.cancel();
  }
  if (cancelled) throw _cancelled;
  if (timedOut) throw _tooLong;
}

/// Reads the info of the video at [url] with the yt-dlp at [ytDlp]. Throws [YtDlpException].
/// yt-dlp's warnings arrive on the same stream as the JSON, so the JSON is the last line that
/// starts with "{".
Future<YoutubeVideo> readYtDlpInfo(
  String url, {
  required String ytDlp,
  Future<void>? cancel,
  void Function(CancellableJob job)? onJob,
  Duration timeout = const Duration(seconds: 60),
}) async {
  var json = '';
  await _run(
    ytDlp,
    ytDlpInfoArgs(url),
    timeout: timeout,
    cancel: cancel,
    onJob: onJob,
    onLine: (line) {
      if (line.trimLeft().startsWith('{')) json = line;
    },
  );
  return parseYtDlpInfo(json);
}

/// Downloads the audio of the video at [url] as [into]/download.mp3 (made by the ffmpeg in
/// [ffmpegDir]) and returns it. [onStatus] hears 'Downloading the audio...' with the bytes so
/// far and the total, then 'Making the MP3...'. [onJob] gets the running program for the
/// app's job list. [onLog] gets one line per step, never song text. Throws [YtDlpException];
/// whatever happens, nothing but a good download.mp3 is left in [into] by yt-dlp.
Future<File> downloadWithYtDlp(
  String url,
  Directory into, {
  required String ytDlp,
  required String ffmpegDir,
  void Function(String status, int? received, int? total)? onStatus,
  Future<void>? cancel,
  void Function(CancellableJob job)? onJob,
  void Function(String line)? onLog,
  Duration timeout = const Duration(minutes: 10),
}) async {
  final clock = Stopwatch()..start();
  void log(String step) {
    final seconds = (clock.elapsedMilliseconds / 1000).toStringAsFixed(1);
    onLog?.call('ytdlp +${seconds}s $step');
  }

  final dest = File(p.join(into.path, 'download.mp3'));
  void cleanUp({required bool keepMp3}) {
    for (final entry in into.listSync()) {
      if (!p.basename(entry.path).startsWith('download.')) continue;
      if (keepMp3 && entry.path == dest.path) continue;
      deleteQuietly(entry);
    }
  }

  log('start, time limit ${timeout.inSeconds}s');
  var ok = false;
  try {
    var making = false;
    await _run(
      ytDlp,
      ytDlpAudioArgs(url, into.path, ffmpegDir),
      timeout: timeout,
      cancel: cancel,
      onJob: onJob,
      log: log,
      onLine: (line) {
        final progress = parseYtDlpProgress(line);
        if (progress != null) {
          onStatus?.call('Downloading the audio...', progress.received, progress.total);
        } else if (!making && line.startsWith('[ExtractAudio]')) {
          making = true;
          log('making the MP3');
          onStatus?.call('Making the MP3...', null, null);
        }
      },
    );
    if (!dest.existsSync()) throw _noMp3;
    final length = dest.lengthSync();
    final reader = dest.openSync();
    final List<int> head;
    try {
      head = readMp3Head(reader);
    } finally {
      reader.closeSync();
    }
    final info = readMp3Info(head);
    log('file: $length bytes, ${info == null ? 'not an MP3' : describeMp3(info)}');
    if (length > 50 * 1024 * 1024 || info == null) throw _noMp3;
    ok = true;
    log('done');
    return dest;
  } catch (e) {
    log('failed: $e');
    rethrow;
  } finally {
    cleanUp(keepMp3: ok);
  }
}
