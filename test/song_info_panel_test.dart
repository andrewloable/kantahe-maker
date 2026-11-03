import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/screens/song_info_panel.dart';
import 'package:kantahe_maker/song_info.dart';
import 'package:kantahe_maker/web_get.dart';

const first = SongInfoCandidate(
  title: 'Song One',
  artist: 'Artist One',
  album: 'Album One',
  year: '1999',
  recordingId: 'r1',
  seconds: 185,
);
const second = SongInfoCandidate(
  title: 'Song Two',
  artist: 'Artist Two',
  album: '',
  year: '',
  recordingId: 'r2',
);

class Harness {
  final calls = <(String, String)>[];
  final picked = <SongInfoCandidate>[];
}

Future<Harness> pumpPanel(
  WidgetTester tester,
  SongInfoFinder finder, {
  String title = 'T',
  String artist = 'A',
  bool autoSearch = true,
  String? loadingId,
}) async {
  final h = Harness();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SongInfoPanel(
            title: title,
            artist: artist,
            autoSearch: autoSearch,
            loadingId: loadingId,
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
    final h = await pumpPanel(tester, (t, a) async => [first], autoSearch: false);
    expect(h.calls, isEmpty);
    await tapAndPump(tester, 'info-search');
    expect(h.calls, hasLength(1));
  });

  testWidgets('no_search_without_title', (tester) async {
    final h = await pumpPanel(tester, (t, a) async => [first], title: '  ');
    expect(h.calls, isEmpty);
    expect(find.text('Type a title to search musicbrainz.org.'), findsOneWidget);
    expect(find.byKey(const ValueKey('info-search')), findsNothing);
  });

  testWidgets('says_what_is_sent', (tester) async {
    await pumpPanel(tester, (t, a) async => [first]);
    expect(
      find.text(
        'Searching musicbrainz.org sends the title and artist (or the file name); nothing else.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('picking_a_result_calls_back', (tester) async {
    final h = await pumpPanel(tester, (t, a) async => [first, second]);
    await tester.tap(find.byKey(const ValueKey('info-result-1')));
    await tester.pump();
    expect(h.picked, [same(second)]);
  });

  testWidgets('result_tiles_show_album_year_length', (tester) async {
    await pumpPanel(tester, (t, a) async => [first, second]);
    expect(find.text('Song One - Artist One'), findsOneWidget);
    expect(find.text('Album One · 1999 · 3:05'), findsOneWidget);
    expect(find.text('Song Two - Artist Two'), findsOneWidget);
  });

  testWidgets('a_tile_shows_a_spinner_while_its_details_load', (tester) async {
    await pumpPanel(tester, (t, a) async => [first, second], loadingId: 'r2');
    final spinner = find.byKey(const ValueKey('info-loading'));
    expect(spinner, findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('info-result-1')),
        matching: spinner,
      ),
      findsOneWidget,
    );
  });

  testWidgets('empty_result_says_fill_in', (tester) async {
    await pumpPanel(tester, (t, a) async => []);
    expect(
      find.text('No match on musicbrainz.org. Fill in the details below.'),
      findsOneWidget,
    );
  });

  testWidgets('error_then_retry', (tester) async {
    var n = 0;
    final h = await pumpPanel(tester, (t, a) async {
      if (n++ == 0) throw const SongInfoException('down');
      return [first];
    });
    expect(find.text('down'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
    await tapAndPump(tester, 'info-search');
    expect(find.text('Song One - Artist One'), findsOneWidget);
    expect(h.calls, hasLength(2));
  });

  testWidgets('searching_shows_what_is_searched', (tester) async {
    final done = Completer<List<SongInfoCandidate>>();
    await pumpPanel(tester, (t, a) => done.future, title: 'My Song');
    expect(find.byKey(const ValueKey('info-searching')), findsOneWidget);
    expect(
      find.text('Searching musicbrainz.org for "My Song" by "A"...'),
      findsOneWidget,
    );
    done.complete([first]);
    await tester.pump();
    expect(find.byKey(const ValueKey('info-searching')), findsNothing);
  });

  testWidgets('searching_text_leaves_out_a_blank_artist', (tester) async {
    await pumpPanel(
      tester,
      (t, a) => Completer<List<SongInfoCandidate>>().future,
      title: 'My Song',
      artist: ' ',
    );
    expect(find.text('Searching musicbrainz.org for "My Song"...'), findsOneWidget);
  });

  testWidgets('a_web_error_is_shown_as_its_message', (tester) async {
    await pumpPanel(tester, (t, a) async => throw const WebGetException('offline'));
    expect(find.text('offline'), findsOneWidget);
  });

  testWidgets('stale_answer_is_dropped', (tester) async {
    final slow = Completer<List<SongInfoCandidate>>();
    var n = 0;
    await pumpPanel(
      tester,
      (t, a) => n++ == 0 ? slow.future : Future.value([second]),
    );
    await tapAndPump(tester, 'info-search');
    expect(find.text('Song Two - Artist Two'), findsOneWidget);
    slow.complete([first]);
    await tester.pump();
    expect(find.text('Song One - Artist One'), findsNothing);
    expect(find.text('Song Two - Artist Two'), findsOneWidget);
  });

  testWidgets('closing_while_searching_is_quiet', (tester) async {
    final done = Completer<List<SongInfoCandidate>>();
    await pumpPanel(tester, (t, a) => done.future);
    await tester.pumpWidget(const SizedBox());
    done.complete([first]);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
