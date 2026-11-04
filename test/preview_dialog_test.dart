import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/karmp3.dart' show LrcLine;
import 'package:kantahe_maker/screens/preview_dialog.dart';
import 'package:kantahe_maker/screens/tap_screen.dart';

import 'support/fake_player.dart';

// Made-up lyrics only.
const defaultLines = [LrcLine(1.0, 'la la'), LrcLine(3.0, 'na na')];

class Players {
  Players({FakePlayer? first}) : inst = first ?? FakePlayer();
  final FakePlayer inst;
  final vocals = FakePlayer();
  int made = 0;

  /// The first player asked for is the instrumental, the second the vocals.
  TapPlayer make() => made++ == 0 ? inst : vocals;
}

class FailingPlayer extends FakePlayer {
  @override
  Future<void> open(String path, {Duration start = Duration.zero, bool play = false}) async =>
      throw StateError('no such file');
}

Future<Players> openPreview(
  WidgetTester tester, {
  List<LrcLine> lines = defaultLines,
  bool vocals = false,
  Players? players,
}) async {
  final p = players ?? Players();
  await tester.binding.setSurfaceSize(const Size(900, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => PreviewDialog(
                  title: 'Song - Singer',
                  lines: lines,
                  instrumentalPath: '/x/instrumental.mp3',
                  vocalsPath: vocals ? '/x/vocals.mp3' : null,
                  createPlayer: p.make,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return p;
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pump();
}

bool selected(WidgetTester tester, int line) =>
    tester.widget<ListTile>(find.byKey(ValueKey('preview-line-$line'))).selected;

List<bool> boldWords(WidgetTester tester, int line) {
  final text = tester.widget<Text>(find.byKey(ValueKey('preview-text-$line')));
  final spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
  return [for (final s in spans) s.style?.fontWeight == FontWeight.bold];
}

void main() {
  testWidgets('opens_paused_and_plays', (tester) async {
    final p = await openPreview(tester);
    expect(find.byKey(const ValueKey('preview-dialog')), findsOneWidget);
    expect(find.text('Song - Singer'), findsOneWidget);
    expect(p.made, 1, reason: 'no vocals: one player');
    expect(p.inst.opened.single.path, '/x/instrumental.mp3');
    expect(p.inst.opened.single.play, isFalse);
    expect(p.inst.playing, isFalse);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    await tapKey(tester, 'preview-play');
    expect(p.inst.playing, isTrue);
    expect(find.byIcon(Icons.pause), findsOneWidget);
    await tapKey(tester, 'preview-play');
    expect(p.inst.playing, isFalse);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    await tapKey(tester, 'preview-close');
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('shows_the_time', (tester) async {
    final p = await openPreview(tester);
    p.inst.moveTo(const Duration(seconds: 65));
    await tester.pump();
    expect(find.byKey(const ValueKey('preview-time')), findsOneWidget);
    expect(find.text('1:05 / 3:00'), findsOneWidget);
    await tapKey(tester, 'preview-close');
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('highlights_the_current_line', (tester) async {
    final p = await openPreview(tester);
    expect(selected(tester, 0), isFalse);
    expect(selected(tester, 1), isFalse);
    p.inst.moveTo(const Duration(seconds: 2));
    await tester.pump();
    expect(selected(tester, 0), isTrue);
    expect(selected(tester, 1), isFalse);
    p.inst.moveTo(const Duration(milliseconds: 3500));
    await tester.pump();
    expect(selected(tester, 0), isFalse);
    expect(selected(tester, 1), isTrue);
    await tapKey(tester, 'preview-close');
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('word_highlight', (tester) async {
    final p = await openPreview(
      tester,
      lines: const [
        LrcLine(1.0, 'la la', [(1.0, 'la '), (1.5, 'la')]),
      ],
    );
    p.inst.moveTo(const Duration(milliseconds: 1200));
    await tester.pump();
    expect(boldWords(tester, 0), [true, false]);
    p.inst.moveTo(const Duration(milliseconds: 1600));
    await tester.pump();
    expect(boldWords(tester, 0), [true, true]);
    await tapKey(tester, 'preview-close');
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('seek_moves_both_players', (tester) async {
    final p = await openPreview(tester, vocals: true);
    tester.widget<Slider>(find.byKey(const ValueKey('preview-seek'))).onChangeEnd!(90000);
    await tester.pump();
    expect(p.inst.seeks.last, const Duration(seconds: 90));
    expect(p.vocals.seeks.last, const Duration(seconds: 90));
    await tapKey(tester, 'preview-close');
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('tapping_a_line_seeks', (tester) async {
    final p = await openPreview(tester, vocals: true);
    await tapKey(tester, 'preview-line-1');
    expect(p.inst.seeks.last, const Duration(seconds: 3));
    expect(p.vocals.seeks.last, const Duration(seconds: 3));
    await tapKey(tester, 'preview-close');
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('vocals_switch', (tester) async {
    final p = await openPreview(tester, vocals: true);
    expect(p.made, 2);
    expect(p.vocals.opened.single.path, '/x/vocals.mp3');
    expect(tester.widget<Switch>(find.byKey(const ValueKey('preview-vocals'))).value, isTrue);
    await tapKey(tester, 'preview-play');
    expect(p.inst.playing, isTrue);
    expect(p.vocals.playing, isTrue);
    // Off: the vocals stop and are silent; the instrumental goes on.
    await tapKey(tester, 'preview-vocals');
    expect(p.vocals.playing, isFalse);
    expect(p.vocals.volume, 0);
    expect(p.inst.playing, isTrue);
    // On again: moved to the instrumental's position, at the chosen level, and playing.
    p.inst.moveTo(const Duration(seconds: 12));
    await tester.pump();
    await tapKey(tester, 'preview-vocals');
    expect(p.vocals.seeks.last, const Duration(seconds: 12));
    expect(p.vocals.volume, 1.0);
    expect(p.vocals.playing, isTrue);
    await tapKey(tester, 'preview-play');
    await tapKey(tester, 'preview-close');
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('vocals_off_while_paused_stays_paused_when_switched_on', (tester) async {
    final p = await openPreview(tester, vocals: true);
    await tapKey(tester, 'preview-vocals');
    await tapKey(tester, 'preview-vocals');
    expect(p.vocals.playing, isFalse, reason: 'the song is not playing');
    await tapKey(tester, 'preview-close');
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('vocals_level', (tester) async {
    final p = await openPreview(tester, vocals: true);
    tester.widget<Slider>(find.byKey(const ValueKey('preview-vocals-level'))).onChanged!(50);
    await tester.pump();
    expect(p.vocals.volume, 0.5);
    expect(find.text('50 %'), findsOneWidget);
    await tapKey(tester, 'preview-close');
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('vocals_level_is_kept_while_the_vocals_are_off', (tester) async {
    final p = await openPreview(tester, vocals: true);
    await tapKey(tester, 'preview-vocals');
    tester.widget<Slider>(find.byKey(const ValueKey('preview-vocals-level'))).onChanged!(30);
    await tester.pump();
    expect(p.vocals.volume, 0, reason: 'still off');
    await tapKey(tester, 'preview-vocals');
    expect(p.vocals.volume, 0.3);
    await tapKey(tester, 'preview-close');
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('no_vocals_no_controls', (tester) async {
    await openPreview(tester);
    expect(find.byKey(const ValueKey('preview-vocals')), findsNothing);
    expect(find.byKey(const ValueKey('preview-vocals-level')), findsNothing);
    await tapKey(tester, 'preview-close');
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('drift_is_corrected', (tester) async {
    final p = await openPreview(tester, vocals: true);
    p.inst.moveTo(const Duration(seconds: 10));
    await tapKey(tester, 'preview-play');
    final afterPlay = p.vocals.seeks.length;
    // 400 ms ahead: more than the 150 ms allowed.
    p.vocals.position = const Duration(milliseconds: 10400);
    await tester.pump(const Duration(milliseconds: 500));
    expect(p.vocals.seeks.length, afterPlay + 1);
    expect(p.vocals.seeks.last, const Duration(seconds: 10));
    // Drifting again at once: not moved again within a second.
    p.vocals.position = const Duration(milliseconds: 9000);
    await tester.pump(const Duration(milliseconds: 500));
    expect(p.vocals.seeks.length, afterPlay + 1);
    await tester.pump(const Duration(milliseconds: 500));
    expect(p.vocals.seeks.length, afterPlay + 2);
    // In step: left alone.
    await tester.pump(const Duration(milliseconds: 500));
    expect(p.vocals.seeks.length, afterPlay + 2);
    await tapKey(tester, 'preview-play');
    await tapKey(tester, 'preview-close');
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('no_drift_check_while_paused_or_vocals_off', (tester) async {
    final p = await openPreview(tester, vocals: true);
    p.inst.moveTo(const Duration(seconds: 10));
    p.vocals.position = const Duration(seconds: 12);
    final before = p.vocals.seeks.length;
    await tester.pump(const Duration(seconds: 2));
    expect(p.vocals.seeks.length, before, reason: 'paused');
    await tapKey(tester, 'preview-vocals');
    await tapKey(tester, 'preview-play');
    final playing = p.vocals.seeks.length;
    p.vocals.position = const Duration(seconds: 12);
    await tester.pump(const Duration(seconds: 2));
    expect(p.vocals.seeks.length, playing, reason: 'vocals off');
    await tapKey(tester, 'preview-play');
    await tapKey(tester, 'preview-close');
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('close_disposes_both_players', (tester) async {
    final p = await openPreview(tester, vocals: true);
    await tapKey(tester, 'preview-play');
    await tapKey(tester, 'preview-close');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('preview-dialog')), findsNothing);
    expect(p.inst.disposed, isTrue);
    expect(p.vocals.disposed, isTrue);
    // The drift timer is gone: nothing moves the vocals any more.
    final seeks = p.vocals.seeks.length;
    p.vocals.position = const Duration(seconds: 50);
    await tester.pump(const Duration(seconds: 2));
    expect(p.vocals.seeks.length, seeks);
  });

  testWidgets('end_of_song', (tester) async {
    final p = await openPreview(tester);
    await tapKey(tester, 'preview-play');
    expect(find.byIcon(Icons.pause), findsOneWidget);
    // The song ends: the player says it stopped, with the position at the end.
    p.inst.moveTo(p.inst.duration);
    await p.inst.pause();
    await tester.pump();
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    await tapKey(tester, 'preview-play');
    expect(p.inst.seeks.last, Duration.zero, reason: 'plays again from the start');
    expect(p.inst.playing, isTrue);
    await tapKey(tester, 'preview-play');
    await tapKey(tester, 'preview-close');
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('no_lyrics', (tester) async {
    await openPreview(tester, lines: const []);
    expect(find.text('No lyrics'), findsOneWidget);
    await tapKey(tester, 'preview-close');
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('open_failure_is_shown', (tester) async {
    final failing = FailingPlayer();
    await openPreview(tester, players: Players(first: failing));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('preview-error')), findsOneWidget);
    expect(find.textContaining('Could not play the song'), findsOneWidget);
    await tapKey(tester, 'preview-close');
    await tester.pump(const Duration(milliseconds: 300));
  });
}
