import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/youtube_link.dart';
import 'package:kantahe_maker/ytdlp.dart';

const _id = 'dQw4w9WgXcQ';
const _canonical = 'https://www.youtube.com/watch?v=$_id';

void main() {
  group('youtubeVideoUrl', () {
    test('accepted_forms', () {
      const cases = {
        'https://www.youtube.com/watch?v=$_id': _canonical,
        'https://youtu.be/$_id?si=abc': _canonical,
        'https://m.youtube.com/watch?v=$_id&t=42s': _canonical,
        'https://music.youtube.com/watch?v=$_id&list=RDAMVM': _canonical,
        'https://www.youtube.com/watch?feature=share&v=$_id': _canonical,
        'https://www.youtube.com/shorts/$_id': _canonical,
        'youtube.com/embed/$_id': _canonical,
        'https://www.youtube-nocookie.com/embed/$_id': _canonical,
        'https://www.youtube.com/live/$_id?feature=share': _canonical,
        'https://www.youtube.com/v/$_id': _canonical,
        'http://youtube.com/watch?v=$_id': _canonical,
        'Check this out: https://youtu.be/$_id !!': _canonical,
        'Watch https://youtu.be/$_id.': _canonical,
        '(https://www.youtube.com/watch?v=$_id)': _canonical,
        'HTTPS://WWW.YOUTUBE.COM/watch?v=$_id': _canonical,
        'https://www.youtube.com/watch?v=a-b_c-d_e-f': 'https://www.youtube.com/watch?v=a-b_c-d_e-f',
      };
      cases.forEach((input, expected) => expect(youtubeVideoUrl(input), expected, reason: input));
    });

    test('rejected', () {
      for (final input in [
        'https://www.youtube.com/playlist?list=PL123',
        'https://www.youtube.com/@artist',
        'https://www.youtube.com/channel/UC1234567890',
        'https://www.youtube.com/results?search_query=song',
        'https://youtu.be/short',
        'https://www.youtube.com/watch?v=${_id}X',
        'https://vimeo.com/123',
        'https://notyoutube.com/watch?v=$_id',
        'https://open.spotify.com/track/4u7EnebtmKWzUH433cf5Qv',
        'hello',
        '',
      ]) {
        expect(youtubeVideoUrl(input), isNull, reason: input);
      }
    });

    test('bad_percent_encoding_never_throws', () {
      // km-9q6: clipboard text is untrusted; an odd link gives null (or the valid id), never an error.
      expect(youtubeVideoUrl('https://youtu.be/%FF'), isNull);
      expect(youtubeVideoUrl('https://www.youtube.com/watch?v=%FF'), isNull);
      expect(youtubeVideoUrl('https://www.youtube.com/watch?v=$_id&x=%FF'), _canonical);
    });

    test('playlist_embed_is_not_a_video', () {
      // km-36z: YouTube's "Embed playlist" code; "videoseries" is 11 letters.
      expect(youtubeVideoUrl('https://www.youtube.com/embed/videoseries?list=PL123'), isNull);
    });

    test('link_with_characters_right_after_it', () {
      // km-c1a.
      const url = 'https://youtu.be/$_id';
      for (final text in [
        '[$url]($url)',
        '[$url]',
        '**$url**',
        '$url,https://youtu.be/aaaaaaaaaaa',
        '$url。',
        '<$url>',
      ]) {
        expect(youtubeVideoUrl(text), _canonical, reason: text);
      }
      expect(
        youtubeVideoUrl('https://www.youtube.com/watch?v=$_id&list=PL1,https://youtu.be/aaaaaaaaaaa'),
        _canonical,
      );
    });

    test('long_text_without_video_links_is_fast', () {
      // km-hzz: the clipboard may hold a big blob of playlist links without spaces; reading
      // it must never freeze the app. (It took 7.8 s for 207 KB before the fix.)
      final playlists = List.filled(4000, '"https://www.youtube.com/watch?list=PL1234567890"').join(',');
      final bare = 'youtube.com/watch?' * 20000;
      final clock = Stopwatch()..start();
      expect(youtubeVideoUrl(playlists), isNull);
      expect(youtubeVideoUrl(bare), isNull);
      expect(youtubeVideoUrl('$playlists https://youtu.be/$_id'), _canonical);
      expect(clock.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('first_link_wins', () {
      expect(
        youtubeVideoUrl('a https://youtu.be/$_id and https://youtu.be/aaaaaaaaaaa'),
        _canonical,
      );
    });
  });

  group('songFromYoutube', () {
    // Made-up names only.
    YoutubeVideo v(String title, String channel, {String? track, String? artist}) => YoutubeVideo(
      id: 'aaaaaaaaaaa',
      url: 'https://www.youtube.com/watch?v=aaaaaaaaaaa',
      title: title,
      channel: channel,
      seconds: 200,
      track: track,
      artist: artist,
    );

    test('uses_track_and_artist_metadata', () {
      final s = songFromYoutube(v('Whatever (Official Video)', 'X', track: 'Song', artist: 'Singer'));
      expect((s.title, s.artist), ('Song', 'Singer'));
    });

    test('metadata_needs_both', () {
      final s = songFromYoutube(v('Singer - Song', 'X', track: 'Other'));
      expect((s.title, s.artist), ('Song', 'Singer'));
    });

    test('splits_artist_dash_title', () {
      final s = songFromYoutube(v('Singer - Song', 'Uploads'));
      expect((s.title, s.artist), ('Song', 'Singer'));
    });

    test('splits_at_the_first_dash_only', () {
      final s = songFromYoutube(v('Singer - Song - Part 2', 'Uploads'));
      expect((s.title, s.artist), ('Song - Part 2', 'Singer'));
    });

    test('strips_official_video', () {
      final s = songFromYoutube(v('Singer - Song (Official Video)', 'Uploads'));
      expect((s.title, s.artist), ('Song', 'Singer'));
    });

    test('strips_bracket_and_pipe', () {
      final s = songFromYoutube(v('Song [Official Music Video] | Singer', 'SingerVEVO'));
      expect((s.title, s.artist), ('Song', 'Singer'));
    });

    test('pipe_tail_goes_before_splitting', () {
      // The shape of a real result: without this, "BBC" would become the song title.
      final s = songFromYoutube(v("Song | Singer Rocks New Year's Eve - BBC", 'BBC'));
      expect((s.title, s.artist), ('Song', 'BBC'));
    });

    test('strips_every_listed_decoration', () {
      for (final d in [
        '(Official Video)', '(Official Music Video)', '(Official Audio)', '(Official Lyric Video)',
        '(Lyric Video)', '(Lyrics)', '(Visualizer)', '(Audio)', '(Video)', '(HD)', '[4K]', '(MV)',
        '(M/V)', '[OFFICIAL VIDEO]',
      ]) {
        expect(songFromYoutube(v('Singer - Song $d', 'Uploads')).title, 'Song', reason: d);
      }
    });

    test('remaster_is_removed_as_for_spotify', () {
      // The shape of a real official upload.
      final s = songFromYoutube(v('Singer - Song (Official Video) (4K Remaster)', 'Singer'));
      expect((s.title, s.artist), ('Song', 'Singer'));
    });

    test('keeps_other_brackets', () {
      // A version that is part of the song's name stays.
      expect(songFromYoutube(v('Singer - Song (Acoustic)', 'Uploads')).title, 'Song (Acoustic)');
    });

    test('topic_channel', () {
      final s = songFromYoutube(v('Song', 'Singer - Topic'));
      expect((s.title, s.artist), ('Song', 'Singer'));
    });

    test('vevo_channel', () {
      expect(songFromYoutube(v('Song', 'SingerVEVO')).artist, 'Singer');
      expect(songFromYoutube(v('Song', 'Singer VEVO')).artist, 'Singer');
      expect(songFromYoutube(v('Song', 'singervevo')).artist, 'singer');
    });

    test('en_and_em_dash', () {
      expect(songFromYoutube(v('Singer – Song', 'U')).artist, 'Singer');
      expect(songFromYoutube(v('Singer — Song', 'U')).title, 'Song');
    });

    test('title_that_is_only_decoration_falls_back', () {
      final s = songFromYoutube(v('(Official Video)', 'Singer'));
      expect((s.title, s.artist), ('(Official Video)', 'Singer'));
    });
  });
}
