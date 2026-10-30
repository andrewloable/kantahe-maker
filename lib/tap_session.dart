// Tap-timing logic: the user presses a key at the start of each lyric line while the
// song plays. Times are stored as tapped; the reaction-time offset is applied only when
// the lines are exported or previewed, so changing it never loses a tap.
// Pure Dart: no Flutter imports.

import 'karmp3.dart';

/// [line] cut into words. Every word but the last keeps one trailing space, so joining
/// them gives the line back with its runs of spaces collapsed.
List<String> splitWords(String line) {
  final words = line.trim().split(RegExp(r'\s+'));
  if (words.length == 1 && words.single.isEmpty) return const [];
  return [
    for (var i = 0; i < words.length; i++)
      i < words.length - 1 ? '${words[i]} ' : words[i],
  ];
}

class TapSession {
  TapSession(
    List<String> lines, {
    List<double?>? times,
    List<List<double?>?>? wordTimes,
    double offset = 0,
  }) : _lines = List.unmodifiable(lines),
       _times = times == null
           ? List.filled(lines.length, null)
           : List.of(times) {
    if (_times.length != _lines.length) {
      throw ArgumentError('${_times.length} times for ${_lines.length} lines');
    }
    // Word times that do not fit their line (another word count, or a line that is not
    // tapped) are dropped rather than refused: they come from a file on disk.
    _words = [
      for (var i = 0; i < _lines.length; i++)
        if (wordTimes != null &&
            i < wordTimes.length &&
            wordTimes[i] != null &&
            _times[i] != null &&
            wordTimes[i]!.length == splitWords(_lines[i]).length)
          List.of(wordTimes[i]!)
        else
          null,
    ];
    this.offset = offset;
  }

  static const maxOffset = 0.5;

  final List<String> _lines;
  final List<double?> _times;
  late final List<List<double?>?> _words;
  double _offset = 0;

  /// The tapped time of every word of every line; null for a line timed as a whole.
  /// Read-only.
  List<List<double?>?> get wordTimes => List.unmodifiable([
    for (final w in _words) w == null ? null : List<double?>.unmodifiable(w),
  ]);

  /// Gives the next untimed word of [line] the time [t]. The first word always has the
  /// line's own time, so the first call times the second word. Does nothing when every
  /// word is timed. Throws StateError if [line] is not tapped.
  void wordStamp(int line, double t) {
    RangeError.checkValidIndex(line, _lines);
    final start = _times[line];
    if (start == null) throw StateError('Line $line is not tapped yet');
    final words =
        _words[line] ??
        (List<double?>.filled(splitWords(_lines[line]).length, null)
          ..[0] = start);
    final i = words.indexOf(null);
    if (i < 0) return;
    words[i] = t;
    _words[line] = words;
  }

  /// Removes the last word tap of [line]; the line goes back to line-only timing when
  /// only the line time is left.
  void undoWord(int line) {
    RangeError.checkValidIndex(line, _lines);
    final words = _words[line];
    if (words == null) return;
    final i = words.lastIndexWhere((t) => t != null);
    if (i > 0) words[i] = null;
    if (i <= 1) _words[line] = null;
  }

  /// The tapped time of every line, null where not tapped yet. Read-only.
  List<double?> get times => List.unmodifiable(_times);

  /// The index of the first line that has not been tapped, or the number of lines.
  int get next {
    final i = _times.indexOf(null);
    return i < 0 ? _lines.length : i;
  }

  /// Gives the next untapped line the time [t]. Later lines that were tapped earlier
  /// than [t] cannot be right any more and are cleared. Does nothing when all lines are
  /// tapped.
  void stamp(double t) {
    final i = next;
    if (i >= _lines.length) return;
    _times[i] = t;
    for (var j = i + 1; j < _times.length; j++) {
      final later = _times[j];
      if (later != null && later < t) _clear(j);
    }
  }

  /// Removes the last tap.
  void undo() {
    final i = _times.lastIndexWhere((t) => t != null);
    if (i >= 0) _clear(i);
  }

  void _clear(int line) {
    _times[line] = null;
    _words[line] = null;
  }

  /// Goes back to line [i] to tap it again: its time and every later one are cleared.
  void select(int i) {
    RangeError.checkValidIndex(i, _times);
    for (var j = i; j < _times.length; j++) {
      _clear(j);
    }
  }

  /// Every line is tapped and the times never go backwards.
  bool get isComplete {
    double? previous;
    for (final t in _times) {
      if (t == null || (previous != null && t < previous)) return false;
      previous = t;
    }
    return true;
  }

  /// Seconds added to every tap, between -0.5 and 0.5 (a negative value makes up for
  /// tapping late).
  double get offset => _offset;
  set offset(double v) => _offset = v.clamp(-maxOffset, maxOffset).toDouble();

  /// The line being sung at [position] seconds: the last tapped line whose time (with the
  /// offset) has passed, or -1.
  int activeLine(double position) {
    for (var i = _times.length - 1; i >= 0; i--) {
      final t = _times[i];
      if (t != null && t + _offset <= position) return i;
    }
    return -1;
  }

  double _shifted(double t) => t + _offset < 0 ? 0.0 : t + _offset;

  /// Every line with its time (with the offset); a line gets its words only when every
  /// word is timed and the times never go backwards, otherwise it stays line-only.
  /// Throws StateError unless [isComplete].
  List<LrcLine> exportLines() {
    if (!isComplete) {
      throw StateError(
        'Not every line is tapped, or the times are out of order',
      );
    }
    return [
      for (var i = 0; i < _lines.length; i++)
        LrcLine(_shifted(_times[i]!), _lines[i], _wordsOf(i)),
    ];
  }

  List<(double, String)> _wordsOf(int line) {
    final times = _words[line];
    if (times == null || times.contains(null)) return const [];
    for (var i = 1; i < times.length; i++) {
      if (times[i]! < times[i - 1]!) return const [];
    }
    final parts = splitWords(_lines[line]);
    return [
      for (var i = 0; i < parts.length; i++) (_shifted(times[i]!), parts[i]),
    ];
  }
}
