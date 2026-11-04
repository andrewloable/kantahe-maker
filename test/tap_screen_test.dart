import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/screens/tap_screen.dart';

import 'support/fake_player.dart';

class Harness {
  final player = FakePlayer();
  final changes = <(List<double?>, double)>[];
  final wordChanges = <List<List<double?>?>>[];
}

Future<Harness> pumpScreen(
  WidgetTester tester, {
  List<String> lines = const ['first line', 'second line', 'third line'],
  List<double?>? times,
  List<List<double?>?> wordTimes = const [],
  double offset = 0,
  String? instrumental = '/w/instrumental.mp3',
  ThemeMode mode = ThemeMode.light,
}) async {
  final h = Harness();
  await tester.binding.setSurfaceSize(const Size(900, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      themeMode: mode,
      home: Scaffold(
        body: TapScreen(
          lines: lines,
          sourcePath: '/w/source.mp3',
          instrumentalPath: instrumental,
          initialTimes: times ?? List.filled(lines.length, null),
          initialWordTimes: wordTimes,
          initialOffset: offset,
          onChanged: (t, o) => h.changes.add((List.of(t), o)),
          onWordTimesChanged: (w) => h.wordChanges.add([
            for (final l in w) l == null ? null : List.of(l),
          ]),
          createPlayer: () => h.player,
        ),
      ),
    ),
  );
  await tester.pump();
  return h;
}

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.pump();
}

String labelOfRow(WidgetTester tester, int i) {
  final row = find.byKey(ValueKey('line-$i'));
  final texts = tester.widgetList<Text>(
    find.descendant(of: row, matching: find.byType(Text)),
  );
  return texts.first.data!;
}

/// The tap screen next to a text field, like the song screen (lyrics field above it).
Future<Harness> pumpWithTextField(WidgetTester tester) async {
  final h = Harness();
  await tester.binding.setSurfaceSize(const Size(900, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            const TextField(key: ValueKey('other')),
            Expanded(
              child: TapScreen(
                lines: const ['first line', 'second line', 'third line'],
                sourcePath: '/w/source.mp3',
                instrumentalPath: '/w/instrumental.mp3',
                initialTimes: const [null, null, null],
                initialOffset: 0,
                onChanged: (t, o) => h.changes.add((List.of(t), o)),
                createPlayer: () => h.player,
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
  return h;
}

bool textFieldHasFocus() =>
    FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<TextField>() !=
        null ||
    FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>() !=
        null;

void main() {
  testWidgets('shows_every_line_with_its_stamp', (tester) async {
    await pumpScreen(tester, times: [1.5, null, null]);
    expect(find.text('first line'), findsOneWidget);
    expect(find.text('second line'), findsOneWidget);
    expect(find.text('third line'), findsOneWidget);
    expect(labelOfRow(tester, 0), '00:01.50');
    expect(labelOfRow(tester, 1), '--');
  });

  testWidgets('opens_the_source_file_paused_and_disposes_the_player', (
    tester,
  ) async {
    final h = await pumpScreen(tester);
    expect(h.player.opened.single.path, '/w/source.mp3');
    expect(h.player.opened.single.play, isFalse);
    expect(h.player.disposed, isFalse);
    await tester.pumpWidget(const SizedBox());
    expect(h.player.disposed, isTrue);
  });

  testWidgets('space_stamps_the_player_position', (tester) async {
    final h = await pumpScreen(tester);
    h.player.moveTo(const Duration(milliseconds: 12340));
    await tester.pump();
    await press(tester, LogicalKeyboardKey.space);
    expect(labelOfRow(tester, 0), '00:12.34');
    expect(h.changes.last.$1, [12.34, null, null]);
    h.player.moveTo(const Duration(seconds: 20));
    await press(tester, LogicalKeyboardKey.space);
    expect(h.changes.last.$1, [12.34, 20.0, null]);
  });

  testWidgets('stamp_reads_the_player_not_a_clock', (tester) async {
    final h = await pumpScreen(tester);
    h.player.position = const Duration(seconds: 7); // no stream event at all
    await press(tester, LogicalKeyboardKey.space);
    expect(h.changes.last.$1.first, 7.0);
  });

  testWidgets('a_held_key_stamps_only_once', (tester) async {
    final h = await pumpScreen(tester);
    h.player.moveTo(const Duration(seconds: 3));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(h.changes.last.$1, [3.0, null, null]);
    expect(h.changes, hasLength(1));
  });

  testWidgets('space_does_nothing_when_everything_is_tapped', (tester) async {
    final h = await pumpScreen(tester, times: [1, 2, 3]);
    await press(tester, LogicalKeyboardKey.space);
    expect(h.changes, isEmpty);
    // control: once a line is free again, the same key stamps it
    await press(tester, LogicalKeyboardKey.backspace);
    h.player.moveTo(const Duration(seconds: 8));
    await press(tester, LogicalKeyboardKey.space);
    expect(h.changes.last.$1, [1, 2, 8.0]);
  });

  testWidgets('backspace_undoes_the_last_tap', (tester) async {
    final h = await pumpScreen(tester, times: [1, 2, null]);
    await press(tester, LogicalKeyboardKey.backspace);
    expect(h.changes.last.$1, [1, null, null]);
    expect(labelOfRow(tester, 1), '--');
  });

  testWidgets('s_and_the_button_move_every_line_with_the_first', (tester) async {
    final h = await pumpScreen(tester, times: [10, 14, 20]);
    h.player.moveTo(const Duration(seconds: 12));
    await press(tester, LogicalKeyboardKey.keyS);
    expect(h.changes.last.$1, [12, 16, 22]);
    h.player.moveTo(const Duration(seconds: 9));
    await tester.tap(find.byKey(const ValueKey('shift')));
    await tester.pump();
    expect(h.changes.last.$1, [9, 13, 19]);
  });

  testWidgets('shift_is_off_without_a_first_tap_and_while_previewing', (
    tester,
  ) async {
    final h = await pumpScreen(tester);
    await press(tester, LogicalKeyboardKey.keyS);
    expect(h.changes, isEmpty);
    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('shift')),
    );
    expect(button.onPressed, isNull);
    final h2 = await pumpScreen(tester, times: [1, 2, 3]);
    await tester.tap(find.byKey(const ValueKey('preview')));
    await tester.pump();
    h2.player.moveTo(const Duration(seconds: 5));
    await press(tester, LogicalKeyboardKey.keyS);
    expect(h2.changes, isEmpty);
  });

  testWidgets('row_click_selects_and_seeks_to_the_previous_line', (
    tester,
  ) async {
    final h = await pumpScreen(tester, times: [1, 2, 3]);
    await tester.tap(find.byKey(const ValueKey('line-2')));
    await tester.pump();
    expect(h.changes.last.$1, [1, 2, null]);
    expect(h.player.seeks.last, const Duration(seconds: 2));
    await tester.tap(find.byKey(const ValueKey('line-0')));
    await tester.pump();
    expect(h.changes.last.$1, [null, null, null]);
    expect(h.player.seeks.last, Duration.zero);
  });

  testWidgets('keys_still_work_after_clicking_a_row_or_button', (tester) async {
    // On a desktop platform a click gives a button the keyboard focus, and Space would
    // press it again instead of stamping.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final h = await pumpScreen(tester, times: [1, 2, 3]);
      await tester.tap(find.byKey(const ValueKey('line-1')));
      await tester.tap(find.byKey(const ValueKey('play-pause')));
      await tester.pump();
      final playing = h.player.playing;
      h.player.moveTo(const Duration(seconds: 9));
      await press(tester, LogicalKeyboardKey.space);
      expect(h.changes.last.$1, [1, 9.0, null]);
      expect(
        h.player.playing,
        playing,
        reason: 'Space must not press the focused button',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('arrow_keys_seek_after_clicking_a_slider', (tester) async {
    // A focused slider would use the arrow keys itself (offset +-0.01) and the key
    // handler would never see them.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final h = await pumpScreen(tester);
      await tester.tap(find.byKey(const ValueKey('offset')));
      await tester.pump();
      final changesBefore = h.changes.length;
      h.player.moveTo(const Duration(seconds: 10));
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(h.player.seeks.last, const Duration(seconds: 12));
      expect(
        h.changes.length,
        changesBefore,
        reason: 'the offset must not move',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('play_pause_button_and_p_key', (tester) async {
    final h = await pumpScreen(tester);
    await tester.tap(find.byKey(const ValueKey('play-pause')));
    await tester.pump();
    expect(h.player.playing, isTrue);
    await press(tester, LogicalKeyboardKey.keyP);
    expect(h.player.playing, isFalse);
    await press(tester, LogicalKeyboardKey.keyP);
    expect(h.player.playing, isTrue);
  });

  testWidgets('arrow_keys_seek_two_seconds_within_the_song', (tester) async {
    final h = await pumpScreen(tester);
    h.player.moveTo(const Duration(seconds: 10));
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(h.player.seeks.last, const Duration(seconds: 12));
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(h.player.seeks.last, const Duration(seconds: 10));
    h.player.moveTo(const Duration(seconds: 1));
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(h.player.seeks.last, Duration.zero, reason: 'not before the start');
    h.player.moveTo(const Duration(minutes: 3) - const Duration(seconds: 1));
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(
      h.player.seeks.last,
      const Duration(minutes: 3),
      reason: 'not past the end',
    );
  });

  testWidgets('speed_buttons_set_the_playback_rate', (tester) async {
    final h = await pumpScreen(tester);
    await tester.tap(find.text('0.5x'));
    await tester.pump();
    await tester.tap(find.text('0.75x'));
    await tester.pump();
    await tester.tap(find.text('1x'));
    await tester.pump();
    expect(h.player.rates, [0.5, 0.75, 1.0]);
  });

  testWidgets('offset_slider_changes_the_offset_and_keeps_the_taps', (
    tester,
  ) async {
    final h = await pumpScreen(tester, times: [1, 2, null]);
    final slider = tester.widget<Slider>(find.byKey(const ValueKey('offset')));
    expect(slider.min, -0.5);
    expect(slider.max, 0.5);
    expect(slider.divisions, 100);
    slider.onChanged!(-0.2);
    await tester.pump();
    expect(h.changes.last.$2, closeTo(-0.2, 1e-9));
    expect(h.changes.last.$1, [1, 2, null]);
    expect(find.text('-0.20 s'), findsOneWidget);
  });

  testWidgets('initial_offset_is_shown', (tester) async {
    await pumpScreen(tester, offset: 0.25);
    expect(find.text('+0.25 s'), findsOneWidget);
  });

  testWidgets('seek_slider_seeks_and_the_time_is_shown', (tester) async {
    final h = await pumpScreen(tester);
    h.player.moveTo(const Duration(seconds: 65, milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('01:05.50 / 03:00.00'), findsOneWidget);
    tester.widget<Slider>(find.byKey(const ValueKey('seek'))).onChanged!(30);
    await tester.pump();
    expect(h.player.seeks.last, const Duration(seconds: 30));
  });

  group('preview', () {
    testWidgets('switch_is_disabled_without_an_instrumental', (tester) async {
      await pumpScreen(tester, instrumental: null);
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const ValueKey('preview')))
            .onChanged,
        isNull,
      );
    });

    testWidgets('switching_reopens_the_other_file_at_the_same_position', (
      tester,
    ) async {
      final h = await pumpScreen(tester, times: [1, 2, 3]);
      h.player.moveTo(const Duration(seconds: 42));
      await h.player.play();
      await tester.tap(find.byKey(const ValueKey('preview')));
      await tester.pump();
      expect(h.player.opened.last.path, '/w/instrumental.mp3');
      expect(h.player.opened.last.start, const Duration(seconds: 42));
      expect(h.player.opened.last.play, isTrue, reason: 'it keeps playing');
      await tester.tap(find.byKey(const ValueKey('preview')));
      await tester.pump();
      expect(h.player.opened.last.path, '/w/source.mp3');
    });

    testWidgets('paused_stays_paused', (tester) async {
      final h = await pumpScreen(tester);
      await tester.tap(find.byKey(const ValueKey('preview')));
      await tester.pump();
      expect(h.player.opened.last.play, isFalse);
    });

    testWidgets('row_click_only_seeks_and_never_edits_the_taps', (
      tester,
    ) async {
      final h = await pumpScreen(tester, times: [1, 5, 9], offset: 0.5);
      await tester.tap(find.byKey(const ValueKey('preview')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('line-1')));
      await tester.pump();
      expect(
        h.player.seeks.last,
        const Duration(milliseconds: 5500),
        reason: 'the tapped time plus the offset',
      );
      expect(h.changes, isEmpty, reason: 'previewing never changes the taps');
    });

    testWidgets('speed_survives_switching_to_the_preview_file', (tester) async {
      final h = await pumpScreen(tester);
      await tester.tap(find.text('0.75x'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('preview')));
      await tester.pump();
      expect(h.player.rates, [0.75, 0.75], reason: 'set again after reopening');
    });

    testWidgets('no_stamping_or_undo_while_previewing', (tester) async {
      final h = await pumpScreen(tester, times: [1, null, null]);
      await tester.tap(find.byKey(const ValueKey('preview')));
      await tester.pump();
      h.player.moveTo(const Duration(seconds: 8));
      await press(tester, LogicalKeyboardKey.space);
      await press(tester, LogicalKeyboardKey.backspace);
      expect(h.changes, isEmpty);
      expect(labelOfRow(tester, 0), '00:01.00');
      expect(labelOfRow(tester, 1), '--');
      // control: back in tap mode the same keys work
      await tester.tap(find.byKey(const ValueKey('preview')));
      await tester.pump();
      await press(tester, LogicalKeyboardKey.space);
      expect(h.changes.last.$1, [1, 8.0, null]);
    });

    testWidgets('highlights_the_line_being_sung_and_spacebar_does_not_stamp', (
      tester,
    ) async {
      final h = await pumpScreen(tester, times: [1, 5, 9], offset: 0.5);
      await tester.tap(find.byKey(const ValueKey('preview')));
      await tester.pump();
      h.player.moveTo(const Duration(seconds: 6)); // 5 + 0.5 offset has passed
      await tester.pump();
      expect(
        tester.widget<ListTile>(find.byKey(const ValueKey('line-1'))).selected,
        isTrue,
      );
      expect(
        tester.widget<ListTile>(find.byKey(const ValueKey('line-0'))).selected,
        isFalse,
      );
      h.player.moveTo(const Duration(seconds: 5, milliseconds: 200));
      await tester.pump();
      expect(
        tester.widget<ListTile>(find.byKey(const ValueKey('line-0'))).selected,
        isTrue,
        reason: 'the offset delays the highlight',
      );
      final before = h.changes.length;
      await press(tester, LogicalKeyboardKey.space);
      expect(h.changes.length, before, reason: 'no tapping while previewing');
    });
  });

  testWidgets('the_next_line_is_marked_while_tapping', (tester) async {
    await pumpScreen(tester, times: [1, null, null]);
    expect(
      tester.widget<ListTile>(find.byKey(const ValueKey('line-1'))).selected,
      isTrue,
    );
    expect(
      tester.widget<ListTile>(find.byKey(const ValueKey('line-0'))).selected,
      isFalse,
    );
  });

  testWidgets('initial_times_of_the_wrong_length_do_not_crash', (tester) async {
    await pumpScreen(tester, times: [1]);
    expect(labelOfRow(tester, 0), '00:01.00');
    expect(labelOfRow(tester, 2), '--');
  });

  testWidgets('empty_lyrics_show_a_hint', (tester) async {
    await pumpScreen(tester, lines: const []);
    expect(find.textContaining('lyrics'), findsOneWidget);
  });

  group('keyboard focus next to a text field', () {
    testWidgets('space_stamps_after_the_lyrics_field_had_the_focus', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final h = await pumpWithTextField(tester);
        await tester.tap(find.byKey(const ValueKey('other')));
        await tester.pump();
        expect(textFieldHasFocus(), isTrue, reason: 'the user was typing');
        await tester.tap(find.byKey(const ValueKey('play-pause')));
        await tester.pump();
        h.player.moveTo(const Duration(seconds: 5));
        await press(tester, LogicalKeyboardKey.space);
        expect(h.changes.last.$1, [5.0, null, null]);
        expect(
          tester
                  .widget<TextField>(find.byKey(const ValueKey('other')))
                  .controller
                  ?.text ??
              '',
          isEmpty,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('clicking_any_part_of_the_screen_gives_it_the_focus', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final h = await pumpWithTextField(tester);
        final targets = [
          find.text('0.75x'),
          find.byKey(const ValueKey('offset')),
          find.byKey(const ValueKey('line-2')),
        ];
        for (var i = 0; i < targets.length; i++) {
          await tester.tap(find.byKey(const ValueKey('other')));
          await tester.pump();
          await tester.tap(targets[i]);
          await tester.pump();
          h.player.moveTo(Duration(seconds: 10 + i));
          await press(tester, LogicalKeyboardKey.space);
          expect(h.changes.length, i + 1, reason: 'target $i');
        }
        expect(h.changes.last.$1, [10.0, 11.0, 12.0]);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('typing_in_the_text_field_still_works', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final h = await pumpWithTextField(tester);
        await tester.tap(find.byKey(const ValueKey('other')));
        await tester.enterText(find.byKey(const ValueKey('other')), 'hello');
        await tester.pump();
        h.player.moveTo(const Duration(seconds: 3)); // the tap screen rebuilds
        await tester.pump();
        await press(tester, LogicalKeyboardKey.space);
        expect(
          h.changes,
          isEmpty,
          reason: 'the key belongs to the text field being typed in',
        );
        expect(textFieldHasFocus(), isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('word timing', () {
    const lines = ['Hello big world', 'bye now'];

    Future<Harness> wordScreen(
      WidgetTester tester, {
      List<double?> times = const [1.0, 2.0],
      List<List<double?>?> words = const [],
    }) async {
      final h = await pumpScreen(
        tester,
        lines: lines,
        times: times,
        wordTimes: words,
      );
      return h;
    }

    Future<void> wordModeOn(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('word-mode')));
      await tester.pump();
    }

    Future<void> tapWordAt(
      WidgetTester tester,
      Harness h,
      double seconds,
    ) async {
      h.player.position = Duration(microseconds: (seconds * 1e6).round());
      await press(tester, LogicalKeyboardKey.space);
    }

    testWidgets('the_word_timing_switch_is_off_at_first', (tester) async {
      await wordScreen(tester);
      final tile = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('word-mode')),
      );
      expect(tile.value, isFalse);
    });

    testWidgets('space_stamps_the_next_word_of_the_selected_line', (
      tester,
    ) async {
      final h = await wordScreen(tester);
      await wordModeOn(tester);
      await tester.tap(find.byKey(const ValueKey('line-0')));
      await tester.pump();
      await tapWordAt(tester, h, 1.4);
      expect(h.wordChanges.last, [
        [1.4, null, null],
        null,
      ], reason: 'the first press times the first word');
      await tapWordAt(tester, h, 1.9);
      await tapWordAt(tester, h, 2.3);
      expect(h.wordChanges.last, [
        [1.4, 1.9, 2.3],
        null,
      ]);
      expect(h.changes, isEmpty, reason: 'the line taps did not change');
      expect(find.text('3/3 words'), findsOneWidget);
    });

    testWidgets('backspace_takes_back_the_last_word', (tester) async {
      final h = await wordScreen(tester);
      await wordModeOn(tester);
      await tester.tap(find.byKey(const ValueKey('line-0')));
      await tester.pump();
      await tapWordAt(tester, h, 1.4);
      await press(tester, LogicalKeyboardKey.backspace);
      expect(h.wordChanges.last, [null, null]);
      expect(h.changes, isEmpty);
    });

    testWidgets('row_click_in_word_mode_keeps_the_line_taps', (tester) async {
      // In line mode a click clears the line and all after it; word mode must not.
      final h = await wordScreen(tester);
      await wordModeOn(tester);
      await tester.tap(find.byKey(const ValueKey('line-0')));
      await tester.pump();
      expect(h.changes, isEmpty);
      expect(h.wordChanges, isEmpty);
      expect(labelOfRow(tester, 0), '00:01.00');
      expect(labelOfRow(tester, 1), '00:02.00');
      expect(
        h.player.seeks.last,
        const Duration(seconds: 1),
        reason: 'goes to the line start',
      );
    });

    testWidgets('after_the_last_word_the_next_line_is_selected', (
      tester,
    ) async {
      final h = await pumpScreen(
        tester,
        lines: const ['a b', 'c d'],
        times: const [1.0, 2.0],
      );
      await wordModeOn(tester);
      await tester.tap(find.byKey(const ValueKey('line-0')));
      await tester.pump();
      await tapWordAt(tester, h, 1.5);
      await tapWordAt(tester, h, 1.7);
      await tapWordAt(tester, h, 2.5);
      await tapWordAt(tester, h, 2.7);
      expect(h.wordChanges.last, [
        [1.5, 1.7],
        [2.5, 2.7],
      ]);
    });

    testWidgets('the_next_line_starts_at_its_first_word', (tester) async {
      // Reported: after the last word of a line the selection landed on the 2nd word of the
      // next line, and again after the next line.
      final h = await pumpScreen(
        tester,
        lines: const ['a b', 'c d', 'e f'],
        times: const [1.0, 2.0, 3.0],
      );
      await wordModeOn(tester);
      await tester.tap(find.byKey(const ValueKey('line-0')));
      await tester.pump();
      await tapWordAt(tester, h, 1.2);
      await tapWordAt(tester, h, 1.5);
      await tapWordAt(tester, h, 2.2);
      expect(h.wordChanges.last, [
        [1.2, 1.5],
        [2.2, null],
        null,
      ]);
      await tapWordAt(tester, h, 2.5);
      await tapWordAt(tester, h, 3.2);
      expect(h.wordChanges.last, [
        [1.2, 1.5],
        [2.2, 2.5],
        [3.2, null],
      ]);
    });

    testWidgets('backspace_after_finishing_a_line_takes_back_its_last_word', (
      tester,
    ) async {
      final h = await pumpScreen(
        tester,
        lines: const ['a b', 'c d'],
        times: const [1.0, 2.0],
      );
      await wordModeOn(tester);
      await tester.tap(find.byKey(const ValueKey('line-0')));
      await tester.pump();
      await tapWordAt(tester, h, 1.5);
      await tapWordAt(tester, h, 1.6); // line 0 is done, line 1 is selected
      await press(tester, LogicalKeyboardKey.backspace);
      expect(h.wordChanges.last, [
        [1.5, null],
        null,
      ]);
      await tapWordAt(tester, h, 1.7);
      expect(h.wordChanges.last, [
        [1.5, 1.7],
        null,
      ], reason: 'the line is selected again');
    });

    testWidgets('an_untapped_line_cannot_get_word_times', (tester) async {
      final h = await wordScreen(tester, times: const [null, null]);
      await wordModeOn(tester);
      await tester.tap(find.byKey(const ValueKey('line-0')));
      await tester.pump();
      await tapWordAt(tester, h, 1.4);
      expect(h.wordChanges, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('line_mode_still_stamps_lines_and_leaves_words_alone', (
      tester,
    ) async {
      final h = await wordScreen(tester, times: const [null, null]);
      expect(find.byKey(const ValueKey('word-mode')), findsOneWidget);
      await tapWordAt(tester, h, 1.0);
      expect(h.changes.last.$1, [1.0, null]);
      expect(h.wordChanges, isEmpty);
    });

    testWidgets('word_progress_is_shown_on_the_row', (tester) async {
      await wordScreen(
        tester,
        words: const [
          [1.0, 1.4, null],
          null,
        ],
      );
      expect(find.text('2/3 words'), findsOneWidget);
    });

    testWidgets('retapping_a_line_drops_its_word_times', (tester) async {
      final h = await wordScreen(
        tester,
        words: const [
          [1.0, 1.4, 1.9],
          null,
        ],
      );
      await tester.tap(find.byKey(const ValueKey('line-0')));
      await tester.pump();
      expect(h.changes.last.$1, [null, null]);
      expect(h.wordChanges.last, [null, null]);
    });

    testWidgets('previewing_never_changes_word_times', (tester) async {
      final h = await wordScreen(tester);
      await wordModeOn(tester);
      await tester.tap(find.byKey(const ValueKey('preview')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('line-0')));
      await tester.pump();
      await tapWordAt(tester, h, 1.4);
      expect(h.wordChanges, isEmpty);
    });
  });

  group('word highlight', () {
    // Made-up lyrics only.
    const lines = ['Hello big world', 'bye now'];

    /// The marks of the words of row [line]: 'lit', 'current' (underlined) or 'plain'. A row shown
    /// as plain text has [words] plain marks.
    List<String> marksOf(WidgetTester tester, int line, int words) {
      final text = tester.widget<Text>(find.byKey(ValueKey('line-text-$line')));
      final span = text.textSpan;
      if (span == null) return List.filled(words, 'plain');
      final scheme = Theme.of(
        tester.element(find.byKey(ValueKey('line-$line'))),
      ).colorScheme;
      return [
        for (final s in (span as TextSpan).children!.cast<TextSpan>())
          s.style?.decoration == TextDecoration.underline
              ? 'current'
              : s.style?.color == scheme.primary
              ? 'lit'
              // An unlit word has its own colour: a selected row tints its text with the
              // primary colour, which would hide the difference.
              : s.style?.color == scheme.onSurface
              ? 'plain'
              : 'other',
      ];
    }

    Future<Harness> screen(
      WidgetTester tester, {
      List<List<double?>?> words = const [],
      double offset = 0,
    }) => pumpScreen(
      tester,
      lines: lines,
      times: const [1.0, 2.0],
      wordTimes: words,
      offset: offset,
    );

    Future<void> wordOn(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('word-mode')));
      await tester.pump();
    }

    Future<void> tapWord(WidgetTester tester, Harness h, double seconds) async {
      h.player.position = Duration(microseconds: (seconds * 1e6).round());
      await press(tester, LogicalKeyboardKey.space);
    }

    Future<void> playAt(WidgetTester tester, Harness h, int ms) async {
      h.player.moveTo(Duration(milliseconds: ms));
      // The screen follows the player one pump later.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('word_mode_shows_the_timed_and_the_next_word', (tester) async {
      final h = await screen(tester);
      await wordOn(tester);
      await tester.tap(find.byKey(const ValueKey('line-0')));
      await tester.pump();
      // Nothing is lit before the first Space: only the word it will time is underlined.
      expect(marksOf(tester, 0, 3), ['current', 'plain', 'plain']);
      await tapWord(tester, h, 1.4);
      expect(marksOf(tester, 0, 3), ['current', 'plain', 'plain'], reason: 'the first word is being sung');
      await tapWord(tester, h, 1.9);
      expect(marksOf(tester, 0, 3), ['lit', 'current', 'plain']);
      await tapWord(tester, h, 2.3);
      // The last word is being sung; the selection moved on to the next line, at its first word.
      expect(marksOf(tester, 0, 3), ['lit', 'lit', 'lit'], reason: 'no underline off the selected line');
      expect(marksOf(tester, 1, 2), ['current', 'plain']);
    });

    testWidgets('word_mode_shows_no_next_word_on_other_lines', (tester) async {
      await screen(
        tester,
        words: const [
          [1.0, 1.4, null],
          null,
        ],
      );
      await wordOn(tester);
      await tester.tap(find.byKey(const ValueKey('line-1')));
      await tester.pump();
      // Line 0 is half timed: its timed words are lit, but only the selected line has a next word.
      expect(marksOf(tester, 0, 3), ['lit', 'lit', 'plain']);
      expect(marksOf(tester, 1, 2), ['current', 'plain']);
    });

    testWidgets('backspace_takes_the_mark_back', (tester) async {
      final h = await screen(tester);
      await wordOn(tester);
      await tester.tap(find.byKey(const ValueKey('line-0')));
      await tester.pump();
      await tapWord(tester, h, 1.4);
      await tapWord(tester, h, 1.9);
      expect(marksOf(tester, 0, 3), ['lit', 'current', 'plain']);
      await press(tester, LogicalKeyboardKey.backspace);
      expect(h.wordChanges.last, [
        [1.4, null, null],
        null,
      ]);
      expect(marksOf(tester, 0, 3), ['current', 'plain', 'plain']);
      await press(tester, LogicalKeyboardKey.backspace);
      expect(h.wordChanges.last, [null, null]);
      expect(marksOf(tester, 0, 3), ['current', 'plain', 'plain']);
    });

    testWidgets('playing_lights_the_words_one_by_one', (tester) async {
      final h = await screen(
        tester,
        words: const [
          [1.0, 1.4, 1.9],
          null,
        ],
      );
      await playAt(tester, h, 1500);
      expect(marksOf(tester, 0, 3), ['lit', 'lit', 'plain']);
      await playAt(tester, h, 1950);
      expect(marksOf(tester, 0, 3), ['lit', 'lit', 'lit']);
      // Line 1 is being sung now: line 0 is plain again.
      await playAt(tester, h, 2500);
      expect(marksOf(tester, 0, 3), ['plain', 'plain', 'plain']);
    });

    testWidgets('playing_uses_the_offset', (tester) async {
      final h = await screen(
        tester,
        words: const [
          [1.0, 1.4, 1.9],
          null,
        ],
        offset: 0.3,
      );
      await playAt(tester, h, 1500);
      expect(marksOf(tester, 0, 3), ['lit', 'plain', 'plain']);
    });

    testWidgets('nothing_lights_before_the_first_line', (tester) async {
      final h = await screen(
        tester,
        words: const [
          [1.0, 1.4, 1.9],
          null,
        ],
      );
      await playAt(tester, h, 500);
      expect(marksOf(tester, 0, 3), ['plain', 'plain', 'plain']);
    });

    testWidgets('lines_without_word_times_stay_plain', (tester) async {
      final h = await screen(
        tester,
        words: const [
          [1.0, 1.4, 1.9],
          null,
        ],
      );
      await playAt(tester, h, 2500);
      expect(marksOf(tester, 1, 2), ['plain', 'plain']);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('line-text-1'))).data,
        'bye now',
        reason: 'shown as plain text, as before',
      );
    });
  });

  group('word reset', () {
    // Made-up lyrics only.
    const lines = ['Hello big world', 'bye now'];

    Future<Harness> screen(
      WidgetTester tester, {
      List<List<double?>?> words = const [],
    }) => pumpScreen(tester, lines: lines, times: const [1.0, 2.0], wordTimes: words);

    Future<void> wordOn(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('word-mode')));
      await tester.pump();
    }

    Future<void> tapWord(WidgetTester tester, Harness h, double seconds) async {
      h.player.position = Duration(microseconds: (seconds * 1e6).round());
      await press(tester, LogicalKeyboardKey.space);
    }

    Future<void> clickLine(WidgetTester tester, int i) async {
      await tester.tap(find.byKey(ValueKey('line-$i')));
      await tester.pump();
    }

    VoidCallback? resetAction(WidgetTester tester) =>
        tester.widget<OutlinedButton>(find.byKey(const ValueKey('word-reset'))).onPressed;

    testWidgets('reset_button_clears_the_selected_lines_words', (tester) async {
      final h = await screen(tester);
      await wordOn(tester);
      await clickLine(tester, 0);
      await tapWord(tester, h, 1.4);
      await tapWord(tester, h, 1.9);
      await tapWord(tester, h, 2.3);
      expect(h.wordChanges.last, [
        [1.4, 1.9, 2.3],
        null,
      ]);
      // The selection moved on by itself; go back to line 0 and reset it.
      await clickLine(tester, 0);
      final seeksBefore = h.player.seeks.length;
      await tester.tap(find.byKey(const ValueKey('word-reset')));
      await tester.pump();
      expect(h.wordChanges.last, [null, null]);
      expect(h.changes, isEmpty, reason: 'the line taps did not change');
      expect(h.player.seeks.length, seeksBefore + 1, reason: 'the reset itself seeks');
      expect(h.player.seeks.last, const Duration(seconds: 1), reason: 'ready to time it again');
      expect(find.text('3/3 words'), findsNothing);
      // And the line can be timed again at once.
      await tapWord(tester, h, 1.5);
      expect(h.wordChanges.last, [
        [1.5, null, null],
        null,
      ]);
    });

    testWidgets('reset_button_state', (tester) async {
      final h = await screen(tester);
      expect(find.byKey(const ValueKey('word-reset')), findsNothing, reason: 'word timing is off');
      await wordOn(tester);
      expect(find.byKey(const ValueKey('word-reset')), findsOneWidget);
      expect(resetAction(tester), isNull, reason: 'the selected line has no word times');
      await tapWord(tester, h, 1.4);
      expect(resetAction(tester), isNotNull);
    });

    testWidgets('reset_leaves_other_lines_alone', (tester) async {
      final h = await screen(
        tester,
        words: const [
          [1.0, 1.4, 1.9],
          [2.0, 2.5],
        ],
      );
      await wordOn(tester);
      await clickLine(tester, 1);
      await tester.tap(find.byKey(const ValueKey('word-reset')));
      await tester.pump();
      expect(h.wordChanges.last, [
        [1.0, 1.4, 1.9],
        null,
      ]);
    });

    testWidgets('reset_is_off_in_the_preview', (tester) async {
      final h = await screen(
        tester,
        words: const [
          [1.0, 1.4, 1.9],
          null,
        ],
      );
      await wordOn(tester);
      await clickLine(tester, 0);
      await tester.tap(find.byKey(const ValueKey('preview')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('word-reset')), warnIfMissed: false);
      await tester.pump();
      expect(h.wordChanges, isEmpty, reason: 'previewing never changes the taps');
    });

    testWidgets('backspace_after_a_click_stays_on_the_selected_line', (tester) async {
      final h = await screen(
        tester,
        words: const [
          [1.0, 1.4, 1.9],
          null,
        ],
      );
      await wordOn(tester);
      await clickLine(tester, 1);
      await press(tester, LogicalKeyboardKey.backspace);
      expect(h.wordChanges, isEmpty, reason: 'line 1 has nothing to take back');
      expect(find.text('3/3 words'), findsOneWidget, reason: 'line 0 keeps all its words');
    });

    testWidgets('backspace_after_clicking_the_line_it_moved_to_stays_there', (tester) async {
      final h = await screen(tester);
      await wordOn(tester);
      await clickLine(tester, 0);
      await tapWord(tester, h, 1.4);
      await tapWord(tester, h, 1.9);
      await tapWord(tester, h, 2.3);
      final before = h.wordChanges.length;
      // The selection moved on to line 1 by itself; clicking it makes it the user's choice.
      await clickLine(tester, 1);
      await press(tester, LogicalKeyboardKey.backspace);
      expect(h.wordChanges.length, before, reason: 'line 1 has nothing to take back');
      expect(find.text('3/3 words'), findsOneWidget);
    });

    testWidgets('backspace_after_finishing_a_line_goes_back_and_goes_on', (tester) async {
      final h = await screen(tester);
      await wordOn(tester);
      await clickLine(tester, 0);
      await tapWord(tester, h, 1.4);
      await tapWord(tester, h, 1.9);
      await tapWord(tester, h, 2.3);
      await press(tester, LogicalKeyboardKey.backspace);
      expect(h.wordChanges.last, [
        [1.4, 1.9, null],
        null,
      ]);
      await press(tester, LogicalKeyboardKey.backspace);
      expect(h.wordChanges.last, [
        [1.4, null, null],
        null,
      ]);
      await press(tester, LogicalKeyboardKey.backspace);
      expect(h.wordChanges.last, [null, null]);
    });
  });
}
