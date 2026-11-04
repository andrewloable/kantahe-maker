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

  group('shiftTo', () {
    test('shift_keeps_the_gaps', () {
      final s = three(times: [10, 14, 20])..shiftTo(12);
      expect(s.times, [12, 16, 22]);
      s.shiftTo(9);
      expect(s.times, [9, 13, 19]);
    });

    test('shift_skips_untapped_lines', () {
      final s = three(times: [10, null, 20])..shiftTo(11);
      expect(s.times, [11, null, 21]);
    });

    test('shift_moves_word_times_too', () {
      final s = TapSession(
        ['a b', 'c'],
        times: [10, 14],
        wordTimes: [
          [10, 12],
          null,
        ],
      )..shiftTo(11);
      expect(s.times, [11, 15]);
      expect(s.wordTimes[0], [11, 13]);
    });

    test('shift_never_goes_below_zero', () {
      final s = three(times: [1, 2, 0.5])..shiftTo(0);
      expect(s.times, [0, 1, 0]);
    });

    test('shift_needs_a_tapped_first_line', () {
      final s = three(times: [null, 2, 3])..shiftTo(5);
      expect(s.times, [null, 2, 3]);
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

    test('word_stamp_first_call_times_the_first_word', () {
      final s = hello()..wordStamp(0, 1.4);
      expect(s.wordTimes[0], [1.4, null, null]);
      expect(s.times, [1.4, 2], reason: 'the first word is where the line starts');
      expect(s.wordTimes[1], isNull);
    });

    test('word_stamp_fills_in_order_and_stops_when_full', () {
      final s = hello()..wordStamp(0, 1.4)..wordStamp(0, 1.9)..wordStamp(0, 2.3);
      expect(s.wordTimes[0], [1.4, 1.9, 2.3]);
      s.wordStamp(0, 5);
      expect(s.wordTimes[0], [1.4, 1.9, 2.3]);
    });

    test('word_stamp_needs_a_tapped_line', () {
      expect(() => hello(times: [null, 2]).wordStamp(0, 1), throwsStateError);
      expect(() => hello().wordStamp(2, 1), throwsRangeError);
    });

    test('word_stamp_one_word_line_takes_one_press', () {
      final s = hello()..wordStamp(1, 5)..wordStamp(1, 6);
      expect(s.wordTimes[1], [5.0]);
    });

    test('undo_word', () {
      final s = hello()..wordStamp(0, 1.4)..wordStamp(0, 1.9);
      s.undoWord(0);
      expect(s.wordTimes[0], [1.4, null, null]);
      s.undoWord(0);
      expect(s.wordTimes[0], isNull, reason: 'no word is left: line-only again');
      s.undoWord(0);
      s.undoWord(1);
      expect(s.wordTimes, [null, null]);
      expect(s.times, [1.4, 2], reason: 'the line keeps the time of its first word');
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

  group('wordMarks', () {
    const lit = WordMark.lit, current = WordMark.current, plain = WordMark.plain;

    test('timing_before_any_tap_the_first_word_is_current', () {
      expect(wordMarks(wordCount: 3, timing: true), [current, plain, plain]);
      expect(wordMarks(wordCount: 3, times: [null, null, null], timing: true), [current, plain, plain]);
    });

    test('timing_with_a_gap', () {
      expect(wordMarks(wordCount: 3, times: [1.0, null, 1.9], timing: true), [lit, plain, current]);
      expect(wordMarks(wordCount: 3, times: [null, 1.4, null], timing: true), [plain, current, plain]);
    });

    test('timing_a_one_word_line', () {
      expect(wordMarks(wordCount: 1, timing: true), [current]);
      expect(wordMarks(wordCount: 1, times: [1.0], timing: true), [current]);
    });

    test('timing_the_current_word_is_the_last_one_timed', () {
      expect(wordMarks(wordCount: 3, times: [1.0, null, null], timing: true), [current, plain, plain]);
      expect(wordMarks(wordCount: 3, times: [1.0, 1.4, null], timing: true), [lit, current, plain]);
      expect(wordMarks(wordCount: 3, times: [1.0, 1.4, 1.9], timing: true), [lit, lit, current]);
    });

    test('playing_lights_words_whose_time_has_come', () {
      const times = <double?>[1.0, 1.4, 1.9];
      expect(wordMarks(wordCount: 3, times: times, position: 1.5), [lit, lit, plain]);
      expect(wordMarks(wordCount: 3, times: times, position: 0.9), [plain, plain, plain]);
      expect(wordMarks(wordCount: 3, times: times, position: 1.0), [lit, plain, plain]);
      expect(wordMarks(wordCount: 3, times: times, position: 2.0), [lit, lit, lit]);
    });

    test('playing_uses_the_offset', () {
      expect(
        wordMarks(wordCount: 3, times: [1.0, 1.4, 1.9], position: 1.5, offset: 0.3),
        [lit, plain, plain],
      );
      expect(
        wordMarks(wordCount: 3, times: [1.0, 1.4, 1.9], position: 1.5, offset: -0.3),
        [lit, lit, plain],
      );
    });

    test('playing_ignores_untimed_words', () {
      expect(
        wordMarks(wordCount: 3, times: [1.0, null, 1.9], position: 5),
        [lit, plain, lit],
      );
    });

    test('playing_never_marks_a_next_word', () {
      expect(
        wordMarks(wordCount: 3, times: [1.0, null, null], position: 5).contains(current),
        isFalse,
      );
    });

    test('no_word_times_no_marks', () {
      expect(wordMarks(wordCount: 3, position: 5), [plain, plain, plain]);
      expect(wordMarks(wordCount: 0, timing: true), isEmpty);
    });

    test('a_time_list_longer_or_shorter_than_the_words_is_safe', () {
      expect(wordMarks(wordCount: 2, times: [1.0, 1.4, 1.9], position: 9), [lit, lit]);
      expect(wordMarks(wordCount: 3, times: [1.0], position: 9), [lit, plain, plain]);
    });
  });

  group('resetWords', () {
    TapSession twoLines() => TapSession(
      ['la la la', 'na na'],
      times: [1.0, 2.0],
    )
      ..wordStamp(0, 1.0)
      ..wordStamp(0, 1.4)
      ..wordStamp(0, 1.9)
      ..wordStamp(1, 2.0)
      ..wordStamp(1, 2.5);

    test('reset_words_clears_one_line', () {
      final s = twoLines()..resetWords(0);
      expect(s.wordTimes, [
        null,
        [2.0, 2.5],
      ]);
      expect(s.times, [1.0, 2.0]);
      expect(s.isComplete, isTrue);
    });

    test('reset_words_on_a_line_without_words_does_nothing', () {
      final s = TapSession(['la la'], times: [1.0])..resetWords(0);
      expect(s.wordTimes, [null]);
      expect(s.times, [1.0]);
    });

    test('reset_words_bad_index_throws', () {
      expect(() => twoLines().resetWords(5), throwsRangeError);
    });
  });

  group('setTimes', () {
    test('sets_line_and_words', () {
      final s = TapSession(['la la', 'na'], times: [1.0, 2.0]);
      s.setTimes(0, 1.5, [1.5, 1.8]);
      expect(s.times[0], 1.5);
      expect(s.wordTimes[0], [1.5, 1.8]);
    });

    test('null_words_makes_the_line_line_only', () {
      final s = TapSession(['la la', 'na'], times: [1.0, 2.0]);
      s.setTimes(0, 1.5, [1.5, 1.8]);
      s.setTimes(0, 1.0, null);
      expect(s.times[0], 1.0);
      expect(s.wordTimes[0], isNull);
    });

    test('line_before_the_line_above_throws', () {
      final s = TapSession(['a', 'b', 'c'], times: [1.0, 2.0, null]);
      expect(() => s.setTimes(1, 0.5, null), throwsArgumentError);
      expect(s.times, [1.0, 2.0, null]);
    });

    test('line_after_the_line_below_throws', () {
      final s = TapSession(['a', 'b', 'c'], times: [1.0, null, 3.0]);
      expect(() => s.setTimes(1, 3.5, null), throwsArgumentError);
      expect(s.times, [1.0, null, 3.0]);
    });

    test('word_before_line_start_throws', () {
      final s = TapSession(['la la', 'na'], times: [1.0, 2.0]);
      expect(() => s.setTimes(0, 1.0, [0.9, 1.2]), throwsArgumentError);
    });

    test('word_out_of_order_throws', () {
      final s = TapSession(['la la', 'na'], times: [1.0, 2.0]);
      expect(() => s.setTimes(0, 1.0, [1.5, 1.2]), throwsArgumentError);
    });

    test('word_after_the_next_line_throws', () {
      final s = TapSession(['la la', 'na'], times: [1.0, 2.0]);
      expect(() => s.setTimes(0, 1.0, [1.5, 2.5]), throwsArgumentError);
    });

    test('wrong_word_count_throws', () {
      final s = TapSession(['la la la', 'na'], times: [1.0, 2.0]);
      expect(() => s.setTimes(0, 1.0, [1.0, 1.2]), throwsArgumentError);
    });

    test('negative_time_throws', () {
      final s = TapSession(['la', 'na'], times: [1.0, 2.0]);
      expect(() => s.setTimes(0, -1, null), throwsArgumentError);
      expect(s.times[0], 1.0);
    });

    test('untapped_line_can_be_set', () {
      final s = TapSession(['la', 'na'], times: [null, null]);
      s.setTimes(1, 2.0, null);
      expect(s.times, [null, 2.0]);
    });
  });

  group('shiftBy', () {
    TapSession timed() => TapSession(['la la', 'na'], times: [1.0, 2.0])
      ..setTimes(0, 1.0, [1.0, 1.5]);

    test('moves_every_line_and_word', () {
      final s = timed()..shiftBy(-0.5);
      expect(s.times, [0.5, 1.5]);
      expect(s.wordTimes[0], [0.5, 1.0]);
    });

    test('positive_shift_moves_later', () {
      final s = timed()..shiftBy(1.25);
      expect(s.times, [2.25, 3.25]);
      expect(s.wordTimes[0], [2.25, 2.75]);
    });

    test('untapped_lines_stay_untapped', () {
      final s = TapSession(['a', 'b'], times: [1.0, null])..shiftBy(1);
      expect(s.times, [2.0, null]);
    });

    test('below_zero_throws_and_changes_nothing', () {
      final s = TapSession(['a', 'b'], times: [0.5, 2.0]);
      expect(() => s.shiftBy(-1), throwsArgumentError);
      expect(s.times, [0.5, 2.0]);
    });

    test('non_finite_throws', () {
      final s = TapSession(['a'], times: [1.0]);
      expect(() => s.shiftBy(double.nan), throwsArgumentError);
    });
  });
}
