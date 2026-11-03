// Looking up the lyrics of a song in LRCLIB (https://lrclib.net), a free community
// lyrics database. Only the plain lyrics are used. Pure Dart: no Flutter imports.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'export.dart' show oneLine;

const lyricsHost = 'lrclib.net';

class LyricsLookupException implements Exception {
  final String message;

  /// The HTTP status of the answer, when the failure was an answer of the server.
  final int? statusCode;
  const LyricsLookupException(this.message, {this.statusCode});

  /// The server had a problem (502, 503...): trying again in a moment may work.
  bool get isServerError => (statusCode ?? 0) >= 500;

  @override
  String toString() => message;
}

/// A Google search for the lyrics of [title] by [artist], for when lrclib.net does not answer.
Uri googleLyricsUri(String title, String artist) => Uri.https('www.google.com', '/search', {
      'q': [oneLine(title), oneLine(artist), 'lyrics'].where((t) => t.isNotEmpty).join(' '),
    });

class LyricsCandidate {
  final String title, artist, album, lyrics;
  final double? seconds;

  /// The lines with their times when LRCLIB has synced lyrics (see
  /// [parseSyncedLyrics]); empty otherwise.
  final List<(double, String)> synced;

  /// The service the lyrics came from.
  final String source;
  const LyricsCandidate({
    required this.title,
    required this.artist,
    required this.album,
    required this.lyrics,
    this.seconds,
    this.synced = const [],
    this.source = lyricsHost,
  });
}

/// lyrics.ovh, a free lyrics service, searched when LRCLIB finds nothing.
const lyricsOvhHost = 'api.lyrics.ovh';

/// The lyrics.ovh address for [artist] and [title]: both are path parts.
Uri lyricsOvhUri(String artist, String title, {Uri? base}) {
  final root = base ?? Uri.https(lyricsOvhHost, '/v1');
  return root.replace(
    pathSegments: [...root.pathSegments, oneLine(artist), oneLine(title)],
  );
}

/// The lyrics in a lyrics.ovh answer, or null when there are none.
String? parseLyricsOvh(String body) {
  final Object? json;
  try {
    json = jsonDecode(body);
  } on FormatException {
    return null;
  }
  final lyrics = json is Map ? json['lyrics'] : null;
  if (lyrics is! String) return null;
  final text = lyrics.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  return text.isEmpty ? null : text;
}

/// The timed lines in LRCLIB's syncedLyrics ("[mm:ss.xx]text" per line). Marks like
/// "<mm:ss.xx>" inside a line are removed; lines without a time or without text are
/// skipped. Empty when the times are not in order (the lyrics are not usable as timing).
List<(double, String)> parseSyncedLyrics(String lrc) {
  final line = RegExp(r'^\[(\d+):(\d{2})(?:[.:](\d{1,3}))?\](.*)$');
  final out = <(double, String)>[];
  for (final raw in lrc.split('\n')) {
    final m = line.firstMatch(raw.trim());
    if (m == null) continue;
    final text = m.group(4)!.replaceAll(RegExp(r'<\d+:\d{2}(?:[.:]\d{1,3})?>'), '').trim();
    if (text.isEmpty) continue;
    final fraction = m.group(3) == null ? 0.0 : double.parse('0.${m.group(3)}');
    final seconds = int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!) + fraction;
    if (out.isNotEmpty && seconds < out.last.$1) return const [];
    out.add((seconds, text));
  }
  return out;
}

/// The LRCLIB search address for [title] and [artist]. Spaces are written as %20 and
/// the artist is left out when it is blank.
Uri lyricsSearchUri(String title, String artist, {Uri? base}) {
  final query = [
    'track_name=${_enc(title)}',
    if (oneLine(artist).isNotEmpty) 'artist_name=${_enc(artist)}',
  ].join('&');
  return (base ?? Uri.https(lyricsHost, '/api/search')).replace(query: query);
}

String _enc(String v) =>
    Uri.encodeQueryComponent(oneLine(v)).replaceAll('+', '%20');

/// The LRCLIB address that finds the one entry of [title] by [artist] that is [seconds]
/// long (LRCLIB allows a couple of seconds either way).
Uri lyricsGetUri(String title, String artist, int seconds, {Uri? base}) =>
    (base ?? Uri.https(lyricsHost, '/api/get')).replace(
      query:
          'track_name=${_enc(title)}&artist_name=${_enc(artist)}&duration=$seconds',
    );

const _unexpected = LyricsLookupException(
  'Unexpected answer from the lyrics server',
);

/// The usable matches in an LRCLIB search answer (a JSON array). Instrumentals and
/// entries without plain lyrics are left out. Throws [LyricsLookupException] for an
/// error answer (a JSON object with a "message") or anything else unexpected.
List<LyricsCandidate> parseLyricsSearch(String body) {
  final Object? json;
  try {
    json = jsonDecode(body);
  } on FormatException {
    throw _unexpected;
  }
  if (json is Map) {
    final message = json['message'];
    // LRCLIB repeats the status in the body ("statusCode": 503), which is all there is to go
    // by when the answer does not carry it in the HTTP line.
    final code = json['statusCode'];
    throw message is String && message.isNotEmpty
        ? LyricsLookupException(message, statusCode: code is int ? code : null)
        : _unexpected;
  }
  if (json is! List) throw _unexpected;
  final out = <LyricsCandidate>[];
  for (final e in json) {
    final c = e is Map ? _candidate(e) : null;
    if (c != null) out.add(c);
  }
  return out;
}

/// One LRCLIB entry as a candidate, or null for an instrumental or an entry without plain
/// lyrics.
LyricsCandidate? _candidate(Map e) {
  String str(Object? v) => v is String ? v : '';
  if (e['instrumental'] == true) return null;
  final plain = e['plainLyrics'];
  if (plain is! String) return null;
  final lyrics = plain.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (lyrics.isEmpty) return null;
  final duration = e['duration'];
  final synced = e['syncedLyrics'];
  return LyricsCandidate(
    title: str(e['trackName']).isNotEmpty ? str(e['trackName']) : str(e['name']),
    artist: str(e['artistName']),
    album: str(e['albumName']),
    lyrics: lyrics,
    seconds: duration is num ? duration.toDouble() : null,
    synced: synced is String ? parseSyncedLyrics(synced) : const [],
  );
}

/// [candidates] with the exact matches first: title and artist, then title only, then the
/// rest; each group keeps its order. Case and spacing do not matter. With [seconds] (the
/// length of the user's audio), inside each group the entries of about that length come
/// first, the closest first, and entries without a length come last: timed lyrics only
/// line up with a version of the same length.
List<LyricsCandidate> rankLyrics(
  List<LyricsCandidate> candidates,
  String title,
  String artist, {
  double? seconds,
}) {
  String norm(String v) => oneLine(v).toLowerCase();
  final wantTitle = norm(title), wantArtist = norm(artist);
  int group(LyricsCandidate c) {
    if (norm(c.title) != wantTitle) return 2;
    return norm(c.artist) == wantArtist ? 0 : 1;
  }

  List<LyricsCandidate> byLength(List<LyricsCandidate> members) {
    if (seconds == null) return members;
    // List.sort is not stable, so the original place breaks a tie.
    double away(int i) => members[i].seconds == null
        ? double.infinity
        : (members[i].seconds! - seconds).abs();
    final order = List.generate(members.length, (i) => i)
      ..sort((a, b) {
        final byAway = away(a).compareTo(away(b));
        return byAway != 0 ? byAway : a.compareTo(b);
      });
    return [for (final i in order) members[i]];
  }

  return [
    for (final g in [0, 1, 2])
      ...byLength([
        for (final c in candidates)
          if (group(c) == g) c,
      ]),
  ];
}

/// Searches LRCLIB for [title] and [artist]: up to ten matches, best first (then lyrics.ovh
/// when LRCLIB has none). When both found nothing and title and artist are both filled in,
/// the same is tried with the two swapped: the file name may be "Artist - Title" rather than
/// "Title - Artist". Throws [LyricsLookupException] with a message fit to show the user.
Future<List<LyricsCandidate>> findLyrics(
  String title,
  String artist, {
  Uri? base,
  Uri? ovhBase,
  Duration timeout = const Duration(seconds: 15),
  int maxBytes = 8 * 1024 * 1024,
}) async {
  return _withClient(timeout, (client) async {
    Future<List<LyricsCandidate>> lookUp(String t, String a) async {
      final found = await _search(client, t, a, base, maxBytes).timeout(timeout);
      if (found.isNotEmpty || oneLine(a).isEmpty) return found;
      return _ovh(client, t, a, ovhBase, maxBytes, timeout);
    }

    final found = await lookUp(title, artist);
    return found.isNotEmpty || !_canSwap(title, artist) ? found : await lookUp(artist, title);
  });
}

/// Runs [body] with an HTTP client that is closed afterwards, turning a timeout or a
/// network error into a [LyricsLookupException] with a message fit to show the user.
Future<T> _withClient<T>(
  Duration timeout,
  Future<T> Function(HttpClient client) body,
) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    return await body(client);
  } on TimeoutException {
    throw const LyricsLookupException(
      'The lyrics server did not answer in time',
    );
  } on IOException catch (e) {
    throw LyricsLookupException(
      'Could not reach $lyricsHost: ${e is SocketException ? e.message : e}',
    );
  } finally {
    client.close(force: true);
  }
}

/// The one LRCLIB entry of [title] by [artist] that is [seconds] long (a couple of seconds
/// either way), or null when there is none (or no title or artist to ask for). Use it when
/// the names are exact, as from a Spotify link; [findLyrics] is the search for the rest.
/// Throws [LyricsLookupException] with a message fit to show the user.
Future<LyricsCandidate?> findLyricsExact(
  String title,
  String artist,
  double seconds, {
  Uri? base,
  Duration timeout = const Duration(seconds: 15),
  int maxBytes = 8 * 1024 * 1024,
}) async {
  if (oneLine(title).isEmpty || oneLine(artist).isEmpty) return null;
  return _withClient(timeout, (client) async {
    final request = await client.getUrl(
      lyricsGetUri(title, artist, seconds.round(), base: base),
    );
    request.headers
      ..set(HttpHeaders.userAgentHeader, 'KantaheMaker/1.0')
      ..set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(timeout);
    final body = await _readBody(response, maxBytes).timeout(timeout);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) throw _failure(response.statusCode, body);
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw _unexpected;
    }
    if (json is! Map) throw _unexpected;
    return _candidate(json);
  });
}

/// Whether swapping title and artist gives another search: both are filled in and differ.
bool _canSwap(String title, String artist) {
  final t = oneLine(title).toLowerCase(), a = oneLine(artist).toLowerCase();
  return t.isNotEmpty && a.isNotEmpty && t != a;
}

/// The second source, asked when LRCLIB found nothing. Whatever goes wrong here counts as
/// "nothing found": lyrics.ovh is a bonus, not a reason to show an error.
Future<List<LyricsCandidate>> _ovh(
  HttpClient client,
  String title,
  String artist,
  Uri? base,
  int maxBytes,
  Duration timeout,
) async {
  try {
    return await () async {
      final request = await client.getUrl(lyricsOvhUri(artist, title, base: base));
      request.headers
        ..set(HttpHeaders.userAgentHeader, 'KantaheMaker/1.0')
        ..set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      final body = await _readBody(response, maxBytes);
      if (response.statusCode != 200) return const <LyricsCandidate>[];
      final lyrics = parseLyricsOvh(body);
      if (lyrics == null) return const <LyricsCandidate>[];
      return [
        LyricsCandidate(
          title: oneLine(title),
          artist: oneLine(artist),
          album: '',
          lyrics: lyrics,
          source: 'lyrics.ovh',
        ),
      ];
    }().timeout(timeout);
  } catch (_) {
    return const [];
  }
}

Future<String> _readBody(HttpClientResponse response, int maxBytes) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in response) {
    bytes.add(chunk);
    if (bytes.length > maxBytes) {
      throw const LyricsLookupException('The lyrics server sent too much data');
    }
  }
  return utf8.decode(bytes.takeBytes(), allowMalformed: true);
}

Future<List<LyricsCandidate>> _search(
  HttpClient client,
  String title,
  String artist,
  Uri? base,
  int maxBytes,
) async {
  final request = await client.getUrl(
    lyricsSearchUri(title, artist, base: base),
  );
  request.headers
    ..set(HttpHeaders.userAgentHeader, 'KantaheMaker/1.0')
    ..set(HttpHeaders.acceptHeader, 'application/json');
  final response = await request.close();
  final body = await _readBody(response, maxBytes);
  if (response.statusCode == 200) {
    return rankLyrics(parseLyricsSearch(body), title, artist).take(10).toList();
  }
  throw _failure(response.statusCode, body);
}

/// The error for a non-success answer: the server's own message when it sent one, else the
/// HTTP status.
LyricsLookupException _failure(int status, String body) {
  try {
    parseLyricsSearch(body); // an error object throws its message
  } on LyricsLookupException catch (e) {
    if (e.message != _unexpected.message) {
      // The server's own number wins when the HTTP line says nothing is wrong.
      return LyricsLookupException(e.message, statusCode: status >= 500 ? status : e.statusCode ?? status);
    }
  }
  return LyricsLookupException('The lyrics server answered HTTP $status', statusCode: status);
}
