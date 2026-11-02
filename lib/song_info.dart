// Looking up a song in MusicBrainz (https://musicbrainz.org), a free music database:
// title, artist, album, year, composer and lyricist. Pure Dart: no Flutter imports.

import 'dart:convert';

import 'package:path/path.dart' as p;

import 'export.dart' show oneLine;
import 'web_get.dart';

const songInfoHost = 'musicbrainz.org';

class SongInfoException implements Exception {
  final String message;
  const SongInfoException(this.message);
  @override
  String toString() => message;
}

class SongInfoCandidate {
  final String title, artist, album, year, recordingId;
  final double? seconds;
  const SongInfoCandidate({
    required this.title,
    required this.artist,
    required this.album,
    required this.year,
    required this.recordingId,
    this.seconds,
  });
}

final _bracketed = RegExp(r'\([^)]*\)|\[[^\]]*\]|\{[^}]*\}');

/// The title and artist a file name suggests: "Artist - Title (Official Video).mp4".
/// Parts in (), [] or {} are dropped; the text before the first " - " is the artist.
({String title, String artist}) queryFromFileName(String path) {
  final name = oneLine(
    p.basenameWithoutExtension(path).replaceAll(_bracketed, ' '),
  );
  final dash = name.indexOf(' - ');
  if (dash < 0) return (title: name, artist: '');
  return (
    title: oneLine(name.substring(dash + 3)),
    artist: oneLine(name.substring(0, dash)),
  );
}

Uri _recordingBase(Uri? base) =>
    base ?? Uri.https(songInfoHost, '/ws/2/recording');

String _enc(String v) =>
    Uri.encodeQueryComponent(v).replaceAll('+', '%20');

String _quoted(String v) =>
    '"${oneLine(v).replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

/// The search for recordings called [title] (by [artist], when it is not blank).
Uri songInfoSearchUri(String title, String artist, {Uri? base}) {
  final query = [
    'recording:${_quoted(title)}',
    if (oneLine(artist).isNotEmpty) 'artist:${_quoted(artist)}',
  ].join(' AND ');
  return _recordingBase(base).replace(query: 'query=${_enc(query)}&fmt=json&limit=10');
}

const _unexpected = SongInfoException('Unexpected answer from $songInfoHost');

/// Decodes a MusicBrainz answer: a JSON object. An object with "error" throws its text.
Map<String, Object?> _object(String body) {
  final Object? json;
  try {
    json = jsonDecode(body);
  } on FormatException {
    throw _unexpected;
  }
  if (json is! Map) throw _unexpected;
  final error = json['error'];
  if (error is String && error.isNotEmpty) throw SongInfoException(error);
  return json.cast<String, Object?>();
}

/// The recordings in a search answer, in MusicBrainz's order. Throws
/// [SongInfoException] for an error answer or anything unexpected.
List<SongInfoCandidate> parseSongInfoSearch(String body) {
  final recordings = _object(body)['recordings'];
  if (recordings is! List) throw _unexpected;
  String str(Object? v) => v is String ? v : '';
  final out = <SongInfoCandidate>[];
  for (final e in recordings) {
    if (e is! Map) continue;
    final title = str(e['title']);
    if (title.isEmpty) continue;
    final credits = e['artist-credit'];
    final artist = StringBuffer();
    if (credits is List) {
      for (final c in credits) {
        if (c is Map) artist.write('${str(c['name'])}${str(c['joinphrase'])}');
      }
    }
    final releases = e['releases'];
    final album = releases is List && releases.isNotEmpty && releases.first is Map
        ? str((releases.first as Map)['title'])
        : '';
    final date = str(e['first-release-date']);
    final length = e['length'];
    out.add(
      SongInfoCandidate(
        title: title,
        artist: artist.toString(),
        album: album,
        year: date.length > 4 ? date.substring(0, 4) : date,
        recordingId: str(e['id']),
        seconds: length is num ? length / 1000 : null,
      ),
    );
  }
  return out;
}

/// The lookup of one recording with the works it performs and their writers.
Uri songInfoDetailsUri(String recordingId, {Uri? base}) {
  final recording = _recordingBase(base);
  return recording.replace(
    path: '${recording.path}/${Uri.encodeComponent(recordingId)}',
    // The + signs are MusicBrainz's separators, so they stay as they are.
    query: 'inc=work-rels+work-level-rels+artist-rels&fmt=json',
  );
}

/// The composer and lyricist of the works a recording performs. A "writer" counts as
/// both. Names are in the order MusicBrainz gives them, without repeats.
({String composer, String lyricist}) parseSongInfoDetails(String body) {
  final relations = _object(body)['relations'];
  final composer = <String>[], lyricist = <String>[];
  void add(List<String> list, String name) {
    if (!list.contains(name)) list.add(name);
  }

  if (relations is List) {
    for (final rel in relations) {
      if (rel is! Map || rel['type'] != 'performance') continue;
      final work = rel['work'];
      final workRelations = work is Map ? work['relations'] : null;
      if (workRelations is! List) continue;
      for (final r in workRelations) {
        if (r is! Map) continue;
        final artist = r['artist'];
        final name = artist is Map ? artist['name'] : null;
        if (name is! String || name.isEmpty) continue;
        final type = r['type'];
        if (type == 'composer' || type == 'writer') add(composer, name);
        if (type == 'lyricist' || type == 'writer') add(lyricist, name);
      }
    }
  }
  return (composer: composer.join(', '), lyricist: lyricist.join(', '));
}

/// MusicBrainz allows one request per second; this leaves a little more.
const _minGap = Duration(milliseconds: 1100);

/// How long to wait before a request, given when the previous one was made.
Duration waitBeforeNextRequest(DateTime? last, DateTime now) {
  if (last == null) return Duration.zero;
  final rest = _minGap - now.difference(last);
  return rest > Duration.zero ? rest : Duration.zero;
}

/// When the last request to musicbrainz.org was (or will be) made.
DateTime? _lastRequest;

Future<String> _fetch(Uri uri, Duration timeout) async {
  // Only the real server needs the pause (and tests with a local server do not wait).
  if (uri.host == songInfoHost) {
    final now = DateTime.now();
    final wait = waitBeforeNextRequest(_lastRequest, now);
    // Booked before waiting, so a second call that comes meanwhile queues behind this one.
    _lastRequest = now.add(wait);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }
  final int status;
  final String body;
  try {
    (status, body) = await getText(uri, timeout: timeout);
  } on WebGetException catch (e) {
    throw SongInfoException(e.message);
  }
  if (status == 200) return body;
  if (status == 503) {
    throw const SongInfoException('$songInfoHost is busy; try again in a moment');
  }
  throw SongInfoException('$songInfoHost answered HTTP $status');
}

/// Searches MusicBrainz for [title] by [artist]; at most 10 matches.
Future<List<SongInfoCandidate>> findSongInfo(
  String title,
  String artist, {
  Uri? base,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final body = await _fetch(songInfoSearchUri(title, artist, base: base), timeout);
  return parseSongInfoSearch(body).take(10).toList();
}

/// The composer and lyricist of one recording found by [findSongInfo].
Future<({String composer, String lyricist})> songInfoDetails(
  String recordingId, {
  Uri? base,
  Duration timeout = const Duration(seconds: 15),
}) async => parseSongInfoDetails(
  await _fetch(songInfoDetailsUri(recordingId, base: base), timeout),
);
