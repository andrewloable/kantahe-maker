import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/cdp.dart';
import 'package:kantahe_maker/youtube_rank.dart';
import 'package:kantahe_maker/youtube_search.dart';
import 'package:path/path.dart' as p;

import 'support/test_browser.dart';

/// A trimmed, hand-written YouTube results page (ytInitialData) with made-up videos.
Object? fixture() => jsonDecode(
  File(p.join('test', 'fixtures', 'youtube_results.json')).readAsStringSync(),
);

Map<String, Object?> page(List<Object?> items) => {
  'contents': {
    'twoColumnSearchResultsRenderer': {
      'primaryContents': {
        'sectionListRenderer': {
          'contents': [
            {
              'itemSectionRenderer': {'contents': items},
            },
          ],
        },
      },
    },
  },
};

void main() {
  group('parseYtInitialData', () {
    test('parses_videos_in_order', () {
      final r = parseYtInitialData(fixture());
      expect(r.map((v) => v.videoId), ['aaaaaaaaaa1', 'aaaaaaaaaa2', 'aaaaaaaaaa3']);
      expect(r[0].title, 'Singer - Song (Official Video)');
      expect(r[0].channel, 'Singer');
      expect(r[2].channel, 'Stream Channel');
    });

    test('reads_badge_and_length', () {
      final r = parseYtInitialData(fixture());
      expect(r[0].seconds, 225);
      expect(r[0].officialArtist, isTrue);
      expect(r[1].seconds, 3723);
      expect(r[1].officialArtist, isFalse, reason: 'a plain verified badge is not the artist');
      expect(r[2].seconds, isNull, reason: 'no lengthText (live)');
    });

    test('skips_non_videos', () {
      final r = parseYtInitialData(fixture());
      expect(r, everyElement(isA<YoutubeResult>()));
      expect(r.where((v) => v.title == 'No id'), isEmpty);
    });

    test('unreadable_length_is_null', () {
      final r = parseYtInitialData(page([
        {
          'videoRenderer': {
            'videoId': 'aaaaaaaaaa4',
            'title': {'runs': [{'text': 'Song'}]},
            'ownerText': {'runs': [{'text': 'Singer'}]},
            'lengthText': {'simpleText': 'LIVE'},
          },
        },
      ]));
      expect(r.single.seconds, isNull);
    });

    test('video_without_title_is_skipped', () {
      final r = parseYtInitialData(page([
        {
          'videoRenderer': {
            'videoId': 'aaaaaaaaaa5',
            'ownerText': {'runs': [{'text': 'Singer'}]},
          },
        },
      ]));
      expect(r, isEmpty);
    });

    test('missing_path_throws', () {
      Matcher odd() => throwsA(isA<YoutubeSearchException>().having(
        (e) => e.message,
        'message',
        'YouTube looks different than expected',
      ));
      expect(() => parseYtInitialData(null), odd());
      expect(() => parseYtInitialData('text'), odd());
      expect(() => parseYtInitialData({'contents': {}}), odd());
      expect(
        () => parseYtInitialData({
          'contents': {
            'twoColumnSearchResultsRenderer': {
              'primaryContents': {'sectionListRenderer': {}},
            },
          },
        }),
        odd(),
      );
    });

    test('parses_lockup_videos_as_a_real_browser_gets_them', () {
      // km-4jl: a real browser gets lockupViewModel items, not videoRenderer.
      final r = parseYtInitialData(jsonDecode(
        File(p.join('test', 'fixtures', 'youtube_results_browser.json')).readAsStringSync(),
      ));
      expect(r.map((v) => v.videoId), ['bbbbbbbbbb1', 'bbbbbbbbbb2', 'bbbbbbbbbb3', 'bbbbbbbbbb4']);
      expect(r[0].title, 'Singer - Song (Official Video)');
      expect(r[0].channel, 'Singer');
      expect(r[0].seconds, 225);
      expect(r[0].officialArtist, isTrue);
      expect(r[1].channel, 'Lyrics Hub');
      expect(r[1].seconds, 3723);
      expect(r[1].officialArtist, isFalse, reason: 'a plain verified badge is not the artist');
      expect(r[2].channel, 'Stream Channel', reason: 'a byline without an avatar');
      expect(r[2].seconds, isNull);
      expect(r[3].channel, 'Singer - Topic', reason: 'old and new items can be mixed');
    });

    test('no_videos_gives_empty', () {
      expect(parseYtInitialData(page([])), isEmpty);
    });
  });

  group('youtubeNeedsUser', () {
    test('needs_user_on_consent_or_check', () {
      expect(youtubeNeedsUser('consent.youtube.com', 'Before you continue', ''), isTrue);
      expect(youtubeNeedsUser('www.youtube.com', 'Just a moment...', ''), isTrue);
      expect(youtubeNeedsUser('www.youtube.com', 'YouTube', 'Verify you are human'), isTrue);
      expect(youtubeNeedsUser('www.youtube.com', 'song - YouTube', 'results'), isFalse);
    });
  });

  group('searchYoutube', () {
    late HttpServer server;
    late String mode; // ok, empty, check (a check page on the first load only)
    final queries = <String>[];

    setUp(() async {
      mode = 'ok';
      queries.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final data = File(p.join('test', 'fixtures', 'youtube_results.json')).readAsStringSync();
      server.listen((req) {
        final r = req.response;
        if (req.uri.path == '/results') {
          queries.add(req.uri.queryParameters['search_query'] ?? '');
          r.headers.contentType = ContentType.html;
          if (mode == 'check' && queries.length == 1) {
            r.write('<!doctype html><html><head><title>Just a moment...</title></head>'
                '<body>Checking your browser</body></html>');
          } else {
            r.write('<!doctype html><html><head><title>fake - YouTube</title></head><body>'
                '${mode != 'empty' ? '<script>var ytInitialData = $data;</script>' : ''}'
                '</body></html>');
          }
        } else {
          r.statusCode = 404;
        }
        r.close();
      });
    });
    tearDown(() => server.close(force: true));

    Uri site() => Uri.parse('http://127.0.0.1:${server.port}/');

    test('search_returns_results', () async {
      final browsers = <CdpBrowser>[];
      final logs = <String>[];
      final r = await searchYoutube(
        'Singer Song & more',
        browserPath: browser,
        site: site(),
        headless: true,
        onBrowser: browsers.add,
        onLog: logs.add,
      );
      expect(r.map((v) => v.videoId), ['aaaaaaaaaa1', 'aaaaaaaaaa2', 'aaaaaaaaaa3']);
      expect(queries, ['Singer Song & more']);
      expect(browsers, hasLength(1));
      await browsers.single.done.timeout(const Duration(seconds: 10));
      expect(logs.every((l) => l.startsWith('youtube +')), isTrue);
      expect(logs.join('\n'), isNot(contains('Singer Song')), reason: 'no song text in the log');
    }, skip: noBrowser, timeout: const Timeout(Duration(seconds: 90)));

    test('no_browser_message', () async {
      await expectLater(
        searchYoutube('x', browserExists: (_) => false, site: site()),
        throwsA(isA<YoutubeSearchException>().having(
          (e) => e.message,
          'message',
          'Kantahe Maker needs Google Chrome or Microsoft Edge to search YouTube. '
              'Install one of them, or choose an MP3 file.',
        )),
      );
    });

    test('check_page_is_handed_to_the_user', () async {
      // km-6nk. The first load is a check page: the browser is closed and opened again (a
      // visible window in the app; still headless here, so the test runs without a display),
      // the user is told, and the search goes on by itself.
      mode = 'check';
      final browsers = <CdpBrowser>[];
      final agents = <Future<Object?>>[];
      final statuses = <String>[];
      final r = await searchYoutube(
        'x',
        browserPath: browser,
        site: site(),
        headless: true,
        onBrowser: (b) {
          browsers.add(b);
          agents.add(b.send('Browser.getVersion').then((v) => v['userAgent']));
        },
        onStatus: statuses.add,
      );
      expect(r, hasLength(3));
      expect(browsers, hasLength(2));
      expect(await Future.wait(agents), everyElement(contains('Headless')),
          reason: 'no window opens in tests');
      expect(queries, ['x', 'x']);
      expect(statuses, [
        'YouTube wants you to confirm something. Finish it in the browser window; '
            'the search then continues by itself.',
      ]);
      for (final b in browsers) {
        await b.done.timeout(const Duration(seconds: 10));
        expect(Directory(b.profilePath!).existsSync(), isFalse);
      }
    }, skip: noBrowser, timeout: const Timeout(Duration(seconds: 90)));

    test('browser_problem_message', () async {
      // km-6nk: a browser that cannot be started (or controlled) gives one clear message.
      final missing = p.join(Directory.systemTemp.path, 'no-such-browser', 'chrome.exe');
      await expectLater(
        searchYoutube('x', browserPath: missing, site: site(), headless: true),
        throwsA(isA<YoutubeSearchException>().having(
          (e) => e.message,
          'message',
          startsWith('Could not control the browser: '),
        )),
      );
    });

    test('page_without_data_times_out', () async {
      mode = 'empty';
      final browsers = <CdpBrowser>[];
      await expectLater(
        searchYoutube(
          'x',
          browserPath: browser,
          site: site(),
          headless: true,
          findTimeout: const Duration(seconds: 2),
          onBrowser: browsers.add,
        ),
        throwsA(isA<YoutubeSearchException>().having(
          (e) => e.message,
          'message',
          'YouTube did not show any results',
        )),
      );
      await browsers.single.done.timeout(const Duration(seconds: 10));
    }, skip: noBrowser, timeout: const Timeout(Duration(seconds: 90)));

    test('cancel_stops', () async {
      mode = 'empty';
      final cancel = Completer<void>();
      final clock = Stopwatch()..start();
      final run = searchYoutube(
        'x',
        browserPath: browser,
        site: site(),
        headless: true,
        cancel: cancel.future,
        onBrowser: (_) => Timer(const Duration(milliseconds: 500), cancel.complete),
      );
      await expectLater(
        run,
        throwsA(isA<YoutubeSearchException>().having((e) => e.message, 'message', 'Cancelled')),
      );
      expect(clock.elapsed, lessThan(const Duration(seconds: 25)), reason: 'not the 30 s time limit');
    }, skip: noBrowser, timeout: const Timeout(Duration(seconds: 90)));
  });
}
