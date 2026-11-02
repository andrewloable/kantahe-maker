import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/mp3_info.dart';
import 'package:kantahe_maker/pipeline.dart';
import 'package:kantahe_maker/tools.dart';

List<int> withHeader(List<int> header, {List<int> before = const []}) => [
  ...before,
  ...header,
  ...List.filled(100, 0),
];

/// A first frame with a Xing or Info tag, as ffmpeg writes it. [frames] and [bytes] are
/// left out of the tag when null. [crc] puts the two CRC bytes after the header.
List<int> tagged(
  List<int> header, {
  String tag = 'Xing',
  int? frames,
  int? bytes,
  bool mono = false,
  bool crc = false,
  List<int> before = const [],
}) {
  List<int> u32(int v) => [v >> 24 & 255, v >> 16 & 255, v >> 8 & 255, v & 255];
  final flags = (frames != null ? 1 : 0) | (bytes != null ? 2 : 0) | 4;
  return [
    ...before,
    ...header,
    ...List.filled((mono ? 17 : 32) + (crc ? 2 : 0), 0),
    ...tag.codeUnits,
    ...u32(flags),
    if (frames != null) ...u32(frames),
    if (bytes != null) ...u32(bytes),
    ...List.filled(100, 0),
  ];
}

void main() {
  test('mp3_info_128', () {
    final i = readMp3Info(withHeader([0xFF, 0xFB, 0x90, 0x00]))!;
    expect((i.kbps, i.hertz, i.channels), (128, 44100, 2));
  });

  test('mp3_info_192', () {
    final i = readMp3Info(withHeader([0xFF, 0xFB, 0xB0, 0x00]))!;
    expect((i.kbps, i.hertz, i.channels), (192, 44100, 2));
  });

  test('mp3_info_mono_64', () {
    final i = readMp3Info(withHeader([0xFF, 0xFB, 0x50, 0xC0]))!;
    expect((i.kbps, i.hertz, i.channels), (64, 44100, 1));
  });

  test('mp3_info_skips_an_id3_tag', () {
    final tag = [
      ...'ID3'.codeUnits, 3, 0, 0, 0x00, 0x00, 0x00, 0x14, // 20 bytes follow
      // The tag holds something that looks like a 128 kbps header (cover art can).
      ...List.filled(5, 0x41), 0xFF, 0xFB, 0x90, 0x00, ...List.filled(11, 0x42),
    ];
    final i = readMp3Info(withHeader([0xFF, 0xFB, 0xB0, 0x00], before: tag))!;
    expect(i.kbps, 192);
  });

  test('mp3_info_other_sampling_rates', () {
    final a = readMp3Info(withHeader([0xFF, 0xFB, 0x94, 0x00]))!;
    expect((a.kbps, a.hertz), (128, 48000));
    final b = readMp3Info(withHeader([0xFF, 0xFB, 0x98, 0x00]))!;
    expect((b.kbps, b.hertz), (128, 32000));
  });

  test('mp3_info_accepts_a_crc_protected_header', () {
    expect(readMp3Info(withHeader([0xFF, 0xFA, 0x90, 0x00]))!.kbps, 128);
  });

  test('mp3_info_search_window', () {
    const h192 = [0xFF, 0xFB, 0xB0, 0x00];
    expect(readMp3Info(withHeader(h192, before: List.filled(100, 0)))!.kbps, 192);
    expect(readMp3Info(withHeader(h192, before: List.filled(1000, 0)))!.kbps, 192);
    expect(readMp3Info(withHeader(h192, before: List.filled(4200, 0))), isNull);
  });

  test('mp3_info_id3_sizes', () {
    const lookAlike = [0xFF, 0xFB, 0x90, 0x00]; // 128 kbps, at the END of the tag
    const real = [0xFF, 0xFB, 0xB0, 0x00]; // 192 kbps, after it
    // A tag of [size] bytes after its 10-byte header: a size that is read too small ends
    // up on the look-alike, one that is read too large skips the real header.
    List<int> tag(List<int> sizeBytes, int size, {int flags = 0, List<int> footer = const []}) => [
      ...'ID3'.codeUnits, 4, 0, flags, ...sizeBytes,
      ...List.filled(size - 4, 0x42), ...lookAlike,
      ...footer,
    ];
    int kbps(List<int> before) => readMp3Info(withHeader(real, before: before))!.kbps;
    expect(kbps(tag([0, 0, 0, 20], 20)), 192, reason: 'lowest size byte');
    expect(kbps(tag([0, 0, 2, 0x2C], 300)), 192, reason: 'size 300 = 2 * 128 + 44');
    expect(kbps(tag([0, 0, 1, 0], 128)), 192, reason: 'size 128');
    expect(kbps(tag([0, 1, 0, 0], 16384)), 192, reason: 'size 2^14');
    expect(kbps(tag([1, 0, 0, 0], 2097152)), 192, reason: 'size 2^21');
    // The footer flag adds 10 bytes ("3DI" ...) that may look like a frame too.
    final footer = [...'3DI'.codeUnits, ...lookAlike, 0, 0, 0];
    expect(footer, hasLength(10));
    expect(kbps(tag([0, 0, 0, 20], 20, flags: 0x10, footer: footer)), 192, reason: 'footer');
  });

  test('mp3_info_unreadable', () {
    expect(readMp3Info([]), isNull);
    expect(readMp3Info([0xFF, 0xFB]), isNull);
    expect(readMp3Info(List.filled(200, 0)), isNull);
    expect(readMp3Info(withHeader([0xFF, 0xFB, 0xF0, 0x00])), isNull, reason: 'bitrate index 15');
    expect(readMp3Info(withHeader([0xFF, 0xF3, 0x90, 0x00])), isNull, reason: 'MPEG-2');
  });

  group('Xing and Info tags', () {
    const h96 = [0xFF, 0xFB, 0x70, 0x00]; // 96 kbps, 44.1 kHz, stereo

    test('xing_gives_the_average_and_says_variable', () {
      // 1000 frames last 26.122 s; 360000 bytes in that time is 110 kbps.
      final i = readMp3Info(tagged(h96, frames: 1000, bytes: 360000))!;
      expect((i.kbps, i.hertz, i.channels, i.variable), (110, 44100, 2, true));
    });

    test('info_tag_is_constant_bitrate', () {
      // 1000 frames of 313 bytes (96 kbps at 44.1 kHz): the counts agree with the header.
      final i = readMp3Info(tagged(h96, tag: 'Info', frames: 1000, bytes: 313000))!;
      expect((i.kbps, i.variable), (96, false));
    });

    test('info_frame_may_have_a_larger_bitrate_than_the_stream', () {
      // A 48 kbps mono frame (156 bytes) is too small for the tag, so ffmpeg writes the Info
      // frame itself at 56 kbps; the counts say what the stream is.
      final i = readMp3Info(
        tagged([0xFF, 0xFB, 0x40, 0xC0], tag: 'Info', mono: true, frames: 1000, bytes: 156000),
      )!;
      expect((i.kbps, i.channels, i.variable), (48, 1, false));
    });

    test('info_average_is_rounded_to_a_standard_bitrate', () {
      // 1000 frames, 360000 bytes: 110 kbps, which is no MP3 bitrate; 112 is the closest.
      final i = readMp3Info(tagged(h96, tag: 'Info', frames: 1000, bytes: 360000))!;
      expect((i.kbps, i.variable), (112, false));
    });

    test('info_without_counts_keeps_the_header_bitrate', () {
      expect(readMp3Info(tagged(h96, tag: 'Info'))!.kbps, 96);
      expect(readMp3Info(tagged(h96, tag: 'Info', frames: 1000))!.kbps, 96);
    });

    test('xing_without_counts_keeps_the_header_bitrate', () {
      expect(readMp3Info(tagged(h96))!.variable, isFalse);
      expect(readMp3Info(tagged(h96, frames: 1000))!.variable, isFalse);
      expect(readMp3Info(tagged(h96, bytes: 360000))!.variable, isFalse);
      expect(readMp3Info(tagged(h96))!.kbps, 96);
    });

    test('xing_with_no_frames_does_not_divide_by_zero', () {
      final i = readMp3Info(tagged(h96, frames: 0, bytes: 1000))!;
      expect((i.kbps, i.variable), (96, false));
    });

    test('xing_mono_tag_sits_after_the_short_side_info', () {
      // 1000 frames, 150000 bytes: 45.9 kbps.
      final i = readMp3Info(
        tagged([0xFF, 0xFB, 0x50, 0xC0], mono: true, frames: 1000, bytes: 150000),
      )!;
      expect((i.kbps, i.channels, i.variable), (46, 1, true));
    });

    test('xing_after_a_crc', () {
      final i = readMp3Info(
        tagged([0xFF, 0xFA, 0x70, 0x00], crc: true, frames: 1000, bytes: 360000),
      )!;
      expect((i.kbps, i.variable), (110, true));
    });

    test('xing_uses_the_sampling_rate', () {
      // 96 kbps header at 48 kHz: 1000 frames last 24 s, 360000 bytes is 120 kbps.
      final i = readMp3Info(
        tagged([0xFF, 0xFB, 0x74, 0x00], frames: 1000, bytes: 360000),
      )!;
      expect((i.kbps, i.hertz), (120, 48000));
    });

    test('xing_behind_an_id3_tag', () {
      final id3 = [0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 20, ...List.filled(20, 0)];
      final i = readMp3Info(tagged(h96, frames: 1000, bytes: 360000, before: id3))!;
      expect((i.kbps, i.variable), (110, true));
    });

    test('cut_short_tag_does_not_throw', () {
      final all = tagged(h96, frames: 1000, bytes: 360000);
      for (var n = 4; n < 4 + 32 + 14; n++) {
        final i = readMp3Info(all.sublist(0, n));
        expect(i?.kbps ?? 96, 96, reason: 'cut at $n');
        expect(i?.variable ?? false, isFalse, reason: 'cut at $n');
      }
    });

    test('describe_variable_and_channels', () {
      expect(
        describeMp3(const Mp3Info(kbps: 95, hertz: 44100, channels: 2, variable: true)),
        'MP3, 44.1 kHz, 95 kbps average (VBR)',
      );
      expect(
        describeMp3(
          const Mp3Info(kbps: 48, hertz: 44100, channels: 1, variable: true),
          withChannels: true,
        ),
        'MP3, 44.1 kHz, 48 kbps average (VBR), mono',
      );
      expect(
        describeMp3(const Mp3Info(kbps: 64, hertz: 44100, channels: 1), withChannels: true),
        'MP3, 44.1 kHz, 64 kbps, mono',
      );
      expect(
        describeMp3(const Mp3Info(kbps: 128, hertz: 44100, channels: 2), withChannels: true),
        'MP3, 44.1 kHz, 128 kbps, stereo',
      );
      expect(
        describeMp3(const Mp3Info(kbps: 128, hertz: 44100, channels: 2)),
        'MP3, 44.1 kHz, 128 kbps',
      );
    });
  });

  test('describe_mp3', () {
    expect(describeMp3(const Mp3Info(kbps: 128, hertz: 44100, channels: 2)), 'MP3, 44.1 kHz, 128 kbps');
    expect(describeMp3(const Mp3Info(kbps: 128, hertz: 48000, channels: 2)), 'MP3, 48 kHz, 128 kbps');
    expect(describeMp3(const Mp3Info(kbps: 192, hertz: 32000, channels: 2)), 'MP3, 32 kHz, 192 kbps');
  });

  final host = parseHost(Platform.version);
  final ffmpeg = findExecutable(
    'ffmpeg',
    os: host.$1,
    tools: ToolsDir('/nonexistent-tools'),
    env: Platform.environment,
    extraDirs: defaultExtraDirs(host.$1),
  );

  test('mp3_info_reads_a_real_ffmpeg_file', () {
    final tmp = Directory.systemTemp.createTempSync('mp3_info');
    addTearDown(() => tmp.deleteSync(recursive: true));
    Mp3Info? made(String bitrate, String channels) {
      final out = '${tmp.path}/$bitrate-$channels.mp3';
      final r = Process.runSync(ffmpeg!, [
        '-v', 'error', '-y', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=3',
        '-c:a', 'libmp3lame', '-b:a', bitrate, '-ar', '44100', '-ac', channels, out,
      ]);
      if (r.exitCode != 0) throw Exception('ffmpeg failed: ${r.stderr}');
      return readMp3Info(File(out).readAsBytesSync());
    }

    for (final (bitrate, channels, kbps) in [('128k', '2', 128), ('192k', '2', 192), ('64k', '1', 64)]) {
      final i = made(bitrate, channels)!;
      expect((i.kbps, i.hertz, i.channels), (kbps, 44100, int.parse(channels)), reason: bitrate);
    }
  }, skip: ffmpeg == null ? 'ffmpeg not found' : false);

  // What the app really makes: constant bitrate (browsers seek wrongly in variable bitrate),
  // with an Info tag that holds the frame count (exact length) and a seek table.
  test('mp3_info_reads_the_files_the_app_encodes', () {
    final tmp = Directory.systemTemp.createTempSync('mp3_cbr');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final ffprobe = findExecutable(
      'ffprobe',
      os: host.$1,
      tools: ToolsDir('/nonexistent-tools'),
      env: Platform.environment,
      extraDirs: defaultExtraDirs(host.$1),
    );
    final wav = '${tmp.path}/in.wav';
    final made = Process.runSync(ffmpeg!, [
      '-v', 'error', '-y', '-f', 'lavfi', '-i', 'anoisesrc=d=6:c=pink:r=44100:a=0.3',
      '-ac', '2', '-ar', '44100', wav,
    ]);
    if (made.exitCode != 0) throw Exception('ffmpeg failed: ${made.stderr}');
    for (final (name, args, channels, kbps) in [
      ('instrumental', encodeInstrumentalArgs(wav, '${tmp.path}/i.mp3'), 2, 96),
      ('vocals', encodeVocalsArgs(wav, '${tmp.path}/v.mp3'), 1, 48),
    ]) {
      final out = args.last;
      final r = Process.runSync(ffmpeg, ['-v', 'error', ...args]);
      if (r.exitCode != 0) throw Exception('ffmpeg failed: ${r.stderr}');
      final bytes = File(out).readAsBytesSync();
      final i = readMp3Info(bytes)!;
      expect((i.kbps, i.channels, i.variable), (kbps, channels, false), reason: name);
      // The tag says: frame count, byte count and TOC.
      var at = -1;
      for (var k = 0; k < 400 && at < 0; k++) {
        if (String.fromCharCodes(bytes.sublist(k, k + 4)) == 'Info') at = k;
      }
      expect(at, greaterThan(0), reason: '$name has an Info tag');
      final flags = bytes[at + 4] << 24 | bytes[at + 5] << 16 | bytes[at + 6] << 8 | bytes[at + 7];
      expect(flags & 7, 7, reason: '$name: frames, bytes and TOC');
      final frames = bytes[at + 8] << 24 | bytes[at + 9] << 16 | bytes[at + 10] << 8 | bytes[at + 11];
      if (ffprobe != null) {
        final c = Process.runSync(ffprobe, [
          '-v', 'error', '-count_frames', '-select_streams', 'a',
          '-show_entries', 'stream=nb_read_frames', '-of', 'csv=p=0', out,
        ]);
        expect(int.parse((c.stdout as String).trim()), frames, reason: '$name frame count');
      }
    }
  }, skip: ffmpeg == null ? 'ffmpeg not found' : false);

  // Version 1.2.0 wrote variable bitrate; such files exist and are described by their average.
  test('mp3_info_reads_a_variable_bitrate_file_of_1_2_0', () {
    final tmp = Directory.systemTemp.createTempSync('mp3_abr');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final out = '${tmp.path}/abr.mp3';
    final r = Process.runSync(ffmpeg!, [
      '-v', 'error', '-y', '-f', 'lavfi', '-i', 'anoisesrc=d=6:c=pink:r=44100:a=0.3',
      '-c:a', 'libmp3lame', '-abr', '1', '-b:a', '96k', '-write_xing', '1',
      '-ar', '44100', '-ac', '2', out,
    ]);
    if (r.exitCode != 0) throw Exception('ffmpeg failed: ${r.stderr}');
    final i = readMp3Info(File(out).readAsBytesSync())!;
    expect(i.variable, isTrue);
    expect(i.kbps, inInclusiveRange(60, 130));
  }, skip: ffmpeg == null ? 'ffmpeg not found' : false);
}
