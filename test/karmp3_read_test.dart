import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/karmp3.dart';
import 'package:kantahe_maker/karmp3_read.dart';

// Made-up lyrics only.
Uint8List bytes(List<int> v) => Uint8List.fromList(v);

/// A ZIP built by hand: (entry name, content) in the given order.
Uint8List zip(List<(String, List<int>)> entries) {
  final archive = Archive();
  for (final (name, content) in entries) {
    archive.addFile(ArchiveFile.bytes(name, content));
  }
  return bytes(ZipEncoder().encodeBytes(archive));
}

List<int> text(String s) => utf8.encode(s);

const lrc = '[ti:T]\n[ar:A]\n[00:01.50]la la\n';

void expectFails(Uint8List data, String message) {
  expect(
    () => readKarMp3(data),
    throwsA(isA<KarMp3Exception>().having((e) => e.message, 'message', message)),
  );
}

void main() {
  group('parseLrc', () {
    test('lrc_round_trip_line_timing', () {
      final written = buildLrc(
        title: 'T',
        artist: 'A',
        composer: 'C',
        lines: const [LrcLine(1.5, 'la la'), LrcLine(61.23, 'na na')],
      );
      final r = parseLrc(written);
      expect(r.tags, {'ti': 'T', 'ar': 'A', 'au': 'C'});
      expect(r.lines, hasLength(2));
      expect(r.lines[0].seconds, 1.5);
      expect(r.lines[0].text, 'la la');
      expect(r.lines[0].words, isEmpty);
      expect(r.lines[1].seconds, 61.23);
      expect(r.lines[1].text, 'na na');
    });

    test('lrc_round_trip_word_timing', () {
      const original = [
        LrcLine(2.0, 'ignored', [(2.0, 'la '), (2.5, 'la')]),
        LrcLine(4.0, 'na na'),
      ];
      final written = buildLrc(title: 'T', artist: 'A', lines: original);
      final r = parseLrc(written);
      expect(r.lines[0].words, [(2.0, 'la '), (2.5, 'la')]);
      expect(r.lines[0].text, 'la la');
      expect(r.lines[0].seconds, 2.0);
      expect(r.lines[1].words, isEmpty);
      // Writing what was read gives the same text.
      expect(buildLrc(title: 'T', artist: 'A', lines: r.lines), written);
    });

    test('lrc_accepts_crlf_and_skips_junk', () {
      final r = parseLrc('[ti:T]\r\n[ar:A]\r\nhello\r\n[00:01.00]la la\r\n');
      expect(r.tags, {'ti': 'T', 'ar': 'A'});
      expect(r.lines.single.text, 'la la');
    });

    test('lrc_text_that_looks_like_a_mark_stays_text', () {
      final r = parseLrc('[00:01.00]<3 la la\n');
      expect(r.lines.single.text, '<3 la la');
      expect(r.lines.single.words, isEmpty);
    });

    test('lrc_minutes_over_ninety_nine', () {
      final r = parseLrc('[100:00.50]la\n');
      expect(r.lines.single.seconds, 6000.5);
    });
  });

  group('parseNfo', () {
    test('nfo_round_trip', () {
      final written = const Nfo(
        title: 'Song : Remix',
        artist: 'A',
        number: 101,
        composer: 'C',
        lyricist: 'L',
        seconds: 227,
        audio: 'MP3, 44.1 kHz, 96 kbps',
        separator: 'Model',
        instrumental: 'A - Song : Remix.mp3',
        vocals: 'A - Song : Remix.vocals.mp3',
        vocalsAudio: 'MP3, 44.1 kHz, 48 kbps, mono',
        lyricLines: 4,
        lyricTiming: 'from lrclib.net synced lyrics',
        wordTiming: true,
      ).toString();
      final nfo = parseNfo(written);
      expect(nfo['Title'], 'Song : Remix');
      expect(nfo['Artist'], 'A');
      expect(nfo['Song number'], '101');
      expect(nfo['Composer'], 'C');
      expect(nfo['Vocals removed'], 'Model');
      expect(nfo['Instrumental'], 'A - Song : Remix.mp3');
      expect(nfo['Vocals'], 'A - Song : Remix.vocals.mp3');
      expect(nfo['Lyric timing'], 'from lrclib.net synced lyrics');
      expect(nfo['Timing by'], 'word');
    });

    test('nfo_leaves_out_empty_rows', () {
      final nfo = parseNfo(
        const Nfo(
          title: 'T',
          artist: 'A',
          seconds: 60,
          audio: '',
          separator: 'M',
          instrumental: 'A - T.mp3',
          lyricLines: 1,
        ).toString(),
      );
      expect(nfo.containsKey('Song number'), isFalse);
      expect(nfo.containsKey('Vocals'), isFalse);
      expect(nfo.containsKey('Composer'), isFalse);
    });
  });

  group('readKarMp3', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('read_karmp3'));
    tearDown(() => dir.deleteSync(recursive: true));

    Nfo nfoFor({bool vocals = false, int? number}) => Nfo(
      title: 'T',
      artist: 'A',
      number: number,
      seconds: 60,
      audio: 'MP3, 44.1 kHz, 96 kbps',
      separator: 'M',
      instrumental: 'A - T.mp3',
      vocals: vocals ? 'A - T.vocals.mp3' : '',
      lyricLines: 1,
    );

    test('read_what_write_writes', () async {
      final path = '${dir.path}/x.karmp3';
      final instrumental = bytes([1, 2, 3, 4]);
      final vocals = bytes([5, 6, 7]);
      final nfo = nfoFor(vocals: true, number: 7).toString();
      final written = buildLrc(
        title: 'T',
        artist: 'A',
        lines: const [LrcLine(1.5, 'la la'), LrcLine(3.25, 'na na')],
      );
      await writeKarMp3(
        path,
        name: 'A - T',
        mp3: instrumental,
        lrc: written,
        nfo: nfo,
        vocals: vocals,
      );
      final c = readKarMp3(File(path).readAsBytesSync());
      expect(c.name, 'A - T');
      expect(c.instrumental, instrumental);
      expect(c.vocals, vocals);
      expect(c.tags['ti'], 'T');
      expect(c.lines.map((l) => (l.seconds, l.text)), [(1.5, 'la la'), (3.25, 'na na')]);
      expect(c.nfo['Song number'], '7');
      expect(c.nfo['Vocals'], 'A - T.vocals.mp3');
    });

    test('read_without_vocals', () {
      final c = readKarMp3(
        zip([
          ('A - T.mp3', [1]),
          ('A - T.lrc', text(lrc)),
          ('A - T.nfo', text(nfoFor().toString())),
        ]),
      );
      expect(c.vocals, isNull);
      expect(c.instrumental, [1]);
    });

    test('read_a_1_0_file', () {
      // 1.0.x wrote no Instrumental row: the only .mp3 is the instrumental.
      final nfo = nfoFor().toString().split('\n').where((l) => !l.startsWith('Instrumental')).join('\n');
      final c = readKarMp3(
        zip([
          ('A - T.mp3', [9, 9]),
          ('A - T.lrc', text(lrc)),
          ('A - T.nfo', text(nfo)),
        ]),
      );
      expect(c.instrumental, [9, 9]);
      expect(c.name, 'A - T');
      expect(c.vocals, isNull);
    });

    test('read_uses_the_instrumental_row_not_the_first_mp3', () {
      // A vocals entry first, the instrumental second: the row decides.
      final c = readKarMp3(
        zip([
          ('A - T.vocals.mp3', [5]),
          ('A - T.mp3', [1]),
          ('A - T.lrc', text(lrc)),
          ('A - T.nfo', text(nfoFor(vocals: true).toString())),
        ]),
      );
      expect(c.instrumental, [1]);
      expect(c.vocals, [5]);
    });

    test('read_ignores_unknown_entries', () {
      final c = readKarMp3(
        zip([
          ('A - T.mp3', [1]),
          ('cover.jpg', [0xFF, 0xD8]),
          ('A - T.lrc', text(lrc)),
          ('A - T.nfo', text(nfoFor().toString())),
        ]),
      );
      expect(c.instrumental, [1]);
    });

    test('read_errors', () {
      expectFails(bytes([1, 2, 3, 4, 5]), 'This is not a .karmp3 file');
      expectFails(bytes([]), 'This is not a .karmp3 file');
      expectFails(
        zip([('A - T.mp3', [1]), ('A - T.nfo', text(nfoFor().toString()))]),
        'This .karmp3 has no lyrics (.lrc)',
      );
      expectFails(
        zip([('A - T.mp3', [1]), ('A - T.lrc', text(lrc))]),
        'This .karmp3 has no song details (.nfo)',
      );
      expectFails(
        zip([('A - T.lrc', text(lrc)), ('A - T.nfo', text(nfoFor().toString()))]),
        'This .karmp3 has no instrumental',
      );
      // The Instrumental row names an entry that is not there.
      expectFails(
        zip([
          ('Other.mp3', [1]),
          ('A - T.lrc', text(lrc)),
          ('A - T.nfo', text(nfoFor().toString())),
        ]),
        'This .karmp3 has no instrumental',
      );
      // No row, and two plain .mp3 entries: which one is not known.
      final noRow = nfoFor().toString().split('\n').where((l) => !l.startsWith('Instrumental')).join('\n');
      expectFails(
        zip([
          ('a.mp3', [1]),
          ('b.mp3', [2]),
          ('A - T.lrc', text(lrc)),
          ('A - T.nfo', text(noRow)),
        ]),
        'This .karmp3 has no instrumental',
      );
      // The Vocals row names an entry that is not there.
      expectFails(
        zip([
          ('A - T.mp3', [1]),
          ('A - T.lrc', text(lrc)),
          ('A - T.nfo', text(nfoFor(vocals: true).toString())),
        ]),
        'This .karmp3 names a vocals track that is not in it',
      );
    });
  });
}
