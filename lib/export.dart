// Turning a finished project into a .karmp3 file, and saying what is still missing.
// Pure Dart: no Flutter imports.

import 'dart:io';

import 'karmp3.dart';
import 'mp3_info.dart';
import 'project.dart';
import 'tap_session.dart';
import 'tool_pins.dart';

/// Text on one line: whitespace runs (including line breaks and tabs) become one space.
/// The title, artist, composer and lyricist go through this before they reach the .lrc
/// and .nfo, whose lines must stay one per field.
String oneLine(String s) =>
    s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');

/// The file to write for the place [chosen] in the Save dialog. Windows can answer with a
/// folder (an existing one, or a path ending in a separator) or with nothing but the
/// extension; that must not become a file called ".karmp3", so those get [suggestedName]
/// inside the folder. Both kinds of separator count, whatever the host OS. A missing
/// ".karmp3" is added. [isDirectory] is for tests.
String exportDestination(
  String chosen,
  String suggestedName, {
  bool Function(String path)? isDirectory,
}) {
  const ext = '.karmp3';
  final path = chosen.trim();
  final cut = path.lastIndexOf(RegExp(r'[\\/]'));
  final folder = cut < 0 ? '' : path.substring(0, cut + 1);
  final name = path.substring(cut + 1);
  final isFolder =
      name.isEmpty || (isDirectory ?? (d) => Directory(d).existsSync())(path);
  if (isFolder || name.toLowerCase() == ext) {
    final dir = isFolder && name.isNotEmpty
        ? path + (path.contains(r'\') ? r'\' : '/')
        : folder;
    return '$dir$suggestedName';
  }
  return name.toLowerCase().endsWith(ext) ? path : '$path$ext';
}

/// What stops the export, in the order the user should fix it; empty means ready.
List<String> exportBlockers(
  SongProject p, {
  required bool instrumentalReady,
  bool vocalsReady = false,
}) {
  final lines = p.lyricLines();
  return [
    if (!instrumentalReady) 'Vocal removal is not finished',
    if (p.includeVocals && !vocalsReady) 'The vocals track is missing',
    if (lines.isEmpty) 'Add lyrics' else ...timingBlockers(p),
    if (oneLine(p.title).isEmpty) 'Title is required',
    if (oneLine(p.artist).isEmpty) 'Artist is required',
  ];
}

/// The taps of the lyric lines (a missing entry counts as not tapped).
List<double?> _tapsFor(List<String> lines, SongProject p) => [
  for (var i = 0; i < lines.length; i++) i < p.times.length ? p.times[i] : null,
];

/// What stops the timing: untapped lines or taps out of order. Empty when there are no
/// lyric lines (exportBlockers says "Add lyrics" for that).
List<String> timingBlockers(SongProject p) {
  final lines = p.lyricLines();
  if (lines.isEmpty) return const [];
  final times = _tapsFor(lines, p);
  final untapped = times.where((t) => t == null).length;
  if (untapped > 0) return ['$untapped line(s) not tapped yet'];
  if (!TapSession(lines, times: times).isComplete) {
    return ['Timing is out of order'];
  }
  return const [];
}

/// Writes the .karmp3 for [p] to [dest]: the instrumental from [work], the lyrics timed
/// as tapped (plus the offset) and the song info. Throws StateError, writing nothing,
/// while [exportBlockers] is not empty.
Future<void> exportKarMp3(
  SongProject p,
  Directory work,
  String dest, {
  required double durationSeconds,
}) async {
  final mp3 = File('${work.path}/instrumental.mp3');
  final vocals = File('${work.path}/vocals.mp3');
  final blockers = exportBlockers(
    p,
    instrumentalReady: mp3.existsSync(),
    vocalsReady: vocals.existsSync(),
  );
  if (blockers.isNotEmpty) throw StateError(blockers.join('; '));

  // What the file says about itself, so the .nfo is right for songs made by older versions
  // too (their instrumental has another bitrate). Left out when it cannot be read.
  final instrumentalBytes = await mp3.readAsBytes();
  final instrumentalInfo = readMp3Info(instrumentalBytes);
  final vocalsInfo = p.includeVocals ? readMp3Info(await vocals.readAsBytes()) : null;

  final lines = p.lyricLines();
  final session = TapSession(
    lines,
    times: _tapsFor(lines, p),
    wordTimes: p.wordTimes,
    offset: p.offset,
  );
  final title = oneLine(p.title), artist = oneLine(p.artist);
  final composer = oneLine(p.composer), lyricist = oneLine(p.lyricist);
  final name = karMp3Name(number: p.number, artist: artist, title: title);
  final lrc = buildLrc(
    title: title,
    artist: artist,
    composer: composer,
    lines: session.exportLines(),
  );
  final nfo = Nfo(
    title: title,
    artist: artist,
    number: p.number,
    composer: composer,
    lyricist: lyricist,
    seconds: durationSeconds.round(),
    audio: instrumentalInfo == null ? '' : describeMp3(instrumentalInfo),
    separator: separatorModel.replaceAll(RegExp(r'\.onnx$'), ''),
    instrumental: '$name.mp3',
    vocals: p.includeVocals ? '$name.vocals.mp3' : '',
    vocalsAudio: vocalsInfo == null ? '' : describeMp3(vocalsInfo, withChannels: true),
    lyricLines: lines.length,
    lyricTiming: switch (p.timingSource) {
      'lrclib' => 'from lrclib.net synced lyrics',
      'lrclib+tapped' =>
        'from lrclib.net synced lyrics, corrected by hand in Kantahe Maker',
      _ => 'tapped by hand in Kantahe Maker',
    },
  ).toString();
  await writeKarMp3(
    dest,
    name: name,
    mp3: instrumentalBytes,
    lrc: lrc,
    nfo: nfo,
    vocals: p.includeVocals ? await vocals.readAsBytes() : null,
  );
}
