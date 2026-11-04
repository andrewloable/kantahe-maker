// What the preview of a .karmp3 (the Export step) needs besides audio: the lyric lines as the
// export writes them, which line and word is being sung at a time, and how the vocals are kept
// in step with the instrumental (the rule of the Kantahe web player: the vocals are moved to the
// instrumental's position when they are more than 150 ms away, at most once a second).
// Pure Dart: no Flutter imports.

import 'karmp3.dart' show LrcLine;
import 'project.dart';
import 'tap_session.dart';

/// The lyric lines the export would write for [p]: the tapped times plus the offset, and the
/// word times where every word is timed. Throws [StateError] unless the timing is complete
/// (the Export step offers the preview only then).
List<LrcLine> previewLines(SongProject p) {
  final lines = p.lyricLines();
  return TapSession(
    lines,
    times: [for (var i = 0; i < lines.length; i++) i < p.times.length ? p.times[i] : null],
    wordTimes: p.wordTimes,
    offset: p.offset,
  ).exportLines();
}

/// The index of the line being sung at [seconds] (the last one whose time has passed), or -1
/// before the first line.
int previewLineAt(List<LrcLine> lines, double seconds) {
  for (var i = lines.length - 1; i >= 0; i--) {
    if (lines[i].seconds <= seconds) return i;
  }
  return -1;
}

/// The index of the word being sung in [line] at [seconds], or -1 before its first word and
/// for a line without word times.
int previewWordAt(LrcLine line, double seconds) {
  for (var i = line.words.length - 1; i >= 0; i--) {
    if (line.words[i].$1 <= seconds) return i;
  }
  return -1;
}

/// Decides when the vocals player must be moved to the instrumental's position. Ask it every
/// 500 ms while both play. It never reads a clock: [now] comes from the caller.
class VocalsSync {
  VocalsSync({
    this.limit = const Duration(milliseconds: 150),
    this.pause = const Duration(seconds: 1),
  });

  /// How far apart the two may be before the vocals are moved.
  final Duration limit;

  /// The shortest time between two moves.
  final Duration pause;
  Duration? _lastReseek;

  /// True when the vocals are more than [limit] from the instrumental and the last move was at
  /// least [pause] ago; then [now] is remembered as the time of the move.
  bool shouldReseek({
    required Duration instrumental,
    required Duration vocals,
    required Duration now,
  }) {
    if ((instrumental - vocals).abs() <= limit) return false;
    final last = _lastReseek;
    if (last != null && now - last < pause) return false;
    _lastReseek = now;
    return true;
  }

  /// Forgets the last move (when the vocals are switched on again).
  void reset() => _lastReseek = null;
}

/// "m:ss" in whole seconds, rounded down; a negative time is "0:00".
String clockLabel(Duration d) {
  final seconds = d.inSeconds < 0 ? 0 : d.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// The vocals level for [percent]: rounded down to a step of 10, between 0 and 100, as a
/// fraction (55 gives 0.5).
double vocalsLevel(int percent) => (percent.clamp(0, 100) ~/ 10) * 10 / 100;
