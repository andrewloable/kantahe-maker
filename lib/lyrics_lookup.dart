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
  const LyricsLookupException(this.message);
  @override
  String toString() => message;
}

class LyricsCandidate {
  final String title, artist, album, lyrics;
  final double? seconds;
  const LyricsCandidate({
    required this.title,
    required this.artist,
    required this.album,
    required this.lyrics,
    this.seconds,
  });
}

/// The LRCLIB search address for [title] and [artist]. Spaces are written as %20 and
/// the artist is left out when it is blank.
Uri lyricsSearchUri(String title, String artist, {Uri? base}) {
  String enc(String v) =>
      Uri.encodeQueryComponent(oneLine(v)).replaceAll('+', '%20');
  final query = [
    'track_name=${enc(title)}',
    if (oneLine(artist).isNotEmpty) 'artist_name=${enc(artist)}',
  ].join('&');
  return (base ?? Uri.https(lyricsHost, '/api/search')).replace(query: query);
}

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
    throw message is String && message.isNotEmpty
        ? LyricsLookupException(message)
        : _unexpected;
  }
  if (json is! List) throw _unexpected;
  String str(Object? v) => v is String ? v : '';
  final out = <LyricsCandidate>[];
  for (final e in json) {
    if (e is! Map || e['instrumental'] == true) continue;
    final plain = e['plainLyrics'];
    if (plain is! String) continue;
    final lyrics = plain.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
    if (lyrics.isEmpty) continue;
    final duration = e['duration'];
    out.add(
      LyricsCandidate(
        title: str(e['trackName']).isNotEmpty
            ? str(e['trackName'])
            : str(e['name']),
        artist: str(e['artistName']),
        album: str(e['albumName']),
        lyrics: lyrics,
        seconds: duration is num ? duration.toDouble() : null,
      ),
    );
  }
  return out;
}

/// [candidates] with the exact matches first: title and artist, then title only, then the
/// rest; each group keeps its order. Case and spacing do not matter.
List<LyricsCandidate> rankLyrics(
  List<LyricsCandidate> candidates,
  String title,
  String artist,
) {
  String norm(String v) => oneLine(v).toLowerCase();
  final wantTitle = norm(title), wantArtist = norm(artist);
  int group(LyricsCandidate c) {
    if (norm(c.title) != wantTitle) return 2;
    return norm(c.artist) == wantArtist ? 0 : 1;
  }

  return [
    for (final g in [0, 1, 2])
      for (final c in candidates)
        if (group(c) == g) c,
  ];
}

/// Searches LRCLIB for [title] and [artist]: up to ten matches, best first. Throws
/// [LyricsLookupException] with a message fit to show the user.
Future<List<LyricsCandidate>> findLyrics(
  String title,
  String artist, {
  Uri? base,
  Duration timeout = const Duration(seconds: 15),
  int maxBytes = 8 * 1024 * 1024,
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    return await _search(
      client,
      title,
      artist,
      base,
      maxBytes,
    ).timeout(timeout);
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
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in response) {
    bytes.add(chunk);
    if (bytes.length > maxBytes) {
      throw const LyricsLookupException('The lyrics server sent too much data');
    }
  }
  final body = utf8.decode(bytes.takeBytes(), allowMalformed: true);
  if (response.statusCode == 200) {
    return rankLyrics(parseLyricsSearch(body), title, artist).take(10).toList();
  }
  try {
    parseLyricsSearch(body); // an error object throws its message
  } on LyricsLookupException catch (e) {
    if (e.message != _unexpected.message) rethrow;
  }
  throw LyricsLookupException(
    'The lyrics server answered HTTP ${response.statusCode}',
  );
}
