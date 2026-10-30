import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/tap_session.dart';

TapSession three({List<double?>? times, double offset = 0}) =>
    TapSession(['a', 'b', 'c'], times: times, offset: offset);

void main() {
  group('stamp', () {
    test('stamp_advances', () {
      final s = three()..stamp(1)..stamp(2);
      expect(s.times, [1, 2, null]);
      expect(s.next, 2);
      expect(s.isComplete, isFalse);
    });

    test('stamp_when_full', () {
      final s = three()..stamp(1)..stamp(2)..stamp(3);
      s.stamp(9);
      expect(s.times, [1, 2, 3]);
      expect(s.next, 3);
    });

    test('stamp_clears_lower_later', () {
      final s = three(times: [1, null, 0.5]);
      expect(s.next, 1);
      s.stamp(2);
      expect(s.times, [1, 2, null]);
    });

    test('stamp_keeps_higher_later', () {
      final s = three(times: [null, null, 9]);
      s.stamp(1);
      expect(s.times, [1, null, 9]);
    });

    test('stamp_stores_the_raw_time_whatever_the_offset', () {
      final s = three(offset: -0.3)..stamp(1);
      expect(s.times, [1, null, null]);
      s.offset = 0.4;
      expect(s.times, [1, null, null], reason: 'changing the offset keeps the taps');
    });

    test('stamp_equal_time_is_allowed', () {
      final s = three()..stamp(1)..stamp(1)..stamp(1);
      expect(s.times, [1, 1, 1]);
      expect(s.next, 3);
      expect(s.isComplete, isTrue);
    });
  });

  group('select', () {
    test('select_clears_rest', () {
      final s = three(times: [1, 2, 3])..select(1);
      expect(s.times, [1, null, null]);
      expect(s.next, 1);
      s.stamp(1.5);
      expect(s.times, [1, 1.5, null]);
    });

    test('select_first_clears_everything', () {
      final s = three(times: [1, 2, 3])..select(0);
      expect(s.times, [null, null, null]);
      expect(s.next, 0);
    });

    test('select_out_of_range', () {
      final s = three(times: [1, 2, 3]);
      expect(() => s.select(3), throwsRangeError);
      expect(() => s.select(-1), throwsRangeError);
      expect(s.times, [1, 2, 3]);
    });
  });

  group('undo', () {
    test('undo', () {
      final s = three(times: [1, 2, null])..undo();
      expect(s.times, [1, null, null]);
      expect(s.next, 1);
    });

    test('undo_on_empty_session', () {
      final s = three()..undo();
      expect(s.times, [null, null, null]);
      expect(s.next, 0);
    });

    test('undo_after_complete', () {
      final s = three(times: [1, 2, 3])..undo();
      expect(s.times, [1, 2, null]);
    });
  });

  group('export', () {
    test('export_offset', () {
      final s = three(times: [1, 2, 3], offset: -0.2);
      expect(s.isComplete, isTrue);
      final out = s.exportLines();
      expect(out.map((e) => e.text), ['a', 'b', 'c']);
      expect(out[0].seconds, closeTo(0.8, 1e-9));
      expect(out[1].seconds, closeTo(1.8, 1e-9));
      expect(out[2].seconds, closeTo(2.8, 1e-9));
    });

    test('export_clamps_at_zero', () {
      final s = three(times: [0.2, 1, 2], offset: -0.5);
      expect(s.exportLines().first.seconds, 0);
    });

    test('export_incomplete', () {
      expect(() => three(times: [1, null, 3]).exportLines(), throwsStateError);
    });

    test('export_out_of_order_is_incomplete', () {
      final s = three(times: [1, 3, 2]);
      expect(s.isComplete, isFalse);
      expect(() => s.exportLines(), throwsStateError);
    });

    test('offset_does_not_change_stored_times', () {
      final s = three(times: [1, 2, 3], offset: 0.25);
      s.exportLines();
      expect(s.times, [1, 2, 3]);
    });

    test('empty_session', () {
      final s = TapSession(const []);
      expect(s.next, 0);
      expect(s.isComplete, isTrue);
      expect(s.exportLines(), isEmpty);
      expect(s.activeLine(5), -1);
      s.stamp(1);
      s.undo();
      expect(s.times, isEmpty);
    });
  });

  group('activeLine', () {
    test('active_line', () {
      final s = three(times: [1, 2, 3]);
      expect(s.activeLine(0.5), -1);
      expect(s.activeLine(2.0), 1);
      expect(s.activeLine(99), 2);
    });

    test('active_line_with_offset', () {
      final s = three(times: [1, 2, 3], offset: 0.5);
      expect(s.activeLine(1.2), -1);
      expect(s.activeLine(1.5), 0);
    });

    test('active_line_ignores_untapped', () {
      final s = three(times: [1, null, null]);
      expect(s.activeLine(99), 0);
    });
  });

  group('offset', () {
    test('offset_clamp', () {
      final s = three()..offset = 2;
      expect(s.offset, 0.5);
      s.offset = -9;
      expect(s.offset, -0.5);
      s.offset = 0.25;
      expect(s.offset, 0.25);
    });

    test('offset_clamped_in_constructor', () {
      expect(three(offset: 5).offset, 0.5);
    });
  });

  group('construction', () {
    test('ctor_length_mismatch', () {
      expect(() => TapSession(['a', 'b'], times: [1, 2, 3]), throwsArgumentError);
    });

    test('ctor_copies_the_inputs', () {
      final lines = ['a'];
      final times = <double?>[1];
      final s = TapSession(lines, times: times);
      lines.add('x');
      times[0] = 9;
      expect(s.times, [1]);
      expect(s.exportLines().map((e) => e.text), ['a']);
    });

    test('times_view_is_read_only', () {
      final s = three(times: [1, 2, 3]);
      expect(() => s.times[0] = 5, throwsUnsupportedError);
      expect(s.times, [1, 2, 3]);
    });
  });

  group('words', () {
    TapSession hello({
      List<double?>? times = const [1, 2],
      List<List<double?>?>? words,
      double offset = 0,
    }) =>
        TapSession(['Hello big world', 'bye'], times: times, wordTimes: words, offset: offset);

    TapSession pairs({List<double?>? times, List<List<double?>?>? words}) =>
        TapSession(['a b', 'c d', 'e f'], times: times, wordTimes: words);

    test('split_words', () {
      expect(splitWords('Hello  big world'), ['Hello ', 'big ', 'world']);
    });

    test('split_words_edges', () {
      expect(splitWords('  one\ttwo \n'), ['one ', 'two']);
      expect(splitWords('solo'), ['solo']);
      expect(splitWords('   '), isEmpty);
      expect(splitWords('Hello  big world').join(), 'Hello big world');
    });

    test('word_stamp_first_word_takes_the_line_time', () {
      final s = hello()..wordStamp(0, 1.4);
      expect(s.wordTimes[0], [1.0, 1.4, null]);
      expect(s.wordTimes[1], isNull);
    });

    test('word_stamp_fills_in_order_and_stops_when_full', () {
      final s = hello()..wordStamp(0, 1.4)..wordStamp(0, 1.9);
      expect(s.wordTimes[0], [1.0, 1.4, 1.9]);
      s.wordStamp(0, 5);
      expect(s.wordTimes[0], [1.0, 1.4, 1.9]);
    });

    test('word_stamp_needs_a_tapped_line', () {
      expect(() => hello(times: [null, 2]).wordStamp(0, 1), throwsStateError);
      expect(() => hello().wordStamp(2, 1), throwsRangeError);
    });

    test('word_stamp_one_word_line_has_nothing_to_time', () {
      final s = hello()..wordStamp(1, 5);
      expect(s.wordTimes[1], isNull);
    });

    test('undo_word', () {
      final s = hello()..wordStamp(0, 1.4)..wordStamp(0, 1.9);
      s.undoWord(0);
      expect(s.wordTimes[0], [1.0, 1.4, null]);
      s.undoWord(0);
      expect(s.wordTimes[0], isNull, reason: 'only the line time is left: line-only again');
      s.undoWord(0);
      s.undoWord(1);
      expect(s.wordTimes, [null, null]);
      expect(s.times, [1, 2], reason: 'the line taps stay');
    });

    test('line_changes_clear_the_words_of_the_lines_they_clear', () {
      List<List<double?>?> all() => [
            [1.0, 1.5],
            [2.0, 2.5],
            [3.0, 3.5],
          ];
      final sel = pairs(times: [1, 2, 3], words: all())..select(1);
      expect(sel.wordTimes, [
        [1.0, 1.5],
        null,
        null,
      ]);
      final und = pairs(times: [1, 2, 3], words: all())..undo();
      expect(und.wordTimes, [
        [1.0, 1.5],
        [2.0, 2.5],
        null,
      ]);
      // Stamping line 1 at 3 s makes the already tapped line 2 (at 2 s) wrong.
      final st = pairs(times: [1, null, 2], words: [
        [1.0, 1.5],
        null,
        [2.0, 2.5],
      ])..stamp(3);
      expect(st.times, [1, 3, null]);
      expect(st.wordTimes, [
        [1.0, 1.5],
        null,
        null,
      ]);
    });

    test('word_export', () {
      final out = hello(words: [
        [1.0, 1.4, 1.9],
        null,
      ]).exportLines();
      expect(out[0].seconds, 1);
      expect(out[0].words, [(1.0, 'Hello '), (1.4, 'big '), (1.9, 'world')]);
      expect(out[1].words, isEmpty);
      expect(out[1].text, 'bye');
    });

    test('word_export_applies_the_offset_and_clamps_at_zero', () {
      final out = hello(times: [0.2, 2], offset: -0.5, words: [
        [0.2, 0.4, 1.0],
        null,
      ]).exportLines();
      expect(out[0].words.map((w) => w.$1).toList(), [0.0, 0.0, closeTo(0.5, 1e-9)]);
      expect(out[0].words.map((w) => w.$2).join(), 'Hello big world');
    });

    test('partial_words_fallback', () {
      // Control: the same line with every word timed does get its words.
      expect(
          hello(words: [
            [1.0, 1.4, 1.9],
            null,
          ]).exportLines()[0].words,
          hasLength(3));
      final out = hello(words: [
        [1.0, null, 1.9],
        null,
      ]).exportLines();
      expect(out[0].words, isEmpty);
      expect(out[0].text, 'Hello big world');
    });

    test('decreasing_words_fall_back_to_the_line', () {
      // Control: the same line with every word timed does get its words.
      expect(
          hello(words: [
            [1.0, 1.4, 1.9],
            null,
          ]).exportLines()[0].words,
          hasLength(3));
      final out = hello(words: [
        [1.0, 1.9, 1.4],
        null,
      ]).exportLines();
      expect(out[0].words, isEmpty);
      expect(out[0].seconds, 1);
    });

    test('line_only_session_exports_no_words', () {
      // Control: the same line with every word timed does get its words.
      expect(
          hello(words: [
            [1.0, 1.4, 1.9],
            null,
          ]).exportLines()[0].words,
          hasLength(3));
      expect(three(times: [1, 2, 3]).exportLines().every((l) => l.words.isEmpty), isTrue);
    });

    test('ctor_drops_word_times_that_do_not_fit', () {
      final s = hello(times: [1, null], words: [
        [1.0, 1.4],
        [2.0],
      ]);
      expect(s.wordTimes, [null, null], reason: 'wrong word count; untapped line');
      final long = hello(words: [null, null, [1.0]]);
      expect(long.wordTimes.length, 2, reason: 'one entry per line');
      final short = hello(words: [
        [1.0, 1.4, 1.9],
      ]);
      expect(short.wordTimes, [
        [1.0, 1.4, 1.9],
        null,
      ]);
    });

    test('word_times_view_and_inputs_are_copied', () {
      final input = <List<double?>?>[
        [1.0, 1.4, 1.9],
        null,
      ];
      final s = hello(words: input);
      input[0]![1] = 9;
      expect(s.wordTimes[0], [1.0, 1.4, 1.9]);
      expect(() => s.wordTimes[0]![1] = 5, throwsUnsupportedError);
      expect(() => s.wordTimes[1] = [1.0], throwsUnsupportedError);
      s.wordStamp(1, 5);
      expect(s.wordTimes[0], [1.0, 1.4, 1.9]);
    });
  });
}
