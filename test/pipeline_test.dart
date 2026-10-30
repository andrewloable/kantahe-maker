import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/pipeline.dart';
import 'package:kantahe_maker/tool_pins.dart';
import 'package:kantahe_maker/tools.dart';

import 'support/windows_safe.dart';

/// True if [seq] appears in [list] as consecutive elements.
bool hasSeq(List<String> list, List<String> seq) {
  for (var i = 0; i + seq.length <= list.length; i++) {
    if (list.sublist(i, i + seq.length).join('\u0000') == seq.join('\u0000')) {
      return true;
    }
  }
  return false;
}

void main() {
  group('ffprobe args', () {
    test('probe_codec_args', () {
      final a = probeCodecArgs('in put.mp4');
      expect(hasSeq(a, ['-select_streams', 'a:0']), isTrue);
      expect(hasSeq(a, ['-show_entries', 'stream=codec_name']), isTrue);
      expect(hasSeq(a, ['-of', 'csv=p=0']), isTrue);
      expect(a.last, 'in put.mp4');
    });
    test('duration_args', () {
      final a = durationArgs('s.mp3');
      expect(hasSeq(a, ['-show_entries', 'format=duration']), isTrue);
      expect(hasSeq(a, ['-of', 'csv=p=0']), isTrue);
      expect(a.last, 's.mp3');
    });
  });

  group('ffmpeg args', () {
    test('args_copy', () {
      final a = sourceMp3Args('in put.mp4', 'o.mp3', copy: true);
      expect(hasSeq(a, ['-c:a', 'copy']), isTrue);
      expect(a.sublist(a.length - 3), ['-f', 'mp3', 'o.mp3']);
      expect(
        a.where((x) => x == 'in put.mp4'),
        hasLength(1),
        reason: 'a path with a space is ONE argument',
      );
      expect(hasSeq(a, ['-i', 'in put.mp4']), isTrue);
    });
    test('args_encode', () {
      final a = sourceMp3Args('in.mp4', 'o.mp3', copy: false);
      expect(hasSeq(a, ['-c:a', 'libmp3lame', '-q:a', '2']), isTrue);
      expect(a, isNot(contains('copy')));
    });
    test('args_use_first_audio_stream_only', () {
      for (final a in [
        sourceMp3Args('i', 'o', copy: true),
        sourceMp3Args('i', 'o', copy: false),
        sourceWavArgs('i', 'o'),
      ]) {
        expect(a, contains('-vn'));
        expect(hasSeq(a, ['-map', '0:a:0']), isTrue);
        expect(a.first, '-y', reason: 'overwrite without asking');
      }
    });
    test('args_wav', () {
      final a = sourceWavArgs('in.mp4', 'o.wav');
      expect(hasSeq(a, ['-ar', '44100']), isTrue);
      expect(hasSeq(a, ['-ac', '2']), isTrue);
      expect(hasSeq(a, ['-c:a', 'pcm_s16le']), isTrue);
      expect(a.sublist(a.length - 3), ['-f', 'wav', 'o.wav']);
    });
    test('args_encode_instrumental', () {
      final a = encodeInstrumentalArgs('i.wav', 'o.mp3');
      expect(hasSeq(a, ['-b:a', '192k']), isTrue);
      expect(hasSeq(a, ['-map_metadata', '-1']), isTrue);
      expect(hasSeq(a, ['-c:a', 'libmp3lame']), isTrue);
      expect(hasSeq(a, ['-ar', '44100']), isTrue);
      expect(hasSeq(a, ['-ac', '2']), isTrue);
      expect(a.sublist(a.length - 3), ['-f', 'mp3', 'o.mp3']);
    });
  });

  test('args_separate', () {
    final a = separateArgs('/w/source.wav', '/w/sep', '/t/models');
    expect(a.first, '/w/source.wav');
    expect(hasSeq(a, ['--model_filename', separatorModel]), isTrue);
    expect(hasSeq(a, ['--model_file_dir', '/t/models']), isTrue);
    expect(hasSeq(a, ['--output_dir', '/w/sep']), isTrue);
    expect(hasSeq(a, ['--output_format', 'WAV']), isTrue);
    expect(hasSeq(a, ['--single_stem', singleStemInstrumental]), isTrue);
  });

  test('is_mp3', () {
    expect(isMp3Codec('mp3\n'), isTrue);
    expect(isMp3Codec('MP3'), isTrue);
    expect(isMp3Codec('aac'), isFalse);
    expect(isMp3Codec(''), isFalse);
    expect(isMp3Codec('mp3float'), isFalse);
  });

  group('findInstrumental', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('pipe_fi'));
    tearDown(() => tmp.deleteSync(recursive: true));
    File touch(String name) =>
        File('${tmp.path}/$name')..writeAsStringSync('x');

    test('find_instrumental', () {
      touch('song_(Instrumental)_UVR.wav');
      touch('notes.txt');
      expect(
        findInstrumental(tmp)?.path,
        samePath('${tmp.path}/song_(Instrumental)_UVR.wav'),
      );
      touch('x_instrumental_2.wav');
      expect(
        findInstrumental(tmp),
        isNull,
        reason: 'two candidates is ambiguous',
      );
    });
    test('find_none', () {
      expect(findInstrumental(tmp), isNull);
      touch('song_(Vocals)_UVR.wav');
      expect(findInstrumental(tmp), isNull);
      touch('song_(Instrumental)_UVR.wav'); // control: a match is found
      expect(findInstrumental(tmp), isNotNull);
    });
    test('find_ignores_non_wav_and_directories', () {
      touch('song_(Instrumental).mp3');
      Directory('${tmp.path}/a_(Instrumental).wav').createSync();
      touch('b_(Instrumental).wav');
      expect(
        findInstrumental(tmp)?.path,
        samePath('${tmp.path}/b_(Instrumental).wav'),
      );
    });
    test('find_is_case_insensitive', () {
      touch('SONG_(INSTRUMENTAL).WAV');
      expect(findInstrumental(tmp), isNotNull);
    });
  });

  group('parseDuration', () {
    test('parse_duration', () {
      expect(parseDuration('295.123456\n'), 295.123456);
      expect(parseDuration('  3 '), 3);
    });
    test('parse_duration_bad_input', () {
      for (final bad in ['N/A', '', 'abc', 'NaN', 'Infinity', '-1']) {
        expect(() => parseDuration(bad), throwsFormatException, reason: bad);
      }
    });
  });

  // ------------------------------------------------------------ runners
  final host = parseHost(Platform.version);
  final noTools = ToolsDir('/nonexistent-tools');
  final ffmpegPath = findExecutable(
    'ffmpeg',
    os: host.$1,
    tools: noTools,
    env: Platform.environment,
    extraDirs: defaultExtraDirs(host.$1),
  );
  final ffprobePath = findExecutable(
    'ffprobe',
    os: host.$1,
    tools: noTools,
    env: Platform.environment,
    extraDirs: defaultExtraDirs(host.$1),
  );
  final noFfmpeg = (ffmpegPath == null || ffprobePath == null)
      ? 'ffmpeg not found'
      : false;
  final noSh = Platform.isWindows ? 'needs a POSIX shell' : false;
  final noShOrFfmpeg = Platform.isWindows
      ? 'needs a POSIX shell'
      : (noFfmpeg == false ? false : noFfmpeg);

  ToolPaths realTools({String separator = '/nonexistent/sep'}) => ToolPaths(
    ffmpeg: ffmpegPath ?? '/nonexistent/ffmpeg',
    ffprobe: ffprobePath ?? '/nonexistent/ffprobe',
    separator: separator,
    modelDir: '/nonexistent/models',
  );

  void ff(List<String> args) {
    final r = Process.runSync(ffmpegPath!, ['-v', 'error', '-y', ...args]);
    if (r.exitCode != 0) throw Exception('ffmpeg failed: ${r.stderr}');
  }

  String probe(String file, String entries) =>
      (Process.runSync(ffprobePath!, [
                '-v',
                'error',
                '-show_entries',
                entries,
                '-of',
                'csv=p=0',
                file,
              ]).stdout
              as String)
          .trim();

  Future<void> waitUntil(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final end = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(end)) {
        throw TestFailure('condition not met in $timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  List<String> leftovers(Directory d) => d
      .listSync(recursive: true)
      .map((e) => e.path.substring(d.path.length + 1))
      .where((n) => n.contains('.part.') || n.endsWith('.part'))
      .toList();

  group('importSong', () {
    late Directory tmp;
    late Directory work;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('pipe_imp');
      work = Directory('${tmp.path}/work')..createSync();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    String makeMp4(String path, {bool audio = true}) {
      File(path).parent.createSync(recursive: true);
      ff([
        if (audio) ...['-f', 'lavfi', '-i', 'sine=frequency=440:duration=3'],
        '-f',
        'lavfi',
        '-i',
        'color=c=black:s=64x64:d=3',
        if (audio) ...['-shortest', '-c:a', 'aac'],
        path,
      ]);
      return path;
    }

    test('import_mp4', () async {
      final mp4 = makeMp4('${tmp.path}/test.mp4');
      await importSong(realTools(), mp4, work);
      expect(File('${work.path}/source.mp3').existsSync(), isTrue);
      expect(File('${work.path}/source.wav').existsSync(), isTrue);
      expect(leftovers(work), isEmpty);
      final d = await durationSeconds(realTools(), '${work.path}/source.mp3');
      expect(d, inInclusiveRange(2.9, 3.1));
      expect(
        probe(
          '${work.path}/source.wav',
          'stream=codec_name,sample_rate,channels',
        ),
        'pcm_s16le,44100,2',
      );
    }, skip: noFfmpeg);

    test('import_mp3_copied', () async {
      final mp3 = '${tmp.path}/test.mp3';
      ff([
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=330:duration=3',
        '-c:a',
        'libmp3lame',
        '-b:a',
        '160k',
        mp3,
      ]);
      await importSong(realTools(), mp3, work);
      expect(probe('${work.path}/source.mp3', 'stream=codec_name'), 'mp3');
      final a = File(mp3).lengthSync(),
          b = File('${work.path}/source.mp3').lengthSync();
      expect(
        (a - b).abs() / a,
        lessThan(0.05),
        reason: 'copied, not re-encoded',
      );
      expect(probe('${work.path}/source.mp3', 'stream=bit_rate'), '160000');
    }, skip: noFfmpeg);

    test('import_no_audio', () async {
      final mp4 = makeMp4('${tmp.path}/silent.mp4', audio: false);
      await expectLater(
        importSong(realTools(), mp4, work),
        throwsA(
          isA<ImportException>().having(
            (e) => e.message,
            'message',
            'No audio track in this file',
          ),
        ),
      );
      expect(work.listSync(), isEmpty);
    }, skip: noFfmpeg);

    test('import_path_with_spaces', () async {
      final mp4 = makeMp4('${tmp.path}/a b "c" d/in put.mp4');
      await importSong(realTools(), mp4, work);
      expect(File('${work.path}/source.mp3').existsSync(), isTrue);
      expect(File('${work.path}/source.wav').existsSync(), isTrue);
    }, skip: noFfmpeg);

    test('import_replaces_earlier_files', () async {
      final mp4 = makeMp4('${tmp.path}/test.mp4');
      File('${work.path}/source.mp3').writeAsStringSync('old');
      await importSong(realTools(), mp4, work);
      expect(File('${work.path}/source.mp3').lengthSync(), greaterThan(100));
    }, skip: noFfmpeg);

    test('import_not_a_media_file', () async {
      final junk = File('${tmp.path}/junk.mp4')
        ..writeAsStringSync('this is not media');
      await expectLater(
        importSong(realTools(), junk.path, work),
        throwsA(isA<ProcessFailure>()),
      );
      expect(work.listSync(), isEmpty);
    }, skip: noFfmpeg);

    test('import_ffmpeg_failure_removes_part_file', () async {
      // A fake ffprobe says "aac"; a fake ffmpeg writes half a file and fails.
      final probeFake = _fakeScript(tmp.path, 'ffprobe', 'echo aac');
      final ffmpegFake = _fakeScript(
        tmp.path,
        'ffmpeg',
        r'for last; do :; done; echo partial > "$last"; echo "boom" >&2; exit 1',
      );
      final tools = ToolPaths(
        ffmpeg: ffmpegFake,
        ffprobe: probeFake,
        separator: 'x',
        modelDir: 'm',
      );
      await expectLater(
        importSong(tools, '/some/in.mp4', work),
        throwsA(
          isA<ProcessFailure>().having(
            (e) => e.lastLines,
            'lines',
            contains('boom'),
          ),
        ),
      );
      expect(
        work.listSync(),
        isEmpty,
        reason: 'no .part file and no source files',
      );
    }, skip: noSh);

    test('durationSeconds_reads_ffprobe', () async {
      final fake = _fakeScript(tmp.path, 'ffprobe', 'echo 12.5');
      final tools = ToolPaths(
        ffmpeg: 'x',
        ffprobe: fake,
        separator: 'x',
        modelDir: 'm',
      );
      expect(await durationSeconds(tools, 'any.mp3'), 12.5);
      final bad = _fakeScript(tmp.path, 'ffprobe2', 'echo N/A');
      final tools2 = ToolPaths(
        ffmpeg: 'x',
        ffprobe: bad,
        separator: 'x',
        modelDir: 'm',
      );
      await expectLater(
        durationSeconds(tools2, 'any.mp3'),
        throwsFormatException,
      );
    }, skip: noSh);
  });

  group('separate', () {
    late Directory tmp;
    late Directory work;
    late String sepLog;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('pipe_sep');
      work = Directory('${tmp.path}/work')..createSync();
      File('${work.path}/source.wav').writeAsStringSync('wav');
      sepLog = '${tmp.path}/sep.log';
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    /// A separator that copies [wavFixture] into --output_dir, like the real tool.
    String copyingSeparator(String wavFixture) => _fakeScript(
      tmp.path,
      'sep',
      r'''
echo "$*" >> __LOG__
echo "working"
while [ $# -gt 0 ]; do if [ "$1" = "--output_dir" ]; then out="$2"; fi; shift; done
cp "__WAV__" "$out/x_(Instrumental)_m.wav"
'''
          .replaceAll('__LOG__', sepLog)
          .replaceAll('__WAV__', wavFixture),
    );

    /// A separator that stays alive for a long time, with a child process (sleep).
    String sleepingSeparator(String marker) => _fakeScript(
      tmp.path,
      'sleepsep',
      'echo started >> $sepLog\nsleep $marker\n',
    );

    bool alive(String marker) =>
        Process.runSync('pgrep', ['-f', 'sleep $marker']).exitCode == 0;

    // The outer 8 s limit only keeps a hung job from stalling the run; [within] is an
    // optional upper bound for tests that are about how fast a cancel is.
    Future<void> expectCancelled(SeparationJob job, {Duration? within}) async {
      final sw = Stopwatch()..start();
      await expectLater(
        job.done.timeout(const Duration(seconds: 8)),
        throwsA(isA<SeparationCancelled>()),
      );
      if (within != null) {
        expect(sw.elapsed, lessThan(within), reason: 'cancel took too long');
      }
    }

    /// A job whose SIGKILL fallback comes so late that a cancel which works only
    /// through it makes done time out, instead of passing a little slower.
    SeparationJob patient(ToolPaths t, Directory w) =>
        separate(t, w, killGrace: const Duration(seconds: 30));

    test('separate_success', () async {
      final wav = '${tmp.path}/fixture.wav';
      ff([
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=1',
        '-ac',
        '2',
        '-ar',
        '44100',
        wav,
      ]);
      final lines = <String>[];
      final job = separate(
        realTools(separator: copyingSeparator(wav)),
        work,
        onLine: lines.add,
      );
      await job.done;
      expect(File('${work.path}/instrumental.mp3').existsSync(), isTrue);
      expect(Directory('${work.path}/sep').existsSync(), isFalse);
      expect(leftovers(work), isEmpty);
      expect(lines, contains('working'));
      expect(
        probe(
          '${work.path}/instrumental.mp3',
          'stream=codec_name,sample_rate,channels,bit_rate',
        ),
        'mp3,44100,2,192000',
      );
      final args = File(sepLog).readAsStringSync();
      expect(args, contains('${work.path}/source.wav'));
      expect(args, contains('--single_stem Instrumental'));
    }, skip: noShOrFfmpeg);

    test('separate_cancel', () async {
      const marker = '3000.31';
      final job = patient(
        realTools(separator: sleepingSeparator(marker)),
        work,
      );
      await waitUntil(() => alive(marker)); // the fake separator is running
      job.cancel();
      await expectCancelled(job);
      expect(
        alive(marker),
        isFalse,
        reason: 'the child process must be killed too',
      );
      expect(Directory('${work.path}/sep').existsSync(), isFalse);
      expect(leftovers(work), isEmpty);
      expect(File('${work.path}/instrumental.mp3').existsSync(), isFalse);
    }, skip: noSh);

    test('separate_cancel_during_encode', () async {
      const marker = '3000.32';
      final marked = '${tmp.path}/encode-started';
      final sep = _fakeScript(tmp.path, 'sep', r'''
while [ $# -gt 0 ]; do if [ "$1" = "--output_dir" ]; then out="$2"; fi; shift; done
echo wav > "$out/x_(Instrumental)_m.wav"
''');
      final slowFfmpeg = _fakeScript(
        tmp.path,
        'ffmpeg',
        'touch "$marked"\nsleep $marker\n',
      );
      final job = patient(
        ToolPaths(
          ffmpeg: slowFfmpeg,
          ffprobe: 'x',
          separator: sep,
          modelDir: 'm',
        ),
        work,
      );
      await waitUntil(
        () => File(marked).existsSync(),
      ); // the encode step started
      job.cancel();
      await expectCancelled(job);
      expect(alive(marker), isFalse);
      expect(Directory('${work.path}/sep').existsSync(), isFalse);
      expect(leftovers(work), isEmpty);
    }, skip: noSh);

    test('separate_cancel_right_away', () async {
      const marker = '3000.33';
      final job = patient(
        realTools(separator: sleepingSeparator(marker)),
        work,
      );
      job.cancel();
      await expectCancelled(job);
      expect(alive(marker), isFalse);
      expect(Directory('${work.path}/sep').existsSync(), isFalse);
    }, skip: noSh);

    test('separate_cancel_twice_and_after_done_is_harmless', () async {
      const marker = '3000.34';
      final job = patient(
        realTools(separator: sleepingSeparator(marker)),
        work,
      );
      await waitUntil(() => alive(marker));
      job.cancel();
      job.cancel();
      await expectCancelled(job);
      job.cancel();
    }, skip: noSh);

    test('separate_cancel_at_any_moment_leaves_no_process', () async {
      // Cancelling while the script is still starting used to leave its child
      // (sleep) running: the child was forked after the tree had been listed.
      final rnd = Random(7);
      final leaked = <int>[];
      for (var i = 0; i < 25; i++) {
        final marker = '3001.${(10 + i).toString().padLeft(2, '0')}';
        final w = Directory('${tmp.path}/w$i')..createSync();
        File('${w.path}/source.wav').writeAsStringSync('wav');
        final job = patient(realTools(separator: sleepingSeparator(marker)), w);
        await Future<void>.delayed(Duration(milliseconds: rnd.nextInt(40)));
        job.cancel();
        await expectCancelled(job);
        // A killed sleep can take a moment to go on a busy machine; a leaked one
        // sleeps for about 50 minutes.
        for (var t = 0; t < 20 && alive(marker); t++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (alive(marker)) {
          leaked.add(i);
          Process.runSync('pkill', ['-f', 'sleep $marker']);
        }
      }
      expect(leaked, isEmpty, reason: 'iterations that leaked a child process');
    }, skip: noSh);

    test('separate_cancel_escalates_to_sigkill', () async {
      // A program that ignores SIGTERM must still be ended (SIGKILL after 3 s).
      final ready = '${tmp.path}/ready';
      final sep = _fakeScript(
        tmp.path,
        'trapsep',
        'trap "" TERM\ntouch "$ready"\nwhile true; do sleep 1; done\n',
      );
      final job = separate(
        realTools(separator: sep),
        work,
        killGrace: const Duration(milliseconds: 500),
      );
      try {
        await waitUntil(() => File(ready).existsSync());
        job.cancel();
        await expectCancelled(job, within: const Duration(seconds: 6));
        expect(
          Process.runSync('pgrep', ['-f', sep]).exitCode,
          isNot(0),
          reason: 'the TERM-proof script must be gone',
        );
      } finally {
        Process.runSync('pkill', ['-9', '-f', sep]);
      }
    }, skip: noSh);

    test('separate_kill_grace_is_configurable', () async {
      final ready = '${tmp.path}/ready';
      final sep = _fakeScript(
        tmp.path,
        'trapsep',
        'trap "" TERM\ntouch "$ready"\nwhile true; do sleep 1; done\n',
      );
      final job = separate(
        realTools(separator: sep),
        work,
        killGrace: const Duration(milliseconds: 300),
      );
      try {
        // Only cancel once SIGTERM is being ignored (the trap is installed).
        await waitUntil(() => File(ready).existsSync());
        job.cancel();
        await expectCancelled(job, within: const Duration(seconds: 2));
      } finally {
        Process.runSync('pkill', ['-9', '-f', sep]);
      }
    }, skip: noSh);

    test('separate_failure', () async {
      final sep = _fakeScript(
        tmp.path,
        'sep',
        'echo "model missing" >&2\nexit 2\n',
      );
      final job = separate(realTools(separator: sep), work);
      await expectLater(
        job.done,
        throwsA(
          isA<ProcessFailure>()
              .having((e) => e.exitCode, 'exitCode', 2)
              .having((e) => e.lastLines, 'lines', contains('model missing')),
        ),
      );
      expect(Directory('${work.path}/sep').existsSync(), isFalse);
      expect(leftovers(work), isEmpty);
    }, skip: noSh);

    test('separate_no_instrumental_file', () async {
      final sep = _fakeScript(tmp.path, 'sep', 'exit 0\n');
      final job = separate(realTools(separator: sep), work);
      await expectLater(job.done, throwsStateError);
      expect(Directory('${work.path}/sep').existsSync(), isFalse);
    }, skip: noSh);

    test('separate_ffmpeg_failure_removes_part_file', () async {
      final sep = _fakeScript(tmp.path, 'sep', r'''
while [ $# -gt 0 ]; do if [ "$1" = "--output_dir" ]; then out="$2"; fi; shift; done
echo wav > "$out/x_(Instrumental)_m.wav"
''');
      final badFfmpeg = _fakeScript(
        tmp.path,
        'ffmpeg',
        r'for last; do :; done; echo partial > "$last"; exit 1',
      );
      final job = separate(
        ToolPaths(
          ffmpeg: badFfmpeg,
          ffprobe: 'x',
          separator: sep,
          modelDir: 'm',
        ),
        work,
      );
      await expectLater(job.done, throwsA(isA<ProcessFailure>()));
      expect(leftovers(work), isEmpty);
      expect(Directory('${work.path}/sep').existsSync(), isFalse);
      expect(File('${work.path}/instrumental.mp3').existsSync(), isFalse);
    }, skip: noSh);

    test('separate_removes_stale_sep_folder', () async {
      Directory('${work.path}/sep').createSync();
      File('${work.path}/sep/old_(Instrumental).wav')
          .writeAsStringSync('stale');
      final sep = _fakeScript(tmp.path, 'sep', r'''
while [ $# -gt 0 ]; do if [ "$1" = "--output_dir" ]; then out="$2"; fi; shift; done
echo wav > "$out/new_(Instrumental)_m.wav"
''');
      final badFfmpeg = _fakeScript(
        tmp.path,
        'ffmpeg',
        r'echo "$*" >> __LOG__'.replaceAll('__LOG__', '${tmp.path}/ff.log'),
      );
      final job = separate(
        ToolPaths(
          ffmpeg: badFfmpeg,
          ffprobe: 'x',
          separator: sep,
          modelDir: 'm',
        ),
        work,
      );
      await job.done.catchError((Object _) {});
      expect(
        File('${tmp.path}/ff.log').readAsStringSync(),
        contains('new_(Instrumental)_m.wav'),
        reason: 'the stale file did not make the result ambiguous',
      );
    }, skip: noSh);
  });
}

/// Writes an executable shell script called [name] into [dir] and returns its path.
String _fakeScript(String dir, String name, String body) {
  final file = File('$dir/$name')..writeAsStringSync('#!/bin/sh\n$body\n');
  if (!Platform.isWindows) Process.runSync('chmod', ['+x', file.path]);
  return file.path;
}
