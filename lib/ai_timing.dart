// Automatic word timing of the lyrics: the vocals are sent to Cloudflare Workers AI
// (Deepgram Nova-3), which says when each word starts; the heard words are then lined up with
// the lyric lines. Pure Dart: no Flutter imports.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'tap_session.dart' show splitWords;

/// How much earlier than heard every AI time is put, so a singer reading the lyrics has time
/// to react to the next word.
const aiLeadSeconds = 0.2;

/// Why the automatic timing failed. The message is safe to show: it never holds the token.
class AiTimingException implements Exception {
  final String message;
  const AiTimingException(this.message);
  @override
  String toString() => message;
}

class HeardWord {
  final String word;
  final double start, end, confidence;
  const HeardWord({
    required this.word,
    required this.start,
    required this.end,
    this.confidence = 1,
  });
}

/// Sends [mp3] to Nova-3 and returns the words it heard, with their times. [baseUri] is the
/// Cloudflare API address (tests point it at a local server).
Future<List<HeardWord>> transcribeWords(
  Uint8List mp3, {
  required String accountId,
  required String token,
  Uri? baseUri,
  Duration timeout = const Duration(minutes: 3),
  String? language,
}) async {
  final base = (baseUri ?? Uri.parse('https://api.cloudflare.com/client/v4')).toString();
  // No "detect_language": with it Nova-3 left out the first lines of a real song and returned
  // the other words about 0.8 s late. Without a language it listens in English.
  final query = language == null ? '' : '?language=${Uri.encodeQueryComponent(language)}';
  final uri = Uri.parse(
    '$base/accounts/${Uri.encodeComponent(accountId.trim())}/ai/run/@cf/deepgram/nova-3$query',
  );
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await client.postUrl(uri).timeout(timeout);
    request.headers.set('Authorization', 'Bearer ${token.trim()}');
    request.headers.contentType = ContentType('audio', 'mpeg');
    request.contentLength = mp3.length;
    request.add(mp3);
    final response = await request.close().timeout(timeout);
    final text = await response.transform(utf8.decoder).join().timeout(timeout);
    Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      json = null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300 || _failed(json)) {
      throw AiTimingException(_errorText(response.statusCode, json));
    }
    final words = _words(json);
    if (words.isEmpty) {
      throw const AiTimingException('The AI heard no words in the vocals.');
    }
    return words;
  } on AiTimingException {
    rethrow;
  } on SocketException catch (e) {
    throw AiTimingException('Could not reach Cloudflare: ${e.message}');
  } on HttpException catch (e) {
    throw AiTimingException('Could not talk to Cloudflare: ${e.message}');
  } on TimeoutException {
    throw const AiTimingException('Cloudflare took too long to answer.');
  } finally {
    client.close(force: true);
  }
}

/// Checks that the account ID and token work for Workers AI, without using the AI: it only
/// asks Cloudflare for the first model of the catalog. Throws [AiTimingException] saying
/// why not.
Future<void> verifyCloudflare({
  required String accountId,
  required String token,
  Uri? baseUri,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final base = (baseUri ?? Uri.parse('https://api.cloudflare.com/client/v4')).toString();
  final uri = Uri.parse(
    '$base/accounts/${Uri.encodeComponent(accountId.trim())}/ai/models/search?per_page=1',
  );
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await client.getUrl(uri).timeout(timeout);
    request.headers.set('Authorization', 'Bearer ${token.trim()}');
    final response = await request.close().timeout(timeout);
    final text = await response.transform(utf8.decoder).join().timeout(timeout);
    Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      json = null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300 || _failed(json)) {
      throw AiTimingException(_errorText(response.statusCode, json));
    }
  } on AiTimingException {
    rethrow;
  } on SocketException catch (e) {
    throw AiTimingException('Could not reach Cloudflare: ${e.message}');
  } on HttpException catch (e) {
    throw AiTimingException('Could not talk to Cloudflare: ${e.message}');
  } on TimeoutException {
    throw const AiTimingException('Cloudflare took too long to answer.');
  } finally {
    client.close(force: true);
  }
}

bool _failed(Object? json) => json is Map && json['success'] == false;

String _errorText(int status, Object? json) {
  final errors = json is Map && json['errors'] is List ? json['errors'] as List : const [];
  final first = errors.isNotEmpty && errors.first is Map ? (errors.first as Map)['message'] : null;
  final detail = first is String && first.isNotEmpty ? ' ($first)' : '';
  if (status == 401 || status == 403) {
    return 'Cloudflare refused the request$detail. Check the account ID and that the API '
        'token has the Workers AI permission (Settings).';
  }
  return 'Cloudflare answered with an error, status $status$detail.';
}

List<HeardWord> _words(Object? json) {
  var data = json;
  if (data is Map && data['result'] is Map) data = data['result'];
  try {
    final channels = ((data as Map)['results'] as Map)['channels'] as List;
    final alternatives = (channels.first as Map)['alternatives'] as List;
    final words = (alternatives.first as Map)['words'] as List;
    return [
      for (final w in words)
        if (w is Map && w['word'] is String && w['start'] is num)
          HeardWord(
            word: w['word'] as String,
            start: (w['start'] as num).toDouble(),
            end: w['end'] is num ? (w['end'] as num).toDouble() : (w['start'] as num).toDouble(),
            confidence: w['confidence'] is num ? (w['confidence'] as num).toDouble() : 1,
          ),
    ];
  } on TypeError {
    throw const AiTimingException('Cloudflare sent an answer this app does not understand.');
  } on StateError {
    throw const AiTimingException('Cloudflare sent an answer this app does not understand.');
  }
}

/// A word with only letters, digits and apostrophes, lower case; empty if there are none.
String _norm(String w) =>
    w.toLowerCase().replaceAll('’', "'").replaceAll(RegExp(r"[^\p{L}\p{N}']", unicode: true), '');

/// The lyric lines with their timing.
class AiTiming {
  final List<String> lines;
  final List<double?> times;
  final List<List<double?>?> wordTimes;

  /// How many lyric words were heard, out of [total].
  final int matched, total;

  /// The (0-based) lines of which no word was heard: their times are only guesses.
  final List<int> unheardLines;
  const AiTiming({
    required this.lines,
    required this.times,
    required this.wordTimes,
    required this.matched,
    required this.total,
    this.unheardLines = const [],
  });
}

/// The pairs (lyric word index, heard word index) of the longest common subsequence of the
/// two lists; words that normalise to nothing never match.
List<(int, int)> _lcs(List<String> a, List<String> b) {
  final n = a.length, m = b.length;
  final t = List.generate(n + 1, (_) => List.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      t[i][j] = a[i].isNotEmpty && a[i] == b[j]
          ? t[i + 1][j + 1] + 1
          : (t[i + 1][j] >= t[i][j + 1] ? t[i + 1][j] : t[i][j + 1]);
    }
  }
  final pairs = <(int, int)>[];
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i].isNotEmpty && a[i] == b[j]) {
      pairs.add((i, j));
      i++;
      j++;
    } else if (t[i + 1][j] >= t[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return pairs;
}

({List<String> lyric, List<String> heard, List<int> lineOf, List<int> firstOf}) _flatten(
  List<String> lines,
  List<HeardWord> heard,
) {
  final lyric = <String>[], lineOf = <int>[], firstOf = <int>[];
  for (var l = 0; l < lines.length; l++) {
    firstOf.add(lyric.length);
    for (final w in splitWords(lines[l])) {
      lyric.add(_norm(w));
      lineOf.add(l);
    }
  }
  return (
    lyric: lyric,
    heard: [for (final w in heard) _norm(w.word)],
    lineOf: lineOf,
    firstOf: firstOf,
  );
}

/// Gives every word of [lines] a time from the [heard] words, each [aiLeadSeconds] earlier.
/// Throws [AiTimingException] when none of the lyric words was heard.
AiTiming alignLyrics(List<String> lines, List<HeardWord> heard) {
  final f = _flatten(lines, heard);
  final pairs = _lcs(f.lyric, f.heard);
  if (pairs.isEmpty) {
    throw const AiTimingException('None of the lyric words were heard in the vocals.');
  }
  final n = f.lyric.length;
  final known = <int, double>{for (final (i, j) in pairs) i: heard[j].start};
  final keys = known.keys.toList();
  final flat = List<double>.filled(n, 0);
  var next = 0; // index into keys of the first known word at or after k
  for (var k = 0; k < n; k++) {
    while (next < keys.length && keys[next] < k) {
      next++;
    }
    if (known.containsKey(k)) {
      flat[k] = known[k]!;
    } else if (next == 0) {
      flat[k] = known[keys.first]! - 0.3 * (keys.first - k);
    } else if (next >= keys.length) {
      flat[k] = known[keys.last]! + 0.3 * (k - keys.last);
    } else {
      final lo = keys[next - 1], hi = keys[next];
      flat[k] = known[lo]! + (known[hi]! - known[lo]!) * (k - lo) / (hi - lo);
    }
  }
  var previous = 0.0;
  for (var k = 0; k < n; k++) {
    var t = flat[k] - aiLeadSeconds;
    if (t < previous) t = previous;
    flat[k] = t;
    previous = t;
  }
  final wordTimes = <List<double?>?>[];
  final times = <double?>[];
  for (var l = 0; l < lines.length; l++) {
    final count = splitWords(lines[l]).length;
    final words = <double?>[for (var w = 0; w < count; w++) flat[f.firstOf[l] + w]];
    wordTimes.add(words);
    times.add(words.isEmpty ? null : words.first);
  }
  final heardWords = {for (final (i, _) in pairs) i};
  final unheard = <int>[
    for (var l = 0; l < lines.length; l++)
      if (!List.generate(splitWords(lines[l]).length, (w) => f.firstOf[l] + w).any(heardWords.contains)) l,
  ];
  return AiTiming(
    lines: List.of(lines),
    times: times,
    wordTimes: wordTimes,
    matched: pairs.length,
    total: n,
    unheardLines: unheard,
  );
}

/// A run of heard words that the lyrics do not have, and where it goes: before word
/// [wordIndex] of line [line] (a new line when [wordIndex] is 0, and [line] may be the
/// number of lines, for the end).
class MissingWords {
  final int line, wordIndex;
  final String text;
  final double start;
  const MissingWords({
    required this.line,
    required this.wordIndex,
    required this.text,
    required this.start,
  });
}

const _minRun = 3;
const _minConfidence = 0.6;

/// The runs of at least three confidently heard words that sit between two lyric words that
/// were found next to each other, so they are really missing from the lyrics. A word heard
/// differently ("owe" for "own") is not a missing word and is left alone.
List<MissingWords> findMissingWords(List<String> lines, List<HeardWord> heard) {
  final f = _flatten(lines, heard);
  final pairs = _lcs(f.lyric, f.heard);
  final n = f.lyric.length;
  final bounds = [(-1, -1), ...pairs, (n, heard.length)];
  final found = <MissingWords>[];
  for (var p = 0; p + 1 < bounds.length; p++) {
    final (i1, j1) = bounds[p];
    final (i2, j2) = bounds[p + 1];
    if (i2 != i1 + 1 || j2 - j1 - 1 < _minRun) continue;
    final run = heard.sublist(j1 + 1, j2);
    if (run.any((w) => w.confidence < _minConfidence || _norm(w.word).isEmpty)) continue;
    final line = i2 >= n ? lines.length : f.lineOf[i2];
    final wordIndex = i2 >= n ? 0 : i2 - f.firstOf[line];
    found.add(MissingWords(
      line: line,
      wordIndex: wordIndex,
      text: run.map((w) => w.word).join(' '),
      start: run.first.start,
    ));
  }
  return found;
}

/// [lines] with the [chosen] runs added: a new line (capital first letter) or the words
/// inside the line.
List<String> withMissingWords(List<String> lines, List<MissingWords> chosen) {
  final out = List.of(lines);
  final order = List.of(chosen)
    ..sort((a, b) => a.line != b.line ? b.line - a.line : b.wordIndex - a.wordIndex);
  for (final m in order) {
    if (m.wordIndex == 0) {
      final text = m.text.isEmpty ? m.text : m.text[0].toUpperCase() + m.text.substring(1);
      out.insert(m.line, text);
    } else {
      final words = splitWords(out[m.line]).map((w) => w.trim()).toList()
        ..insert(m.wordIndex, m.text);
      out[m.line] = words.join(' ');
    }
  }
  return out;
}
