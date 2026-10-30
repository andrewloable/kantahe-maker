// The audio pipeline: the argument lists for ffprobe, ffmpeg and audio-separator, how
// to read their results, and the functions that run them. Programs are always started
// with an argument list, never a shell string, so paths with spaces and quotes are
// safe. No Flutter imports.
//
// Files of one song (in its work folder):
//   source.mp3        the song with vocals, for playback while tapping the lyrics
//   source.wav        44.1 kHz stereo PCM, the input of vocal removal
//   instrumental.mp3  192 kbps, 44.1 kHz stereo, no metadata: goes into the .karmp3

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'jobs.dart';
import 'tool_pins.dart';
import 'tools.dart';

/// ffprobe: the codec name of the first audio stream, as a single line.
List<String> probeCodecArgs(String input) => [
      '-v', 'error',
      '-select_streams', 'a:0',
      '-show_entries', 'stream=codec_name',
      '-of', 'csv=p=0',
      input,
    ];

/// ffprobe: the duration in seconds, as a single line.
List<String> durationArgs(String file) => [
      '-v', 'error',
      '-show_entries', 'format=duration',
      '-of', 'csv=p=0',
      file,
    ];

/// ffmpeg: the first audio stream as an MP3. With [copy] the MP3 data is copied as it
/// is (no quality loss), otherwise it is encoded at about 190 kbps (-q:a 2).
List<String> sourceMp3Args(String input, String out, {required bool copy}) => [
      '-y', '-i', input, '-vn', '-map', '0:a:0',
      ...(copy ? ['-c:a', 'copy'] : ['-c:a', 'libmp3lame', '-q:a', '2']),
      '-f', 'mp3', out,
    ];

/// ffmpeg: the first audio stream as 44.1 kHz stereo 16-bit PCM in a WAV file.
List<String> sourceWavArgs(String input, String out) => [
      '-y', '-i', input, '-vn', '-map', '0:a:0',
      '-ac', '2', '-ar', '44100', '-c:a', 'pcm_s16le',
      '-f', 'wav', out,
    ];

/// audio-separator: only the instrumental stem, as WAV, written into [outDir].
List<String> separateArgs(String wav, String outDir, String modelDir) => [
      wav,
      '--model_filename', separatorModel,
      '--model_file_dir', modelDir,
      '--output_dir', outDir,
      '--output_format', 'WAV',
      '--single_stem', singleStemInstrumental,
    ];

/// ffmpeg: the separated WAV as the final 192 kbps MP3, without tags.
List<String> encodeInstrumentalArgs(String wav, String out) => [
      '-y', '-i', wav, '-map_metadata', '-1',
      '-c:a', 'libmp3lame', '-b:a', '192k', '-ar', '44100', '-ac', '2',
      '-f', 'mp3', out,
    ];

/// True if ffprobe's codec line says the audio is already MP3.
bool isMp3Codec(String probeStdout) => probeStdout.trim().toLowerCase() == 'mp3';

/// The one WAV in [outDir] whose name contains "instrumental" (any case), or null if
/// there is none or more than one (audio-separator was asked for a single stem, so
/// two would be a surprise). Only files directly in the folder count.
File? findInstrumental(Directory outDir) {
  final matches = outDir
      .listSync(followLinks: false)
      .whereType<File>()
      .where((f) {
    final name = f.uri.pathSegments.last.toLowerCase();
    return name.endsWith('.wav') && name.contains('instrumental');
  }).toList();
  return matches.length == 1 ? matches.single : null;
}

/// ffprobe's duration line as seconds. Throws FormatException for anything that is not
/// a finite, non-negative number (ffprobe prints "N/A" when it cannot tell).
double parseDuration(String stdout) {
  final seconds = double.parse(stdout.trim());
  if (!seconds.isFinite || seconds < 0) {
    throw FormatException('Not a duration', stdout);
  }
  return seconds;
}

// ------------------------------------------------------------------- runners

/// The input cannot be used (for example a video without an audio track).
class ImportException implements Exception {
  final String message;
  ImportException(this.message);

  @override
  String toString() => message;
}

List<String> _lastLines(String text) {
  final lines =
      LineSplitter.split(text).where((l) => l.trim().isNotEmpty).toList();
  return lines.length > 20 ? lines.sublist(lines.length - 20) : lines;
}

/// Runs a program and returns its stdout. A non-zero exit throws [ProcessFailure]
/// with the end of stderr.
Future<String> _capture(String exe, List<String> args) async {
  final r = await Process.run(exe, args);
  if (r.exitCode != 0) {
    throw ProcessFailure(r.exitCode, _lastLines(r.stderr.toString()));
  }
  return r.stdout.toString();
}

void _deleteIfExists(String path) {
  final f = File(path);
  if (f.existsSync()) f.deleteSync();
}

/// Turns [input] (an audio or video file) into work/source.mp3 and work/source.wav.
/// An MP3 is copied as it is; anything else is encoded. Each file is written under a
/// ".part" name and renamed when finished, and the partial files are removed if
/// anything fails. Throws [ImportException] when there is no audio track and
/// [ProcessFailure] when ffprobe or ffmpeg fail.
Future<void> importSong(
  ToolPaths t,
  String input,
  Directory work, {
  void Function(String line)? onLine,
}) async {
  await work.create(recursive: true);
  final codec = await _capture(t.ffprobe, probeCodecArgs(input));
  if (codec.trim().isEmpty) throw ImportException('No audio track in this file');
  final partMp3 = p.join(work.path, 'source.part.mp3');
  final partWav = p.join(work.path, 'source.part.wav');
  try {
    await runLogged(t.ffmpeg, sourceMp3Args(input, partMp3, copy: isMp3Codec(codec)),
        onLine: onLine);
    await runLogged(t.ffmpeg, sourceWavArgs(input, partWav), onLine: onLine);
  } catch (_) {
    _deleteIfExists(partMp3);
    _deleteIfExists(partWav);
    rethrow;
  }
  await File(partMp3).rename(p.join(work.path, 'source.mp3'));
  await File(partWav).rename(p.join(work.path, 'source.wav'));
}

/// The length of an audio file in seconds, from ffprobe.
Future<double> durationSeconds(ToolPaths t, String file) async =>
    parseDuration(await _capture(t.ffprobe, durationArgs(file)));

/// Thrown by [SeparationJob.done] after [SeparationJob.cancel].
class SeparationCancelled implements Exception {
  const SeparationCancelled();

  @override
  String toString() => 'Vocal removal was cancelled';
}

/// Vocal removal running in the background. [done] completes when work/instrumental.mp3
/// exists, or fails with [SeparationCancelled] (after [cancel]), [ProcessFailure] or
/// StateError. Whatever the outcome, work/sep and the partial files are removed.
class SeparationJob implements CancellableJob {
  SeparationJob._(this._t, this._work, this._onLine, this._killGrace) {
    done = _run();
  }

  final ToolPaths _t;
  final Directory _work;
  final void Function(String line)? _onLine;
  final Duration _killGrace;
  @override
  late final Future<void> done;
  bool _cancelled = false;
  Process? _current;

  /// Stops the job: kills the running program and everything it started.
  @override
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final running = _current;
    if (running != null) unawaited(_killTree(running, _killGrace));
  }

  Future<void> _exec(String exe, List<String> args) async {
    if (_cancelled) throw const SeparationCancelled();
    try {
      await runLogged(exe, args, onLine: _onLine, onStart: (proc) {
        _current = proc;
        // cancel() may have come while the program was starting.
        if (_cancelled) unawaited(_killTree(proc, _killGrace));
      });
    } finally {
      _current = null;
    }
  }

  Future<void> _run() async {
    final sep = Directory(p.join(_work.path, 'sep'));
    final partMp3 = p.join(_work.path, 'instrumental.part.mp3');
    try {
      if (sep.existsSync()) sep.deleteSync(recursive: true);
      sep.createSync(recursive: true);
      await _exec(_t.separator,
          separateArgs(p.join(_work.path, 'source.wav'), sep.path, _t.modelDir));
      final instrumental = findInstrumental(sep);
      if (instrumental == null) {
        throw StateError('audio-separator did not produce exactly one instrumental file');
      }
      await _exec(_t.ffmpeg, encodeInstrumentalArgs(instrumental.path, partMp3));
      if (_cancelled) throw const SeparationCancelled();
      await File(partMp3).rename(p.join(_work.path, 'instrumental.mp3'));
    } catch (_) {
      _deleteIfExists(partMp3);
      // A killed program fails with a non-zero exit; that is the cancel, not an error.
      if (_cancelled) throw const SeparationCancelled();
      rethrow;
    } finally {
      if (sep.existsSync()) sep.deleteSync(recursive: true);
    }
  }
}

/// Starts vocal removal for work/source.wav. See [SeparationJob]. After [cancel] a
/// program that does not end by itself gets [killGrace] before it is killed for good.
SeparationJob separate(
  ToolPaths t,
  Directory work, {
  void Function(String line)? onLine,
  Duration killGrace = const Duration(seconds: 3),
}) =>
    SeparationJob._(t, work, onLine, killGrace);

/// Ends [proc] and every process below it. On Windows taskkill does the whole tree.
/// On macOS and Linux the tree is first frozen (SIGSTOP) so nothing in it can start
/// another process while it is being listed, then every process gets SIGTERM, children
/// first; whatever is still alive after [grace] gets SIGKILL.
Future<void> _killTree(Process proc, Duration grace) async {
  if (Platform.isWindows) {
    await Process.run('taskkill', ['/T', '/F', '/PID', '${proc.pid}']);
    return;
  }
  final pids = await _freezeTree(proc.pid);
  for (final pid in pids.reversed) {
    Process.killPid(pid, ProcessSignal.sigterm);
    // A stopped process only sees the signal once it runs again.
    Process.killPid(pid, ProcessSignal.sigcont);
  }
  var exited = false;
  unawaited(proc.exitCode.then((_) => exited = true));
  await Future.any([proc.exitCode, Future<void>.delayed(grace)]);
  if (!exited) {
    for (final pid in pids) {
      Process.killPid(pid, ProcessSignal.sigkill);
    }
  }
}

/// Stops [pid] and all its descendants and returns their ids, parents before children.
Future<List<int>> _freezeTree(int pid) async {
  Process.killPid(pid, ProcessSignal.sigstop);
  final pids = [pid];
  try {
    final r = await Process.run('pgrep', ['-P', '$pid']);
    for (final line in LineSplitter.split(r.stdout.toString())) {
      final child = int.tryParse(line.trim());
      if (child != null) pids.addAll(await _freezeTree(child));
    }
  } on ProcessException {
    // No pgrep: at least the process itself is stopped and ended.
  }
  return pids;
}
