// Picking the official YouTube upload of a Spotify song from YouTube's search results: the
// artist's VEVO or official channel, "Artist - Topic", "Official" in the title, a length
// close to Spotify's; never a live, cover, karaoke or remix version the Spotify song is not.
// Pure Dart: no Flutter imports.

/// One video in YouTube's search results.
class YoutubeResult {
  final String videoId, title, channel;

  /// The length of the video; null for a live stream or when unknown.
  final double? seconds;

  /// The channel has YouTube's official-artist badge.
  final bool officialArtist;

  const YoutubeResult({
    required this.videoId,
    required this.title,
    required this.channel,
    this.seconds,
    this.officialArtist = false,
  });

  String get url => 'https://www.youtube.com/watch?v=$videoId';
}

final _featGroup = RegExp(r'[(\[]\s*(?:feat|ft)\.[^)\]]*[)\]]', caseSensitive: false);
final _featTail = RegExp(r'\s(?:feat|ft)\.\s.*$', caseSensitive: false);
final _notWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// Lower case, without "feat." parts, with everything but letters and digits as single
/// spaces.
String _normalize(String s) => s
    .toLowerCase()
    .replaceAll(_featGroup, ' ')
    .replaceAll(_featTail, '')
    .replaceAll(_notWord, ' ')
    .trim();

/// Versions that are not the song itself, unless the Spotify title says so too.
const _unwanted = [
  'live', 'cover', 'karaoke', 'instrumental', 'remix', 'sped up', 'slowed', 'reverb', '8d',
  'nightcore', 'reaction',
];

bool _hasWord(String normalized, String word) => ' $normalized '.contains(' $word ');

/// The best result for the song, or null when none fits. Results whose title lacks the
/// song's title are dropped; the rest are scored and the highest wins (the earlier one on
/// a tie, which is YouTube's order). A best score below 0 gives null.
YoutubeResult? rankYoutubeResults(
  List<YoutubeResult> results, {
  required String title,
  required String artist,
  required double seconds,
}) {
  final song = _normalize(title);
  final mainArtist = artist.split(',').first;
  final artistName = _normalize(mainArtist);
  final topic = _normalize('$mainArtist - Topic');

  YoutubeResult? best;
  var bestScore = 0;
  for (final r in results) {
    final t = _normalize(r.title);
    // Whole words: "Love" is not "Lovely".
    if (song.isEmpty || !_hasWord(t, song)) continue;
    final channel = _normalize(r.channel);
    // ponytail: first-guess weights, tune with real searches.
    var score = 0;
    if (channel.replaceAll(' ', '').endsWith('vevo')) score += 50;
    if (r.officialArtist) score += 40;
    if (channel == topic) score += 35;
    if (channel == artistName) score += 30;
    if (t.contains('official')) score += 20;
    final length = r.seconds;
    if (length != null) {
      final off = (length - seconds).abs();
      if (off <= 10) {
        score += 25;
      } else if (off > 30) {
        score -= 40;
      }
    }
    for (final word in _unwanted) {
      if (_hasWord(t, word) && !_hasWord(song, word)) score -= 60;
    }
    if (t.contains('lyric')) score -= 10;
    if (best == null || score > bestScore) {
      best = r;
      bestScore = score;
    }
  }
  return best != null && bestScore >= 0 ? best : null;
}
