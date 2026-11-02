import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/song_info.dart';
import 'package:kantahe_maker/web_get.dart';

// The fixtures are real MusicBrainz answers recorded once on 2026-11-02 (search for
// "Yesterday" by "The Beatles"; the search one is trimmed to two releases per recording and
// no artist aliases, so it stays small).
String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

String recording({
  String title = 'T',
  List<Map<String, Object?>> credits = const [
    {'name': 'A', 'joinphrase': ''},
  ],
  Object? releases = const [],
  Object? date,
  Object? length,
}) => jsonEncode({
  'id': 'rid',
  'title': title,
  'artist-credit': credits,
  'releases': releases,
  'first-release-date': date,
  'length': length,
});

Map<String, Object?> workRel(List<(String, String)> artists) => {
  'type': 'performance',
  'work': {
    'title': 'W',
    'relations': [
      for (final (type, name) in artists)
        {
          'type': type,
          'target-type': 'artist',
          'artist': {'name': name},
        },
    ],
  },
};

void main() {
  group('queryFromFileName', () {
    test('query_from_file_name', () {
      expect(queryFromFileName('/m/Artist - Title (Official Video).mp4'), (
        title: 'Title',
        artist: 'Artist',
      ));
      expect(queryFromFileName('/m/Title.mp3'), (title: 'Title', artist: ''));
      expect(queryFromFileName('/m/A - B - C.mp3'), (title: 'B - C', artist: 'A'));
      expect(queryFromFileName('/m/[HD] Song Name.mp4'), (
        title: 'Song Name',
        artist: '',
      ));
    });
  });

  group('songInfoSearchUri', () {
    test('search_uri_quotes_and_escapes', () {
      final uri = songInfoSearchUri('Say "Hi" now', 'A');
      expect(uri.host, 'musicbrainz.org');
      expect(uri.path, '/ws/2/recording');
      expect(
        uri.queryParameters['query'],
        'recording:"Say \\"Hi\\" now" AND artist:"A"',
      );
      expect(uri.queryParameters['fmt'], 'json');
      expect(uri.queryParameters['limit'], '10');
      expect(uri.query, isNot(contains('+')));
    });

    test('search_uri_without_artist', () {
      final uri = songInfoSearchUri('T', '  ');
      expect(uri.queryParameters['query'], 'recording:"T"');
      expect(uri.query, isNot(contains('artist')));
    });
  });

  group('parseSongInfoSearch', () {
    test('parse_search_fixture', () {
      final out = parseSongInfoSearch(fixture('musicbrainz_search.json'));
      expect(out, hasLength(3));
      expect(out.first.title, 'Yesterday');
      expect(out.first.artist, 'The Beatles');
      expect(out.first.album, 'Top Medleys');
      expect(out.first.year, '1991');
      expect(out.first.recordingId, '553f802a-9d1a-4668-8283-b04fcbe6894a');
      expect(out.first.seconds, closeTo(144.666, 0.001));
    });

    test('parse_search_joins_artist_credits', () {
      final body = jsonEncode({
        'recordings': [
          jsonDecode(
            recording(
              credits: [
                {'name': 'A', 'joinphrase': ' feat. '},
                {'name': 'B', 'joinphrase': ''},
              ],
            ),
          ),
        ],
      });
      final c = parseSongInfoSearch(body).single;
      expect(c.artist, 'A feat. B');
      expect(c.album, '');
      expect(c.year, '');
      expect(c.seconds, isNull);
    });

    test('parse_search_year_is_four_characters', () {
      String yearOf(Object? date) {
        final body = jsonEncode({
          'recordings': [jsonDecode(recording(date: date))],
        });
        return parseSongInfoSearch(body).single.year;
      }

      expect(yearOf('2015-11-06'), '2015');
      expect(yearOf('2015-11'), '2015');
      expect(yearOf('2015'), '2015');
      expect(yearOf(''), '');
      expect(yearOf(null), '');
    });

    test('parse_search_garbage', () {
      for (final bad in ['not json', '[]', '{"recordings": 5}']) {
        expect(
          () => parseSongInfoSearch(bad),
          throwsA(isA<SongInfoException>()),
          reason: bad,
        );
      }
      expect(
        () => parseSongInfoSearch('{"error": "Invalid query"}'),
        throwsA(
          isA<SongInfoException>().having(
            (e) => e.message,
            'message',
            'Invalid query',
          ),
        ),
      );
    });
  });

  group('songInfoDetails parsing', () {
    test('details_uri', () {
      expect(
        songInfoDetailsUri('abc').toString(),
        'https://musicbrainz.org/ws/2/recording/abc'
        '?inc=work-rels+work-level-rels+artist-rels&fmt=json',
      );
    });

    test('parse_details_writer_counts_for_both', () {
      final body = jsonEncode({
        'relations': [
          workRel([
            ('writer', 'W'),
            ('composer', 'C'),
            ('lyricist', 'L'),
            ('composer', 'W'),
          ]),
        ],
      });
      expect(parseSongInfoDetails(body), (composer: 'W, C', lyricist: 'W, L'));
    });

    test('parse_details_fixture', () {
      expect(parseSongInfoDetails(fixture('musicbrainz_recording.json')), (
        composer: 'John Lennon, Paul McCartney',
        lyricist: 'John Lennon, Paul McCartney',
      ));
    });

    test('parse_details_without_works', () {
      expect(parseSongInfoDetails('{"relations": []}'), (
        composer: '',
        lyricist: '',
      ));
    });

    test('parse_details_garbage', () {
      expect(
        () => parseSongInfoDetails('not json'),
        throwsA(isA<SongInfoException>()),
      );
    });
  });

  test('wait_before_next_request', () {
    final now = DateTime(2026, 11, 2, 12);
    expect(waitBeforeNextRequest(null, now), Duration.zero);
    expect(
      waitBeforeNextRequest(now.subtract(const Duration(milliseconds: 300)), now),
      const Duration(milliseconds: 800),
    );
    expect(
      waitBeforeNextRequest(now.subtract(const Duration(seconds: 2)), now),
      Duration.zero,
    );
  });

  group('over the network (local server)', () {
    late HttpServer server;
    late Uri base;
    final seen = <HttpRequest>[];
    var status = 200;
    var body = '{}';
    var hang = false;
    // When set, answers by the request (the query) instead of [body].
    String Function(HttpRequest)? answer;

    setUp(() async {
      seen.clear();
      status = 200;
      body = '{}';
      hang = false;
      answer = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}/ws/2/recording');
      server.listen((req) {
        seen.add(req);
        if (hang) return;
        req.response
          ..statusCode = status
          ..headers.contentType = ContentType.json
          ..write(answer?.call(req) ?? body)
          ..close();
      });
    });
    tearDown(() => server.close(force: true));

    test('find_sends_user_agent_and_query', () async {
      body = fixture('musicbrainz_search.json');
      final out = await findSongInfo('Yesterday', 'The Beatles', base: base);
      expect(out, hasLength(3));
      final req = seen.single;
      expect(req.method, 'GET');
      expect(req.uri.path, '/ws/2/recording');
      expect(req.headers.value('user-agent'), appUserAgent);
      expect(req.headers.value('accept'), contains('application/json'));
      expect(req.uri.queryParameters['fmt'], 'json');
      expect(
        req.uri.queryParameters['query'],
        'recording:"Yesterday" AND artist:"The Beatles"',
      );
    });

    String queryOf(HttpRequest r) => r.uri.queryParameters['query']!;

    test('find_swaps_when_nothing_is_found', () async {
      // "Title - Artist.mp3" read as "Artist - Title": the first search has them the wrong way.
      answer = (r) => queryOf(r) == 'recording:"Yesterday" AND artist:"The Beatles"'
          ? fixture('musicbrainz_search.json')
          : '{"recordings":[]}';
      final out = await findSongInfo('The Beatles', 'Yesterday', base: base);
      expect(out, hasLength(3));
      expect(seen.map(queryOf), [
        'recording:"The Beatles" AND artist:"Yesterday"',
        'recording:"Yesterday" AND artist:"The Beatles"',
      ]);
    });

    test('find_does_not_swap_when_found', () async {
      body = fixture('musicbrainz_search.json');
      await findSongInfo('Yesterday', 'The Beatles', base: base);
      expect(seen, hasLength(1));
    });

    test('find_does_not_swap_without_artist', () async {
      body = '{"recordings":[]}';
      expect(await findSongInfo('Yesterday', '  ', base: base), isEmpty);
      expect(seen, hasLength(1));
    });

    test('find_does_not_swap_when_both_are_the_same_ignoring_case', () async {
      body = '{"recordings":[]}';
      expect(await findSongInfo('Queen', 'queen', base: base), isEmpty);
      expect(seen, hasLength(1));
    });

    test('find_swapped_nothing_either', () async {
      body = '{"recordings":[]}';
      expect(await findSongInfo('A', 'B', base: base), isEmpty);
      expect(seen, hasLength(2));
    });

    test('find_http_error_does_not_swap', () async {
      status = 500;
      body = 'oops';
      await expectLater(findSongInfo('A', 'B', base: base), throwsA(isA<SongInfoException>()));
      expect(seen, hasLength(1));
    });

    test('find_limits_to_ten', () async {
      body = jsonEncode({
        'recordings': [for (var i = 0; i < 15; i++) jsonDecode(recording(title: 'T$i'))],
      });
      expect(await findSongInfo('t', 'a', base: base), hasLength(10));
    });

    test('find_busy', () async {
      status = 503;
      body = '{"error":"Your requests are exceeding the allowable rate limit."}';
      await expectLater(
        findSongInfo('t', 'a', base: base),
        throwsA(
          isA<SongInfoException>().having((e) => e.message, 'message', contains('busy')),
        ),
      );
    });

    test('find_http_error', () async {
      status = 500;
      await expectLater(
        findSongInfo('t', 'a', base: base),
        throwsA(
          isA<SongInfoException>().having((e) => e.message, 'message', contains('500')),
        ),
      );
    });

    test('find_unreachable', () async {
      final closed = Uri.parse('http://127.0.0.1:${server.port}/ws/2/recording');
      await server.close(force: true);
      await expectLater(
        findSongInfo('t', 'a', base: closed),
        throwsA(
          isA<SongInfoException>().having(
            (e) => e.message,
            'message',
            startsWith('Could not reach'),
          ),
        ),
      );
    });

    test('find_timeout', () async {
      hang = true;
      final watch = Stopwatch()..start();
      await expectLater(
        findSongInfo('t', 'a', base: base, timeout: const Duration(milliseconds: 200)),
        throwsA(
          isA<SongInfoException>().having((e) => e.message, 'message', contains('in time')),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('details_sends_the_includes', () async {
      body = fixture('musicbrainz_recording.json');
      final out = await songInfoDetails('abc', base: base);
      expect(out.composer, 'John Lennon, Paul McCartney');
      final req = seen.single;
      expect(req.uri.path, '/ws/2/recording/abc');
      expect(req.uri.query, contains('inc=work-rels+work-level-rels+artist-rels'));
      expect(req.headers.value('user-agent'), appUserAgent);
    });

    test('get_text_too_much_data', () async {
      body = 'x' * 1000;
      await expectLater(
        getText(base, maxBytes: 100),
        throwsA(
          isA<WebGetException>().having(
            (e) => e.message,
            'message',
            contains('too much data'),
          ),
        ),
      );
    });
  });
}
