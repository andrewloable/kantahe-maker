import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/lyrics_lookup.dart';

// The field names are the ones LRCLIB really sends (checked 2026-10-30).
Map<String, Object?> entry({
  String title = 'Bohemian Rhapsody',
  String artist = 'Queen',
  String album = 'A Night at the Opera',
  Object? duration = 355.0,
  Object? plain = 'Is this the real life?\nIs this just fantasy?',
  bool instrumental = false,
}) => {
  'id': 1,
  'name': title,
  'trackName': title,
  'artistName': artist,
  'albumName': album,
  'duration': duration,
  'instrumental': instrumental,
  'plainLyrics': plain,
  'syncedLyrics': '[00:00.15] x',
  'hasWordSync': false,
  'lyricsfile': 'ignored',
};

LyricsCandidate cand(String title, String artist) =>
    LyricsCandidate(title: title, artist: artist, album: '', lyrics: 'l');

const busy =
    '{"message":"The server is busy, please retry in a moment",'
    '"name":"ServerOverloaded","statusCode":503}';

void main() {
  group('lyricsSearchUri', () {
    test('search_uri_encodes', () {
      final u = lyricsSearchUri('Rock & Roll', 'Beyoncé');
      expect(u.path, endsWith('/api/search'));
      expect(u.queryParameters, {
        'track_name': 'Rock & Roll',
        'artist_name': 'Beyoncé',
      });
      expect(u.query, isNot(contains(' ')));
      expect(u.query, isNot(contains('& ')));
      expect(u.host, 'lrclib.net');
    });

    test('search_uri_without_artist', () {
      final u = lyricsSearchUri(' My \n  Song ', '  ');
      expect(u.queryParameters, {'track_name': 'My Song'});
    });

    test('search_uri_base', () {
      final u = lyricsSearchUri(
        'a',
        'b',
        base: Uri.parse('http://127.0.0.1:9/api/search'),
      );
      expect(u.port, 9);
      expect(u.queryParameters['artist_name'], 'b');
    });
  });

  group('parseLyricsSearch', () {
    test('parse_candidates', () {
      final body = jsonEncode([
        entry(plain: 'one\r\ntwo\rthree\n\n'),
        entry(title: 'B', artist: 'Z', album: '', duration: null),
      ]);
      final c = parseLyricsSearch(body);
      expect(c, hasLength(2));
      expect(c[0].title, 'Bohemian Rhapsody');
      expect(c[0].artist, 'Queen');
      expect(c[0].album, 'A Night at the Opera');
      expect(c[0].seconds, 355.0);
      expect(c[0].lyrics, 'one\ntwo\nthree');
      expect(c[1].title, 'B');
      expect(c[1].seconds, isNull);
    });

    test('parse_skips_unusable', () {
      final body = jsonEncode([
        entry(instrumental: true),
        entry(plain: null),
        entry(plain: '   '),
        'a string',
        42,
        entry(title: 'Good'),
      ]);
      final c = parseLyricsSearch(body);
      expect(c.map((e) => e.title), ['Good']);
    });

    test('parse_empty_array', () {
      expect(parseLyricsSearch('[]'), isEmpty);
    });

    test('parse_error_object', () {
      expect(
        () => parseLyricsSearch(busy),
        throwsA(
          isA<LyricsLookupException>().having(
            (e) => e.message,
            'message',
            contains('busy'),
          ),
        ),
      );
    });

    test('parse_garbage', () {
      for (final body in ['not json', '{"a":1}', '42', '']) {
        expect(
          () => parseLyricsSearch(body),
          throwsA(isA<LyricsLookupException>()),
          reason: body,
        );
      }
    });
  });

  group('rankLyrics', () {
    test('rank_exact_first', () {
      final other = cand('Something else', 'Queen');
      final titleOnly = cand('Bohemian Rhapsody', 'Somebody');
      final both = cand('  bohemian   RHAPSODY', 'queen ');
      final other2 = cand('Another', 'Queen');
      final out = rankLyrics(
        [other, titleOnly, both, other2],
        'Bohemian Rhapsody',
        'Queen',
      );
      expect(out, [both, titleOnly, other, other2]);
    });

    test('rank_without_artist_matches_on_title', () {
      final a = cand('X', 'p');
      final b = cand('Y', 'q');
      expect(rankLyrics([a, b], 'Y', ''), [b, a]);
    });
  });

  group('findLyrics', () {
    late HttpServer server;
    late Uri base;
    final seen = <HttpRequest>[];
    var status = 200;
    var body = '[]';
    var hang = false;

    setUp(() async {
      seen.clear();
      status = 200;
      body = '[]';
      hang = false;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}/api/search');
      server.listen((req) {
        seen.add(req);
        if (hang) return;
        req.response
          ..statusCode = status
          ..headers.contentType = ContentType.json
          ..write(body)
          ..close();
      });
    });
    tearDown(() => server.close(force: true));

    test('find_sends_the_request', () async {
      body = jsonEncode([entry(title: 'Other', artist: 'Someone'), entry()]);
      final out = await findLyrics('Bohemian Rhapsody', 'Queen', base: base);
      expect(seen, hasLength(1));
      final req = seen.single;
      expect(req.method, 'GET');
      expect(req.uri.path, '/api/search');
      expect(req.uri.queryParameters, {
        'track_name': 'Bohemian Rhapsody',
        'artist_name': 'Queen',
      });
      expect(req.headers.value('user-agent'), startsWith('KantaheMaker/'));
      expect(out.map((c) => c.title), ['Bohemian Rhapsody', 'Other']);
    });

    test('find_limits_to_ten', () async {
      body = jsonEncode([for (var i = 0; i < 15; i++) entry(title: 'T$i')]);
      expect(await findLyrics('t', 'a', base: base), hasLength(10));
    });

    test('find_server_busy', () async {
      status = 503;
      body = busy;
      await expectLater(
        findLyrics('t', 'a', base: base),
        throwsA(
          isA<LyricsLookupException>().having(
            (e) => e.message,
            'message',
            contains('busy'),
          ),
        ),
      );
    });

    test('find_http_error', () async {
      status = 500;
      body = 'oops';
      await expectLater(
        findLyrics('t', 'a', base: base),
        throwsA(
          isA<LyricsLookupException>().having(
            (e) => e.message,
            'message',
            contains('500'),
          ),
        ),
      );
    });

    test('find_unreachable', () async {
      final closed = Uri.parse('http://127.0.0.1:${server.port}/api/search');
      await server.close(force: true);
      await expectLater(
        findLyrics('t', 'a', base: closed),
        throwsA(
          isA<LyricsLookupException>().having(
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
        findLyrics(
          't',
          'a',
          base: base,
          timeout: const Duration(milliseconds: 200),
        ),
        throwsA(
          isA<LyricsLookupException>().having(
            (e) => e.message,
            'message',
            contains('in time'),
          ),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('find_too_much_data', () async {
      body = jsonEncode([entry(plain: 'x' * 1000)]);
      await expectLater(
        findLyrics('t', 'a', base: base, maxBytes: 100),
        throwsA(
          isA<LyricsLookupException>().having(
            (e) => e.message,
            'message',
            contains('too much data'),
          ),
        ),
      );
    });

    test('find_works_when_the_data_fits', () async {
      body = jsonEncode([entry()]);
      expect(
        await findLyrics('t', 'a', base: base, maxBytes: 100000),
        hasLength(1),
      );
    });
  });
}
