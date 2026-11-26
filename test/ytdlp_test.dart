import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/jobs.dart';
import 'package:kantahe_maker/ytdlp.dart';
import 'package:path/path.dart' as p;

import 'support/windows_safe.dart';

const _url = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';

/// An MP3 whose Info tag says 1000 frames of 1152 samples at 44100 Hz (as in
/// home_screen_test.dart).
List<int> tinyMp3() {
  List<int> u32(int v) => [v >> 24 & 255, v >> 16 & 255, v >> 8 & 255, v & 255];
  return [
    0xFF, 0xFB, 0x70, 0x00, ...List.filled(32, 0),
    ...'Info'.codeUnits, ...u32(3), ...u32(1000), ...u32(313000),
    ...List.filled(100, 0),
  ];
}

String _info(Map<String, Object?> fields) => jsonEncode({
  'id': 'dQw4w9WgXcQ',
  'webpage_url': _url,
  'title': 'Singer - Song (Official Video)',
  'channel': 'SingerVEVO',
  'uploader': 'Uploader Name',
  'duration': 213,
  ...fields,
});

void main() {
  group('arguments', () {
    test('info_args_exact', () {
      expect(ytDlpInfoArgs(_url), [
        '--no-config',
        '--dump-single-json',
        '--no-playlist',
        '--skip-download',
        '--',
        _url,
      ]);
    });

    test('audio_args_exact', () {
      final out = p.join('some dir', 'with space');
      final ffmpegDir = p.join('tools dir', 'bin');
      final args = ytDlpAudioArgs(_url, out, ffmpegDir);
      expect(args, [
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
        p.join(out, 'download.%(ext)s'),
        '--',
        _url,
      ]);
    });

    test('url_comes_right_after_double_dash', () {
      // A "link" that looks like an option must never be read as one.
      const tricky = '--exec=evil';
      for (final args in [ytDlpInfoArgs(tricky), ytDlpAudioArgs(tricky, 'o', 'f')]) {
        expect(args.last, tricky);
        expect(args[args.length - 2], '--');
        expect(args.where((a) => a == '--'), hasLength(1));
      }
    });
  });

  group('parseYtDlpInfo', () {
    test('parse_info_full', () {
      final v = parseYtDlpInfo(_info({'track': ' Song ', 'artist': 'Singer'}));
      expect(v.id, 'dQw4w9WgXcQ');
      expect(v.url, _url);
      expect(v.title, 'Singer - Song (Official Video)');
      expect(v.channel, 'SingerVEVO');
      expect(v.seconds, 213.0);
      expect(v.track, 'Song');
      expect(v.artist, 'Singer');
    });

    test('parse_info_without_track_and_artist', () {
      final v = parseYtDlpInfo(_info({}));
      expect(v.track, isNull);
      expect(v.artist, isNull);
    });

    test('parse_info_uses_uploader_without_channel', () {
      expect(parseYtDlpInfo(_info({'channel': null})).channel, 'Uploader Name');
    });

    test('parse_info_empty_track_is_null', () {
      final v = parseYtDlpInfo(_info({'track': '   ', 'artist': ''}));
      expect(v.track, isNull);
      expect(v.artist, isNull);
    });

    test('parse_info_whitespace_is_collapsed', () {
      expect(parseYtDlpInfo(_info({'title': '  A \n  B  '})).title, 'A B');
    });

    test('parse_info_fractional_duration', () {
      expect(parseYtDlpInfo(_info({'duration': 212.5})).seconds, 212.5);
    });

    test('parse_info_without_webpage_url_builds_it', () {
      expect(parseYtDlpInfo(_info({'webpage_url': null})).url, _url);
    });

    test('parse_info_rejects_bad_json', () {
      Matcher bad() => throwsA(
        isA<YtDlpException>().having((e) => e.message, 'message', 'Unexpected answer from yt-dlp'),
      );
      expect(() => parseYtDlpInfo('not json'), bad());
      expect(() => parseYtDlpInfo('[1, 2]'), bad());
      expect(() => parseYtDlpInfo(_info({'id': null})), bad());
      expect(() => parseYtDlpInfo(_info({'title': '  '})), bad());
      expect(() => parseYtDlpInfo(_info({'duration': '213'})), bad());
      expect(() => parseYtDlpInfo(_info({'duration': null})), bad());
    });
  });

  group('parseYtDlpProgress', () {
    test('parse_progress', () {
      expect(parseYtDlpProgress('KM 10 100 NA'), (received: 10, total: 100));
      expect(parseYtDlpProgress('KM 10 NA 99.6'), (received: 10, total: 100));
      expect(parseYtDlpProgress('KM 10 NA NA'), (received: 10, total: null));
      expect(parseYtDlpProgress('KM 1000 NA 5000.0'), (received: 1000, total: 5000));
      expect(parseYtDlpProgress('[download]   5.0% of 3.00MiB'), isNull);
      expect(parseYtDlpProgress('KM x NA NA'), isNull);
      expect(parseYtDlpProgress('KM'), isNull);
      expect(parseYtDlpProgress(''), isNull);
    });
  });

  // ---------------------------------------------------------------- running yt-dlp
  // A fake yt-dlp (a shell script) stands in for the real one.
  group('running yt-dlp', () {
    final noSh = Platform.isWindows ? 'needs a POSIX shell' : null;
    late Directory tmp, into;
    late File mp3;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('ytdlp_run');
      into = Directory(p.join(tmp.path, 'out dir'))..createSync();
      mp3 = File(p.join(tmp.path, 'tiny.mp3'))..writeAsBytesSync(tinyMp3());
    });
    tearDown(() => deleteTemp(tmp));

    /// Writes the fake yt-dlp. In [body], $OUT is the folder of the -o argument.
    String fake(String body) {
      final f = File(p.join(tmp.path, 'yt-dlp'))
        ..writeAsStringSync('''
#!/bin/sh
out=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-o" ]; then out="\$a"; fi
  prev="\$a"
done
OUT=\$(dirname "\$out")
$body
''');
      Process.runSync('chmod', ['+x', f.path]);
      return f.path;
    }

    test('info_reads_json', () async {
      final exe = fake('''
echo "WARNING: something on stderr" >&2
echo '${_info({'track': 'Song', 'artist': 'Singer'})}'
''');
      final v = await readYtDlpInfo(_url, ytDlp: exe);
      expect(v.id, 'dQw4w9WgXcQ');
      expect(v.track, 'Song');
    }, skip: noSh);

    test('info_without_json_is_unexpected', () async {
      final exe = fake('echo "nothing useful"');
      await expectLater(
        readYtDlpInfo(_url, ytDlp: exe),
        throwsA(isA<YtDlpException>().having((e) => e.message, 'message', 'Unexpected answer from yt-dlp')),
      );
    }, skip: noSh);

    test('info_failure_message', () async {
      final exe = fake('''
echo "[youtube] Extracting URL"
echo "ERROR: [youtube] x: Video unavailable" >&2
exit 1
''');
      await expectLater(
        readYtDlpInfo(_url, ytDlp: exe),
        throwsA(isA<YtDlpException>().having(
          (e) => e.message,
          'message',
          'yt-dlp could not download this video: [youtube] x: Video unavailable',
        )),
      );
    }, skip: noSh);

    test('failure_without_error_line_uses_the_last_line', () async {
      final exe = fake('echo "first"; echo "something broke"; exit 3');
      await expectLater(
        readYtDlpInfo(_url, ytDlp: exe),
        throwsA(isA<YtDlpException>().having(
          (e) => e.message,
          'message',
          'yt-dlp could not download this video: something broke',
        )),
      );
    }, skip: noSh);

    test('download_reports_progress_and_returns_mp3', () async {
      final exe = fake('''
echo "KM 10 100 NA"
echo "KM 100 100 NA"
echo "[ExtractAudio] Destination: \$OUT/download.mp3"
cp "${mp3.path}" "\$OUT/download.mp3"
echo partial > "\$OUT/download.webm.part"
echo x > "\$OUT/download.webm"
''');
      final statuses = <(String, int?, int?)>[];
      final jobs = <CancellableJob>[];
      final file = await downloadWithYtDlp(
        _url,
        into,
        ytDlp: exe,
        ffmpegDir: tmp.path,
        onStatus: (s, r, t) => statuses.add((s, r, t)),
        onJob: jobs.add,
      );
      expect(statuses, [
        ('Downloading the audio...', 10, 100),
        ('Downloading the audio...', 100, 100),
        ('Making the MP3...', null, null),
      ]);
      expect(file.path, p.join(into.path, 'download.mp3'));
      expect(file.readAsBytesSync(), tinyMp3());
      expect(into.listSync().map((e) => p.basename(e.path)), ['download.mp3']);
      expect(jobs, hasLength(1));
      await jobs.single.done.timeout(const Duration(seconds: 5));
    }, skip: noSh);

    test('download_passes_the_arguments', () async {
      final argsFile = p.join(tmp.path, 'args.txt');
      final exe = fake('''
for a in "\$@"; do echo "\$a" >> "$argsFile"; done
cp "${mp3.path}" "\$OUT/download.mp3"
''');
      await downloadWithYtDlp(_url, into, ytDlp: exe, ffmpegDir: p.join(tmp.path, 'ff dir'));
      expect(
        File(argsFile).readAsLinesSync(),
        ytDlpAudioArgs(_url, into.path, p.join(tmp.path, 'ff dir')),
      );
    }, skip: noSh);

    test('download_refuses_non_mp3', () async {
      final exe = fake('echo "not audio" > "\$OUT/download.mp3"');
      await expectLater(
        downloadWithYtDlp(_url, into, ytDlp: exe, ffmpegDir: tmp.path),
        throwsA(isA<YtDlpException>().having((e) => e.message, 'message', 'yt-dlp did not make an MP3')),
      );
      expect(into.listSync(), isEmpty, reason: 'a refused file is not left behind');
    }, skip: noSh);

    test('download_without_file_is_refused', () async {
      final exe = fake('echo "done"');
      await expectLater(
        downloadWithYtDlp(_url, into, ytDlp: exe, ffmpegDir: tmp.path),
        throwsA(isA<YtDlpException>().having((e) => e.message, 'message', 'yt-dlp did not make an MP3')),
      );
    }, skip: noSh);

    test('download_failure_cleans_up', () async {
      final exe = fake('''
echo partial > "\$OUT/download.webm.part"
echo "ERROR: [youtube] x: Sign in to confirm your age" >&2
exit 1
''');
      await expectLater(
        downloadWithYtDlp(_url, into, ytDlp: exe, ffmpegDir: tmp.path),
        throwsA(isA<YtDlpException>().having(
          (e) => e.message,
          'message',
          'yt-dlp could not download this video: [youtube] x: Sign in to confirm your age',
        )),
      );
      expect(into.listSync(), isEmpty);
    }, skip: noSh);

    test('download_cancel_kills', () async {
      final exe = fake('echo started; sleep 30');
      final cancel = Completer<void>();
      final started = Completer<void>();
      final clock = Stopwatch()..start();
      final run = downloadWithYtDlp(
        _url,
        into,
        ytDlp: exe,
        ffmpegDir: tmp.path,
        cancel: cancel.future,
        onJob: (_) => started.complete(),
      );
      await started.future;
      cancel.complete();
      await expectLater(
        run,
        throwsA(isA<YtDlpException>().having((e) => e.message, 'message', 'Cancelled')),
      );
      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
    }, skip: noSh);

    test('job_cancel_kills', () async {
      // The app's job list cancels it when the window closes.
      final exe = fake('sleep 30');
      late CancellableJob job;
      final started = Completer<void>();
      final run = downloadWithYtDlp(
        _url,
        into,
        ytDlp: exe,
        ffmpegDir: tmp.path,
        onJob: (j) {
          job = j;
          started.complete();
        },
      );
      await started.future;
      job.cancel();
      await expectLater(
        run,
        throwsA(isA<YtDlpException>().having((e) => e.message, 'message', 'Cancelled')),
      );
      await job.done.timeout(const Duration(seconds: 5));
    }, skip: noSh);

    test('cancel_after_the_run_kills_nothing', () async {
      // The dialog keeps one cancel for all its runs: a cancel that comes after yt-dlp has
      // exited must not kill its old pid, which may belong to another program by now (km-ojp).
      final exe = fake('cp "${mp3.path}" "\$OUT/download.mp3"');
      final cancel = Completer<void>();
      final logs = <String>[];
      late CancellableJob job;
      await downloadWithYtDlp(
        _url,
        into,
        ytDlp: exe,
        ffmpegDir: tmp.path,
        cancel: cancel.future,
        onLog: logs.add,
        onJob: (j) => job = j,
      );
      await job.done;
      final before = logs.length;
      cancel.complete();
      job.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(logs.skip(before), isEmpty, reason: 'nothing is killed after the run');
      expect(job is YtDlpJob && (job as YtDlpJob).killed, isFalse);
    }, skip: noSh);

    test('download_timeout', () async {
      final exe = fake('sleep 30');
      await expectLater(
        downloadWithYtDlp(
          _url,
          into,
          ytDlp: exe,
          ffmpegDir: tmp.path,
          timeout: const Duration(seconds: 1),
        ),
        throwsA(isA<YtDlpException>().having(
          (e) => e.message,
          'message',
          'yt-dlp took too long. Try again later.',
        )),
      );
    }, skip: noSh);

    test('log_lines_have_no_song_text', () async {
      final exe = fake('''
echo "[download] Destination: Singer - Secret Title.webm"
cp "${mp3.path}" "\$OUT/download.mp3"
''');
      final logs = <String>[];
      await downloadWithYtDlp(_url, into, ytDlp: exe, ffmpegDir: tmp.path, onLog: logs.add);
      expect(logs, isNotEmpty);
      expect(logs.every((l) => l.startsWith('ytdlp +')), isTrue);
      expect(logs.join('\n'), isNot(contains('Secret Title')));
    }, skip: noSh);
  });
}
