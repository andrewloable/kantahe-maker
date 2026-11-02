import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/mp3_info.dart';
import 'package:kantahe_maker/tools.dart';

List<int> withHeader(List<int> header, {List<int> before = const []}) => [
  ...before,
  ...header,
  ...List.filled(100, 0),
];

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
}
