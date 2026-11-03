// Reading a song's title, artist and length from a Spotify link: the link's track ID is
// looked up on Spotify's public embed page (open.spotify.com/embed/track/ID), which needs no
// account. That page is not a documented interface, so a change on Spotify's side shows as
// an error message, never as wrong data. Pure Dart: no Flutter imports.

import 'dart:convert';

import 'export.dart' show oneLine;
import 'web_get.dart';

const spotifyHost = 'open.spotify.com';

class SpotifyLinkException implements Exception {
  final String message;
  const SpotifyLinkException(this.message);
  @override
  String toString() => message;
}

class SpotifyTrack {
  final String id, title, artist;

  /// The length of Spotify's version of the song.
  final double seconds;
  const SpotifyTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.seconds,
  });
}

const _id = r'([A-Za-z0-9]{22})(?![A-Za-z0-9])';
final _trackLink = RegExp(
  'spotify:track:$_id|open\\.spotify\\.com/(?:intl-[A-Za-z]+/)?(?:embed/)?track/$_id',
);

/// The ID of the first Spotify track link (or spotify:track: URI) found anywhere in [text],
/// since a pasted share text can have words around the link. Albums, playlists, artists,
/// other sites and IDs of the wrong length give null.
String? spotifyTrackId(String text) {
  final m = _trackLink.firstMatch(text);
  return m == null ? null : (m.group(1) ?? m.group(2));
}

final _shortLink = RegExp(
  r'(?:https?://)?(spotify\.(?:app\.)?link/[^\s"<>]+)',
  caseSensitive: false,
);

/// The first spotify.link or spotify.app.link address in [text], with https, or null. The
/// phone app's Share button gives these.
String? spotifyShortLink(String text) {
  final m = _shortLink.firstMatch(text);
  if (m == null) return null;
  return 'https://${m.group(1)!.replaceAll(RegExp(r'''[.,;:!?)'"]+$'''), '')}';
}

final _remasterGroup = RegExp(
  r'\s*[(\[][^)\]]*remaster[^)\]]*[)\]]',
  caseSensitive: false,
);

/// Spotify's name of a song without a "Remastered" part: "Song - Remastered 2011" and
/// "Song (2015 Remaster)" become "Song". Other parts stay ("Song - Live" is another
/// recording).
// ponytail: only "remaster" suffixes; add more (Radio Edit, Mono) when real links need it.
String cleanSpotifyTitle(String name) {
  var t = name.replaceAll(_remasterGroup, '');
  final dash = t.lastIndexOf(' - ');
  if (dash >= 0 && t.substring(dash + 3).toLowerCase().contains('remaster')) {
    t = t.substring(0, dash);
  }
  final clean = oneLine(t);
  return clean.isEmpty ? oneLine(name) : clean;
}

const _unexpected = SpotifyLinkException(
  'Unexpected answer from $spotifyHost',
);

final _nextData = RegExp(
  r'<script id="__NEXT_DATA__"[^>]*>(.*?)</script>',
  dotAll: true,
);

/// The song in an embed page. Throws [SpotifyLinkException] when Spotify has no such song
/// or the page is not what it was when this was written.
SpotifyTrack parseSpotifyEmbed(String html) {
  final script = _nextData.firstMatch(html)?.group(1);
  if (script == null) throw _unexpected;
  final Object? json;
  try {
    json = jsonDecode(script);
  } on FormatException {
    throw _unexpected;
  }
  final props = json is Map ? json['props'] : null;
  final pageProps = props is Map ? props['pageProps'] : null;
  if (pageProps is! Map) throw _unexpected;
  final state = pageProps['state'];
  if (pageProps['status'] == 404 || state == null) {
    throw const SpotifyLinkException('Spotify has no song with this link');
  }
  final data = state is Map ? state['data'] : null;
  final entity = data is Map ? data['entity'] : null;
  if (entity is! Map || entity['type'] != 'track') throw _unexpected;
  final name = entity['name'], id = entity['id'], duration = entity['duration'];
  final artists = entity['artists'];
  if (name is! String || oneLine(name).isEmpty) throw _unexpected;
  if (id is! String || duration is! num || artists is! List) throw _unexpected;
  final names = [
    for (final a in artists)
      if (a is Map && a['name'] is String && oneLine(a['name'] as String).isNotEmpty)
        oneLine(a['name'] as String),
  ];
  if (names.isEmpty) throw _unexpected;
  return SpotifyTrack(
    id: id,
    title: cleanSpotifyTitle(name),
    artist: names.join(', '),
    seconds: duration / 1000,
  );
}

/// Reads the title, artist and length of the song a Spotify link (or pasted share text with
/// one in it) points to. Only the track ID goes to open.spotify.com; a short link
/// (spotify.link) is opened once to learn the track ID. [base] and [shortBase] are for tests.
Future<SpotifyTrack> findSpotifyTrack(
  String link, {
  Uri? base,
  Uri? shortBase,
  Duration timeout = const Duration(seconds: 15),
}) async {
  Future<(int, String)> get(Uri uri) async {
    try {
      return await getText(uri, timeout: timeout);
    } on WebGetException catch (e) {
      throw SpotifyLinkException(e.message);
    }
  }

  var id = spotifyTrackId(link);
  if (id == null) {
    final short = spotifyShortLink(link);
    if (short != null) {
      final uri = Uri.parse(short);
      final (_, body) = await get(
        shortBase == null
            ? uri
            : shortBase.replace(path: uri.path, query: uri.hasQuery ? uri.query : null),
      );
      id = spotifyTrackId(body);
      if (id == null) {
        throw const SpotifyLinkException('Could not read this Spotify link');
      }
    }
  }
  if (id == null) {
    throw const SpotifyLinkException(
      'Paste a Spotify song link (open.spotify.com/track/...)',
    );
  }
  final root = base ?? Uri.https(spotifyHost, '/');
  final (status, body) = await get(root.replace(path: '/embed/track/$id'));
  if (status != 200) {
    throw SpotifyLinkException('$spotifyHost answered HTTP $status');
  }
  return parseSpotifyEmbed(body);
}
