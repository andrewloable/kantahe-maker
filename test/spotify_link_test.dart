import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/spotify_link.dart';

const id = '4u7EnebtmKWzUH433cf5Qv';

/// The embed page as far as the code reads it: one __NEXT_DATA__ script. Built here, not
/// copied from Spotify.
String page(Object? pageProps) =>
    '<html><body><script id="__NEXT_DATA__" type="application/json">'
    '${jsonEncode({'props': {'pageProps': pageProps}})}'
    '</script></body></html>';

Map<String, Object?> trackProps({
  String type = 'track',
  String name = 'X - Remastered 2011',
  Object? artists = const [
    {'name': 'A'},
    {'name': 'B'},
  ],
  Object? duration = 354320,
}) => {
  'state': {
    'data': {
      'entity': {
        'type': type,
        'name': name,
        'artists': artists,
        'duration': duration,
        'id': id,
      },
    },
  },
};

void main() {
  group('spotifyTrackId', () {
    test('track_id_from_links', () {
      for (final text in [
        'https://open.spotify.com/track/$id?si=x1',
        'open.spotify.com/intl-de/track/$id',
        'https://open.spotify.com/embed/track/$id',
        'spotify:track:$id',
        '  https://open.spotify.com/track/$id  ',
      ]) {
        expect(spotifyTrackId(text), id, reason: text);
      }
    });

    test('track_id_inside_share_text', () {
      expect(
        spotifyTrackId(
          'Listen to this on Spotify: https://open.spotify.com/track/$id?si=x1 enjoy',
        ),
        id,
      );
      const other = '0000000000000000000000';
      expect(
        spotifyTrackId(
          'https://open.spotify.com/track/$id and https://open.spotify.com/track/$other',
        ),
        id,
      );
    });

    test('track_id_rejects_others', () {
      for (final text in [
        'https://open.spotify.com/album/$id',
        'https://open.spotify.com/playlist/$id',
        'https://example.com/track/$id',
        'https://open.spotify.com/track/${id.substring(1)}',
        'https://open.spotify.com/track/${id}x',
        '',
      ]) {
        expect(spotifyTrackId(text), isNull, reason: text);
      }
    });
  });

  test('short_link_detection', () {
    expect(
      spotifyShortLink('check https://spotify.link/AbC now'),
      'https://spotify.link/AbC',
    );
    expect(spotifyShortLink('spotify.app.link/x1'), 'https://spotify.app.link/x1');
    expect(spotifyShortLink('https://open.spotify.com/track/$id'), isNull);
  });

  test('clean_title', () {
    expect(cleanSpotifyTitle('Bohemian Rhapsody - Remastered 2011'), 'Bohemian Rhapsody');
    expect(cleanSpotifyTitle('Song (2015 Remaster)'), 'Song');
    expect(cleanSpotifyTitle('Song - Live'), 'Song - Live');
    expect(cleanSpotifyTitle('Song'), 'Song');
  });

  group('parseSpotifyEmbed', () {
    test('parse_embed_track', () {
      final t = parseSpotifyEmbed(page(trackProps()));
      expect(t.title, 'X');
      expect(t.artist, 'A, B');
      expect(t.seconds, closeTo(354.32, 0.0001));
      expect(t.id, id);
    });

    test('parse_embed_not_found', () {
      expect(
        () => parseSpotifyEmbed(page({'status': 404})),
        throwsA(
          isA<SpotifyLinkException>().having(
            (e) => e.message,
            'message',
            'Spotify has no song with this link',
          ),
        ),
      );
    });

    test('parse_embed_status_404_wins_over_a_state', () {
      expect(
        () => parseSpotifyEmbed(page({'status': 404, ...trackProps()})),
        throwsA(
          isA<SpotifyLinkException>().having(
            (e) => e.message,
            'message',
            'Spotify has no song with this link',
          ),
        ),
      );
    });

    test('parse_embed_unexpected', () {
      for (final body in [
        '<html></html>',
        '<script id="__NEXT_DATA__" type="application/json">{not json</script>',
        page(trackProps(type: 'album')),
        page(trackProps(artists: const [])),
        page(trackProps(name: '')),
        page(trackProps(duration: 'long')),
      ]) {
        expect(
          () => parseSpotifyEmbed(body),
          throwsA(
            isA<SpotifyLinkException>().having(
              (e) => e.message,
              'message',
              'Unexpected answer from open.spotify.com',
            ),
          ),
          reason: body,
        );
      }
    });
  });

  group('findSpotifyTrack', () {
    late HttpServer server;
    late Uri base;
    final paths = <String>[];
    var status = 200;
    // The answer for a path; the embed page by default.
    late String Function(String path) answer;

    setUp(() async {
      paths.clear();
      status = 200;
      answer = (_) => page(trackProps());
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((req) {
        paths.add(req.uri.path);
        req.response
          ..statusCode = status
          ..headers.contentType = ContentType.html
          ..write(answer(req.uri.path))
          ..close();
      });
    });
    tearDown(() => server.close(force: true));

    test('find_track_over_local_server', () async {
      final t = await findSpotifyTrack(
        'https://open.spotify.com/track/$id',
        base: base,
      );
      expect(t.title, 'X');
      expect(paths, ['/embed/track/$id']);
    });

    test('find_track_bad_link', () async {
      await expectLater(
        findSpotifyTrack('https://open.spotify.com/album/$id', base: base),
        throwsA(
          isA<SpotifyLinkException>().having(
            (e) => e.message,
            'message',
            startsWith('Paste a Spotify song link'),
          ),
        ),
      );
      expect(paths, isEmpty);
    });

    test('find_track_http_error', () async {
      status = 500;
      await expectLater(
        findSpotifyTrack('spotify:track:$id', base: base),
        throwsA(
          isA<SpotifyLinkException>().having(
            (e) => e.message,
            'message',
            'open.spotify.com answered HTTP 500',
          ),
        ),
      );
    });

    test('find_track_from_a_short_link', () async {
      // The short link's page names the song; the same local server plays both parts.
      answer = (path) => path.startsWith('/embed/')
          ? page(trackProps())
          : '<a href="https://open.spotify.com/track/$id">song</a>';
      final t = await findSpotifyTrack(
        'https://spotify.link/AbC',
        base: base,
        shortBase: base,
      );
      expect(t.id, id);
      expect(paths, ['/AbC', '/embed/track/$id']);
    });

    test('find_track_short_link_without_a_track', () async {
      answer = (_) => '<html>nothing here</html>';
      await expectLater(
        findSpotifyTrack('https://spotify.link/AbC', base: base, shortBase: base),
        throwsA(
          isA<SpotifyLinkException>().having(
            (e) => e.message,
            'message',
            'Could not read this Spotify link',
          ),
        ),
      );
    });
  });
}
