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

/// How a word of a lyric line is shown while timing and while playing.
enum WordMark {
  /// Not reached or not timed.
  plain,

  /// Timed (in word timing) or already sung (while playing).
  lit,

  /// In word timing: the word being sung, the last one timed (the first word before any is).
  current,
}

/// The marks of the [wordCount] words of one line. [times] are the line's word times (null
/// when it has none). [timing] is word timing on this line: a timed word is lit and the last
/// timed one is [WordMark.current], the word being sung (the first word while none is timed).
/// Otherwise a word is lit when its time (plus [offset]) has come at [position]; there is
/// never a current word then.
List<WordMark> wordMarks({
  required int wordCount,
  List<double?>? times,
  bool timing = false,
  double? position,
  double offset = 0,
}) {
  final marks = List.filled(wordCount, WordMark.plain);
  if (timing) {
    var last = -1;
    for (var k = 0; k < wordCount; k++) {
      if (times != null && k < times.length && times[k] != null) {
        marks[k] = WordMark.lit;
        last = k;
      }
    }
    if (wordCount > 0) marks[last < 0 ? 0 : last] = WordMark.current;
  } else if (position != null && times != null) {
    for (var k = 0; k < wordCount && k < times.length; k++) {
      final t = times[k];
      if (t != null && t + offset <= position) marks[k] = WordMark.lit;
    }
  }
  return marks;
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

  /// Gives the next untimed word of [line] the time [t]; the first call times the first word,
  /// and the line's time becomes that time. Does nothing when every word is timed. Throws
  /// StateError if [line] is not tapped, and ArgumentError (changing nothing) if the first word
  /// would break the order of the lines.
  void wordStamp(int line, double t) {
    RangeError.checkValidIndex(line, _lines);
    if (_times[line] == null) throw StateError('Line $line is not tapped yet');
    final words =
        _words[line] ?? List<double?>.filled(splitWords(_lines[line]).length, null);
    final i = words.indexOf(null);
    if (i < 0) return;
    if (i == 0) {
      // The first word is where the line starts: the line's time moves to it. Throws
      // ArgumentError, and changes nothing, when that would break the order.
      _checkTimes(line, t, [t]);
      _times[line] = t;
    }
    words[i] = t;
    _words[line] = words;
  }

  /// Removes the last word tap of [line]; the line goes back to line-only timing when no word
  /// is left.
  void undoWord(int line) {
    RangeError.checkValidIndex(line, _lines);
    final words = _words[line];
    if (words == null) return;
    final i = words.lastIndexWhere((t) => t != null);
    if (i >= 0) words[i] = null;
    if (i <= 0) _words[line] = null;
  }

  /// Sets the time of [line] to [t] and its word times to [words] (null or empty: line-only
  /// timing), both at once. Works on untapped lines too. Throws ArgumentError, and changes
  /// nothing, when the time is negative, the word count is wrong, or the times would not
  /// stay in order with the nearest tapped lines above and below.
  void setTimes(int line, double t, List<double>? words) {
    RangeError.checkValidIndex(line, _lines);
    if (!t.isFinite || t < 0) throw ArgumentError('A time cannot be negative');
    if (words != null &&
        words.isNotEmpty &&
        words.length != splitWords(_lines[line]).length) {
      throw ArgumentError('Give one time per word');
    }
    _checkTimes(line, t, words);
    _times[line] = t;
    _words[line] = words == null || words.isEmpty
        ? null
        : List<double?>.of(words);
  }

  /// Throws ArgumentError when [t] for [line] and its [words] would not stay between the
  /// nearest tapped lines above and below, or the words would not follow each other.
  void _checkTimes(int line, double t, List<double?>? words) {
    final before = _tappedBefore(line);
    final after = _tappedAfter(line);
    if (before != null && t < _times[before]!) {
      throw ArgumentError('The line starts before the line above it');
    }
    if (after != null && t > _times[after]!) {
      throw ArgumentError('The line starts after the line below it');
    }
    final limit = after == null ? null : _times[after];
    double? last;
    for (final w in words ?? const <double>[]) {
      if (w == null) continue;
      if (w < t) throw ArgumentError('A word is before its line starts');
      if (last != null && w < last) {
        throw ArgumentError('The words are not in order');
      }
      if (limit != null && w > limit) {
        throw ArgumentError('A word is after the line below starts');
      }
      last = w;
    }
  }

  int? _tappedBefore(int line) {
    for (var j = line - 1; j >= 0; j--) {
      if (_times[j] != null) return j;
    }
    return null;
  }

  int? _tappedAfter(int line) {
    for (var j = line + 1; j < _times.length; j++) {
      if (_times[j] != null) return j;
    }
    return null;
  }

  /// Takes back all the word taps of [line]; it goes back to line-only timing (the line's own
  /// time stays).
  void resetWords(int line) {
    RangeError.checkValidIndex(line, _lines);
    _words[line] = null;
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

  /// Moves the first line to [t] and every other tapped line (and word) by the same
  /// amount, so the gaps between them stay. For lyrics whose times are right except for
  /// a constant lead-in error. Does nothing when the first line is not tapped.
  void shiftTo(double t) {
    final first = _times.isEmpty ? null : _times[0];
    if (first == null) return;
    final delta = t - first;
    double move(double v) => v + delta < 0 ? 0.0 : v + delta;
    for (var i = 0; i < _times.length; i++) {
      final v = _times[i];
      if (v != null) _times[i] = move(v);
      final w = _words[i];
      if (w != null) {
        for (var j = 0; j < w.length; j++) {
          final x = w[j];
          if (x != null) w[j] = move(x);
        }
      }
    }
  }

  /// Adds [delta] seconds (negative: earlier) to every tapped line and word, so the gaps stay.
  /// Throws ArgumentError, and changes nothing, when [delta] is not a number or a time would
  /// go below 0:00. Untapped lines stay untapped.
  void shiftBy(double delta) {
    if (!delta.isFinite) throw ArgumentError('Type the seconds, e.g. -1 or 0.5');
    // A word is never before its line, so checking the lines and the words is the same.
    for (final v in _times) {
      if (v != null && v + delta < 0) {
        throw ArgumentError('Moving by ${delta}s would put a time before 0:00');
      }
    }
    for (var i = 0; i < _times.length; i++) {
      final v = _times[i];
      if (v != null) _times[i] = v + delta;
      final w = _words[i];
      if (w != null) {
        for (var j = 0; j < w.length; j++) {
          final x = w[j];
          if (x != null) w[j] = x + delta;
        }
      }
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
