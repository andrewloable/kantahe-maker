import 'dart:async';
import 'dart:io';

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
  final opened = <Uri>[];
}

Future<Harness> pumpPanel(
  WidgetTester tester,
  LyricsFinder finder, {
  String title = 'T',
  String artist = 'A',
  bool autoSearch = true,
  Duration retryDelay = Duration.zero,
  Future<void> Function(Uri url)? openUrl,
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
            retryDelay: retryDelay,
            openUrl: openUrl ?? (url) async => h.opened.add(url),
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
        'Searching lrclib.net (and lyrics.ovh when it finds nothing) sends the title and artist; nothing else.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('tile_says_from_lyrics_ovh', (tester) async {
    const ovh = LyricsCandidate(
      title: 'Song Four',
      artist: 'Artist Four',
      album: '',
      lyrics: 'x',
      source: 'lyrics.ovh',
    );
    await pumpPanel(tester, (t, a) async => [ovh, second]);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('lyrics-result-0')),
        matching: find.textContaining('from lyrics.ovh'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('from lyrics.ovh'), findsOneWidget);
  });

  testWidgets('picking_a_result_calls_back', (tester) async {
    final h = await pumpPanel(tester, (t, a) async => [first, second]);
    await tester.tap(find.byKey(const ValueKey('lyrics-result-1')));
    await tester.pump();
    expect(h.picked, [same(second)]);
  });

  // Ported from the dialog's shows_results_and_returns_the_pick.
  testWidgets('tile_says_timed', (tester) async {
    const timed = LyricsCandidate(
      title: 'Song Three',
      artist: 'Artist Three',
      album: 'Album Three',
      lyrics: 'x',
      synced: [(1.0, 'x')],
    );
    await pumpPanel(tester, (t, a) async => [timed, second]);
    final tile = find.byKey(const ValueKey('lyrics-result-0'));
    expect(
      find.descendant(of: tile, matching: find.textContaining('timed')),
      findsOneWidget,
    );
    final plain = find.byKey(const ValueKey('lyrics-result-1'));
    expect(
      find.descendant(of: plain, matching: find.textContaining('timed')),
      findsNothing,
    );
  });

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
    expect(find.text('Try again'), findsNothing);
    await tapAndPump(tester, 'lyrics-search');
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

  group('lrclib.net server problems', () {
    const busy503 = LyricsLookupException(
      'The server is busy, please retry in a moment',
      statusCode: 503,
    );
    final googleLink = find.byKey(const ValueKey('lyrics-google'));

    testWidgets('tried_five_times_then_a_google_link', (tester) async {
      final h = await pumpPanel(tester, (t, a) async => throw busy503);
      await tester.pumpAndSettle();
      expect(h.calls, hasLength(5));
      expect(find.text('The server is busy, please retry in a moment'), findsOneWidget);
      expect(find.textContaining('did not answer after 5 tries'), findsOneWidget);
      expect(googleLink, findsOneWidget);
      expect(find.byKey(const ValueKey('lyrics-search')), findsOneWidget, reason: 'Search again stays');
    });

    // The real lookup against a server that answers like lrclib does when it is busy: with a
    // 503 line, or with a 200 line and the status only in the body.
    for (final httpStatus in [503, 200]) {
      testWidgets('real_busy_answers_end_in_the_google_link_http_$httpStatus', (tester) async {
        // The test harness blocks real network calls; this test talks to a server of its own.
        final blocked = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = blocked);
        late HttpServer server;
        var requests = 0;
        await tester.runAsync(() async {
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server.listen((r) {
            requests++;
            r.response
              ..statusCode = httpStatus
              ..headers.contentType = ContentType.json
              ..write('{"name":"ServerOverloaded","message":"The server is busy, '
                  'please retry in a moment","statusCode":503}');
            r.response.close();
          });
        });
        final base = Uri.parse('http://127.0.0.1:${server.port}/');
        await pumpPanel(tester, (t, a) => findLyrics(t, a, base: base));
        for (var i = 0; i < 300 && googleLink.evaluate().isEmpty; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(googleLink, findsOneWidget);
        expect(requests, 5, reason: 'five tries, then the link');
        expect(find.text('The server is busy, please retry in a moment'), findsOneWidget);
        await tester.runAsync(() => server.close(force: true));
      });
    }

    testWidgets('the_link_opens_a_google_search_for_the_lyrics', (tester) async {
      final h = await pumpPanel(
        tester,
        (t, a) async => throw busy503,
        title: 'Song',
        artist: 'Singer',
      );
      await tester.pumpAndSettle();
      await tester.tap(googleLink);
      await tester.pump();
      expect(h.opened, [Uri.parse('https://www.google.com/search?q=Song+Singer+lyrics')]);
    });

    testWidgets('a_browser_that_will_not_open_is_reported', (tester) async {
      await pumpPanel(
        tester,
        (t, a) async => throw busy503,
        openUrl: (url) async => throw 'no browser',
      );
      await tester.pumpAndSettle();
      await tester.tap(googleLink);
      await tester.pump();
      expect(find.textContaining('Could not open the browser: no browser'), findsOneWidget);
    });

    testWidgets('no_link_while_it_may_still_work', (tester) async {
      var n = 0;
      final h = await pumpPanel(tester, (t, a) async {
        if (++n < 3) throw busy503;
        return [first];
      });
      await tester.pumpAndSettle();
      expect(h.calls, hasLength(3));
      expect(find.text('Song One - Artist One'), findsOneWidget);
      expect(googleLink, findsNothing);
    });

    testWidgets('says_which_attempt_it_is_on', (tester) async {
      var n = 0;
      await pumpPanel(
        tester,
        (t, a) async {
          if (++n < 3) throw busy503;
          return [first];
        },
        retryDelay: const Duration(seconds: 1),
      );
      await tester.pump();
      expect(find.textContaining('Trying again (attempt 2 of 5)'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.textContaining('Trying again (attempt 3 of 5)'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Song One - Artist One'), findsOneWidget);
    });

    testWidgets('other_errors_are_not_retried_and_have_no_link', (tester) async {
      for (final e in const [
        LyricsLookupException('Could not reach lrclib.net: offline'),
        LyricsLookupException('bad request', statusCode: 400),
      ]) {
        final h = await pumpPanel(tester, (t, a) async => throw e);
        await tester.pumpAndSettle();
        expect(h.calls, hasLength(1), reason: e.message);
        expect(find.text(e.message), findsOneWidget);
        expect(googleLink, findsNothing, reason: e.message);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('search_again_counts_from_the_start', (tester) async {
      final h = await pumpPanel(tester, (t, a) async => throw busy503);
      await tester.pumpAndSettle();
      expect(h.calls, hasLength(5));
      await tester.tap(find.byKey(const ValueKey('lyrics-search')));
      await tester.pumpAndSettle();
      expect(h.calls, hasLength(10));
      expect(googleLink, findsOneWidget);
    });

    testWidgets('starting_over_stops_the_retries_of_the_old_search', (tester) async {
      var n = 0;
      final h = await pumpPanel(
        tester,
        (t, a) async {
          if (++n <= 2) throw busy503;
          return [second];
        },
        retryDelay: const Duration(seconds: 5),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('lyrics-search')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.text('Song Two - Artist Two'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(h.calls.length, lessThan(6));
    });
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
