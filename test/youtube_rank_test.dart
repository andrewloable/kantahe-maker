import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/youtube_rank.dart';

// Made-up songs, artists and channels only.
YoutubeResult r(String id, String title, String channel,
        {double? seconds = 200, bool badge = false}) =>
    YoutubeResult(
      videoId: id,
      title: title,
      channel: channel,
      seconds: seconds,
      officialArtist: badge,
    );

String? pick(List<YoutubeResult> results,
        {String title = 'Song', String artist = 'Singer', double seconds = 200}) =>
    rankYoutubeResults(results, title: title, artist: artist, seconds: seconds)?.videoId;

void main() {
  test('url_is_the_watch_link', () {
    expect(r('abcdefghijk', 'Song', 'Singer').url, 'https://www.youtube.com/watch?v=abcdefghijk');
  });

  test('vevo_beats_lyric_video', () {
    expect(
      pick([
        r('lyric', 'Singer - Song (Lyrics)', 'Lyrics Hub'),
        r('vevo', 'Singer - Song', 'SingerVEVO'),
      ]),
      'vevo',
    );
  });

  test('topic_beats_cover', () {
    expect(
      pick([
        r('cover', 'Song - Singer (Cover)', 'Some Coverer'),
        r('topic', 'Song', 'Singer - Topic'),
      ]),
      'topic',
    );
  });

  test('official_artist_badge_counts', () {
    expect(
      pick([
        r('fan', 'Song', 'Fan Uploads'),
        r('badge', 'Song', 'Singer Music', badge: true),
      ]),
      'badge',
    );
  });

  test('length_decides_between_two_official', () {
    expect(
      pick(seconds: 202, [
        r('long', 'Singer - Song (Official Video)', 'SingerVEVO', seconds: 260),
        r('right', 'Singer - Song (Official Audio)', 'SingerVEVO', seconds: 200),
      ]),
      'right',
    );
  });

  test('live_kept_when_spotify_title_says_live', () {
    expect(pick(title: 'Song - Live', [r('live', 'Song - Live (Official)', 'SingerVEVO')]), 'live');
  });

  test('live_penalised_otherwise', () {
    expect(
      pick([
        r('live', 'Singer - Song (Live at the Arena)', 'SingerVEVO'),
        r('studio', 'Singer - Song', 'Fan Uploads'),
      ]),
      'studio',
    );
  });

  test('every_unwanted_version_is_penalised', () {
    for (final word in [
      'live', 'cover', 'karaoke', 'instrumental', 'remix', 'sped up', 'slowed', 'reverb',
      '8d', 'nightcore', 'reaction',
    ]) {
      // Same channel, same length: only the word differs.
      expect(
        pick([
          r('bad', 'Singer - Song ($word)', 'SingerVEVO'),
          r('good', 'Singer - Song', 'SingerVEVO'),
        ]),
        'good',
        reason: word,
      );
    }
  });

  test('word_must_be_whole', () {
    // "Delivery" holds "live" but is not a live version.
    expect(pick(title: 'Song Delivery', [r('ok', 'Song Delivery', 'SingerVEVO')]), 'ok');
  });

  test('off_title_results_dropped_gives_null', () {
    expect(pick([r('x', 'Another Tune', 'SingerVEVO', badge: true)]), isNull);
    expect(pick([]), isNull);
  });

  test('title_must_match_whole_words', () {
    expect(pick(title: 'Love', [r('x', 'Lovely (Official Video)', 'SingerVEVO')]), isNull);
    expect(pick(title: 'Love', [r('y', 'Singer - Love (Official Video)', 'SingerVEVO')]), 'y');
  });

  test('below_zero_gives_null', () {
    expect(pick([r('k', 'Song (Karaoke Version)', 'Karaoke Channel', seconds: 300)]), isNull);
  });

  test('feat_is_ignored', () {
    expect(
      pick(title: 'Song (feat. X)', [r('ft', 'Singer - Song ft. X (Official Video)', 'SingerVEVO')]),
      'ft',
    );
    expect(
      pick(title: 'Song', [r('ft2', 'Singer - Song [feat. X]', 'SingerVEVO')]),
      'ft2',
    );
  });

  test('first_artist_of_a_list_counts', () {
    expect(
      pick(artist: 'Singer, Other', [
        r('fan', 'Song', 'Fan Uploads'),
        r('own', 'Song', 'Singer'),
      ]),
      'own',
    );
  });

  test('tie_keeps_youtube_order', () {
    expect(
      pick([
        r('first', 'Singer - Song', 'SingerVEVO'),
        r('second', 'Singer - Song', 'SingerVEVO'),
      ]),
      'first',
    );
  });

  test('unknown_length_is_neutral', () {
    expect(pick([r('nolen', 'Song', 'Fan Uploads', seconds: null)]), 'nolen');
  });

  test('unicode_titles_match', () {
    expect(pick(title: 'Bésame', [r('b', 'BÉSAME (Official Video)', 'SingerVEVO')]), 'b');
    expect(pick(title: 'Café del Mar', [r('c', 'Café Del Mar - Singer', 'Singer - Topic')]), 'c');
  });
}
