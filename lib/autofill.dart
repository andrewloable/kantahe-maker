// Filling in a song's details from a Spotify track without asking the user anything: the
// composer and lyricist (musicbrainz.org) and the lyrics (lrclib.net), whose times are used
// only when the lyrics entry is as long as the user's audio. Pure Dart: no Flutter imports.

import 'export.dart' show oneLine;
import 'lyrics_lookup.dart';
import 'song_info.dart';
import 'spotify_link.dart';

class AutofillResult {
  /// The name of the song and its artist as Spotify has them.
  final String title, artist;

  /// Blank when musicbrainz.org has no exact match for the song.
  final String composer, lyricist;

  /// The lyric lines with their times, or without ([null]) when the times cannot be trusted.
  /// Empty when no lyrics were found.
  final List<(double?, String)> lines;

  /// 'lrclib' when every line has a time, 'tapped' otherwise (the user taps the timing).
  final String timingSource;

  /// One sentence for the user, or an empty string.
  final String note;
  const AutofillResult({
    required this.title,
    required this.artist,
    this.composer = '',
    this.lyricist = '',
    this.lines = const [],
    this.timingSource = 'tapped',
    this.note = '',
  });
}

/// How far, in seconds, a version of the song may be from the user's audio for its times
/// to be used: LRCLIB's own matching allows about as much.
const _timingTolerance = 2.0;

/// How far musicbrainz.org's length may be from Spotify's for it to be the same recording.
const _recordingTolerance = 3.0;

String _norm(String v) => oneLine(v).toLowerCase();

/// Looks up everything about [track] that can be found without the user. The lookups run
/// at once and do not wait for [audioSeconds] (the length of the user's audio, null when it
/// cannot be known); only the choice of times does. Never throws: whatever fails is left
/// empty. The finders are for tests; the defaults ask the real services.
Future<AutofillResult> autofillFromSpotify(
  SpotifyTrack track,
  Future<double?> audioSeconds, {
  Future<List<SongInfoCandidate>> Function(String title, String artist)? songInfoFinder,
  Future<({String composer, String lyricist})> Function(String recordingId)? songInfoDetailsFn,
  Future<LyricsCandidate?> Function(String title, String artist, double seconds)? exactLyricsFn,
  Future<List<LyricsCandidate>> Function(String title, String artist)? lyricsFinder,
  void Function(String line)? onLog,
}) async {
  void log(String line) => onLog?.call('autofill $line');
  log('start: "${track.title}" by "${track.artist}", ${track.seconds.toStringAsFixed(1)} s');
  // Listened to at once, so an error in it is never reported as unhandled.
  final audio = audioSeconds.then<double?>((v) => v, onError: (Object _) => null);
  final credits = _credits(
    track,
    songInfoFinder ?? findSongInfo,
    songInfoDetailsFn ?? songInfoDetails,
    log,
  );
  final entry = _lyrics(
    track,
    exactLyricsFn ?? findLyricsExact,
    lyricsFinder ?? findLyrics,
    log,
  );
  final composerAndLyricist = await credits;
  final found = await entry;
  log('lookups done, waiting for the length of the audio');
  final length = await audio;
  log('audio length: ${length == null ? 'unknown' : '${length.toStringAsFixed(1)} s'}');

  var lines = <(double?, String)>[];
  var timingSource = 'tapped';
  var note = '';
  if (found != null) {
    final timedOk =
        found.synced.isNotEmpty &&
        length != null &&
        found.seconds != null &&
        (found.seconds! - length).abs() <= _timingTolerance;
    log(
      'timing: ${found.synced.length} timed lines, entry '
      '${found.seconds == null ? 'length unknown' : '${found.seconds!.toStringAsFixed(1)} s'}, '
      'audio ${length == null ? 'unknown' : '${length.toStringAsFixed(1)} s'} -> '
      '${timedOk ? 'times used' : 'times dropped'}',
    );
    if (timedOk) {
      lines = [for (final l in found.synced) (l.$1, l.$2)];
      timingSource = 'lrclib';
    } else {
      lines = [for (final l in found.lyrics.split('\n')) (null, l)];
      if (found.synced.isNotEmpty) {
        note = length == null
            ? 'The length of the audio is not known yet; tap the timing in Timing.'
            : 'The timed lyrics are for a version of a different length; tap the timing in Timing.';
      }
    }
  } else {
    log('no lyrics found');
  }
  log(
    'result: composer ${composerAndLyricist.composer.isEmpty ? 'no' : 'yes'}, '
    'lyricist ${composerAndLyricist.lyricist.isEmpty ? 'no' : 'yes'}, '
    '${lines.length} lyric lines, source $timingSource${note.isEmpty ? '' : ', note given'}',
  );
  return AutofillResult(
    title: track.title,
    artist: track.artist,
    composer: composerAndLyricist.composer,
    lyricist: composerAndLyricist.lyricist,
    lines: lines,
    timingSource: timingSource,
    note: note,
  );
}

/// The composer and lyricist of the musicbrainz.org recording that is [track] (same title and
/// artist, about the same length), or blanks.
Future<({String composer, String lyricist})> _credits(
  SpotifyTrack track,
  Future<List<SongInfoCandidate>> Function(String, String) find,
  Future<({String composer, String lyricist})> Function(String) details,
  void Function(String) log,
) async {
  try {
    final recordings = await find(track.title, track.artist);
    log('musicbrainz: ${recordings.length} recordings found');
    for (final c in recordings) {
      final sameLength =
          c.seconds == null || (c.seconds! - track.seconds).abs() <= _recordingTolerance;
      if (_norm(c.title) == _norm(track.title) &&
          _norm(c.artist) == _norm(track.artist) &&
          sameLength) {
        final credits = await details(c.recordingId);
        log('musicbrainz: recording matched, credits read');
        return credits;
      }
    }
    log('musicbrainz: no recording matched the name and length');
  } catch (e) {
    // musicbrainz.org is a bonus: the composer and lyricist stay blank.
    log('musicbrainz failed: ${e.runtimeType}: $e');
  }
  return (composer: '', lyricist: '');
}

/// The lyrics of [track]: the exact entry of that length, else the best search result with
/// the same title and artist, else null.
Future<LyricsCandidate?> _lyrics(
  SpotifyTrack track,
  Future<LyricsCandidate?> Function(String, String, double) exact,
  Future<List<LyricsCandidate>> Function(String, String) search,
  void Function(String) log,
) async {
  try {
    final byLength = await exact(track.title, track.artist, track.seconds);
    log('lrclib exact lookup: ${byLength == null ? 'no entry' : 'entry found'}');
    if (byLength != null) return byLength;
    final ranked = rankLyrics(
      await search(track.title, track.artist),
      track.title,
      track.artist,
      seconds: track.seconds,
    );
    log('lrclib search: ${ranked.length} results');
    for (final c in ranked) {
      if (_norm(c.title) == _norm(track.title) && _norm(c.artist) == _norm(track.artist)) {
        return c;
      }
    }
  } catch (e) {
    // lrclib.net is a bonus: the lyrics stay empty.
    log('lrclib failed: ${e.runtimeType}: $e');
  }
  return null;
}
