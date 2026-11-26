// Recognising a YouTube video link in pasted text, in any of the forms YouTube and its apps
// share, and turning it into the plain watch link yt-dlp gets; and the song's title and
// artist from a video's info. Pure Dart: no Flutter imports.

import 'export.dart' show oneLine;
import 'spotify_link.dart' show cleanSpotifyTitle;
import 'ytdlp.dart' show YoutubeVideo;

/// One video link: a YouTube host at a word start (so "notyoutube.com" is not one), then
/// `/watch?...v=ID`, `/shorts|embed|live|v/ID` or (on youtu.be) `/ID`. The id is 11
/// characters that must not run on into more id characters, so whatever text follows the
/// link (brackets, stars, commas, other scripts) is left out. Nothing is decoded, so odd
/// text never makes this fail. The query before v= is bounded (at most 32 parameters of at
/// most 256 characters, none crossing a quote or angle bracket): unbounded, a long text of
/// playlist links without spaces made the search take seconds (km-hzz).
final _link = RegExp(
  r'(?<![\w.-])(?:https?://)?(?:(?:www|m|music)\.)?'
  r'(?:(?:youtube\.com|youtube-nocookie\.com)'
  r'''(?:/watch/?\?(?:[^\s#&"'<>]{0,256}&){0,32}v=|/(?:shorts|embed|live|v)/)'''
  r'|youtu\.be/)'
  r'([A-Za-z0-9_-]{11})(?![A-Za-z0-9_-])',
  caseSensitive: false,
);

/// The canonical link (https://www.youtube.com/watch?v=ID) of the first YouTube video link
/// anywhere in [text], or null. Accepted: youtube.com/watch?v=, youtu.be/, /shorts/, /embed/,
/// /live/, /v/, on www., m., music. and youtube-nocookie.com, with or without http(s)://.
/// Playlists (also embedded ones, /embed/videoseries), channels, searches, other sites and
/// ids that are not 11 characters give null. Other parameters (list=, t=, si=...) are dropped.
String? youtubeVideoUrl(String text) {
  for (final m in _link.allMatches(text)) {
    final id = m.group(1)!;
    // YouTube's "Embed playlist" code: /embed/videoseries?list=... is not a video.
    if (id.toLowerCase() == 'videoseries') continue;
    return 'https://www.youtube.com/watch?v=$id';
  }
  return null;
}

/// What YouTube adds to a song's name in brackets: "(Official Video)", "[Lyrics]", "(HD)"...
final _decoration = RegExp(
  r'\s*[(\[]\s*(?:official\s+(?:music\s+|lyric\s+)?(?:video|audio)|lyric\s+video|lyrics'
  r'|visualizer|audio|video|hd|4k|mv|m/v)\s*[)\]]',
  caseSensitive: false,
);
final _dash = RegExp(' [-–—] ');
final _topic = RegExp(r'\s+-\s+topic$', caseSensitive: false);
final _vevo = RegExp(r'\s*vevo$', caseSensitive: false);

/// Without decorations, and without "Remaster" parts the same way as a Spotify title.
String _cleanTitle(String title) {
  final t = oneLine(title.replaceAll(_decoration, ''));
  return t.isEmpty ? t : cleanSpotifyTitle(t);
}

String _artistFromChannel(String channel) =>
    oneLine(channel.trim().replaceFirst(_topic, '').replaceFirst(_vevo, ''));

/// The song's title and artist from a YouTube video. The first rule that fits wins:
/// YouTube Music's track and artist; else "Artist - Title" in the video title (anything
/// after " | " is left out first); else the video title, with the artist from the channel
/// name without " - Topic" or "VEVO". Decorations such as "(Official Video)" are removed from
/// the title; a title that is nothing but decoration stays as it is.
({String title, String artist}) songFromYoutube(YoutubeVideo v) {
  String title, artist;
  if (v.track != null && v.artist != null) {
    title = v.track!;
    artist = oneLine(v.artist!);
  } else {
    var t = v.title;
    final pipe = t.indexOf(' | ');
    if (pipe > 0) t = t.substring(0, pipe);
    final dash = _dash.firstMatch(t);
    if (dash != null && oneLine(t.substring(0, dash.start)).isNotEmpty) {
      artist = oneLine(t.substring(0, dash.start));
      title = t.substring(dash.end);
    } else {
      title = t;
      artist = _artistFromChannel(v.channel);
    }
  }
  final clean = _cleanTitle(title);
  return (title: clean.isEmpty ? oneLine(v.title) : clean, artist: artist);
}
