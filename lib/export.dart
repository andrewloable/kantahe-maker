// Turning a finished project into a .karmp3 file, and saying what is still missing.
// Pure Dart: no Flutter imports.

import 'dart:io';

import 'karmp3.dart';
import 'project.dart';
import 'tap_session.dart';
import 'tool_pins.dart';

/// Text on one line: whitespace runs (including line breaks and tabs) become one space.
/// The title, artist, composer and lyricist go through this before they reach the .lrc
/// and .nfo, whose lines must stay one per field.
String oneLine(String s) =>
    s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');

/// What stops the export, in the order the user should fix it; empty means ready.
List<String> exportBlockers(SongProject p, {required bool instrumentalReady}) {
  final lines = p.lyricLines();
  return [
    if (!instrumentalReady) 'Vocal removal is not finished',
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
  final blockers = exportBlockers(p, instrumentalReady: mp3.existsSync());
  if (blockers.isNotEmpty) throw StateError(blockers.join('; '));

  final lines = p.lyricLines();
  final session = TapSession(
    lines,
    times: _tapsFor(lines, p),
    wordTimes: p.wordTimes,
    offset: p.offset,
  );
  final title = oneLine(p.title), artist = oneLine(p.artist);
  final composer = oneLine(p.composer), lyricist = oneLine(p.lyricist);
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
    audio: 'MP3, 44.1 kHz, 192 kbps',
    separator: separatorModel.replaceAll(RegExp(r'\.onnx$'), ''),
    lyricLines: lines.length,
  ).toString();
  await writeKarMp3(
    dest,
    name: karMp3Name(number: p.number, artist: artist, title: title),
    mp3: await mp3.readAsBytes(),
    lrc: lrc,
    nfo: nfo,
  );
}
