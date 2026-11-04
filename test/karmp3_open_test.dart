import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/export.dart';
import 'package:kantahe_maker/karmp3_open.dart';
import 'package:kantahe_maker/karmp3_read.dart';
import 'package:kantahe_maker/project.dart';

// Made-up lyrics and stand-in MP3 bytes only.
SongProject song({bool vocals = true, String timingSource = 'lrclib+tapped'}) =>
    SongProject(id: 'a', inputPath: '/x/in.mp3')
      ..title = 'T'
      ..artist = 'A'
      ..number = 101
      ..composer = 'C'
      ..lyricist = 'L'
      ..includeVocals = vocals
      ..lyrics = 'la la\nna na'
      ..times = [1.5, 3.25]
      ..wordTimes = [
        [1.5, 1.9],
        null,
      ]
      ..offset = 0.2
      ..timingSource = timingSource;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('open_karmp3'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Exports [p] (instrumental [1, 2, 3], vocals [4, 5] when included) to a .karmp3.
  Future<String> exported(SongProject p, String file, {String folder = 'work'}) async {
    final work = Directory('${tmp.path}/$folder')..createSync(recursive: true);
    File('${work.path}/instrumental.mp3').writeAsBytesSync([1, 2, 3]);
    if (p.includeVocals) File('${work.path}/vocals.mp3').writeAsBytesSync([4, 5]);
    final dest = '${tmp.path}/$file';
    await exportKarMp3(p, work, dest, durationSeconds: 100);
    return dest;
  }

  Map<String, List<int>> entries(String path) => {
    for (final f in ZipDecoder().decodeBytes(File(path).readAsBytesSync()).files)
      f.name: f.content,
  };

  test('round_trip_keeps_the_file', () async {
    final one = await exported(song(), 'one.karmp3');
    final opened = await openKarMp3(one, Directory('${tmp.path}/opened'), id: 'b');
    final two = await exported(opened, 'two.karmp3', folder: 'opened');
    final a = entries(one), b = entries(two);
    expect(b.keys.toList(), a.keys.toList());
    for (final name in a.keys) {
      expect(b[name], a[name], reason: name);
    }
    expect(File(two).readAsBytesSync(), File(one).readAsBytesSync());
  });

  test('open_sets_the_fields', () async {
    final one = await exported(song(), 'one.karmp3');
    final dir = Directory('${tmp.path}/opened');
    final p = await openKarMp3(one, dir, id: 'b');
    expect(p.id, 'b');
    expect(p.karmp3Path, one);
    expect(p.audioFromKarmp3, isTrue);
    expect(p.offset, 0, reason: 'the times in the file already include the offset');
    expect((p.title, p.artist, p.number, p.composer, p.lyricist), ('T', 'A', 101, 'C', 'L'));
    expect(p.lyrics, 'la la\nna na');
    expect(p.times[0], closeTo(1.7, 0.0001));
    expect(p.times[1], closeTo(3.45, 0.0001));
    expect(p.wordTimes[0]![0], closeTo(1.7, 0.0001));
    expect(p.wordTimes[0]![1], closeTo(2.1, 0.0001));
    expect(p.wordTimes[1], isNull);
    expect(p.timingSource, 'lrclib+tapped');
    expect(p.includeVocals, isTrue);
    expect(p.separator, 'UVR-MDX-NET-Inst_HQ_3');
    // And it was saved: the folder loads back as the same project.
    final back = await SongProject.load(dir);
    expect(back.karmp3Path, one);
    expect(back.audioFromKarmp3, isTrue);
    expect(back.lyrics, 'la la\nna na');
  });

  test('open_writes_the_stems', () async {
    final one = await exported(song(), 'one.karmp3');
    final dir = Directory('${tmp.path}/opened');
    await openKarMp3(one, dir, id: 'b');
    expect(File('${dir.path}/instrumental.mp3').readAsBytesSync(), [1, 2, 3]);
    expect(File('${dir.path}/vocals.mp3').readAsBytesSync(), [4, 5]);
    expect(
      dir.listSync(recursive: true).where((e) => e.path.endsWith('.part')),
      isEmpty,
      reason: 'nothing half written is left',
    );
  });

  test('open_without_vocals_copies_source', () async {
    final one = await exported(song(vocals: false), 'one.karmp3');
    final dir = Directory('${tmp.path}/opened');
    final p = await openKarMp3(one, dir, id: 'b');
    expect(File('${dir.path}/instrumental.mp3').readAsBytesSync(), [1, 2, 3]);
    expect(File('${dir.path}/source.mp3').readAsBytesSync(), [1, 2, 3]);
    expect(File('${dir.path}/vocals.mp3').existsSync(), isFalse);
    expect(p.includeVocals, isFalse);
  });

  test('open_with_vocals_leaves_source_to_the_mix', () async {
    final one = await exported(song(), 'one.karmp3');
    final dir = Directory('${tmp.path}/opened');
    await openKarMp3(one, dir, id: 'b');
    expect(File('${dir.path}/source.mp3').existsSync(), isFalse);
  });

  test('open_maps_lyric_timing', () async {
    for (final (source, back) in [
      ('lrclib', 'lrclib'),
      ('lrclib+tapped', 'lrclib+tapped'),
      ('tapped', 'tapped'),
      ('ai', 'ai'),
      ('ai+tapped', 'ai+tapped'),
    ]) {
      final one = await exported(song(vocals: false, timingSource: source), '$source.karmp3');
      final p = await openKarMp3(one, Directory('${tmp.path}/o-$source'), id: 'b');
      expect(p.timingSource, back, reason: source);
    }
  });

  test('open_falls_back_to_the_lrc_tags_and_ignores_a_bad_number', () async {
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('X.mp3', [1]))
      ..addFile(ArchiveFile.bytes('X.lrc', utf8.encode('[ti:Tag T]\n[ar:Tag A]\n[au:Tag C]\n[00:01.00]la\n')))
      ..addFile(ArchiveFile.bytes('X.nfo', utf8.encode('Song number : abc\nInstrumental : X.mp3\n')));
    final file = File('${tmp.path}/bare.karmp3')..writeAsBytesSync(ZipEncoder().encodeBytes(archive));
    final p = await openKarMp3(file.path, Directory('${tmp.path}/bare'), id: 'b');
    expect((p.title, p.artist, p.composer), ('Tag T', 'Tag A', 'Tag C'));
    expect(p.number, isNull);
    expect(p.lyricist, '');
    expect(p.separator, isNull);
    expect(p.timingSource, 'tapped', reason: 'no Lyric timing row');
  });

  test('open_failure_leaves_no_folder', () async {
    final bad = File('${tmp.path}/bad.karmp3')..writeAsStringSync('this is not a zip');
    final dir = Directory('${tmp.path}/opened');
    await expectLater(
      openKarMp3(bad.path, dir, id: 'b'),
      throwsA(isA<KarMp3Exception>().having((e) => e.message, 'message', 'This is not a .karmp3 file')),
    );
    expect(dir.existsSync(), isFalse);
  });

  test('open_failure_after_the_folder_exists_removes_it', () async {
    final one = await exported(song(vocals: false), 'one.karmp3');
    final dir = Directory('${tmp.path}/opened');
    // A folder where instrumental.mp3 must go: renaming the file onto it fails.
    Directory('${dir.path}/instrumental.mp3').createSync(recursive: true);
    await expectLater(openKarMp3(one, dir, id: 'b'), throwsA(isA<FileSystemException>()));
    expect(dir.existsSync(), isFalse);
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('open_a_missing_file_says_which', () async {
    final dir = Directory('${tmp.path}/opened');
    await expectLater(
      openKarMp3('${tmp.path}/gone.karmp3', dir, id: 'b'),
      throwsA(isA<KarMp3Exception>().having((e) => e.message, 'message', startsWith('Could not read gone.karmp3'))),
    );
    expect(dir.existsSync(), isFalse);
  });
}
