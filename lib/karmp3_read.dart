// Reading a .karmp3: the ZIP archive, its .lrc (the lyrics with times) and its .nfo (the song
// details). The format is specified in README.md, section "The .karmp3 format"; the writer is
// in karmp3.dart. Pure Dart: no Flutter imports, so it can be tested without a window.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'karmp3.dart' show LrcLine;

/// Why a file cannot be read as a .karmp3, in words fit to show the user.
class KarMp3Exception implements Exception {
  final String message;
  const KarMp3Exception(this.message);
  @override
  String toString() => message;
}

/// What is in a .karmp3.
class KarMp3Contents {
  /// The base name of the entries: "Artist - Title" or "NNNNN - Artist - Title".
  final String name;
  final Uint8List instrumental;

  /// The vocals MP3, null when the file does not include them.
  final Uint8List? vocals;

  /// The tag lines of the .lrc, keys in lower case ("ti", "ar", "au").
  final Map<String, String> tags;
  final List<LrcLine> lines;

  /// The rows of the .nfo, by key ("Title", "Song number", "Vocals removed", ...).
  final Map<String, String> nfo;
  const KarMp3Contents({
    required this.name,
    required this.instrumental,
    this.vocals,
    required this.tags,
    required this.lines,
    required this.nfo,
  });
}

/// Seconds from the digits of "mm:ss.xx" (whole hundredths, so no rounding error).
double _seconds(String minutes, String seconds, String hundredths) =>
    (int.parse(minutes) * 6000 + int.parse(seconds) * 100 + int.parse(hundredths)) / 100;

final _tagLine = RegExp(r'^\[([A-Za-z]+):(.*)\]$');
final _timedLine = RegExp(r'^\[(\d{2,}):(\d{2})\.(\d{2})\](.*)$');
final _firstMark = RegExp(r'^<\d{2,}:\d{2}\.\d{2}>');
final _wordMark = RegExp(r'<(\d{2,}):(\d{2})\.(\d{2})>([^<]*)');

/// The tags and the timed lines of an .lrc. A line with word marks gets its words (each keeps
/// the space that follows it) and its text is the words joined; other lines have no words.
/// Lines that are neither tags nor timed lines are skipped.
({Map<String, String> tags, List<LrcLine> lines}) parseLrc(String text) {
  final tags = <String, String>{};
  final lines = <LrcLine>[];
  for (final raw in text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
    final timed = _timedLine.firstMatch(raw);
    if (timed != null) {
      final seconds = _seconds(timed.group(1)!, timed.group(2)!, timed.group(3)!);
      final rest = timed.group(4)!;
      if (_firstMark.hasMatch(rest)) {
        final words = [
          for (final m in _wordMark.allMatches(rest))
            (_seconds(m.group(1)!, m.group(2)!, m.group(3)!), m.group(4)!),
        ];
        lines.add(LrcLine(seconds, words.map((w) => w.$2).join(), words));
      } else {
        lines.add(LrcLine(seconds, rest));
      }
      continue;
    }
    final tag = _tagLine.firstMatch(raw);
    if (tag != null) tags[tag.group(1)!.toLowerCase()] = tag.group(2)!;
  }
  return (tags: tags, lines: lines);
}

final _nfoRow = RegExp(r'^(.+?)\s+:\s(.*)$');

/// The rows of an .nfo by key. Only the first " : " of a line splits it, so a value may
/// hold one.
Map<String, String> parseNfo(String text) {
  final rows = <String, String>{};
  for (final raw in text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
    final m = _nfoRow.firstMatch(raw);
    if (m != null) rows[m.group(1)!.trim()] = m.group(2)!;
  }
  return rows;
}

bool _isVocals(String name) => name.toLowerCase().endsWith('.vocals.mp3');

/// Reads a .karmp3 from its [bytes]. Entries it does not know are ignored. Throws
/// [KarMp3Exception] (and nothing else) when the bytes are not a usable .karmp3.
KarMp3Contents readKarMp3(Uint8List bytes) {
  try {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const KarMp3Exception('This is not a .karmp3 file');
    }
    final files = [for (final f in archive.files) if (f.isFile) f];
    // Bytes that are not a ZIP can decode to an archive with nothing in it.
    if (files.isEmpty) throw const KarMp3Exception('This is not a .karmp3 file');
    ArchiveFile? byExtension(String ext) {
      for (final f in files) {
        if (f.name.toLowerCase().endsWith(ext)) return f;
      }
      return null;
    }

    final lrcFile = byExtension('.lrc');
    if (lrcFile == null) throw const KarMp3Exception('This .karmp3 has no lyrics (.lrc)');
    final nfoFile = byExtension('.nfo');
    if (nfoFile == null) {
      throw const KarMp3Exception('This .karmp3 has no song details (.nfo)');
    }
    String textOf(ArchiveFile f) => utf8.decode(f.readBytes() ?? Uint8List(0), allowMalformed: true);
    final nfo = parseNfo(textOf(nfoFile));
    final lrc = parseLrc(textOf(lrcFile));

    ArchiveFile? named(String name) {
      for (final f in files) {
        if (f.name == name) return f;
      }
      return null;
    }

    // The instrumental is the entry the Instrumental row names; files made by 1.0.x have no
    // such row, and then it is the only .mp3 that is not a vocals track.
    final ArchiveFile? instrumental;
    final row = nfo['Instrumental'];
    if (row != null) {
      instrumental = named(row);
    } else {
      final candidates = [
        for (final f in files)
          if (f.name.toLowerCase().endsWith('.mp3') && !_isVocals(f.name)) f,
      ];
      instrumental = candidates.length == 1 ? candidates.single : null;
    }
    if (instrumental == null) throw const KarMp3Exception('This .karmp3 has no instrumental');

    Uint8List? vocals;
    final vocalsRow = nfo['Vocals'];
    if (vocalsRow != null) {
      final entry = named(vocalsRow);
      if (entry == null) {
        throw const KarMp3Exception('This .karmp3 names a vocals track that is not in it');
      }
      vocals = entry.readBytes() ?? Uint8List(0);
    }

    final entryName = instrumental.name;
    return KarMp3Contents(
      name: entryName.substring(0, entryName.length - '.mp3'.length),
      instrumental: instrumental.readBytes() ?? Uint8List(0),
      vocals: vocals,
      tags: lrc.tags,
      lines: lrc.lines,
      nfo: nfo,
    );
  } on KarMp3Exception {
    rethrow;
  } catch (_) {
    throw const KarMp3Exception('This is not a .karmp3 file');
  }
}
