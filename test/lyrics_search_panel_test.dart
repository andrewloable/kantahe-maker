import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/lyrics_lookup.dart';
import 'package:kantahe_maker/screens/lyrics_search_panel.dart';

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
  final picked = <LyricsCandidate>[];
}

Future<Harness> pumpPanel(
  WidgetTester tester,
  LyricsFinder finder, {
  String title = 'T',
  String artist = 'A',
  bool autoSearch = true,
}) async {
  final h = Harness();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: LyricsSearchPanel(
            title: title,
            artist: artist,
            autoSearch: autoSearch,
            onPicked: h.picked.add,
            finder: (t, a) {
              h.calls.add((t, a));
              return finder(t, a);
            },
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return h;
}

Future<void> tapAndPump(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('searches_at_once_when_asked', (tester) async {
    final h = await pumpPanel(tester, (t, a) async => [first]);
    expect(h.calls, [('T', 'A')]);
    expect(find.text('Song One - Artist One'), findsOneWidget);
  });

  testWidgets('no_search_without_auto', (tester) async {
    final h = await pumpPanel(
      tester,
      (t, a) async => [first],
      autoSearch: false,
    );
    expect(h.calls, isEmpty);
    await tapAndPump(tester, 'lyrics-search');
    expect(h.calls, hasLength(1));
  });

  testWidgets('no_search_without_title', (tester) async {
    final h = await pumpPanel(tester, (t, a) async => [first], title: '  ');
    expect(h.calls, isEmpty);
    expect(
      find.text('Fill in the title in Details to search online.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('lyrics-search')), findsNothing);
  });

  testWidgets('says_what_is_sent', (tester) async {
    await pumpPanel(tester, (t, a) async => [first]);
    expect(
      find.text(
        'Searching lrclib.net sends the title and artist; nothing else.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('picking_a_result_calls_back', (tester) async {
    final h = await pumpPanel(tester, (t, a) async => [first, second]);
    await tester.tap(find.byKey(const ValueKey('lyrics-result-1')));
    await tester.pump();
    expect(h.picked, [same(second)]);
  });

  // Ported from the dialog's shows_results_and_returns_the_pick.
  testWidgets('result_tiles_show_the_details', (tester) async {
    await pumpPanel(tester, (t, a) async => [first, second]);
    expect(find.text('Song One - Artist One'), findsOneWidget);
    expect(find.textContaining('Album One'), findsOneWidget);
    expect(find.textContaining('3:05'), findsOneWidget);
    expect(find.textContaining('first line'), findsOneWidget);
    expect(find.text('Song Two - Artist Two'), findsOneWidget);
  });

  testWidgets('empty_result_says_paste', (tester) async {
    await pumpPanel(tester, (t, a) async => []);
    expect(
      find.text('No lyrics found for this title and artist. Paste them below.'),
      findsOneWidget,
    );
  });

  testWidgets('error_then_retry', (tester) async {
    var n = 0;
    final h = await pumpPanel(tester, (t, a) async {
      if (n++ == 0) throw const LyricsLookupException('down');
      return [first];
    });
    expect(find.text('down'), findsOneWidget);
    await tapAndPump(tester, 'lyrics-retry');
    expect(find.text('Song One - Artist One'), findsOneWidget);
    expect(h.calls, hasLength(2));
  });

  // Ported from the dialog's searching_indicator and ask_text_leaves_out_a_blank_artist.
  testWidgets('searching_shows_what_is_searched', (tester) async {
    final done = Completer<List<LyricsCandidate>>();
    await pumpPanel(tester, (t, a) => done.future, title: 'My Song');
    expect(find.byKey(const ValueKey('lyrics-searching')), findsOneWidget);
    expect(
      find.text('Searching lrclib.net for "My Song" by "A"...'),
      findsOneWidget,
    );
    done.complete([first]);
    await tester.pump();
    expect(find.byKey(const ValueKey('lyrics-searching')), findsNothing);
  });

  testWidgets('searching_text_leaves_out_a_blank_artist', (tester) async {
    await pumpPanel(
      tester,
      (t, a) => Completer<List<LyricsCandidate>>().future,
      title: 'My Song',
      artist: ' ',
    );
    expect(find.text('Searching lrclib.net for "My Song"...'), findsOneWidget);
  });

  testWidgets('stale_answer_is_dropped', (tester) async {
    final slow = Completer<List<LyricsCandidate>>();
    var n = 0;
    await pumpPanel(
      tester,
      (t, a) => n++ == 0 ? slow.future : Future.value([second]),
    );
    await tapAndPump(tester, 'lyrics-search');
    expect(find.text('Song Two - Artist Two'), findsOneWidget);
    slow.complete([first]);
    await tester.pump();
    expect(find.text('Song One - Artist One'), findsNothing);
    expect(find.text('Song Two - Artist Two'), findsOneWidget);
  });

  testWidgets('closing_while_searching_is_quiet', (tester) async {
    final done = Completer<List<LyricsCandidate>>();
    await pumpPanel(tester, (t, a) => done.future);
    await tester.pumpWidget(const SizedBox());
    done.complete([first]);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
