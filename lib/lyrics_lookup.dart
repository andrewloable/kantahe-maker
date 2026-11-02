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
    final synced = e['syncedLyrics'];
    out.add(
      LyricsCandidate(
        title: str(e['trackName']).isNotEmpty
            ? str(e['trackName'])
            : str(e['name']),
        artist: str(e['artistName']),
        album: str(e['albumName']),
        lyrics: lyrics,
        seconds: duration is num ? duration.toDouble() : null,
        synced: synced is String ? parseSyncedLyrics(synced) : const [],
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
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    Future<List<LyricsCandidate>> lookUp(String t, String a) async {
      final found = await _search(client, t, a, base, maxBytes).timeout(timeout);
      if (found.isNotEmpty || oneLine(a).isEmpty) return found;
      return _ovh(client, t, a, ovhBase, maxBytes, timeout);
    }

    final found = await lookUp(title, artist);
    return found.isNotEmpty || !_canSwap(title, artist) ? found : await lookUp(artist, title);
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
  try {
    parseLyricsSearch(body); // an error object throws its message
  } on LyricsLookupException catch (e) {
    if (e.message != _unexpected.message) rethrow;
  }
  throw LyricsLookupException(
    'The lyrics server answered HTTP ${response.statusCode}',
  );
}
