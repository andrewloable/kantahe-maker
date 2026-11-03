import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/autofill.dart';
import 'package:kantahe_maker/lyrics_lookup.dart';
import 'package:kantahe_maker/song_info.dart';
import 'package:kantahe_maker/spotify_link.dart';

const track = SpotifyTrack(id: 'i', title: 'T', artist: 'A', seconds: 200);

// Made-up lyrics only.
LyricsCandidate lyricsEntry({
  String title = 'T',
  String artist = 'A',
  double? seconds = 200.5,
  bool timed = true,
}) => LyricsCandidate(
  title: title,
  artist: artist,
  album: '',
  lyrics: 'la la\nna na',
  seconds: seconds,
  synced: timed ? const [(1.0, 'la la'), (2.5, 'na na')] : const [],
);

SongInfoCandidate recording({
  String title = 'T',
  String artist = 'A',
  double? seconds = 199,
  String id = 'rec1',
}) => SongInfoCandidate(
  title: title,
  artist: artist,
  album: '',
  year: '',
  recordingId: id,
  seconds: seconds,
);

class Calls {
  final songInfo = <(String, String)>[];
  final details = <String>[];
  final exact = <(String, String, double)>[];
  final search = <(String, String)>[];
}

Future<AutofillResult> run({
  Future<double?>? audio,
  List<SongInfoCandidate> recordings = const [],
  Object? songInfoError,
  Object? detailsError,
  LyricsCandidate? exactAnswer,
  Object? exactError,
  List<LyricsCandidate> searchAnswer = const [],
  Object? searchError,
  Calls? calls,
  List<String>? logs,
}) {
  final c = calls ?? Calls();
  return autofillFromSpotify(
    track,
    audio ?? Future.value(201.0),
    onLog: logs?.add,
    songInfoFinder: (t, a) async {
      c.songInfo.add((t, a));
      if (songInfoError != null) throw songInfoError;
      return recordings;
    },
    songInfoDetailsFn: (id) async {
      c.details.add(id);
      if (detailsError != null) throw detailsError;
      return (composer: 'C', lyricist: 'L');
    },
    exactLyricsFn: (t, a, s) async {
      c.exact.add((t, a, s));
      if (exactError != null) throw exactError;
      return exactAnswer;
    },
    lyricsFinder: (t, a) async {
      c.search.add((t, a));
      if (searchError != null) throw searchError;
      return searchAnswer;
    },
  );
}

void main() {
  test('fills_all', () async {
    final r = await run(
      recordings: [recording(title: 'Other'), recording()],
      exactAnswer: lyricsEntry(),
      audio: Future.value(201.0),
    );
    expect((r.title, r.artist, r.composer, r.lyricist), ('T', 'A', 'C', 'L'));
    expect(r.lines, [(1.0, 'la la'), (2.5, 'na na')]);
    expect((r.timingSource, r.note), ('lrclib', ''));
  });

  test('the_log_tells_each_decision', () async {
    final used = <String>[];
    await run(
      logs: used,
      recordings: [recording()],
      exactAnswer: lyricsEntry(),
      audio: Future.value(201.0),
    );
    final text = used.join('\n');
    expect(text, contains('autofill start: "T" by "A"'));
    expect(text, contains('musicbrainz: recording matched'));
    expect(text, contains('lrclib exact lookup: entry found'));
    expect(text, contains('audio length: 201.0 s'));
    expect(text, contains('times used'));
    expect(text, contains('result: composer yes, lyricist yes, 2 lyric lines, source lrclib'));
    expect(text, isNot(contains('la la')), reason: 'no lyrics in the log');
    final dropped = <String>[];
    await run(logs: dropped, exactAnswer: lyricsEntry(), audio: Future.value(215.0));
    expect(dropped.join('\n'), contains('times dropped'));
    final failing = <String>[];
    await run(logs: failing, songInfoError: StateError('down'), exactError: StateError('down'));
    expect(failing.join('\n'), contains('musicbrainz failed: StateError'));
    expect(failing.join('\n'), contains('lrclib failed: StateError'));
  });

  test('times_dropped_for_other_length', () async {
    final r = await run(exactAnswer: lyricsEntry(), audio: Future.value(215.0));
    expect(r.lines, [(null, 'la la'), (null, 'na na')]);
    expect(r.timingSource, 'tapped');
    expect(r.note, contains('different length'));
  });

  test('times_dropped_when_length_unknown', () async {
    final r = await run(exactAnswer: lyricsEntry(), audio: Future.value(null));
    expect(r.lines, [(null, 'la la'), (null, 'na na')]);
    expect(r.timingSource, 'tapped');
    expect(r.note, contains('not known'));
  });

  test('times_kept_inside_the_tolerance_only', () async {
    // The lyrics entry is 200.5 s: 2.0 s away is still the same version, 2.6 s is not.
    final inside = await run(exactAnswer: lyricsEntry(), audio: Future.value(202.5));
    expect(inside.timingSource, 'lrclib');
    final outside = await run(exactAnswer: lyricsEntry(), audio: Future.value(203.1));
    expect(outside.timingSource, 'tapped');
  });

  test('times_compare_with_the_audio_not_with_spotify', () async {
    // Spotify says 200 s and so does the lyrics entry, but the audio is 30 s longer.
    final r = await run(
      exactAnswer: lyricsEntry(seconds: 200),
      audio: Future.value(230.0),
    );
    expect(r.timingSource, 'tapped');
  });

  test('plain_lyrics_have_no_note', () async {
    final r = await run(
      exactAnswer: lyricsEntry(timed: false),
      audio: Future.value(null),
    );
    expect(r.lines, [(null, 'la la'), (null, 'na na')]);
    expect((r.timingSource, r.note), ('tapped', ''));
  });

  test('falls_back_to_search', () async {
    final calls = Calls();
    final r = await run(
      calls: calls,
      exactAnswer: null,
      searchAnswer: [
        lyricsEntry(title: 'Something else'),
        lyricsEntry(),
      ],
    );
    expect(calls.exact, [('T', 'A', 200.0)]);
    expect(calls.search, [('T', 'A')]);
    expect(r.lines, [(1.0, 'la la'), (2.5, 'na na')]);
  });

  test('search_needs_the_exact_name', () async {
    final r = await run(searchAnswer: [lyricsEntry(title: 'Something else')]);
    expect(r.lines, isEmpty);
  });

  test('musicbrainz_needs_exact_name_and_length', () async {
    final calls = Calls();
    final r = await run(
      calls: calls,
      recordings: [recording(seconds: 260)],
      exactAnswer: lyricsEntry(),
    );
    expect((r.composer, r.lyricist), ('', ''));
    expect(calls.details, isEmpty);
  });

  test('musicbrainz_match_without_a_length_counts', () async {
    final r = await run(recordings: [recording(seconds: null)]);
    expect((r.composer, r.lyricist), ('C', 'L'));
  });

  test('details_failure_leaves_composer_and_lyricist_empty', () async {
    final r = await run(
      recordings: [recording()],
      detailsError: StateError('down'),
      exactAnswer: lyricsEntry(),
    );
    expect((r.composer, r.lyricist), ('', ''));
    expect(r.lines, isNotEmpty);
  });

  test('lookups_fail_quietly', () async {
    final r = await run(
      songInfoError: StateError('a'),
      exactError: StateError('b'),
      searchError: StateError('c'),
      audio: Future.error(StateError('d')),
    );
    expect((r.title, r.artist), ('T', 'A'));
    expect((r.composer, r.lyricist, r.note), ('', '', ''));
    expect(r.lines, isEmpty);
    expect(r.timingSource, 'tapped');
  });

  test('lookups_start_before_the_audio_is_known', () async {
    final audio = Completer<double?>();
    final calls = Calls();
    final future = run(
      calls: calls,
      audio: audio.future,
      recordings: [recording()],
      exactAnswer: lyricsEntry(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(calls.songInfo, isNotEmpty);
    expect(calls.exact, isNotEmpty);
    expect(calls.details, ['rec1']);
    audio.complete(201.0);
    expect((await future).timingSource, 'lrclib');
  });
}
