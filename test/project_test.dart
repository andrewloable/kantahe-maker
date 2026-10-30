import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/project.dart';
import 'package:path/path.dart' as p;

SongProject full() =>
    SongProject(id: '20260102-030405', inputPath: '/x/in put.mp4')
      ..title = 'T'
      ..artist = 'A'
      ..number = 7
      ..composer = 'C'
      ..lyricist = 'L'
      ..lyrics = 'one\ntwo'
      ..times = [1.5, null]
      ..wordTimes = [
        [1.5, 1.8],
        null,
      ]
      ..offset = -0.1;

void expectSame(SongProject a, SongProject b) {
  expect(a.id, b.id);
  expect(a.inputPath, b.inputPath);
  expect(a.title, b.title);
  expect(a.artist, b.artist);
  expect(a.number, b.number);
  expect(a.composer, b.composer);
  expect(a.lyricist, b.lyricist);
  expect(a.lyrics, b.lyrics);
  expect(a.times, b.times);
  expect(a.wordTimes, b.wordTimes);
  expect(a.offset, b.offset);
}

void main() {
  group('json', () {
    test('json_roundtrip', () {
      final back = SongProject.fromJson(
        jsonDecode(jsonEncode(full().toJson())) as Map<String, dynamic>,
      );
      expectSame(back, full());
    });

    test('json_defaults', () {
      final p = SongProject.fromJson({'id': 'x', 'inputPath': 'a.mp3'});
      expect(p.id, 'x');
      expect(p.inputPath, 'a.mp3');
      expect(p.lyrics, '');
      expect(p.title, '');
      expect(p.times, isEmpty);
      expect(p.offset, 0);
      expect(p.number, isNull);
    });

    test('json_missing_required', () {
      expect(
        () => SongProject.fromJson({'inputPath': 'a'}),
        throwsFormatException,
      );
      expect(() => SongProject.fromJson({'id': 'a'}), throwsFormatException);
    });

    test('json_wrong_types', () {
      for (final bad in [
        {'id': 'x', 'inputPath': 'a', 'number': 'seven'},
        {'id': 'x', 'inputPath': 'a', 'title': 5},
        {'id': 'x', 'inputPath': 'a', 'times': 'nope'},
        {
          'id': 'x',
          'inputPath': 'a',
          'times': [1, 'x'],
        },
        {'id': 'x', 'inputPath': 'a', 'offset': 'late'},
        {'id': 5, 'inputPath': 'a'},
      ]) {
        expect(
          () => SongProject.fromJson(bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });

    test('json_integers_are_fine_for_times_and_offset', () {
      final p = SongProject.fromJson({
        'id': 'x',
        'inputPath': 'a',
        'times': [1, null, 2],
        'offset': 0,
      });
      expect(p.times, [1.0, null, 2.0]);
      expect(p.offset, 0.0);
    });

    test('json_unknown_keys_are_ignored', () {
      final p = SongProject.fromJson({
        'id': 'x',
        'inputPath': 'a',
        'futureField': {'a': 1},
      });
      expect(p.id, 'x');
    });
  });

  group('lyrics', () {
    test('lyric_lines', () {
      final p = SongProject(id: 'x', inputPath: 'a')..lyrics = '  a \n\n b\r\n';
      expect(p.lyricLines(), ['a', 'b']);
    });

    test('lyric_lines_empty', () {
      expect(SongProject(id: 'x', inputPath: 'a').lyricLines(), isEmpty);
    });

    test('set_lyrics_keeps_unchanged', () {
      final p = SongProject(id: 'x', inputPath: 'a')
        ..lyrics = 'a\nb\nc'
        ..times = [1, 2, 3];
      p.setLyrics('a\nX\nc');
      expect(p.lyrics, 'a\nX\nc');
      expect(p.times, [1, null, 3]);
    });

    test('set_lyrics_append', () {
      final p = SongProject(id: 'x', inputPath: 'a')
        ..lyrics = 'a\nb'
        ..times = [1, 2];
      p.setLyrics('a\nb\nc');
      expect(p.times, [1, 2, null]);
    });

    test('set_lyrics_remove_from_end', () {
      final p = SongProject(id: 'x', inputPath: 'a')
        ..lyrics = 'a\nb\nc'
        ..times = [1, 2, 3];
      p.setLyrics('a\nb');
      expect(p.times, [1, 2]);
    });

    test('set_lyrics_ignores_blank_lines_and_whitespace_changes', () {
      final p = SongProject(id: 'x', inputPath: 'a')
        ..lyrics = 'a\nb'
        ..times = [1, 2];
      p.setLyrics('  a  \n\n\nb\r\n');
      expect(
        p.lyrics,
        '  a  \n\n\nb\r\n',
        reason: 'the text is stored as typed',
      );
      expect(p.times, [1, 2], reason: 'the lines did not change');
    });

    test('set_lyrics_insert_in_the_middle_keeps_only_matching_positions', () {
      final p = SongProject(id: 'x', inputPath: 'a')
        ..lyrics = 'a\nb\nc'
        ..times = [1, 2, 3];
      p.setLyrics('a\nNEW\nb\nc');
      expect(p.times, [
        1,
        null,
        null,
        null,
      ], reason: 'index-aligned: shifted lines lose their taps');
    });

    test('set_lyrics_when_times_are_shorter_than_lines', () {
      final p = SongProject(id: 'x', inputPath: 'a')..lyrics = 'a\nb';
      p.setLyrics('a\nb\nc');
      expect(p.times, [null, null, null]);
    });

    test('set_lyrics_to_nothing', () {
      final p = SongProject(id: 'x', inputPath: 'a')
        ..lyrics = 'a'
        ..times = [1];
      p.setLyrics('');
      expect(p.times, isEmpty);
    });
  });

  group('files', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('project_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('save_atomic', () async {
      final dir = Directory('${tmp.path}/p1')..createSync();
      await full().save(dir);
      expect(File('${dir.path}/project.json.part').existsSync(), isFalse);
      expect(File('${dir.path}/project.json').existsSync(), isTrue);
      expectSame(await SongProject.load(dir), full());
    });

    test('save_creates_the_folder', () async {
      final dir = Directory('${tmp.path}/new/deep');
      await full().save(dir);
      expect(File('${dir.path}/project.json').existsSync(), isTrue);
    });

    test('save_overwrites', () async {
      final dir = Directory('${tmp.path}/p1')..createSync();
      await full().save(dir);
      final p = full()..title = 'Changed';
      await p.save(dir);
      expect((await SongProject.load(dir)).title, 'Changed');
    });

    test('save_failure_keeps_the_old_file', () async {
      final dir = Directory('${tmp.path}/p1')..createSync();
      await full().save(dir);
      final before = File('${dir.path}/project.json').readAsStringSync();
      // A directory where the .part file would go makes the write fail.
      Directory('${dir.path}/project.json.part').createSync();
      await expectLater(full().save(dir), throwsA(isA<FileSystemException>()));
      expect(File('${dir.path}/project.json').readAsStringSync(), before);
    });

    test('save_overlapping_calls_all_succeed', () async {
      final dir = Directory('${tmp.path}/p1')..createSync();
      final p = full()..lyrics = 'x' * 5000;
      final futures = <Future<void>>[];
      for (var i = 0; i < 6; i++) {
        p.title = 'v$i';
        futures.add(
          p.save(dir),
        ); // not awaited: the UI saves after every change
      }
      await Future.wait(futures);
      expect((await SongProject.load(dir)).title, 'v5');
      expect(File('${dir.path}/project.json.part').existsSync(), isFalse);
    });

    test('save_writes_the_state_at_the_time_of_its_turn', () async {
      final dir = Directory('${tmp.path}/p1')..createSync();
      final p = full()..title = 'first';
      final a = p.save(dir);
      p.title = 'second';
      final b = p.save(dir);
      p.title = 'late';
      await Future.wait([a, b]);
      expect(
        (await SongProject.load(dir)).title,
        'late',
        reason: 'the newest state wins, not the state at the time of the call',
      );
    });

    test('save_error_does_not_block_later_saves', () async {
      final dir = Directory('${tmp.path}/p1')..createSync();
      final blocker = Directory('${dir.path}/project.json.part')..createSync();
      final p = full();
      await expectLater(p.save(dir), throwsA(isA<FileSystemException>()));
      blocker.deleteSync();
      await p.save(dir);
      expectSame(await SongProject.load(dir), full());
    });

    test('save_is_utf8', () async {
      final dir = Directory('${tmp.path}/p1')..createSync();
      final p = full()..lyrics = 'Ñandú 歌\nsecond';
      await p.save(dir);
      expect((await SongProject.load(dir)).lyrics, 'Ñandú 歌\nsecond');
    });

    test('load_corrupt', () async {
      final dir = Directory('${tmp.path}/p1')..createSync();
      File('${dir.path}/project.json').writeAsStringSync('{');
      await expectLater(
        SongProject.load(dir),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('project.json'),
          ),
        ),
      );
    });

    test('load_not_an_object', () async {
      final dir = Directory('${tmp.path}/p1')..createSync();
      File('${dir.path}/project.json').writeAsStringSync('[1,2]');
      await expectLater(SongProject.load(dir), throwsFormatException);
    });

    test('load_missing_file', () async {
      final dir = Directory('${tmp.path}/none')..createSync();
      await expectLater(
        SongProject.load(dir),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('list_order', () async {
      for (final id in ['20260101-000000', '20260102-000000']) {
        final d = Directory('${tmp.path}/$id')..createSync();
        await (SongProject(id: id, inputPath: 'a')).save(d);
      }
      Directory('${tmp.path}/junk').createSync();
      File('${tmp.path}/notes.txt').writeAsStringSync('x');
      final dirs = await listProjectDirs(tmp);
      expect(dirs.map((d) => p.basename(d.path)), [
        '20260102-000000',
        '20260101-000000',
      ]);
    });

    test('list_missing_root', () async {
      expect(await listProjectDirs(Directory('${tmp.path}/nope')), isEmpty);
    });

    test('list_empty_root', () async {
      expect(await listProjectDirs(tmp), isEmpty);
    });
  });

  group('newProjectId', () {
    test('new_id', () {
      expect(newProjectId(DateTime(2026, 1, 2, 3, 4, 5)), '20260102-030405');
    });
    test('new_id_two_digit_everything', () {
      expect(
        newProjectId(DateTime(2026, 12, 31, 23, 59, 59)),
        '20261231-235959',
      );
    });
  });

  group('word times', () {
    Map<String, dynamic> json(Object? words) => {
      'id': 'x',
      'inputPath': 'a.mp3',
      'times': [1, 2, null],
      'wordTimes': words,
    };

    test('project_backcompat', () {
      final p = SongProject.fromJson({
        'id': 'x',
        'inputPath': 'a.mp3',
        'times': [1, 2, null],
      });
      expect(p.wordTimes, [null, null, null]);
      expect(
        SongProject.fromJson({'id': 'x', 'inputPath': 'a.mp3'}).wordTimes,
        isEmpty,
      );
    });

    test('word_times_json_roundtrip_with_integers', () {
      final p = SongProject.fromJson(
        json([
          [1, 1.5, null],
          null,
          [3],
        ]),
      );
      expect(p.wordTimes, [
        [1.0, 1.5, null],
        null,
        [3.0],
      ]);
      final back = SongProject.fromJson(
        jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>,
      );
      expect(back.wordTimes, p.wordTimes);
    });

    test('word_times_wrong_type_is_an_error', () {
      expect(() => SongProject.fromJson(json('x')), throwsFormatException);
      expect(() => SongProject.fromJson(json([5])), throwsFormatException);
      expect(
        () => SongProject.fromJson(
          json([
            ['a'],
          ]),
        ),
        throwsFormatException,
      );
    });

    test('set_lyrics_keeps_word_times_of_unchanged_lines', () {
      final p = SongProject(id: 'x', inputPath: 'a')
        ..lyrics = 'a b\nc d'
        ..times = [1, 2]
        ..wordTimes = [
          [1.0, 1.5],
          [2.0, 2.5],
        ];
      p.setLyrics('a b\nc e');
      expect(p.times, [1, null]);
      expect(p.wordTimes, [
        [1.0, 1.5],
        null,
      ]);
      p.setLyrics('new\na b\nc e');
      expect(p.wordTimes, [null, null, null]);
    });

    test('word_times_survive_save_and_load', () async {
      final dir = Directory.systemTemp.createTempSync('wt_');
      addTearDown(() => dir.deleteSync(recursive: true));
      await full().save(dir);
      expectSame(await SongProject.load(dir), full());
    });
  });
}
