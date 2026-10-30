// The .karmp3 text formats (names, timestamps, LRC, NFO). The ZIP writer is in the
// same file. Pure Dart: no Flutter imports, so it can be tested without a window.
// The rules come from PLAN.md, section "The output: .karmp3".

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'fs_retry.dart';

final _unsafeChars = RegExp(r'[\\/:*?"<>|\u0000-\u001f]');
final _whitespace = RegExp(r'[\s\u001c-\u001f]+');
final _edgeSpaceDots = RegExp(r'^[ .]+|[ .]+$');

/// Makes [s] usable in a file name on macOS, Windows and Linux, at most [limit]
/// characters long. An empty result becomes "Unknown".
String safeName(String s, {int limit = 80}) {
  s = s.replaceAll(_unsafeChars, ' ');
  s = s.split(_whitespace).where((w) => w.isNotEmpty).join(' ');
  s = s.replaceAll(_edgeSpaceDots, '');
  final runes = s.runes.toList();
  if (runes.length > limit) {
    s = String.fromCharCodes(runes.take(limit)).replaceAll(_edgeSpaceDots, '');
  }
  return s.isEmpty ? 'Unknown' : s;
}

/// Base name of a song: "00005 - Artist - Title", or "Artist - Title" without a number.
String karMp3Name({int? number, required String artist, required String title}) {
  final base = '${safeName(artist)} - ${safeName(title)}';
  return number == null ? base : '${number.toString().padLeft(5, '0')} - $base';
}

/// "mm:ss.xx". Rounds to whole centiseconds first, so 59.996 s is "01:00.00"
/// and never "00:60.00". Negative times are clamped to 0.
String stamp(double seconds) {
  final cs = ((seconds < 0 ? 0 : seconds) * 100).round();
  final minutes = (cs ~/ 6000).toString().padLeft(2, '0');
  final secs = ((cs % 6000) / 100).toStringAsFixed(2).padLeft(5, '0');
  return '$minutes:$secs';
}

/// One lyric line. An empty [words] list means line-only timing, otherwise [text]
/// is ignored and each word carries its own time.
class LrcLine {
  final double seconds;
  final String text;
  final List<(double, String)> words;
  const LrcLine(this.seconds, this.text, [this.words = const []]);
}

String buildLrc({
  required String title,
  required String artist,
  String composer = '',
  required List<LrcLine> lines,
}) {
  final b = StringBuffer('[ti:$title]\n[ar:$artist]\n');
  if (composer.isNotEmpty) b.write('[au:$composer]\n');
  for (final line in lines) {
    if (line.words.isEmpty) {
      if (line.text.trim().isEmpty) continue;
      b.write('[${stamp(line.seconds)}]${line.text}\n');
    } else {
      b.write('[${stamp(line.words.first.$1)}]');
      for (final (t, w) in line.words) {
        b.write('<${stamp(t)}>$w');
      }
      b.write('\n');
    }
  }
  return b.toString();
}

/// The song info stored as NAME.nfo: aligned "Key : value" lines.
class Nfo {
  final String title, artist, composer, lyricist, audio, separator, lyricTiming;
  final int? number;
  final int seconds, lyricLines;

  const Nfo({
    required this.title,
    required this.artist,
    this.number,
    this.composer = '',
    this.lyricist = '',
    required this.seconds,
    required this.audio,
    required this.separator,
    required this.lyricLines,
    this.lyricTiming = 'tapped by hand in Kantahe Maker',
  });

  /// Rows with an empty value are left out. Keys are padded to the longest key
  /// among all rows, empty ones included, so the layout never shifts.
  @override
  String toString() {
    final rows = <(String, String)>[
      ('Title', title),
      ('Artist', artist),
      ('Song number', number?.toString() ?? ''),
      ('Composer', composer),
      ('Lyricist', lyricist),
      ('Duration', '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}'),
      ('Audio', audio),
      ('Vocals removed', separator),
      ('Lyrics', 'timed (.lrc, $lyricLines lines)'),
      ('Lyric timing', lyricTiming),
    ];
    final width = rows.map((r) => r.$1.length).reduce((a, b) => a > b ? a : b);
    final b = StringBuffer();
    for (final (key, value) in rows) {
      if (value.isNotEmpty) b.write('${key.padRight(width)} : $value\n');
    }
    return b.toString();
  }
}

/// Writes the archive: NAME.mp3, NAME.lrc, NAME.nfo, in that order, deflated, every
/// entry dated 1980-01-01 00:00 so the same input gives the same bytes. It goes to
/// "$path.part" first and is renamed at the end, so a file with the final name is
/// always complete. On any error the .part file is removed and the error rethrown.
Future<void> writeKarMp3(
  String path, {
  required String name,
  required Uint8List mp3,
  required String lrc,
  required String nfo,
}) async {
  final part = File('$path.part');
  try {
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('$name.mp3', mp3))
      ..addFile(ArchiveFile.bytes('$name.lrc', utf8.encode(lrc)))
      ..addFile(ArchiveFile.bytes('$name.nfo', utf8.encode(nfo)));
    // `modified` is the archive-wide DOS time and overrides each entry's own time.
    // DateTime(1980) is local calendar fields, so it does not depend on the timezone.
    final bytes = ZipEncoder().encodeBytes(
      archive,
      level: DeflateLevel.bestCompression,
      modified: DateTime(1980),
    );
    await part.writeAsBytes(bytes, flush: true);
    await retryBusy(() => part.rename(path));
  } catch (_) {
    deleteQuietly(part);
    rethrow;
  }
}
