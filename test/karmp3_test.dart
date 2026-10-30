import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/karmp3.dart';

void main() {
  group('safeName', () {
    test('safeName_unsafe', () {
      expect(safeName('AC/DC: "Live?"'), 'AC DC Live');
    });
    test('safeName_spaces_dots', () {
      expect(safeName('  ..Hello   World..  '), 'Hello World');
    });
    test('safeName_control', () {
      expect(safeName('a\u0001b'), 'a b');
    });
    test('safeName_empty', () {
      expect(safeName('///'), 'Unknown');
    });
    test('safeName_limit', () {
      expect(safeName('a' * 100), 'a' * 80);
      expect(safeName('ab. ${'c' * 90}', limit: 3), 'ab');
    });
  });

  group('karMp3Name', () {
    test('name_with_number', () {
      expect(
        karMp3Name(number: 5, artist: 'Whitney Houston', title: 'I Wanna Dance'),
        '00005 - Whitney Houston - I Wanna Dance',
      );
    });
    test('name_without_number', () {
      expect(
        karMp3Name(artist: 'Whitney Houston', title: 'I Wanna Dance'),
        'Whitney Houston - I Wanna Dance',
      );
    });
  });

  test('stamp', () {
    expect(stamp(0), '00:00.00');
    expect(stamp(7.31), '00:07.31');
    expect(stamp(65.5), '01:05.50');
    expect(stamp(59.996), '01:00.00');
    expect(stamp(-1), '00:00.00');
    expect(stamp(6000), '100:00.00');
  });

  group('buildLrc', () {
    test('lrc_line_only', () {
      final lrc = buildLrc(
        title: 'T',
        artist: 'A',
        lines: const [LrcLine(7.31, 'Hello'), LrcLine(9, 'World')],
      );
      expect(lrc, '[ti:T]\n[ar:A]\n[00:07.31]Hello\n[00:09.00]World\n');
    });
    test('lrc_skip_blank', () {
      final lrc = buildLrc(
        title: 'T',
        artist: 'A',
        lines: const [LrcLine(1, '  '), LrcLine(2, 'x')],
      );
      expect(lrc, '[ti:T]\n[ar:A]\n[00:02.00]x\n');
    });
    test('lrc_words', () {
      final lrc = buildLrc(
        title: 'T',
        artist: 'A',
        composer: 'C',
        lines: const [
          LrcLine(1, '', [(1.0, 'Hel'), (1.5, 'lo ')]),
        ],
      );
      expect(lrc, contains('[au:C]\n'));
      expect(lrc, contains('[00:01.00]<00:01.00>Hel<00:01.50>lo \n'));
    });
  });

  group('Nfo', () {
    Nfo nfo({int? number}) => Nfo(
          title: 'T',
          artist: 'A',
          number: number,
          seconds: 295,
          audio: 'MP3, 44.1 kHz, 192 kbps',
          separator: 'UVR-MDX-NET-Inst_HQ_3',
          lyricLines: 3,
        );

    test('nfo_format', () {
      expect(
        nfo().toString(),
        'Title          : T\n'
        'Artist         : A\n'
        'Duration       : 4:55\n'
        'Audio          : MP3, 44.1 kHz, 192 kbps\n'
        'Vocals removed : UVR-MDX-NET-Inst_HQ_3\n'
        'Lyrics         : timed (.lrc, 3 lines)\n'
        'Lyric timing   : tapped by hand in Kantahe Maker\n',
      );
    });
    test('nfo_number', () {
      final lines = nfo(number: 7).toString().split('\n');
      expect(lines[1], 'Artist         : A');
      expect(lines[2], 'Song number    : 7');
    });
    test('nfo_reader_regex', () {
      final re = RegExp(r'^(.+?)\s+:\s(.*)$');
      for (final line in nfo(number: 7).toString().trimRight().split('\n')) {
        expect(re.hasMatch(line), isTrue, reason: line);
      }
    });
  });

  group('writeKarMp3', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('karmp3_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<String> write(
      String file, {
      String name = 'N',
      List<int> mp3 = const [1, 2, 3],
      String lrc = 'L',
      String nfo = 'I',
    }) async {
      final path = '${dir.path}/$file';
      await writeKarMp3(path,
          name: name, mp3: Uint8List.fromList(mp3), lrc: lrc, nfo: nfo);
      return path;
    }

    test('zip_roundtrip', () async {
      final path = await write('a.karmp3');
      expect(File('$path.part').existsSync(), isFalse);
      final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
      expect(archive.files.map((f) => f.name), ['N.mp3', 'N.lrc', 'N.nfo']);
      expect(archive.files[0].content, [1, 2, 3]);
      expect(utf8.decode(archive.files[1].content), 'L');
      expect(utf8.decode(archive.files[2].content), 'I');
    });

    test('zip_dos_time', () async {
      final bytes = File(await write('a.karmp3')).readAsBytesSync();
      expect(bytes.sublist(10, 14), [0x00, 0x00, 0x21, 0x00]);
    });

    test('zip_deflate', () async {
      final bytes = File(await write('a.karmp3')).readAsBytesSync();
      expect(bytes.sublist(8, 10), [0x08, 0x00]);
    });

    test('zip_reproducible', () async {
      final a = File(await write('a.karmp3')).readAsBytesSync();
      final b = File(await write('b.karmp3')).readAsBytesSync();
      expect(a, b);
    });

    test('zip_utf8', () async {
      final path = await write('a.karmp3',
          name: 'Ñino - Café', lrc: 'ñ', nfo: 'é');
      final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
      expect(archive.files.map((f) => f.name),
          ['Ñino - Café.mp3', 'Ñino - Café.lrc', 'Ñino - Café.nfo']);
      expect(utf8.decode(archive.files[1].content), 'ñ');
      expect(utf8.decode(archive.files[2].content), 'é');
    });

    test('zip_rename_failure_cleanup', () async {
      // The .part file is written, then the rename fails (the target is a directory).
      Directory('${dir.path}/taken.karmp3').createSync();
      await expectLater(write('taken.karmp3'), throwsA(isA<Exception>()));
      expect(File('${dir.path}/taken.karmp3.part').existsSync(), isFalse);
    });

    test('zip_existing_untouched_on_failure', () async {
      // The final path is only replaced by a rename of a finished .part file.
      // A directory sits where the .part would go, so the write must fail
      // without touching the file that is already at the final path.
      final dest = File('${dir.path}/keep.karmp3')..writeAsStringSync('OLD');
      Directory('${dir.path}/keep.karmp3.part').createSync();
      await expectLater(write('keep.karmp3'), throwsA(isA<Exception>()));
      expect(dest.readAsStringSync(), 'OLD');
    });

    test('zip_failure_cleanup', () async {
      final path = '${dir.path}/missing/a.karmp3';
      await expectLater(write('missing/a.karmp3'), throwsA(isA<Exception>()));
      expect(dir.listSync(recursive: true).where((e) => e.path.endsWith('.part')), isEmpty);
      expect(File(path).existsSync(), isFalse);
    });
  });
}
