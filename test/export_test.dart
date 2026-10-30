import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/export.dart';
import 'package:kantahe_maker/project.dart';

SongProject ready({
  String title = 'T',
  String artist = 'A',
  String lyrics = 'a\nb',
  List<double?> times = const [1, 2],
  double offset = 0,
  int? number,
}) =>
    SongProject(id: 'x', inputPath: '/x/in.mp3')
      ..title = title
      ..artist = artist
      ..lyrics = lyrics
      ..times = List.of(times)
      ..offset = offset
      ..number = number;

void main() {
  group('exportBlockers', () {
    test('blockers_all', () {
      expect(exportBlockers(SongProject(id: 'x', inputPath: 'a'), instrumentalReady: false), [
        'Vocal removal is not finished',
        'Add lyrics',
        'Title is required',
        'Artist is required',
      ]);
    });

    test('blockers_untapped', () {
      final p = ready(times: [1, null]);
      expect(exportBlockers(p, instrumentalReady: true), ['1 line(s) not tapped yet']);
    });

    test('blockers_counts_every_untapped_line', () {
      final p = ready(lyrics: 'a\nb\nc', times: [null, null, null]);
      expect(exportBlockers(p, instrumentalReady: true), ['3 line(s) not tapped yet']);
    });

    test('blockers_out_of_order', () {
      final p = ready(times: [2, 1]);
      expect(exportBlockers(p, instrumentalReady: true), ['Timing is out of order']);
    });

    test('blockers_none', () {
      expect(exportBlockers(ready(), instrumentalReady: true), isEmpty);
    });

    test('blockers_blank_title_or_artist', () {
      expect(exportBlockers(ready(title: '  ', artist: ' \n'), instrumentalReady: true),
          ['Title is required', 'Artist is required']);
    });

    test('blockers_ignore_blank_lyric_lines', () {
      final p = ready(lyrics: 'a\n\n  \nb', times: [1, 2]);
      expect(exportBlockers(p, instrumentalReady: true), isEmpty);
    });

    test('blockers_times_longer_than_lines_are_not_a_problem', () {
      final p = ready(times: [1, 2, 3]);
      expect(exportBlockers(p, instrumentalReady: true), isEmpty);
    });
  });

  group('exportKarMp3', () {
    late Directory tmp;
    late Directory work;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('export_test');
      work = Directory('${tmp.path}/work')..createSync();
      File('${work.path}/instrumental.mp3').writeAsBytesSync([9, 9]);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Map<String, Uint8List> entries(String path) => {
          for (final f in ZipDecoder().decodeBytes(File(path).readAsBytesSync()).files)
            f.name: f.content,
        };

    String text(Uint8List b) => utf8.decode(b);

    test('export_content', () async {
      final dest = '${tmp.path}/out.karmp3';
      await exportKarMp3(ready(offset: -0.5), work, dest, durationSeconds: 61.4);
      final e = entries(dest);
      expect(e.keys.toList(), ['A - T.mp3', 'A - T.lrc', 'A - T.nfo']);
      expect(e['A - T.mp3'], [9, 9]);
      expect(text(e['A - T.lrc']!), '[ti:T]\n[ar:A]\n[00:00.50]a\n[00:01.50]b\n');
      final nfo = text(e['A - T.nfo']!);
      expect(nfo, contains('Duration       : 1:01'));
      expect(nfo.split('\n'), contains('Vocals removed : UVR-MDX-NET-Inst_HQ_3'),
          reason: 'the model name without its file extension, on a line of its own');
      expect(nfo, contains('Lyrics         : timed (.lrc, 2 lines)'));
      expect(File('$dest.part').existsSync(), isFalse);
    });

    test('line_only_unchanged', () async {
      final dest = '${tmp.path}/out.karmp3';
      final lineOnly = ready(offset: -0.5)..wordTimes = [null, null];
      await exportKarMp3(lineOnly, work, dest, durationSeconds: 61.4);
      // Byte for byte what export_content expects.
      expect(text(entries(dest)['A - T.lrc']!), '[ti:T]\n[ar:A]\n[00:00.50]a\n[00:01.50]b\n');
      // The same project with word times does differ (so the check above can fail).
      final timed = ready(lyrics: 'a x\nb')..wordTimes = [[1.0, 1.5], null];
      await exportKarMp3(timed, work, dest, durationSeconds: 61.4);
      expect(text(entries(dest)['A - T.lrc']!), isNot('[ti:T]\n[ar:A]\n[00:01.00]a x\n[00:02.00]b\n'));
    });

    test('export_word_marks', () async {
      final dest = '${tmp.path}/out.karmp3';
      final p = ready(lyrics: 'Hello big world\nbye')
        ..wordTimes = [
          [1.0, 1.4, 1.9],
          null,
        ];
      await exportKarMp3(p, work, dest, durationSeconds: 10);
      expect(
          text(entries(dest)['A - T.lrc']!),
          '[ti:T]\n[ar:A]\n'
          '[00:01.00]<00:01.00>Hello <00:01.40>big <00:01.90>world\n'
          '[00:02.00]bye\n');
    });

    test('export_blocked', () async {
      final dest = '${tmp.path}/out.karmp3';
      await expectLater(
          exportKarMp3(ready(times: [1, null]), work, dest, durationSeconds: 10),
          throwsStateError);
      expect(File(dest).existsSync(), isFalse);
      expect(File('$dest.part').existsSync(), isFalse);
    });

    test('export_without_the_instrumental_is_blocked', () async {
      File('${work.path}/instrumental.mp3').deleteSync();
      final dest = '${tmp.path}/out.karmp3';
      await expectLater(exportKarMp3(ready(), work, dest, durationSeconds: 10),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Vocal removal'))));
      expect(File(dest).existsSync(), isFalse);
    });

    test('export_name_has_the_songbook_number', () async {
      final dest = '${tmp.path}/out.karmp3';
      await exportKarMp3(ready(number: 7), work, dest, durationSeconds: 10);
      expect(entries(dest).keys.first, '00007 - A - T.mp3');
    });

    test('export_collapses_whitespace_and_newlines_in_the_text_fields', () async {
      final dest = '${tmp.path}/out.karmp3';
      final p = ready(title: 'T\nX   Y', artist: ' A\t B ')
        ..composer = 'C\n1'
        ..lyricist = 'L  2';
      await exportKarMp3(p, work, dest, durationSeconds: 10);
      final e = entries(dest);
      expect(e.keys.first, 'A B - T X Y.mp3');
      expect(text(e['A B - T X Y.lrc']!),
          startsWith('[ti:T X Y]\n[ar:A B]\n[au:C 1]\n'));
      final nfo = text(e['A B - T X Y.nfo']!);
      expect(nfo, contains('Title          : T X Y'));
      expect(nfo, contains('Composer       : C 1'));
      expect(nfo, contains('Lyricist       : L 2'));
      // every nfo line is a readable "Key : value" line
      for (final line in nfo.trimRight().split('\n')) {
        expect(RegExp(r'^(.+?)\s+:\s(.*)$').hasMatch(line), isTrue, reason: line);
      }
    });

    test('export_unicode', () async {
      final dest = '${tmp.path}/out.karmp3';
      await exportKarMp3(ready(title: 'Ñandú 歌', artist: 'Café')..lyrics = 'ñ\né',
          work, dest, durationSeconds: 10);
      final e = entries(dest);
      expect(e.keys.first, 'Café - Ñandú 歌.mp3');
      expect(text(e['Café - Ñandú 歌.lrc']!), contains('[00:01.00]ñ'));
    });

    test('export_rounds_the_duration', () async {
      final dest = '${tmp.path}/out.karmp3';
      await exportKarMp3(ready(), work, dest, durationSeconds: 61.6);
      expect(text(entries(dest).values.last), contains('Duration       : 1:02'));
    });

    test('export_leaves_the_project_untouched', () async {
      final p = ready(title: ' T \n', offset: -0.2);
      final before = jsonEncode(p.toJson());
      await exportKarMp3(p, work, '${tmp.path}/out.karmp3', durationSeconds: 10);
      expect(jsonEncode(p.toJson()), before);
    });

    test('export_replaces_an_existing_file', () async {
      final dest = '${tmp.path}/out.karmp3';
      File(dest).writeAsStringSync('old');
      await exportKarMp3(ready(), work, dest, durationSeconds: 10);
      expect(entries(dest).keys, contains('A - T.mp3'));
    });
  });

  group('oneLine', () {
    test('one_line', () {
      expect(oneLine('  a \n b\t\tc  '), 'a b c');
      expect(oneLine(''), '');
      expect(oneLine('x'), 'x');
    });
  });
}
