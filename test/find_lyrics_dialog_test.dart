import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/lyrics_lookup.dart';
import 'package:kantahe_maker/screens/find_lyrics_dialog.dart';

const first = LyricsCandidate(
  title: 'Song One',
  artist: 'Artist One',
  album: 'Album One',
  lyrics: 'first line\nsecond line',
  seconds: 185,
);
const second = LyricsCandidate(
  title: 'Song Two',
  artist: 'Artist Two',
  album: '',
  lyrics: 'other line',
);

class Harness {
  final calls = <(String, String)>[];
  LyricsCandidate? picked;
  bool closed = false;
}

Future<Harness> open(
  WidgetTester tester,
  LyricsFinder finder, {
  String title = 'My Song',
  String artist = 'My Artist',
}) async {
  final h = Harness();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              h.picked = await showFindLyricsDialog(
                context,
                title: title,
                artist: artist,
                finder: (t, a) {
                  h.calls.add((t, a));
                  return finder(t, a);
                },
              );
              h.closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return h;
}

Future<void> search(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('lyrics-search')));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('asks_before_searching', (tester) async {
    final h = await open(tester, (t, a) async => [first]);
    expect(find.textContaining('lrclib.net'), findsOneWidget);
    expect(find.textContaining('"My Song"'), findsOneWidget);
    expect(find.textContaining('"My Artist"'), findsOneWidget);
    expect(h.calls, isEmpty, reason: 'nothing is sent before Search');
    await search(tester);
    expect(h.calls, [('My Song', 'My Artist')]);
  });

  testWidgets('ask_text_leaves_out_a_blank_artist', (tester) async {
    await open(tester, (t, a) async => [first], artist: '  ');
    expect(find.textContaining('"My Song"'), findsOneWidget);
    expect(find.textContaining(' by '), findsNothing);
  });

  testWidgets('cancel_before_search', (tester) async {
    final h = await open(tester, (t, a) async => [first]);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(h.closed, isTrue);
    expect(h.picked, isNull);
    expect(h.calls, isEmpty);
  });

  testWidgets('shows_results_and_returns_the_pick', (tester) async {
    final h = await open(tester, (t, a) async => [first, second]);
    await search(tester);
    expect(find.text('Song One - Artist One'), findsOneWidget);
    expect(find.textContaining('Album One'), findsOneWidget);
    expect(find.textContaining('3:05'), findsOneWidget);
    expect(find.textContaining('first line'), findsOneWidget);
    expect(find.text('Song Two - Artist Two'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lyrics-result-1')));
    await tester.pumpAndSettle();
    expect(h.picked, same(second));
  });

  testWidgets('empty_result', (tester) async {
    final h = await open(tester, (t, a) async => []);
    await search(tester);
    expect(find.textContaining('No lyrics found'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(h.closed, isTrue);
    expect(h.picked, isNull);
  });

  testWidgets('error_then_retry', (tester) async {
    var n = 0;
    final h = await open(tester, (t, a) async {
      if (n++ == 0) throw const LyricsLookupException('server is busy');
      return [first];
    });
    await search(tester);
    expect(find.text('server is busy'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lyrics-retry')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Song One - Artist One'), findsOneWidget);
    expect(h.calls, hasLength(2));
  });

  testWidgets('searching_indicator', (tester) async {
    final done = Completer<List<LyricsCandidate>>();
    await open(tester, (t, a) => done.future);
    await search(tester);
    expect(find.byKey(const ValueKey('lyrics-searching')), findsOneWidget);
    done.complete([first]);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('lyrics-searching')), findsNothing);
    expect(find.text('Song One - Artist One'), findsOneWidget);
  });

  testWidgets('cancel_while_searching', (tester) async {
    final done = Completer<List<LyricsCandidate>>();
    final h = await open(tester, (t, a) => done.future);
    await search(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(h.closed, isTrue);
    expect(h.picked, isNull);
    done.complete([first]);
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel_while_searching_then_error_is_quiet', (tester) async {
    final done = Completer<List<LyricsCandidate>>();
    await open(tester, (t, a) => done.future);
    await search(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    done.completeError(const LyricsLookupException('late'));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
