// Opening a .karmp3 as a song project, so the wizard can edit it: the stems are copied out as
// they are (nothing is split again) and the details, lyrics and times come from the .nfo and
// the .lrc. Pure Dart: no Flutter imports.

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'fs_retry.dart';
import 'karmp3.dart' show lyricTimingAi, lyricTimingAiTapped;
import 'karmp3_read.dart';
import 'project.dart';

/// Writes [bytes] to [file] through a ".part" file and a rename.
Future<void> _write(File file, Uint8List bytes) async {
  final part = File('${file.path}.part');
  await part.writeAsBytes(bytes, flush: true);
  await retryBusy(() => part.rename(file.path));
}

/// Opens the .karmp3 at [karmp3Path] into the song folder [dir] as project [id] and returns
/// it (it is saved there). instrumental.mp3 and, when the file has them, vocals.mp3 are the
/// file's own MP3s; without vocals source.mp3 is a copy of the instrumental (with vocals it is
/// made later, see makeSourceFromStems). The lyric times already include the tap offset the
/// song was exported with, so the offset is 0. Throws [KarMp3Exception] when the file cannot
/// be read; on any error [dir] is deleted.
Future<SongProject> openKarMp3(
  String karmp3Path,
  Directory dir, {
  required String id,
}) async {
  final Uint8List bytes;
  try {
    bytes = await File(karmp3Path).readAsBytes();
  } on FileSystemException catch (e) {
    throw KarMp3Exception('Could not read ${p.basename(karmp3Path)}: ${e.message}');
  }
  final c = readKarMp3(bytes);
  try {
    await dir.create(recursive: true);
    await _write(File(p.join(dir.path, 'instrumental.mp3')), c.instrumental);
    final vocals = c.vocals;
    if (vocals != null) {
      await _write(File(p.join(dir.path, 'vocals.mp3')), vocals);
    } else {
      await _write(File(p.join(dir.path, 'source.mp3')), c.instrumental);
    }

    // A line with nothing but blanks is no lyric line (SongProject.lyricLines drops it), so
    // it must not get a time either.
    final lines = [for (final l in c.lines) if (l.text.trim().isNotEmpty) l];
    final project = SongProject(id: id, inputPath: karmp3Path)
      ..title = c.nfo['Title'] ?? c.tags['ti'] ?? ''
      ..artist = c.nfo['Artist'] ?? c.tags['ar'] ?? ''
      ..number = int.tryParse(c.nfo['Song number'] ?? '')
      ..composer = c.nfo['Composer'] ?? c.tags['au'] ?? ''
      ..lyricist = c.nfo['Lyricist'] ?? ''
      ..includeVocals = vocals != null
      ..karmp3Path = karmp3Path
      ..audioFromKarmp3 = true
      ..separator = c.nfo['Vocals removed']
      ..offset = 0
      ..timingSource = switch (c.nfo['Lyric timing']) {
        'from lrclib.net synced lyrics' => 'lrclib',
        'from lrclib.net synced lyrics, corrected by hand in Kantahe Maker' => 'lrclib+tapped',
        lyricTimingAi => 'ai',
        lyricTimingAiTapped => 'ai+tapped',
        _ => 'tapped',
      };
    project.setLyrics([for (final l in lines) l.text.trim()].join('\n'));
    project.times = [for (final l in lines) l.seconds];
    project.wordTimes = [
      for (final l in lines)
        if (l.words.isEmpty) null else <double?>[for (final w in l.words) w.$1],
    ];
    await project.save(dir);
    return project;
  } catch (_) {
    deleteQuietly(dir);
    rethrow;
  }
}
