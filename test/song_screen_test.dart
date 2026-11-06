import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/ai_timing.dart';
import 'package:kantahe_maker/autofill.dart';
import 'package:kantahe_maker/export.dart';
import 'package:kantahe_maker/jobs.dart';
import 'package:kantahe_maker/karmp3.dart' show karMp3Name;
import 'package:kantahe_maker/karmp3_read.dart';
import 'package:kantahe_maker/lyrics_lookup.dart';
import 'package:kantahe_maker/screens/lyrics_search_panel.dart';
import 'package:kantahe_maker/screens/song_info_panel.dart';
import 'package:kantahe_maker/song_info.dart';
import 'package:kantahe_maker/spotify_link.dart';
import 'package:kantahe_maker/pipeline.dart';
import 'package:kantahe_maker/project.dart';
import 'package:kantahe_maker/screens/song_screen.dart';
import 'package:kantahe_maker/screens/tap_screen.dart';
import 'package:kantahe_maker/settings.dart';
import 'package:kantahe_maker/tools.dart';
import 'package:kantahe_maker/wizard.dart';

import 'support/fake_player.dart';
import 'support/settle.dart';

import 'package:path/path.dart' as p;

import 'support/windows_safe.dart';

const fakeTools = ToolPaths(
  ffmpeg: '/t/ffmpeg',
  ffprobe: '/t/ffprobe',
  separator: '/t/sep',
  modelDir: '/t/m',
);

/// A separation the test controls: it emits lines, finishes or fails when told to.
class FakeSepJob implements CancellableJob {
  FakeSepJob(this.work, this.onLine);
  final Directory work;
  final void Function(String) onLine;
  final _done = Completer<void>();
  bool cancelled = false;

  @override
  Future<void> get done => _done.future;

  @override
  void cancel() {
    cancelled = true;
    if (!_done.isCompleted) _done.completeError(const SeparationCancelled());
  }

  void emit(String line) => onLine(line);

  void finish() {
    // The vocals first, as the real separation does.
    File('${work.path}/vocals.mp3').writeAsBytesSync([5, 5]);
    File('${work.path}/instrumental.mp3').writeAsBytesSync([9, 9]);
    _done.complete();
  }

  void fail(Object e) => _done.completeError(e);
}

class Song {
  late Directory root;
  late Directory dir;
  late SongProject project;
  ToolPaths? toolsResult = fakeTools;
  int ensureCalls = 0;
  final imports = <String>[];
  Object? importError;
  final seps = <FakeSepJob>[];
  double duration = 61.4;
  Object? durationError;
  final durationFiles = <String>[];
  final mixes = <String>[];
  int mixFailures = 0;
  Completer<void>? mixGate;
  String? savePath;
  final suggested = <String>[];
  final revealed = <String>[];
  final player = FakePlayer();
  final aiBytes = <Uint8List>[];

  /// What is on disk, for a failure message.
  String describe() => [
    if (dir.existsSync())
      for (final e in dir.listSync())
        '${e.path}: ${e is File ? '${e.lengthSync()} bytes' : 'dir'}',
    if (File('${dir.path}/project.json').existsSync())
      readText(File('${dir.path}/project.json')),
  ].join('\n');

  Map<String, dynamic> json() =>
      jsonDecode(readText(File('${dir.path}/project.json')))
          as Map<String, dynamic>;

  FakeSepJob get sep => seps.last;
}

Future<Song> pumpSong(
  WidgetTester tester, {
  void Function(SongProject)? configure,
  bool source = false,
  bool openedSource = false,
  int mixFailures = 0,
  Completer<void>? mixGate,
  Future<String?> Function()? pickAudio,
  bool instrumental = false,
  bool vocals = false,
  bool settleAtOnce = true,
  String? corruptJson,
  bool toolsAvailable = true,
  Object? importError,
  Object? durationError,
  LyricsFinder? lyricsFinder,
  Completer<void>? importGate,
  SongInfoFinder? songInfoFinder,
  Future<({String composer, String lyricist})> Function(String)?
  songInfoDetailsFn,
  Future<({String title, String artist})> Function(ToolPaths, String)? tagsFn,
  Future<SpotifyTrack> Function(String)? spotifyFinder,
  Future<AutofillResult> Function(SpotifyTrack, Future<double?>)? autofill,
  bool onTopOfHome = false,
  AppSettings aiSettings = const AppSettings(),
  Future<List<HeardWord>> Function(Uint8List, AppSettings)? aiTranscribe,
}) async {
  final s = Song()
    ..toolsResult = toolsAvailable ? fakeTools : null
    ..importError = importError
    ..durationError = durationError;
  s.root = Directory.systemTemp.createTempSync('song_test');
  addTearDown(() => deleteTemp(s.root));
  s.dir = Directory('${s.root.path}/20260101-000000');
  s.project = SongProject(id: '20260101-000000', inputPath: '/x/in.mp4');
  configure?.call(s.project);
  await tester.runAsync(() => s.project.save(s.dir));
  if (corruptJson != null) {
    File('${s.dir.path}/project.json').writeAsStringSync(corruptJson);
  }
  if (source) {
    File('${s.dir.path}/source.mp3').writeAsStringSync('x');
    File('${s.dir.path}/source.wav').writeAsStringSync('x');
  }
  // A song opened from a .karmp3 has source.mp3 but never source.wav.
  if (openedSource) File('${s.dir.path}/source.mp3').writeAsStringSync('x');
  s.mixFailures = mixFailures;
  s.mixGate = mixGate;
  if (instrumental) {
    File('${s.dir.path}/instrumental.mp3').writeAsBytesSync([9, 9]);
  }
  if (vocals) {
    File('${s.dir.path}/vocals.mp3').writeAsBytesSync([5, 5]);
  }
  await tester.binding.setSurfaceSize(const Size(1000, 3600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final screen = SongScreen(
    // A new screen for every song, also when a test pumps a second one.
    key: UniqueKey(),
    dir: s.dir,
    saveDelay: const Duration(milliseconds: 50),
    createPlayer: () => s.player,
    ensureToolsFn: (context) async {
      s.ensureCalls++;
      return s.toolsResult;
    },
    importFn: (tools, input, work, onLine) async {
      s.imports.add(input);
      await importGate?.future;
      final e = s.importError;
      if (e != null) throw e;
      File('${work.path}/source.mp3').writeAsStringSync('x');
      File('${work.path}/source.wav').writeAsStringSync('x');
    },
    separateFn: (tools, work, onLine) {
      final job = FakeSepJob(work, onLine);
      s.seps.add(job);
      return job;
    },
    pickAudio: pickAudio ?? () async => null,
    sourceFromStemsFn: (tools, work, onLine) async {
      s.mixes.add(work.path);
      await s.mixGate?.future;
      if (s.mixFailures > 0) {
        s.mixFailures--;
        throw StateError('mix failed');
      }
      File('${work.path}/source.mp3').writeAsStringSync('x');
    },
    durationFn: (tools, file) async {
      s.durationFiles.add(file);
      final e = s.durationError;
      if (e != null) throw e;
      return s.duration;
    },
    saveLocation: (suggestedName) async {
      s.suggested.add(suggestedName);
      return s.savePath;
    },
    revealFile: (path) async => s.revealed.add(path),
    // Never the real lrclib.net in a test.
    lyricsFinder: lyricsFinder ?? (title, artist) async => const [],
    // Never the real musicbrainz.org either.
    songInfoFinder: songInfoFinder ?? (title, artist) async => const [],
    songInfoDetailsFn:
        songInfoDetailsFn ?? (id) async => (composer: '', lyricist: ''),
    tagsFn: tagsFn ?? (tools, input) async => (title: '', artist: ''),
    // Never the real open.spotify.com, musicbrainz.org or lrclib.net either.
    spotifyFinder:
        spotifyFinder ?? (link) async => throw StateError('no network in tests'),
    autofill:
        autofill ?? (track, audio) async => throw StateError('no network in tests'),
    loadSettingsFn: () async => aiSettings,
    aiTranscribeFn: (bytes, settings) async {
      s.aiBytes.add(bytes);
      return (aiTranscribe ?? (b, st) async => throw StateError('no network in tests'))(bytes, settings);
    },
  );
  await tester.pumpWidget(
    onTopOfHome
        // "/song" opens on top of "/", so the song screen can be left.
        ? MaterialApp(
            initialRoute: '/song',
            routes: {
              '/': (_) => const Scaffold(body: Text('home route')),
              '/song': (_) => screen,
            },
          )
        : MaterialApp(home: screen),
  );
  if (settleAtOnce) await settle(tester);
  return s;
}

bool shown(String text) => find.textContaining(text).evaluate().isNotEmpty;

/// Opens [step] through the step header (does nothing if the step cannot be opened).
Future<void> goTo(WidgetTester tester, WizardStep step) async {
  await tester.tap(find.byKey(ValueKey('step-${step.name}')));
  await tester.pump();
}

Future<void> typeInto(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(ValueKey(key)), text);
  await tester.pump();
}

/// Title and artist filled in, so the steps after Details can be opened.
SongProject named(SongProject p) => p
  ..title = 'T'
  ..artist = 'A';

SongProject tappedSong(SongProject p) => p
  ..title = 'T'
  ..artist = 'A'
  ..lyrics = 'a\nb'
  ..times = [1, 2];

void main() {
  tearDown(() => expect(jobs.length, 0, reason: 'a job was left registered'));

  group('loading', () {
    testWidgets('loads_the_project_into_the_fields', (tester) async {
      await pumpSong(
        tester,
        configure: (p) {
          p
            ..title = 'My Title'
            ..artist = 'My Artist'
            ..number = 7
            ..composer = 'Comp'
            ..lyricist = 'Lyr'
            ..lyrics = 'one\ntwo';
        },
        source: true,
        instrumental: true,
      );
      String text(String k) =>
          tester.widget<TextField>(find.byKey(ValueKey(k))).controller!.text;
      await goTo(tester, WizardStep.details);
      expect(text('title'), 'My Title');
      expect(text('artist'), 'My Artist');
      expect(text('number'), '7');
      expect(text('composer'), 'Comp');
      expect(text('lyricist'), 'Lyr');
      await goTo(tester, WizardStep.lyrics);
      expect(text('lyrics'), 'one\ntwo');
      expect(
        find.text('My Title - My Artist'),
        findsOneWidget,
        reason: 'app bar',
      );
    });

    testWidgets('a_project_that_cannot_be_read_shows_the_error', (
      tester,
    ) async {
      await pumpSong(tester, corruptJson: '{');
      expect(shown('Could not open this song'), isTrue);
      expect(find.byKey(const ValueKey('title')), findsNothing);
    });

    testWidgets('app_bar_falls_back_to_the_input_file_name', (tester) async {
      await pumpSong(tester);
      expect(find.text('in.mp4'), findsOneWidget);
    });
  });

  group('audio', () {
    testWidgets('tools_are_needed_to_continue', (tester) async {
      final s = await pumpSong(tester, toolsAvailable: false);
      await settle(tester, until: () => shown('Tools are needed to continue'));
      expect(find.text('Get tools'), findsOneWidget);
      expect(s.imports, isEmpty, reason: 'nothing runs without the tools');
      s.toolsResult = fakeTools;
      await tester.tap(find.text('Get tools'));
      await settle(tester, until: () => s.seps.isNotEmpty);
      expect(s.ensureCalls, 2);
      expect(s.imports, ['/x/in.mp4']);
      await goTo(tester, WizardStep.vocals);
      s.sep.finish();
      // Whoever waits on this step is moved on; the result is still shown on the step.
      await settle(tester, until: () => jobs.length == 0);
      await goTo(tester, WizardStep.vocals);
      expect(shown('Vocal splitting finished'), isTrue);
    });

    testWidgets('import_then_separation_flow', (tester) async {
      final s = await pumpSong(
        tester,
        configure: (p) => named(p).lyrics = 'a\nb',
      );
      await settle(tester, until: () => s.seps.isNotEmpty);
      await goTo(tester, WizardStep.timing);
      expect(
        find.byType(TapScreen),
        findsOneWidget,
        reason: 'tapping is possible as soon as the song is read, during vocal splitting',
      );
      expect(s.ensureCalls, 1);
      expect(s.imports, ['/x/in.mp4']);
      await goTo(tester, WizardStep.vocals);
      expect(shown('Splitting vocals'), isTrue);
      expect(find.text('Cancel'), findsOneWidget);
      s.sep.emit('size=  120KiB time=00:00:12');
      await tester.pump();
      expect(
        shown('size=  120KiB time=00:00:12'),
        isTrue,
        reason: 'the last output line',
      );
      s.sep.finish();
      // The user was waiting on this step, so the screen moves on (here: to Timing).
      await settle(tester, until: () => find.byType(TapScreen).evaluate().isNotEmpty);
      await goTo(tester, WizardStep.vocals);
      expect(shown('Vocal splitting finished'), isTrue);
      expect(find.text('Cancel'), findsNothing);
      expect(File('${s.dir.path}/instrumental.mp3').existsSync(), isTrue);
    });

    testWidgets('nothing_runs_when_the_files_already_exist', (tester) async {
      final s = await pumpSong(tester, source: true, instrumental: true);
      await goTo(tester, WizardStep.vocals);
      expect(shown('Vocal splitting finished'), isTrue);
      expect(
        s.ensureCalls,
        0,
        reason: 'no tools are needed to open a finished song',
      );
      expect(s.imports, isEmpty);
      expect(s.seps, isEmpty);
    });

    testWidgets('only_the_separation_runs_when_the_song_was_already_read', (
      tester,
    ) async {
      final s = await pumpSong(tester, source: true);
      await settle(tester, until: () => s.seps.isNotEmpty);
      expect(s.imports, isEmpty);
      s.sep.finish();
      // Whoever waits on this step is moved on; the result is still shown on the step.
      await settle(tester, until: () => jobs.length == 0);
      await goTo(tester, WizardStep.vocals);
      expect(shown('Vocal splitting finished'), isTrue);
    });

    testWidgets('import_failure_shows_the_message_and_retry_works', (
      tester,
    ) async {
      final s = await pumpSong(
        tester,
        importError: ImportException('No audio track in this file'),
      );
      await settle(tester, until: () => shown('No audio track in this file'));
      expect(shown('Could not read the song'), isTrue);
      expect(find.text('Retry'), findsOneWidget);
      expect(s.seps, isEmpty, reason: 'no separation after a failed import');
      s.importError = null;
      await tester.tap(find.text('Retry'));
      await settle(tester, until: () => s.seps.length == 1);
      expect(s.imports, hasLength(2));
      await goTo(tester, WizardStep.vocals);
      s.sep.finish();
      // Whoever waits on this step is moved on; the result is still shown on the step.
      await settle(tester, until: () => jobs.length == 0);
      await goTo(tester, WizardStep.vocals);
      expect(shown('Vocal splitting finished'), isTrue);
    });

    testWidgets('separation_failure_shows_the_error_and_retry_starts_again', (
      tester,
    ) async {
      final s = await pumpSong(tester);
      await settle(tester, until: () => s.seps.isNotEmpty);
      await goTo(tester, WizardStep.vocals);
      s.sep.fail(ProcessFailure(2, const ['model missing']));
      await settle(tester, until: () => shown('Vocal splitting failed'));
      expect(shown('model missing'), isTrue);
      await tester.tap(find.text('Retry'));
      await settle(tester, until: () => s.seps.length == 2);
      expect(shown('Splitting vocals'), isTrue);
      s.sep.finish();
      // Whoever waits on this step is moved on; the result is still shown on the step.
      await settle(tester, until: () => jobs.length == 0);
      await goTo(tester, WizardStep.vocals);
      expect(shown('Vocal splitting finished'), isTrue);
    });

    testWidgets('cancel_button_stops_the_job_and_start_again_runs_a_new_one', (
      tester,
    ) async {
      final s = await pumpSong(tester);
      await settle(tester, until: () => s.seps.isNotEmpty);
      await goTo(tester, WizardStep.vocals);
      await tester.tap(find.text('Cancel'));
      await settle(tester, until: () => shown('Vocal splitting was cancelled'));
      expect(s.sep.cancelled, isTrue);
      await tester.tap(find.text('Start again'));
      await settle(tester, until: () => s.seps.length == 2);
      expect(
        s.imports,
        hasLength(1),
        reason: 'the song is not read a second time',
      );
      s.sep.finish();
      // Whoever waits on this step is moved on; the result is still shown on the step.
      await settle(tester, until: () => jobs.length == 0);
      await goTo(tester, WizardStep.vocals);
      expect(shown('Vocal splitting finished'), isTrue);
    });

    testWidgets(
      'leaving_the_screen_cancels_the_job_and_still_saves_what_was_typed',
      (tester) async {
        final s = await pumpSong(tester);
        await settle(tester, until: () => s.seps.isNotEmpty);
        expect(jobs.length, 1);
        await goTo(tester, WizardStep.details);
        await typeInto(tester, 'title', 'Typed just now');
        await tester.pumpWidget(
          const SizedBox(),
        ); // leave before the save delay has passed
        expect(s.sep.cancelled, isTrue);
        await settle(
          tester,
          until: () => s.json()['title'] == 'Typed just now',
          describe: s.describe,
        );
        await settle(tester, until: () => jobs.length == 0);
      },
    );
  });

  group('lyrics and details', () {
    testWidgets('typing_lyrics_keeps_the_taps_of_unchanged_lines_and_saves', (
      tester,
    ) async {
      final s = await pumpSong(
        tester,
        configure: (p) => named(p)
          ..lyrics = 'a\nb'
          ..times = [1, 2],
        source: true,
        instrumental: true,
      );
      await goTo(tester, WizardStep.lyrics);
      await typeInto(tester, 'lyrics', 'a\nX');
      await settle(
        tester,
        until: () => s.json()['lyrics'] == 'a\nX',
        describe: s.describe,
      );
      expect(s.json()['times'], [1.0, null]);
    });

    testWidgets('details_are_saved', (tester) async {
      final s = await pumpSong(tester, source: true, instrumental: true);
      await typeInto(tester, 'title', 'Song');
      await typeInto(tester, 'artist', 'Singer');
      await typeInto(tester, 'composer', 'Comp');
      await typeInto(tester, 'lyricist', 'Lyr');
      await settle(
        tester,
        until: () => s.json()['lyricist'] == 'Lyr',
        describe: s.describe,
      );
      expect(s.json()['title'], 'Song');
      expect(s.json()['artist'], 'Singer');
      expect(s.json()['composer'], 'Comp');
    });

    testWidgets('the_number_field_takes_digits_only', (tester) async {
      final s = await pumpSong(tester, source: true, instrumental: true);
      await typeInto(tester, 'number', 'ab12c3');
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('number')))
            .controller!
            .text,
        '123',
      );
      await settle(
        tester,
        until: () => s.json()['number'] == 123,
        describe: s.describe,
      );
      await typeInto(tester, 'number', '');
      await settle(
        tester,
        until: () => s.json()['number'] == null,
        describe: s.describe,
      );
    });

    testWidgets('title_and_artist_are_single_line_fields', (tester) async {
      await pumpSong(tester, source: true, instrumental: true);
      for (final k in ['title', 'artist', 'composer', 'lyricist']) {
        expect(
          tester.widget<TextField>(find.byKey(ValueKey(k))).maxLines,
          1,
          reason: k,
        );
      }
    });
  });

  group('ai timing', () {
    const keys = AppSettings(
      cloudflareAccountId: 'acc',
      cloudflareToken: 'tok',
      cloudflareVerified: true,
    );

    HeardWord heard(String w, double t, {double confidence = 1}) =>
        HeardWord(word: w, start: t, end: t + 0.3, confidence: confidence);

    Future<Song> aiSong(
      WidgetTester tester, {
      AppSettings settings = keys,
      String lyrics = 'a b\nc d',
      List<HeardWord>? words,
      Object? error,
      bool vocals = true,
    }) => pumpSong(
      tester,
      configure: (p) => named(p)..lyrics = lyrics,
      source: true,
      instrumental: true,
      vocals: vocals,
      aiSettings: settings,
      aiTranscribe: (bytes, s) async {
        if (error != null) throw error;
        return words ?? [heard('a', 1), heard('b', 2), heard('c', 3), heard('d', 4)];
      },
    );

    Future<void> press(WidgetTester tester, String key) async {
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await tester.tap(find.byKey(ValueKey(key)));
      await settle(tester, seconds: 1);
    }

    Future<void> toReview(WidgetTester tester) async {
      await press(tester, 'ai-time');
      await press(tester, 'ai-send');
      await settle(tester, until: () => find.byKey(const ValueKey('ai-review')).evaluate().isNotEmpty);
    }

    testWidgets('ai_button_hidden_without_keys', (tester) async {
      await aiSong(tester, settings: const AppSettings());
      expect(find.byType(TapScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-time')), findsNothing);
    });

    testWidgets('ai_button_hidden_when_not_verified', (tester) async {
      await aiSong(
        tester,
        settings: const AppSettings(cloudflareAccountId: 'acc', cloudflareToken: 'tok'),
      );
      expect(find.byType(TapScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-time')), findsNothing);
    });

    testWidgets('ai_button_shown_when_ready', (tester) async {
      await aiSong(tester);
      expect(find.byKey(const ValueKey('ai-time')), findsOneWidget);
    });

    testWidgets('ai_consent_cancel_sends_nothing', (tester) async {
      final s = await aiSong(tester);
      await press(tester, 'ai-time');
      expect(find.byKey(const ValueKey('ai-consent')), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await settle(tester, seconds: 1);
      expect(s.aiBytes, isEmpty);
      expect(find.byKey(const ValueKey('ai-review')), findsNothing);
    });

    testWidgets('ai_times_the_words', (tester) async {
      final s = await aiSong(tester);
      await toReview(tester);
      expect(find.textContaining('4 of 4'), findsOneWidget);
      await press(tester, 'ai-apply');
      await settle(tester, until: () => s.json()['timingSource'] == 'ai');
      final times = (s.json()['times'] as List).cast<num>();
      expect(times[0], closeTo(1 - aiLeadSeconds, 1e-6));
      expect(times[1], closeTo(3 - aiLeadSeconds, 1e-6));
      expect((s.json()['wordTimes'] as List)[1], hasLength(2));
      expect(find.text('2/2 words'), findsNWidgets(2));
    });

    testWidgets('ai_review_names_the_unheard_lines', (tester) async {
      await aiSong(tester, words: [heard('c', 3), heard('d', 4)]);
      await toReview(tester);
      expect(find.textContaining('No word of line 1'), findsOneWidget);
    });

    testWidgets('ai_review_has_no_warning_when_all_lines_were_heard', (tester) async {
      await aiSong(tester);
      await toReview(tester);
      expect(find.textContaining('was heard'), findsNothing);
    });

    testWidgets('ai_missing_words_can_be_unticked', (tester) async {
      final words = [
        heard('a', 1), heard('b', 2), heard('c', 3), heard('d', 4), heard('x', 5), heard('e', 6), heard('f', 7),
      ];
      final s = await aiSong(tester, lyrics: 'a b\ne f', words: words);
      await toReview(tester);
      expect(find.byKey(const ValueKey('ai-add-0')), findsOneWidget);
      expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('ai-add-0'))).value, isTrue);
      await tester.tap(find.byKey(const ValueKey('ai-add-0')));
      await tester.pump();
      await press(tester, 'ai-apply');
      await settle(tester, until: () => s.json()['timingSource'] == 'ai');
      expect(s.json()['lyrics'], 'a b\ne f');
    });

    testWidgets('ai_missing_words_are_added_and_timed', (tester) async {
      final words = [
        heard('a', 1), heard('b', 2), heard('c', 3), heard('d', 4), heard('x', 5), heard('e', 6), heard('f', 7),
      ];
      final s = await aiSong(tester, lyrics: 'a b\ne f', words: words);
      await toReview(tester);
      await press(tester, 'ai-apply');
      await settle(tester, until: () => s.json()['timingSource'] == 'ai');
      expect(s.json()['lyrics'], 'a b\nC d x\ne f');
      final times = (s.json()['times'] as List).cast<num>();
      expect(times, hasLength(3));
      expect(times[1], closeTo(3 - aiLeadSeconds, 1e-6));
    });

    testWidgets('ai_error_is_shown', (tester) async {
      final s = await aiSong(tester, error: const AiTimingException('Cloudflare is down'));
      await press(tester, 'ai-time');
      await press(tester, 'ai-send');
      await settle(tester, until: () => shown('Cloudflare is down'));
      expect(s.json()['timingSource'], 'tapped');
      expect(find.byKey(const ValueKey('ai-review')), findsNothing);
      expect(find.byKey(const ValueKey('ai-busy')), findsNothing);
    });

    testWidgets('ai_cancel_in_the_review_changes_nothing', (tester) async {
      final s = await aiSong(tester);
      await toReview(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await settle(tester, seconds: 1);
      expect(s.json()['timingSource'], 'tapped');
      expect((s.json()['times'] as List).every((t) => t == null), isTrue);
    });

    testWidgets('ai_then_tap_marks_corrected', (tester) async {
      final s = await aiSong(tester);
      await toReview(tester);
      await press(tester, 'ai-apply');
      await settle(tester, until: () => s.json()['timingSource'] == 'ai');
      await tester.tap(find.byKey(const ValueKey('line-1')));
      await settle(tester, until: () => s.json()['timingSource'] == 'ai+tapped');
    });

    testWidgets('ai_sends_the_vocals', (tester) async {
      final a = await aiSong(tester);
      await press(tester, 'ai-time');
      await press(tester, 'ai-send');
      await settle(tester, until: () => a.aiBytes.isNotEmpty);
      expect(a.aiBytes.single, [5, 5], reason: 'vocals.mp3');
    });

    testWidgets('ai_button_disabled_until_the_vocals_exist', (tester) async {
      await aiSong(tester, vocals: false);
      final button = find.byKey(const ValueKey('ai-time'));
      expect(button, findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(button).onPressed, isNull);
    });
  });

  group('timing', () {
    testWidgets('tap_screen_appears_with_source_and_lyrics', (tester) async {
      await pumpSong(
        tester,
        configure: (p) => named(p).lyrics = 'a\nb',
        source: true,
        instrumental: true,
      );
      expect(find.byType(TapScreen), findsOneWidget);
    });

    testWidgets('source_without_lyrics_asks_for_lyrics', (tester) async {
      await pumpSong(
        tester,
        configure: named,
        source: true,
        instrumental: true,
      );
      // The wizard asks for the lyrics by not opening Timing before them.
      await goTo(tester, WizardStep.timing);
      expect(find.byType(TapScreen), findsNothing);
      expect(find.byKey(const ValueKey('lyrics')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('wizard-next')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('lyrics_without_the_song_say_it_is_not_ready', (tester) async {
      await pumpSong(
        tester,
        configure: (p) => named(p).lyrics = 'a\nb',
        importError: ImportException('No audio track in this file'),
      );
      await settle(tester, until: () => shown('No audio track in this file'));
      // Timing cannot be opened before the song has been read.
      await goTo(tester, WizardStep.timing);
      expect(find.byType(TapScreen), findsNothing);
      expect(shown('Could not read the song'), isTrue);
    });

    testWidgets('taps_are_saved', (tester) async {
      final s = await pumpSong(
        tester,
        configure: (p) => named(p).lyrics = 'a\nb',
        source: true,
        instrumental: true,
      );
      s.player.moveTo(const Duration(milliseconds: 4200));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await settle(
        tester,
        until: () => (s.json()['times'] as List).any((t) => t != null),
        describe: s.describe,
      );
      expect(s.json()['times'], [4.2, null]);
    });

    testWidgets('a_tap_while_the_lyrics_are_being_edited_is_ignored', (
      tester,
    ) async {
      final s = await pumpSong(
        tester,
        configure: (p) => named(p)
          ..lyrics = 'a\nb'
          ..times = [1, null],
        source: true,
        instrumental: true,
      );
      await goTo(tester, WizardStep.lyrics);
      await typeInto(tester, 'lyrics', 'a\nX\nc');
      // Straight on, before the save delay: the tap screen must already show the
      // new lines, so no tap can be matched to the old two.
      await goTo(tester, WizardStep.timing);
      expect(find.text('X'), findsOneWidget);
      expect(find.text('c'), findsOneWidget);
      await settle(
        tester,
        until: () => s.json()['lyrics'] == 'a\nX\nc',
        describe: s.describe,
      );
      expect(s.json()['times'], [
        1.0,
        null,
        null,
      ], reason: 'times belong to the new three lines, not the old two');
    });

    testWidgets('the_offset_is_saved', (tester) async {
      final s = await pumpSong(
        tester,
        configure: (p) => named(p).lyrics = 'a\nb',
        source: true,
        instrumental: true,
      );
      tester.widget<Slider>(find.byKey(const ValueKey('offset'))).onChanged!(
        -0.25,
      );
      await tester.pump();
      await settle(
        tester,
        until: () => s.json()['offset'] == -0.25,
        describe: s.describe,
      );
    });

    testWidgets('word_times_are_saved', (tester) async {
      final s = await pumpSong(
        tester,
        configure: (p) => named(p)
          ..lyrics = 'a b\nc d'
          ..times = [1, 2],
        source: true,
        instrumental: true,
      );
      await goTo(tester, WizardStep.timing);
      await tester.tap(find.byKey(const ValueKey('word-mode')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('line-0')));
      await tester.pump();
      s.player.position = const Duration(milliseconds: 1500);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await settle(
        tester,
        until: () =>
            s.json()['wordTimes'] != null &&
            (s.json()['wordTimes'] as List).any((w) => w != null),
        describe: s.describe,
      );
      expect(s.json()['wordTimes'], [
        [1.5, null],
        null,
      ]);
    });

    testWidgets('editing_the_lyrics_keeps_the_word_times_of_kept_lines', (
      tester,
    ) async {
      final s = await pumpSong(
        tester,
        configure: (p) => named(p)
          ..lyrics = 'a b\nc d'
          ..times = [1, 2]
          ..wordTimes = [
            [1.0, 1.5],
            [2.0, 2.5],
          ],
        source: true,
        instrumental: true,
      );
      await goTo(tester, WizardStep.lyrics);
      await typeInto(tester, 'lyrics', 'a b\nX Y');
      await settle(
        tester,
        until: () => s.json()['lyrics'] == 'a b\nX Y',
        describe: s.describe,
      );
      expect(s.json()['wordTimes'], [
        [1.0, 1.5],
        null,
      ]);
    });

    testWidgets(
      'editing_the_lyrics_rebuilds_the_tap_screen_with_the_kept_taps',
      (tester) async {
        final s = await pumpSong(
          tester,
          configure: (p) => named(p)
            ..lyrics = 'a\nb'
            ..times = [1, 2],
          source: true,
          instrumental: true,
        );
        await goTo(tester, WizardStep.lyrics);
        await typeInto(tester, 'lyrics', 'a\nX\nc');
        await goTo(tester, WizardStep.timing);
        await settle(tester, until: () => find.text('X').evaluate().isNotEmpty);
        await settle(
          tester,
          until: () => s.json()['lyrics'] == 'a\nX\nc',
          describe: s.describe,
        );
        expect(find.text('c'), findsOneWidget);
        expect(
          find.text('00:01.00'),
          findsOneWidget,
          reason: 'the kept tap of line a',
        );
        expect(s.json()['times'], [1.0, null, null]);
      },
    );
  });

  group('export', () {
    testWidgets('blockers_are_listed_and_the_button_is_off', (tester) async {
      // Export opens once every step before it is done or, for vocal splitting,
      // running: what can still be missing there is the instrumental.
      final s = await pumpSong(tester, configure: tappedSong, source: true);
      await settle(tester, until: () => s.seps.isNotEmpty);
      await goTo(tester, WizardStep.export);
      expect(shown('Split vocals: still running'), isTrue);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Export .karmp3'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('the_button_turns_on_when_nothing_is_missing', (tester) async {
      await pumpSong(
        tester,
        configure: tappedSong,
        source: true,
        instrumental: true,
      );
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Export .karmp3'),
      );
      expect(button.onPressed, isNotNull);
      expect(shown('is required'), isFalse);
    });

    testWidgets('the_blockers_follow_what_is_typed', (tester) async {
      await pumpSong(
        tester,
        configure: tappedSong,
        source: true,
        instrumental: true,
      );
      await goTo(tester, WizardStep.details);
      await typeInto(tester, 'title', '   ');
      await goTo(tester, WizardStep.export);
      expect(
        find.widgetWithText(FilledButton, 'Export .karmp3'),
        findsNothing,
        reason: 'a blank title keeps Export closed',
      );
      await typeInto(tester, 'title', 'Back');
      await goTo(tester, WizardStep.export);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Export .karmp3'),
            )
            .onPressed,
        isNotNull,
      );
      expect(shown('Title is required'), isFalse);
    });

    testWidgets('export_flow', (tester) async {
      final s = await pumpSong(
        tester,
        configure: tappedSong,
        source: true,
        instrumental: true,
      );
      s.savePath = '${s.root.path}/out.karmp3';
      await tester.tap(find.widgetWithText(FilledButton, 'Export .karmp3'));
      await settle(
        tester,
        until: () => File(s.savePath!).existsSync() && shown('Exported'),
      );
      expect(s.suggested, ['A - T.karmp3']);
      expect(s.durationFiles.map(p.normalize), [
        p.normalize('${s.dir.path}/instrumental.mp3'),
      ]);
      final zip = ZipDecoder().decodeBytes(File(s.savePath!).readAsBytesSync());
      expect(zip.files.map((f) => f.name), [
        'A - T.mp3',
        'A - T.lrc',
        'A - T.nfo',
      ]);
      expect(zip.files.first.content, [9, 9]);
      expect(
        utf8.decode(zip.files[1].content),
        '[ti:T]\n[ar:A]\n[00:01.00]a\n[00:02.00]b\n',
      );
      await tester.pump(
        const Duration(seconds: 1),
      ); // the snack bar has slid in
      await tester.tap(find.text('Show'));
      await tester.pump();
      expect(s.revealed, [s.savePath]);
    });

    testWidgets('export_name_has_the_songbook_number', (tester) async {
      final s = await pumpSong(
        tester,
        configure: (p) => tappedSong(p).number = 7,
        source: true,
        instrumental: true,
      );
      s.savePath = null;
      await tester.tap(find.widgetWithText(FilledButton, 'Export .karmp3'));
      await settle(tester, until: () => s.suggested.isNotEmpty);
      expect(s.suggested.single, '00007 - A - T.karmp3');
    });

    testWidgets('export_adds_the_extension_when_the_dialog_does_not', (
      tester,
    ) async {
      final s = await pumpSong(
        tester,
        configure: tappedSong,
        source: true,
        instrumental: true,
      );
      s.savePath = '${s.root.path}/plain';
      await tester.tap(find.widgetWithText(FilledButton, 'Export .karmp3'));
      await settle(
        tester,
        until: () => File('${s.root.path}/plain.karmp3').existsSync(),
      );
      expect(File('${s.root.path}/plain').existsSync(), isFalse);
    });

    testWidgets('cancelling_the_save_dialog_exports_nothing', (tester) async {
      final s = await pumpSong(
        tester,
        configure: tappedSong,
        source: true,
        instrumental: true,
      );
      s.savePath = null;
      await tester.tap(find.widgetWithText(FilledButton, 'Export .karmp3'));
      await settle(tester, until: () => s.suggested.isNotEmpty);
      await settle(tester);
      expect(s.durationFiles, isEmpty);
      expect(shown('Exported'), isFalse);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Export .karmp3'),
            )
            .onPressed,
        isNotNull,
        reason: 'the button works again',
      );
    });

    testWidgets('export_failure_is_shown_and_the_button_works_again', (
      tester,
    ) async {
      final s = await pumpSong(
        tester,
        configure: tappedSong,
        source: true,
        instrumental: true,
      );
      s.savePath = '${s.root.path}/out.karmp3';
      s.durationError = StateError('ffprobe broke');
      await tester.tap(find.widgetWithText(FilledButton, 'Export .karmp3'));
      await settle(tester, until: () => shown('Export failed'));
      expect(shown('ffprobe broke'), isTrue);
      expect(File(s.savePath!).existsSync(), isFalse);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Export .karmp3'),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('export_asks_for_the_tools_when_the_song_was_opened_finished', (
      tester,
    ) async {
      final s = await pumpSong(
        tester,
        configure: tappedSong,
        source: true,
        instrumental: true,
      );
      expect(s.ensureCalls, 0);
      s.savePath = '${s.root.path}/out.karmp3';
      await tester.tap(find.widgetWithText(FilledButton, 'Export .karmp3'));
      await settle(tester, until: () => File(s.savePath!).existsSync());
      expect(s.ensureCalls, 1);
    });

    testWidgets('export_without_the_tools_says_so', (tester) async {
      final s = await pumpSong(
        tester,
        configure: tappedSong,
        source: true,
        instrumental: true,
      );
      s.toolsResult = null;
      s.savePath = '${s.root.path}/out.karmp3';
      await tester.tap(find.widgetWithText(FilledButton, 'Export .karmp3'));
      await settle(
        tester,
        until: () => shown('Tools are needed to read the song length'),
      );
      expect(File(s.savePath!).existsSync(), isFalse);
    });
  });

  group('revealCommand', () {
    test('reveal_command', () {
      expect(revealCommand(HostOs.macos, '/a b/x.karmp3'), [
        'open',
        '-R',
        '/a b/x.karmp3',
      ]);
      expect(revealCommand(HostOs.windows, r'C:\a b\x.karmp3'), [
        'explorer',
        r'/select,C:\a b\x.karmp3',
      ]);
      expect(revealCommand(HostOs.linux, '/a b/x.karmp3'), [
        'xdg-open',
        '/a b',
      ]);
    });
  });

  group('find lyrics', () {
    const found = LyricsCandidate(
      title: 'T',
      artist: 'A',
      album: '',
      lyrics: 'a\nX\nc',
    );

    /// A finder that records its calls.
    (List<(String, String)>, LyricsFinder) recording(
      Future<List<LyricsCandidate>> Function() answer,
    ) {
      final calls = <(String, String)>[];
      return (
        calls,
        (t, a) {
          calls.add((t, a));
          return answer();
        },
      );
    }

    Future<void> tapAndWait(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    String lyricsBox(WidgetTester tester) => tester
        .widget<TextField>(find.byKey(const ValueKey('lyrics')))
        .controller!
        .text;

    testWidgets('picking_synced_lyrics_pre_times_the_lines', (tester) async {
      final s = await pumpSong(
        tester,
        configure: named,
        source: true,
        instrumental: true,
        lyricsFinder: (t, a) async => [
          const LyricsCandidate(
            title: 'T',
            artist: 'A',
            album: '',
            lyrics: 'a\nb',
            synced: [(1.0, 'a'), (2.0, 'b')],
          ),
        ],
      );
      await tapAndWait(tester, 'lyrics-result-0');
      await settle(
        tester,
        until: () => s.json()['lyrics'] == 'a\nb',
        describe: s.describe,
      );
      expect(s.json()['times'], [1.0, 2.0]);
      expect(s.json()['timingSource'], 'lrclib');
      await goTo(tester, WizardStep.timing);
      expect(find.byKey(const ValueKey('timing-from-lrclib')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('timing-status'))).data,
        'All 2 lines tapped',
      );
    });

    testWidgets('a_tap_marks_the_timing_corrected', (tester) async {
      final s = await pumpSong(
        tester,
        configure: (p) => named(p)
          ..lyrics = 'a\nb'
          ..times = [1.0, 2.0]
          ..timingSource = 'lrclib',
        source: true,
        instrumental: true,
      );
      await goTo(tester, WizardStep.timing);
      await settle(tester, until: () => find.byType(TapScreen).evaluate().isNotEmpty);
      expect(s.json()['timingSource'], 'lrclib', reason: 'looking is not correcting');
      // A change on the tap screen (here the tap offset) is a correction by hand.
      tester.widget<Slider>(find.byKey(const ValueKey('offset'))).onChanged!(-0.25);
      await tester.pump();
      await settle(
        tester,
        until: () => s.json()['timingSource'] == 'lrclib+tapped',
        describe: s.describe,
      );
    });

    testWidgets('picking_synced_lyrics_drops_the_old_word_times', (tester) async {
      final s = await pumpSong(
        tester,
        configure: (p) => named(p)
          ..lyrics = 'a b\nc d'
          ..times = [1, 2]
          ..wordTimes = [
            [1.0, 1.5],
            [2.0, 2.5],
          ],
        source: true,
        instrumental: true,
        lyricsFinder: (t, a) async => [
          const LyricsCandidate(
            title: 'T',
            artist: 'A',
            album: '',
            lyrics: 'a b\nX Y',
            synced: [(5.0, 'a b'), (6.0, 'X Y')],
          ),
        ],
      );
      await goTo(tester, WizardStep.lyrics);
      await tapAndWait(tester, 'lyrics-search');
      await tapAndWait(tester, 'lyrics-result-0');
      await tapAndWait(tester, 'lyrics-replace');
      await settle(
        tester,
        until: () => s.json()['lyrics'] == 'a b\nX Y',
        describe: s.describe,
      );
      expect(s.json()['times'], [5.0, 6.0]);
      expect(s.json()['wordTimes'], [null, null]);
    });

    testWidgets('the_note_stays_after_a_correction', (tester) async {
      final s = await pumpSong(
        tester,
        configure: (p) => named(p)
          ..lyrics = 'a\nb'
          ..times = [1.0, 2.0]
          ..timingSource = 'lrclib',
        source: true,
        instrumental: true,
      );
      await goTo(tester, WizardStep.timing);
      await settle(tester, until: () => find.byType(TapScreen).evaluate().isNotEmpty);
      tester.widget<Slider>(find.byKey(const ValueKey('offset'))).onChanged!(-0.25);
      await tester.pump();
      await settle(
        tester,
        until: () => s.json()['timingSource'] == 'lrclib+tapped',
        describe: s.describe,
      );
      expect(find.byKey(const ValueKey('timing-from-lrclib')), findsOneWidget);
    });

    testWidgets('no_lrclib_note_for_hand_tapped_timing', (tester) async {
      await pumpSong(
        tester,
        configure: (p) => named(p)
          ..lyrics = 'a\nb'
          ..times = [1.0, 2.0],
        source: true,
        instrumental: true,
      );
      await goTo(tester, WizardStep.timing);
      await settle(tester, until: () => find.byType(TapScreen).evaluate().isNotEmpty);
      expect(find.byKey(const ValueKey('timing-from-lrclib')), findsNothing);
    });

    testWidgets('picking_plain_lyrics_resets_the_source', (tester) async {
      final s = await pumpSong(
        tester,
        configure: (p) => named(p)
          ..lyrics = 'old'
          ..times = [1.0]
          ..timingSource = 'lrclib',
        source: true,
        instrumental: true,
        lyricsFinder: (t, a) async => [found],
      );
      await goTo(tester, WizardStep.lyrics);
      await tapAndWait(tester, 'lyrics-search');
      await tapAndWait(tester, 'lyrics-result-0');
      await tapAndWait(tester, 'lyrics-replace');
      await settle(
        tester,
        until: () => s.json()['lyrics'] == 'a\nX\nc',
        describe: s.describe,
      );
      expect(s.json()['timingSource'], 'tapped');
    });

    testWidgets('lyrics_step_searches_automatically_once', (tester) async {
      final (calls, finder) = recording(() async => [found]);
      await pumpSong(
        tester,
        configure: named,
        source: true,
        instrumental: true,
        lyricsFinder: finder,
      );
      expect(find.byKey(const ValueKey('lyrics')), findsOneWidget);
      expect(calls, [('T', 'A')]);
      await goTo(tester, WizardStep.details);
      await goTo(tester, WizardStep.lyrics);
      await tester.pump();
      expect(
        calls,
        hasLength(1),
        reason: 'same title and artist: no new search',
      );
    });

    testWidgets('lyrics_ranked_by_audio_length', (tester) async {
      LyricsCandidate version(double seconds) => LyricsCandidate(
        title: 'T',
        artist: 'A',
        album: '',
        lyrics: 'la la',
        seconds: seconds,
      );
      // The fake audio is 61.4 s long (Song.duration).
      final s = await pumpSong(
        tester,
        configure: named,
        source: true,
        lyricsFinder: (t, a) async => [version(300), version(62)],
      );
      await settle(tester, until: () => s.seps.isNotEmpty);
      await goTo(tester, WizardStep.lyrics);
      await settle(tester, until: () => find.byKey(const ValueKey('lyrics-result-0')).evaluate().isNotEmpty);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('lyrics-result-0')),
          matching: find.textContaining('1:02'),
        ),
        findsOneWidget,
      );
      expect(s.durationFiles, [endsWith('source.mp3')]);
    });

    testWidgets('lyrics_unranked_when_length_unknown', (tester) async {
      LyricsCandidate version(double seconds) => LyricsCandidate(
        title: 'T',
        artist: 'A',
        album: '',
        lyrics: 'la la',
        seconds: seconds,
      );
      final s = await pumpSong(
        tester,
        configure: named,
        source: true,
        durationError: StateError('no ffprobe'),
        lyricsFinder: (t, a) async => [version(300), version(62)],
      );
      await settle(tester, until: () => s.seps.isNotEmpty);
      await goTo(tester, WizardStep.lyrics);
      await settle(tester, until: () => find.byKey(const ValueKey('lyrics-result-0')).evaluate().isNotEmpty);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('lyrics-result-0')),
          matching: find.textContaining('5:00'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('lyrics_step_does_not_search_when_there_are_lyrics', (
      tester,
    ) async {
      final (calls, finder) = recording(() async => [found]);
      await pumpSong(
        tester,
        configure: (p) => named(p).lyrics = 'a',
        source: true,
        instrumental: true,
        lyricsFinder: finder,
      );
      await goTo(tester, WizardStep.lyrics);
      await tester.pump();
      expect(calls, isEmpty);
      await tapAndWait(tester, 'lyrics-search');
      expect(calls, hasLength(1));
    });

    testWidgets('picked_lyrics_fill_the_box_and_save', (tester) async {
      final s = await pumpSong(
        tester,
        configure: named,
        source: true,
        instrumental: true,
        lyricsFinder: (t, a) async => [found],
      );
      await tapAndWait(tester, 'lyrics-result-0');
      expect(shown('Replace the current lyrics'), isFalse);
      expect(lyricsBox(tester), 'a\nX\nc');
      await settle(
        tester,
        until: () => s.json()['lyrics'] == 'a\nX\nc',
        describe: s.describe,
      );
    });

    testWidgets('picking_over_typed_lyrics_asks_first', (tester) async {
      final s = await pumpSong(
        tester,
        configure: named,
        source: true,
        instrumental: true,
        lyricsFinder: (t, a) async => [found],
      );
      await typeInto(tester, 'lyrics', 'x');
      await tapAndWait(tester, 'lyrics-search');
      await tapAndWait(tester, 'lyrics-result-0');
      expect(shown('Replace the current lyrics'), isTrue);
      await tapAndWait(tester, 'lyrics-keep');
      expect(lyricsBox(tester), 'x');
      await tapAndWait(tester, 'lyrics-search');
      await tapAndWait(tester, 'lyrics-result-0');
      await tapAndWait(tester, 'lyrics-replace');
      expect(lyricsBox(tester), 'a\nX\nc');
      await settle(
        tester,
        until: () => s.json()['lyrics'] == 'a\nX\nc',
        describe: s.describe,
      );
    });

    testWidgets('find_lyrics_keeps_taps_of_unchanged_lines', (tester) async {
      final s = await pumpSong(
        tester,
        configure: (p) => named(p)
          ..lyrics = 'a\nb'
          ..times = [1.0, 2.0],
        source: true,
        instrumental: true,
        lyricsFinder: (t, a) async => [
          const LyricsCandidate(
            title: 'T',
            artist: 'A',
            album: '',
            lyrics: 'a\nX',
          ),
        ],
      );
      await goTo(tester, WizardStep.lyrics);
      await tapAndWait(tester, 'lyrics-search');
      await tapAndWait(tester, 'lyrics-result-0');
      await tapAndWait(tester, 'lyrics-replace');
      await settle(
        tester,
        until: () => s.json()['lyrics'] == 'a\nX',
        describe: s.describe,
      );
      expect(s.json()['times'], [1.0, null]);
    });

    testWidgets('find_lyrics_error_does_not_touch_the_lyrics', (tester) async {
      await pumpSong(
        tester,
        configure: (p) => named(p)..lyrics = 'old',
        source: true,
        instrumental: true,
        lyricsFinder: (t, a) async =>
            throw const LyricsLookupException('server is busy'),
      );
      await goTo(tester, WizardStep.lyrics);
      await tapAndWait(tester, 'lyrics-search');
      expect(shown('server is busy'), isTrue);
      expect(lyricsBox(tester), 'old');
    });
  });

  group('wizard', () {
    FilledButton next(WidgetTester tester) =>
        tester.widget<FilledButton>(find.byKey(const ValueKey('wizard-next')));

    Finder strip(String text) => find.descendant(
      of: find.byKey(const ValueKey('vocals-status')),
      matching: find.textContaining(text),
    );

    testWidgets('new_song_opens_on_the_song_step', (tester) async {
      // The import never finishes in this test, so no separation starts.
      final s = await pumpSong(tester, importGate: Completer<void>());
      await settle(tester, until: () => s.imports.isNotEmpty);
      expect(shown('File: in.mp4'), isTrue);
      expect(shown('Reading the song...'), isTrue);
    });

    testWidgets('next_waits_for_the_import', (tester) async {
      final gate = Completer<void>();
      final s = await pumpSong(tester, importGate: gate);
      await settle(tester, until: () => s.imports.isNotEmpty);
      expect(next(tester).onPressed, isNull);
      gate.complete();
      await settle(tester, until: () => next(tester).onPressed != null);
      await settle(tester, until: () => s.seps.isNotEmpty);
      s.sep.finish();
      await settle(tester, until: () => jobs.length == 0);
    });

    testWidgets('reopened_song_opens_on_the_first_unfinished_step', (
      tester,
    ) async {
      await pumpSong(
        tester,
        configure: named,
        source: true,
        instrumental: true,
      );
      expect(find.byKey(const ValueKey('lyrics')), findsOneWidget);
      expect(find.byKey(const ValueKey('title')), findsNothing);
    });

    testWidgets('next_works_while_vocals_are_removed', (tester) async {
      final s = await pumpSong(tester, source: true);
      await settle(tester, until: () => s.seps.isNotEmpty);
      expect(next(tester).onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('wizard-next')));
      await tester.pump();
      expect(find.byKey(const ValueKey('title')), findsOneWidget);
      expect(strip('Splitting vocals'), findsOneWidget);
      s.sep.finish();
      await settle(
        tester,
        until: () =>
            find.byKey(const ValueKey('vocals-status')).evaluate().isEmpty,
      );
    });

    testWidgets('moves_on_after_splitting', (tester) async {
      final s = await pumpSong(
        tester,
        configure: tappedSong,
        source: true,
      );
      await settle(tester, until: () => s.seps.isNotEmpty);
      await goTo(tester, WizardStep.vocals);
      expect(shown('Splitting vocals'), isTrue);
      s.sep.finish();
      await settle(
        tester,
        until: () => find.byKey(const ValueKey('export-name')).evaluate().isNotEmpty,
      );
      expect(find.byKey(const ValueKey('export-name')), findsOneWidget);
    });

    testWidgets('moves_to_lyrics_when_they_are_missing', (tester) async {
      final s = await pumpSong(tester, configure: named, source: true);
      await settle(tester, until: () => s.seps.isNotEmpty);
      await goTo(tester, WizardStep.vocals);
      s.sep.finish();
      await settle(
        tester,
        until: () => find.byKey(const ValueKey('lyrics')).evaluate().isNotEmpty,
      );
      expect(find.byKey(const ValueKey('lyrics')), findsOneWidget);
    });

    testWidgets('stays_where_the_user_went', (tester) async {
      final s = await pumpSong(tester, configure: tappedSong, source: true);
      await settle(tester, until: () => s.seps.isNotEmpty);
      await goTo(tester, WizardStep.details);
      expect(find.byKey(const ValueKey('title')), findsOneWidget);
      s.sep.finish();
      await settle(tester, until: () => jobs.length == 0);
      expect(find.byKey(const ValueKey('title')), findsOneWidget);
      expect(find.byKey(const ValueKey('export-name')), findsNothing);
    });

    testWidgets('no_move_when_splitting_fails', (tester) async {
      final s = await pumpSong(tester, configure: tappedSong, source: true);
      await settle(tester, until: () => s.seps.isNotEmpty);
      await goTo(tester, WizardStep.vocals);
      s.sep.fail(StateError('boom'));
      await settle(tester, until: () => shown('boom'));
      expect(find.byKey(const ValueKey('export-name')), findsNothing);
    });

    testWidgets('separation_failure_shows_on_other_steps', (tester) async {
      final s = await pumpSong(tester, source: true);
      await settle(tester, until: () => s.seps.isNotEmpty);
      await goTo(tester, WizardStep.details);
      expect(find.byKey(const ValueKey('title')), findsOneWidget);
      s.sep.fail(StateError('boom'));
      await settle(
        tester,
        until: () => strip('Vocal splitting failed').evaluate().isNotEmpty,
      );
      await tester.tap(find.byKey(const ValueKey('vocals-status-show')));
      await tester.pump();
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('back_goes_to_the_previous_step', (tester) async {
      await pumpSong(tester, source: true, instrumental: true);
      expect(find.byKey(const ValueKey('title')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('wizard-back')));
      await tester.pump();
      expect(shown('Vocal splitting finished'), isTrue);
      expect(find.byKey(const ValueKey('title')), findsNothing);
    });

    testWidgets('header_skips_steps_that_are_not_ready', (tester) async {
      final s = await pumpSong(
        tester,
        configure: (p) => p.lyrics = 'a',
        source: true,
      );
      await settle(tester, until: () => s.seps.isNotEmpty);
      await goTo(tester, WizardStep.export);
      expect(find.widgetWithText(FilledButton, 'Export .karmp3'), findsNothing);
      await goTo(tester, WizardStep.details);
      expect(find.byKey(const ValueKey('title')), findsOneWidget);
      s.sep.finish();
      await settle(tester, until: () => jobs.length == 0);
    });

    testWidgets('tags_fill_blank_title_and_artist', (tester) async {
      final s = await pumpSong(
        tester,
        tagsFn: (tools, input) async => (title: 'Tag T', artist: 'Tag A'),
      );
      await settle(
        tester,
        until: () => s.json()['title'] == 'Tag T',
        describe: s.describe,
      );
      expect(s.json()['artist'], 'Tag A');
      await goTo(tester, WizardStep.details);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('artist')))
            .controller!
            .text,
        'Tag A',
      );
      s.sep.finish();
      await settle(tester, until: () => jobs.length == 0);
    });

    testWidgets('tags_never_overwrite_typed_values', (tester) async {
      final s = await pumpSong(
        tester,
        configure: (p) => p.title = 'Mine',
        tagsFn: (tools, input) async => (title: 'Tag T', artist: 'Tag A'),
      );
      await settle(
        tester,
        until: () => s.json()['artist'] == 'Tag A',
        describe: s.describe,
      );
      expect(s.json()['title'], 'Mine');
      s.sep.finish();
      await settle(tester, until: () => jobs.length == 0);
    });

    testWidgets('tags_never_overwrite_a_typed_artist', (tester) async {
      final s = await pumpSong(
        tester,
        configure: (p) => p.artist = 'Mine',
        tagsFn: (tools, input) async => (title: 'Tag T', artist: 'Tag A'),
      );
      await settle(
        tester,
        until: () => s.json()['title'] == 'Tag T',
        describe: s.describe,
      );
      expect(s.json()['artist'], 'Mine');
      s.sep.finish();
      await settle(tester, until: () => jobs.length == 0);
    });

    testWidgets('cancelled_vocal_removal_shows_on_other_steps', (tester) async {
      final s = await pumpSong(tester, source: true);
      await settle(tester, until: () => s.seps.isNotEmpty);
      await goTo(tester, WizardStep.details);
      s.sep.cancel();
      await settle(
        tester,
        until: () => strip('Vocal splitting was cancelled').evaluate().isNotEmpty,
      );
      await tester.tap(find.byKey(const ValueKey('vocals-status-show')));
      await tester.pump();
      expect(find.text('Start again'), findsOneWidget);
    });

    testWidgets('tags_failure_is_ignored', (tester) async {
      var asked = false;
      final s = await pumpSong(
        tester,
        tagsFn: (tools, input) {
          asked = true;
          throw StateError('no tags');
        },
      );
      await settle(tester, until: () => asked && s.seps.isNotEmpty);
      await settle(tester);
      expect(find.byType(SnackBar), findsNothing);
      expect(s.json()['title'], '');
      expect(shown('Audio ready'), isTrue);
      s.sep.finish();
      await settle(tester, until: () => jobs.length == 0);
    });

    testWidgets('timing_step_gives_the_tap_screen_the_full_height', (
      tester,
    ) async {
      await pumpSong(
        tester,
        configure: (p) => named(p).lyrics = 'a\nb',
        source: true,
        instrumental: true,
      );
      expect(tester.getSize(find.byType(TapScreen)).height, greaterThan(560));
    });

    testWidgets('timing_step_scrolls_when_the_window_is_small', (tester) async {
      await pumpSong(
        tester,
        configure: (p) => named(p).lyrics = 'a\nb\nc\nd\ne\nf\ng\nh',
        source: true,
        instrumental: true,
      );
      await tester.binding.setSurfaceSize(const Size(640, 480));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(TapScreen)).height,
        greaterThanOrEqualTo(300),
      );
    });
  });

  group('timing and export steps', () {
    String statusText(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const ValueKey('timing-status'))).data!;

    testWidgets('timing_status_counts_the_lines', (tester) async {
      await pumpSong(
        tester,
        configure: tappedSong,
        source: true,
        instrumental: true,
      );
      await goTo(tester, WizardStep.timing);
      expect(statusText(tester), 'All 2 lines tapped');
      await pumpSong(
        tester,
        configure: (p) => tappedSong(p).times = [1.0, null],
        source: true,
        instrumental: true,
      );
      expect(statusText(tester), '1 line(s) not tapped yet');
    });

    testWidgets('export_step_shows_the_file_name', (tester) async {
      await pumpSong(
        tester,
        configure: (p) => tappedSong(p).number = 12,
        source: true,
        instrumental: true,
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('export-name'))).data,
        'File name: ${karMp3Name(number: 12, artist: 'A', title: 'T')}.karmp3',
      );
    });

    // Export opens only when every earlier step is done or running, so a step can
    // become unfinished there only by vocal splitting failing after it was opened.
    testWidgets('export_lists_unfinished_steps_with_a_way_there', (
      tester,
    ) async {
      final s = await pumpSong(tester, configure: tappedSong, source: true);
      await settle(tester, until: () => s.seps.isNotEmpty);
      await goTo(tester, WizardStep.export);
      s.sep.fail(StateError('boom'));
      await settle(tester, until: () => shown('Split vocals: not finished'));
      await tester.tap(find.byKey(const ValueKey('fix-vocals')));
      await tester.pump();
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('export_says_vocals_are_still_running', (tester) async {
      final s = await pumpSong(tester, configure: tappedSong, source: true);
      await settle(tester, until: () => s.seps.isNotEmpty);
      await goTo(tester, WizardStep.export);
      expect(shown('Split vocals: still running'), isTrue);
      expect(find.byKey(const ValueKey('fix-vocals')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Export .karmp3'),
            )
            .onPressed,
        isNull,
      );
      s.sep.finish();
      await settle(tester, until: () => jobs.length == 0);
    });

    Future<void> exportAndWaitForToast(WidgetTester tester) async {
      final s = await pumpSong(
        tester,
        configure: tappedSong,
        source: true,
        instrumental: true,
      );
      s.savePath = '${s.root.path}/out.karmp3';
      await tester.tap(find.widgetWithText(FilledButton, 'Export .karmp3'));
      await settle(
        tester,
        until: () => find.byType(SnackBar).evaluate().isNotEmpty,
      );
    }

    testWidgets('export_toast_closes_by_itself_after_3_seconds', (
      tester,
    ) async {
      await exportAndWaitForToast(tester);
      // The 3 s start once the toast has slid in; the exit takes a moment too.
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(SnackBar), findsOneWidget, reason: 'not before 3 s');
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('export_toast_has_a_close_button', (tester) async {
      await exportAndWaitForToast(tester);
      await tester.pump(const Duration(seconds: 1)); // let it slide in
      await tester.tap(find.descendant(
        of: find.byType(SnackBar),
        matching: find.byIcon(Icons.close),
      ));
      // One pump slides it out, the next removes it.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('after_export_show_and_finish', (tester) async {
      final s = await pumpSong(
        tester,
        configure: tappedSong,
        source: true,
        instrumental: true,
        onTopOfHome: true,
      );
      s.savePath = '${s.root.path}/out.karmp3';
      await tester.tap(find.widgetWithText(FilledButton, 'Export .karmp3'));
      await settle(
        tester,
        until: () =>
            find.byKey(const ValueKey('export-done')).evaluate().isNotEmpty,
      );
      expect(shown('Exported out.karmp3'), isTrue);
      await tester.tap(find.byKey(const ValueKey('export-show')));
      await tester.pump();
      expect(s.revealed, [s.savePath]);
      await tester.tap(find.byKey(const ValueKey('wizard-finish')));
      await settle(
        tester,
        until: () => find.byType(SongScreen).evaluate().isEmpty,
      );
      expect(find.text('home route'), findsOneWidget);
    });
  });

  group('vocals option', () {
    Finder exportButton() =>
        find.widgetWithText(FilledButton, 'Export .karmp3');
    bool exportEnabled(WidgetTester tester) =>
        tester.widget<FilledButton>(exportButton()).onPressed != null;
    bool ticked(WidgetTester tester) => tester
        .widget<CheckboxListTile>(find.byKey(const ValueKey('export-vocals')))
        .value!;
    SongProject vocalsOn(SongProject p) => tappedSong(p)..includeVocals = true;

    testWidgets('vocals_option_is_off_and_saved', (tester) async {
      final s = await pumpSong(
        tester,
        configure: tappedSong,
        source: true,
        instrumental: true,
        vocals: true,
      );
      expect(ticked(tester), isFalse);
      await tester.tap(find.byKey(const ValueKey('export-vocals')));
      await tester.pump();
      await settle(
        tester,
        until: () => s.json()['includeVocals'] == true,
        describe: s.describe,
      );
      expect(ticked(tester), isTrue);
    });

    testWidgets('export_with_the_vocals_ticked', (tester) async {
      final s = await pumpSong(
        tester,
        configure: vocalsOn,
        source: true,
        instrumental: true,
        vocals: true,
      );
      s.savePath = '${s.root.path}/out.karmp3';
      await tester.tap(exportButton());
      await settle(tester, until: () => File(s.savePath!).existsSync());
      final zip = ZipDecoder().decodeBytes(File(s.savePath!).readAsBytesSync());
      expect(zip.files.map((f) => f.name), [
        'A - T.mp3',
        'A - T.lrc',
        'A - T.nfo',
        'A - T.vocals.mp3',
      ]);
      expect(zip.files.last.content, [5, 5]);
    });

    testWidgets('old_song_offers_to_run_vocal_removal_again', (tester) async {
      final s = await pumpSong(
        tester,
        configure: vocalsOn,
        source: true,
        instrumental: true,
      );
      expect(find.byKey(const ValueKey('vocals-missing')), findsOneWidget);
      expect(exportEnabled(tester), isFalse);
      await tester.tap(find.byKey(const ValueKey('vocals-rerun')));
      await tester.pump();
      await settle(tester, until: () => s.seps.length == 1);
      s.sep.finish();
      await settle(
        tester,
        until: () =>
            find.byKey(const ValueKey('vocals-missing')).evaluate().isEmpty &&
            exportEnabled(tester),
      );
      expect(File('${s.dir.path}/vocals.mp3').existsSync(), isTrue);
    });

    testWidgets('rerun_button_is_hidden_while_it_runs', (tester) async {
      final s = await pumpSong(
        tester,
        configure: vocalsOn,
        source: true,
        instrumental: true,
      );
      await tester.tap(find.byKey(const ValueKey('vocals-rerun')));
      await tester.pump();
      await settle(tester, until: () => s.seps.length == 1);
      expect(find.byKey(const ValueKey('vocals-rerun')), findsNothing);
      expect(find.byKey(const ValueKey('vocals-missing')), findsNothing);
      expect(s.seps, hasLength(1));
      s.sep.finish();
      await settle(tester, until: () => jobs.length == 0);
    });

    testWidgets('no_rerun_note_without_an_instrumental', (tester) async {
      final s = await pumpSong(tester, configure: vocalsOn, source: true);
      await settle(tester, until: () => s.seps.length == 1);
      await goTo(tester, WizardStep.export);
      s.sep.fail(StateError('x'));
      await settle(
        tester,
        until: () =>
            find.byKey(const ValueKey('vocals-status')).evaluate().isNotEmpty,
      );
      expect(find.byKey(const ValueKey('vocals-missing')), findsNothing);
      expect(find.byKey(const ValueKey('vocals-rerun')), findsNothing);
      expect(shown('Split vocals: not finished'), isTrue);
    });

    testWidgets('failed_rerun_keeps_the_old_instrumental', (tester) async {
      final s = await pumpSong(
        tester,
        configure: vocalsOn,
        source: true,
        instrumental: true,
      );
      await tester.tap(find.byKey(const ValueKey('vocals-rerun')));
      await tester.pump();
      await settle(tester, until: () => s.seps.length == 1);
      s.sep.fail(StateError('x'));
      await settle(
        tester,
        until: () =>
            find.byKey(const ValueKey('vocals-status')).evaluate().isNotEmpty,
      );
      expect(shown('Vocal splitting failed'), isTrue);
      await tester.tap(find.byKey(const ValueKey('export-vocals')));
      await tester.pump();
      expect(ticked(tester), isFalse);
      expect(
        exportEnabled(tester),
        isTrue,
        reason: 'the old instrumental still counts',
      );
    });

    testWidgets('unticking_removes_the_note', (tester) async {
      await pumpSong(
        tester,
        configure: vocalsOn,
        source: true,
        instrumental: true,
      );
      expect(find.byKey(const ValueKey('vocals-missing')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('export-vocals')));
      await tester.pump();
      expect(find.byKey(const ValueKey('vocals-missing')), findsNothing);
      expect(exportEnabled(tester), isTrue);
    });
  });

  group('spotify link', () {
    const link = 'https://open.spotify.com/track/4u7EnebtmKWzUH433cf5Qv?si=x1';
    const track = SpotifyTrack(id: 'i', title: 'New', artist: 'Singer', seconds: 200);

    AutofillResult result({
      String composer = 'C',
      String lyricist = 'L',
      List<(double?, String)> lines = const [],
      String timingSource = 'tapped',
      String note = '',
    }) => AutofillResult(
      title: 'New',
      artist: 'Singer',
      composer: composer,
      lyricist: lyricist,
      lines: lines,
      timingSource: timingSource,
      note: note,
    );

    /// A song at the Details step with spotifyFinder and autofill recorded.
    Future<
      ({
        Song song,
        List<String> links,
        List<double?> lengths,
      })
    >
    pump(
      WidgetTester tester, {
      void Function(SongProject)? configure,
      bool source = false,
      AutofillResult? answer,
      Object? finderError,
    }) async {
      final links = <String>[];
      final lengths = <double?>[];
      final s = await pumpSong(
        tester,
        configure: (p) {
          named(p)
            ..title = 'Old'
            ..artist = 'Someone';
          configure?.call(p);
        },
        source: source,
        instrumental: source,
        spotifyFinder: (l) async {
          links.add(l);
          if (finderError != null) throw finderError;
          return track;
        },
        autofill: (t, audio) async {
          lengths.add(await audio);
          return answer ?? result();
        },
      );
      await goTo(tester, WizardStep.details);
      return (song: s, links: links, lengths: lengths);
    }

    Future<void> paste(WidgetTester tester, String text) async {
      await typeInto(tester, 'spotify-link', text);
      await tester.pump();
    }

    testWidgets('pasting_a_link_fills_details', (tester) async {
      final r = await pump(tester);
      await paste(tester, 'Listen: $link');
      await settle(tester, until: () => r.song.json()['title'] == 'New');
      expect(r.links, ['Listen: $link']);
      expect(r.song.json()['artist'], 'Singer');
      expect(r.song.json()['composer'], 'C');
      expect(r.song.json()['lyricist'], 'L');
      expect(
        tester.widget<TextField>(find.byKey(const ValueKey('title'))).controller!.text,
        'New',
      );
      expect(
        tester.widget<TextField>(find.byKey(const ValueKey('artist'))).controller!.text,
        'Singer',
      );
    });

    testWidgets('typed_composer_is_kept', (tester) async {
      final r = await pump(tester, configure: (p) => p.composer = 'Mine');
      await paste(tester, link);
      await settle(tester, until: () => r.song.json()['title'] == 'New');
      expect(r.song.json()['composer'], 'Mine');
      expect(r.song.json()['lyricist'], 'L');
    });

    testWidgets('timed_lyrics_fill_an_empty_box', (tester) async {
      final r = await pump(
        tester,
        answer: result(
          lines: const [(1.0, 'la la'), (2.5, 'na na')],
          timingSource: 'lrclib',
        ),
      );
      await paste(tester, link);
      await settle(tester, until: () => r.song.json()['title'] == 'New');
      final j = r.song.json();
      expect(j['lyrics'], 'la la\nna na');
      expect(j['times'], [1.0, 2.5]);
      expect(j['timingSource'], 'lrclib');
    });

    testWidgets('plain_lyrics_fill_an_empty_box_untimed', (tester) async {
      final r = await pump(
        tester,
        answer: result(lines: const [(null, 'la la'), (null, 'na na')]),
      );
      await paste(tester, link);
      await settle(tester, until: () => r.song.json()['title'] == 'New');
      final j = r.song.json();
      expect(j['lyrics'], 'la la\nna na');
      expect(j['times'], [null, null]);
      expect(j['timingSource'], 'tapped');
    });

    testWidgets('existing_lyrics_are_kept', (tester) async {
      final r = await pump(
        tester,
        configure: (p) => p.lyrics = 'my words',
        answer: result(lines: const [(null, 'la la')]),
      );
      await paste(tester, link);
      await settle(tester, until: () => r.song.json()['title'] == 'New');
      expect(r.song.json()['lyrics'], 'my words');
    });

    testWidgets('the_note_is_shown', (tester) async {
      final r = await pump(tester, answer: result(note: 'Tap the timing.'));
      await paste(tester, link);
      await settle(tester, until: () => r.song.json()['title'] == 'New');
      expect(shown('Filled in from Spotify'), isTrue);
      expect(shown('Tap the timing.'), isTrue);
    });

    testWidgets('audio_length_comes_from_source_mp3', (tester) async {
      final r = await pump(tester, source: true);
      // An MP3 whose Info tag says 1000 frames of 1152 samples at 44100 Hz (26.122 s).
      List<int> u32(int v) => [v >> 24 & 255, v >> 16 & 255, v >> 8 & 255, v & 255];
      File('${r.song.dir.path}/source.mp3').writeAsBytesSync([
        0xFF, 0xFB, 0x70, 0x00, ...List.filled(32, 0),
        ...'Info'.codeUnits, ...u32(3), ...u32(1000), ...u32(313000),
        ...List.filled(100, 0),
      ]);
      await paste(tester, link);
      await settle(tester, until: () => r.lengths.isNotEmpty);
      expect(r.lengths.single, closeTo(26.122, 0.001));
    });

    testWidgets('length_unknown_without_a_source', (tester) async {
      final r = await pump(tester);
      await paste(tester, link);
      await settle(tester, until: () => r.lengths.isNotEmpty);
      expect(r.lengths.single, isNull);
    });

    testWidgets('error_shows_message', (tester) async {
      final r = await pump(
        tester,
        finderError: const SpotifyLinkException('Spotify has no song with this link'),
      );
      await paste(tester, link);
      await settle(
        tester,
        until: () => shown('Spotify: Spotify has no song with this link'),
      );
      expect(r.song.json()['title'], 'Old');
      expect(r.song.json()['artist'], 'Someone');
    });

    testWidgets('text_without_a_link_does_nothing', (tester) async {
      final r = await pump(tester);
      await paste(tester, 'hello');
      await tester.tap(find.byKey(const ValueKey('spotify-get')));
      await tester.pump();
      expect(r.links, isEmpty);
      expect(r.song.json()['title'], 'Old');
    });

    testWidgets('same_text_is_not_run_again_by_itself', (tester) async {
      final r = await pump(tester);
      await paste(tester, link);
      await settle(tester, until: () => r.song.json()['title'] == 'New');
      await paste(tester, '$link ');
      await paste(tester, link);
      await tester.pump(const Duration(milliseconds: 200));
      expect(r.links, hasLength(1));
      // The button runs it again by hand.
      await tester.tap(find.byKey(const ValueKey('spotify-get')));
      await settle(tester, until: () => r.links.length == 2);
    });

    testWidgets('the_link_is_not_saved', (tester) async {
      final r = await pump(tester);
      await paste(tester, link);
      await settle(tester, until: () => r.song.json()['title'] == 'New');
      expect(
        r.song.json().keys.where((k) => k.toLowerCase().contains('spotify')),
        isEmpty,
      );
      expect(readText(File('${r.song.dir.path}/project.json')), isNot(contains('4u7Eneb')));
    });
  });

  group('song info', () {
    const found = SongInfoCandidate(
      title: 'Song',
      artist: 'Singer',
      album: 'Album',
      year: '1999',
      recordingId: 'r1',
    );

    /// A finder that records its calls.
    (List<(String, String)>, SongInfoFinder) recording(
      List<SongInfoCandidate> answer,
    ) {
      final calls = <(String, String)>[];
      return (
        calls,
        (t, a) async {
          calls.add((t, a));
          return answer;
        },
      );
    }

    testWidgets('details_step_searches_automatically_once', (tester) async {
      final (calls, finder) = recording([found]);
      await pumpSong(
        tester,
        source: true,
        instrumental: true,
        songInfoFinder: finder,
      );
      expect(find.byKey(const ValueKey('title')), findsOneWidget);
      expect(calls, [('in', '')]);
      await goTo(tester, WizardStep.vocals);
      await goTo(tester, WizardStep.details);
      await tester.pump();
      expect(calls, hasLength(1), reason: 'same query: no new search');
    });

    testWidgets('search_uses_the_typed_title', (tester) async {
      final (calls, finder) = recording([found]);
      await pumpSong(
        tester,
        configure: named,
        source: true,
        instrumental: true,
        songInfoFinder: finder,
      );
      await goTo(tester, WizardStep.details);
      await tester.pump();
      expect(calls, [('T', 'A')]);
    });

    testWidgets('picking_fills_names_and_blank_credits', (tester) async {
      final asked = <String>[];
      final s = await pumpSong(
        tester,
        configure: (p) => p.composer = 'Mine',
        source: true,
        instrumental: true,
        songInfoFinder: (t, a) async => [found],
        songInfoDetailsFn: (id) async {
          asked.add(id);
          return (composer: 'C', lyricist: 'L');
        },
      );
      await tester.tap(find.byKey(const ValueKey('info-result-0')));
      await tester.pump();
      await settle(
        tester,
        until: () => s.json()['lyricist'] == 'L',
        describe: s.describe,
      );
      expect(s.json()['title'], 'Song');
      expect(s.json()['artist'], 'Singer');
      expect(s.json()['composer'], 'Mine');
      expect(asked, ['r1']);
    });

    String textOf(WidgetTester tester, String key) => tester
        .widget<TextField>(find.byKey(ValueKey(key)))
        .controller!
        .text;

    testWidgets('picking_updates_the_text_fields', (tester) async {
      await pumpSong(
        tester,
        source: true,
        instrumental: true,
        songInfoFinder: (t, a) async => [found],
        songInfoDetailsFn: (id) async => (composer: 'C', lyricist: 'L'),
      );
      await tester.tap(find.byKey(const ValueKey('info-result-0')));
      await tester.pump();
      await settle(tester, until: () => textOf(tester, 'lyricist') == 'L');
      expect(textOf(tester, 'title'), 'Song');
      expect(textOf(tester, 'artist'), 'Singer');
      expect(textOf(tester, 'composer'), 'C');
    });

    testWidgets('picking_keeps_a_typed_lyricist', (tester) async {
      final s = await pumpSong(
        tester,
        configure: (p) => p.lyricist = 'Mine',
        source: true,
        instrumental: true,
        songInfoFinder: (t, a) async => [found],
        songInfoDetailsFn: (id) async => (composer: 'C', lyricist: 'L'),
      );
      await tester.tap(find.byKey(const ValueKey('info-result-0')));
      await tester.pump();
      await settle(
        tester,
        until: () => s.json()['composer'] == 'C',
        describe: s.describe,
      );
      expect(s.json()['lyricist'], 'Mine');
      expect(textOf(tester, 'lyricist'), 'Mine');
    });

    testWidgets('the_spinner_goes_when_the_details_are_in', (tester) async {
      final credits = Completer<({String composer, String lyricist})>();
      await pumpSong(
        tester,
        source: true,
        instrumental: true,
        songInfoFinder: (t, a) async => [found],
        songInfoDetailsFn: (id) => credits.future,
      );
      await tester.tap(find.byKey(const ValueKey('info-result-0')));
      await tester.pump();
      expect(find.byKey(const ValueKey('info-loading')), findsOneWidget);
      credits.complete((composer: '', lyricist: ''));
      await settle(
        tester,
        until: () =>
            find.byKey(const ValueKey('info-loading')).evaluate().isEmpty,
      );
    });

    testWidgets('details_failure_still_applies_names', (tester) async {
      final s = await pumpSong(
        tester,
        source: true,
        instrumental: true,
        songInfoFinder: (t, a) async => [found],
        songInfoDetailsFn: (id) async => throw StateError('down'),
      );
      await tester.tap(find.byKey(const ValueKey('info-result-0')));
      await tester.pump();
      await settle(
        tester,
        until: () => shown('Could not get the composer and lyricist'),
      );
      await settle(
        tester,
        until: () => s.json()['title'] == 'Song',
        describe: s.describe,
      );
      expect(s.json()['artist'], 'Singer');
    });
  });

  group('opened song', () {
    SongProject opened(SongProject p) => p
      ..inputPath = '/x/a.karmp3'
      ..karmp3Path = '/x/a.karmp3'
      ..audioFromKarmp3 = true;

    testWidgets('opened_song_without_vocals_needs_nothing', (tester) async {
      final s = await pumpSong(
        tester,
        configure: opened,
        instrumental: true,
        openedSource: true,
      );
      await goTo(tester, WizardStep.song);
      expect(shown('Opened from a.karmp3'), isTrue);
      expect(shown('The audio is the one in the file'), isTrue);
      expect(shown('File: '), isFalse);
      expect(s.ensureCalls, 0, reason: 'no tools are needed');
      expect(s.imports, isEmpty);
      expect(s.seps, isEmpty);
      expect(s.mixes, isEmpty);
    });

    testWidgets('opened_song_with_vocals_makes_the_source', (tester) async {
      final s = await pumpSong(
        tester,
        configure: (p) => tappedSong(opened(p))..includeVocals = true,
        instrumental: true,
        vocals: true,
      );
      await settle(tester, until: () => File('${s.dir.path}/source.mp3').existsSync());
      expect(s.mixes, [s.dir.path]);
      expect(s.ensureCalls, 1);
      expect(s.imports, isEmpty);
      expect(s.seps, isEmpty);
      await settle(tester, until: () => !shown('Preparing the song for timing'));
      await goTo(tester, WizardStep.timing);
      expect(find.byType(TapScreen), findsOneWidget);
    });

    testWidgets('opened_song_source_failure_shows_retry', (tester) async {
      final s = await pumpSong(
        tester,
        configure: (p) => opened(p)..includeVocals = true,
        instrumental: true,
        vocals: true,
        mixFailures: 1,
      );
      await settle(
        tester,
        until: () => shown('Could not prepare the song for timing'),
      );
      expect(shown('mix failed'), isTrue);
      expect(find.text('Retry'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await settle(tester, until: () => File('${s.dir.path}/source.mp3').existsSync());
      expect(s.mixes, hasLength(2));
    });

    testWidgets('opened_song_opens_on_export_when_complete', (tester) async {
      await pumpSong(
        tester,
        configure: (p) => tappedSong(opened(p)),
        instrumental: true,
        openedSource: true,
      );
      expect(find.byKey(const ValueKey('export-name')), findsOneWidget);
    });

    testWidgets('opened_song_without_its_instrumental_says_so', (tester) async {
      final s = await pumpSong(
        tester,
        configure: opened,
        openedSource: true,
      );
      await settle(tester, until: () => shown('The audio of this song is missing'));
      expect(s.seps, isEmpty, reason: 'there is nothing to split from');
      expect(s.imports, isEmpty);
    });

    testWidgets('a_normal_song_is_unchanged', (tester) async {
      final s = await pumpSong(tester, source: true, instrumental: true);
      await goTo(tester, WizardStep.song);
      expect(shown('File: in.mp4'), isTrue);
      expect(shown('Opened from'), isFalse);
      expect(s.mixes, isEmpty);
    });
  });

  group('replace the audio', () {
    SongProject opened(SongProject p) => tappedSong(p)
      ..inputPath = '/x/a.karmp3'
      ..karmp3Path = '/x/a.karmp3'
      ..audioFromKarmp3 = true
      ..separator = 'Old-Model'
      ..includeVocals = true;

    /// An opened song with its stems and a source, as after opening a file with vocals.
    Future<Song> pumpOpened(WidgetTester tester, {String? picks = '/x/new.mp3'}) =>
        pumpSong(
          tester,
          configure: opened,
          instrumental: true,
          vocals: true,
          openedSource: true,
          pickAudio: () async => picks,
        );

    Future<void> replaceWith(WidgetTester tester) async {
      await goTo(tester, WizardStep.song);
      await tester.tap(find.byKey(const ValueKey('replace-audio')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('replace_button_only_for_opened_songs', (tester) async {
      await pumpSong(tester, source: true, instrumental: true);
      await goTo(tester, WizardStep.song);
      expect(find.byKey(const ValueKey('replace-audio')), findsNothing);
      await pumpSong(tester, configure: opened, instrumental: true, vocals: true, openedSource: true);
      await goTo(tester, WizardStep.song);
      expect(find.byKey(const ValueKey('replace-audio')), findsOneWidget);
      expect(find.text('Replace the audio...'), findsOneWidget);
    });

    testWidgets('replace_audio_runs_import_and_split', (tester) async {
      final s = await pumpOpened(tester);
      await replaceWith(tester);
      expect(
        shown('The song is read from new.mp3 and split again'),
        isTrue,
        reason: 'the user is told first',
      );
      await tester.tap(find.byKey(const ValueKey('replace-audio-go')));
      await settle(tester, until: () => s.seps.isNotEmpty);
      expect(s.imports, ['/x/new.mp3']);
      final j = s.json();
      expect(j['inputPath'], '/x/new.mp3');
      expect(j['audioFromKarmp3'], isFalse);
      expect(j['separator'], isNull);
      expect(j['karmp3Path'], '/x/a.karmp3', reason: 'Export can still save over the file');
      expect(j['lyrics'], 'a\nb');
      expect(j['times'], [1.0, 2.0]);
      expect((j['title'], j['artist']), ('T', 'A'));
      s.sep.finish();
      await settle(tester, until: () => jobs.length == 0);
    });

    testWidgets('replace_audio_deletes_the_old_stems', (tester) async {
      final s = await pumpOpened(tester);
      await replaceWith(tester);
      await tester.tap(find.byKey(const ValueKey('replace-audio-go')));
      await settle(tester, until: () => s.seps.isNotEmpty);
      // The split is running and has produced nothing yet: the old files are gone.
      expect(File('${s.dir.path}/instrumental.mp3').existsSync(), isFalse);
      expect(File('${s.dir.path}/vocals.mp3').existsSync(), isFalse);
      s.sep.finish();
      await settle(tester, until: () => jobs.length == 0);
      expect(File('${s.dir.path}/instrumental.mp3').existsSync(), isTrue);
    });

    testWidgets('replace_audio_cancel_changes_nothing', (tester) async {
      final s = await pumpOpened(tester);
      await replaceWith(tester);
      await tester.tap(find.byKey(const ValueKey('replace-audio-cancel')));
      // Real time passes here, so anything that would wrongly go on has time to happen.
      await settle(tester);
      expect(s.imports, isEmpty);
      expect(s.seps, isEmpty);
      expect(File('${s.dir.path}/instrumental.mp3').existsSync(), isTrue);
      expect(File('${s.dir.path}/vocals.mp3').existsSync(), isTrue);
      expect(s.json()['audioFromKarmp3'], isTrue);
    });

    testWidgets('picking_no_file_changes_nothing', (tester) async {
      final s = await pumpOpened(tester, picks: null);
      await goTo(tester, WizardStep.song);
      await tester.tap(find.byKey(const ValueKey('replace-audio')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('replace-audio-go')), findsNothing);
      expect(s.imports, isEmpty);
    });

    testWidgets('replaced_song_is_a_normal_song', (tester) async {
      final s = await pumpOpened(tester);
      await replaceWith(tester);
      await tester.tap(find.byKey(const ValueKey('replace-audio-go')));
      await settle(tester, until: () => s.seps.isNotEmpty);
      expect(shown('File: new.mp3'), isTrue);
      expect(shown('Opened from'), isFalse);
      expect(find.byKey(const ValueKey('replace-audio')), findsNothing);
      s.sep.finish();
      await settle(tester, until: () => jobs.length == 0);
    });

    testWidgets('replace_button_is_disabled_while_the_stems_are_mixed', (tester) async {
      final gate = Completer<void>();
      final s = await pumpSong(
        tester,
        configure: opened,
        instrumental: true,
        vocals: true,
        mixGate: gate,
        pickAudio: () async => '/x/new.mp3',
      );
      await settle(tester, until: () => s.mixes.isNotEmpty);
      await goTo(tester, WizardStep.song);
      expect(
        tester.widget<OutlinedButton>(find.byKey(const ValueKey('replace-audio'))).onPressed,
        isNull,
      );
      gate.complete();
      await settle(
        tester,
        until: () => tester
            .widget<OutlinedButton>(find.byKey(const ValueKey('replace-audio')))
            .onPressed != null,
      );
    });
  });

  group('save over', () {
    /// An old .karmp3 on disk (made the app's way, stand-in MP3), the file the song was
    /// "opened" from.
    Future<String> oldFile(WidgetTester tester) async {
      final dir = Directory.systemTemp.createTempSync('save_over');
      addTearDown(() => deleteTemp(dir));
      final work = Directory('${dir.path}/work')..createSync();
      File('${work.path}/instrumental.mp3').writeAsBytesSync([9, 9]);
      final path = '${dir.path}/a.karmp3';
      await tester.runAsync(
        () => exportKarMp3(
          SongProject(id: 'x', inputPath: '/x/in.mp3')
            ..title = 'T'
            ..artist = 'A'
            ..lyrics = 'old line'
            ..times = [1.0],
          work,
          path,
          durationSeconds: 10,
        ),
      );
      return path;
    }

    /// The song opened from [path] and then edited (new lyrics), on its Export step.
    Future<Song> pumpEdited(WidgetTester tester, String path, {Object? durationError}) =>
        pumpSong(
          tester,
          configure: (p) => tappedSong(p)
            ..lyrics = 'la la\nna na'
            ..inputPath = path
            ..karmp3Path = path
            ..audioFromKarmp3 = true,
          instrumental: true,
          openedSource: true,
          durationError: durationError,
        );

    List<String> lyricsIn(String path) =>
        readKarMp3(File(path).readAsBytesSync()).lines.map((l) => l.text).toList();

    Future<void> tapAndWait(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('save_over_replaces_the_file', (tester) async {
      final path = await oldFile(tester);
      expect(lyricsIn(path), ['old line']);
      final s = await pumpEdited(tester, path);
      await tapAndWait(tester, 'export-save-over');
      expect(shown('Replace a.karmp3?'), isTrue, reason: 'the user is asked first');
      await tapAndWait(tester, 'save-over-go');
      await settle(tester, until: () => lyricsIn(path).length == 2);
      expect(lyricsIn(path), ['la la', 'na na']);
      expect(s.suggested, isEmpty, reason: 'no Save dialog');
      expect(File('$path.part').existsSync(), isFalse);
      await settle(tester, until: () => shown('Saved a.karmp3'));
      expect(find.byKey(const ValueKey('export-done')), findsOneWidget);
    });

    testWidgets('save_over_cancel_keeps_the_file', (tester) async {
      final path = await oldFile(tester);
      final before = File(path).readAsBytesSync();
      final s = await pumpEdited(tester, path);
      await tapAndWait(tester, 'export-save-over');
      await tapAndWait(tester, 'save-over-cancel');
      // About a second passes, pumping all the while: a write that wrongly goes on needs
      // both real time (file work) and pumps (the screen's awaits) to finish.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      }
      expect(File(path).readAsBytesSync(), before);
      expect(s.suggested, isEmpty);
      expect(find.byKey(const ValueKey('export-done')), findsNothing);
    });

    testWidgets('save_over_only_for_opened_songs', (tester) async {
      await pumpSong(tester, configure: tappedSong, source: true, instrumental: true);
      expect(find.byKey(const ValueKey('export-save-over')), findsNothing);
      expect(find.text('Export .karmp3'), findsOneWidget);
      expect(find.byKey(const ValueKey('export-as')), findsNothing);
    });

    testWidgets('export_as_still_asks_and_leaves_the_opened_file', (tester) async {
      final path = await oldFile(tester);
      final before = File(path).readAsBytesSync();
      final s = await pumpEdited(tester, path);
      s.savePath = '${File(path).parent.path}/copy.karmp3';
      expect(find.text('Export as...'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('export-as')));
      await settle(tester, until: () => File(s.savePath!).existsSync());
      expect(s.suggested, hasLength(1));
      expect(lyricsIn(s.savePath!), ['la la', 'na na']);
      expect(File(path).readAsBytesSync(), before);
    });

    testWidgets('save_over_missing_folder', (tester) async {
      final path = await oldFile(tester);
      final folder = File(path).parent;
      final s = await pumpEdited(tester, path);
      deleteTemp(folder);
      await tapAndWait(tester, 'export-save-over');
      await tapAndWait(tester, 'save-over-go');
      await settle(tester, until: () => shown('The folder of a.karmp3 is gone; use Export as...'));
      expect(File(path).existsSync(), isFalse);
      expect(s.durationFiles, isEmpty, reason: 'nothing was started');
    });

    testWidgets('save_over_failure_keeps_the_old_file', (tester) async {
      final path = await oldFile(tester);
      final before = File(path).readAsBytesSync();
      await pumpEdited(tester, path, durationError: StateError('no ffprobe'));
      await tapAndWait(tester, 'export-save-over');
      await tapAndWait(tester, 'save-over-go');
      await settle(tester, until: () => shown('Save failed'));
      expect(File(path).readAsBytesSync(), before);
      expect(File('$path.part').existsSync(), isFalse);
    });
  });

  group('preview', () {
    Future<void> closePreview(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('preview-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('preview_button_opens_the_dialog', (tester) async {
      final s = await pumpSong(
        tester,
        configure: tappedSong,
        source: true,
        instrumental: true,
      );
      await tester.tap(find.byKey(const ValueKey('export-preview')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('preview-dialog')), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('preview-dialog')), matching: find.text('T - A')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('preview-line-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('preview-line-1')), findsOneWidget);
      // The song folder's own instrumental, never source.mp3, and no vocals controls.
      expect(s.player.opened.map((o) => o.path), [p.join(s.dir.path, 'instrumental.mp3')]);
      expect(find.byKey(const ValueKey('preview-vocals')), findsNothing);
      await closePreview(tester);
      expect(find.byKey(const ValueKey('preview-dialog')), findsNothing);
      expect(s.player.disposed, isTrue);
    });

    testWidgets('preview_with_the_vocals_included', (tester) async {
      final s = await pumpSong(
        tester,
        configure: (p) => tappedSong(p)..includeVocals = true,
        source: true,
        instrumental: true,
        vocals: true,
      );
      await tester.tap(find.byKey(const ValueKey('export-preview')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        s.player.opened.map((o) => o.path).toSet(),
        {p.join(s.dir.path, 'instrumental.mp3'), p.join(s.dir.path, 'vocals.mp3')},
      );
      expect(find.byKey(const ValueKey('preview-vocals')), findsOneWidget);
      await closePreview(tester);
    });

    testWidgets('preview_without_the_vocals_ticked_has_none', (tester) async {
      // The song has a vocals file, but the export is without it.
      final s = await pumpSong(
        tester,
        configure: tappedSong,
        source: true,
        instrumental: true,
        vocals: true,
      );
      await tester.tap(find.byKey(const ValueKey('export-preview')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(s.player.opened.map((o) => o.path), [p.join(s.dir.path, 'instrumental.mp3')]);
      expect(find.byKey(const ValueKey('preview-vocals')), findsNothing);
      await closePreview(tester);
    });

    testWidgets('preview_button_disabled_until_ready', (tester) async {
      final s = await pumpSong(tester, configure: tappedSong, source: true);
      await settle(tester, until: () => s.seps.isNotEmpty);
      await goTo(tester, WizardStep.export);
      expect(
        tester.widget<OutlinedButton>(find.byKey(const ValueKey('export-preview'))).onPressed,
        isNull,
        reason: 'vocal splitting is still running',
      );
      s.sep.finish();
      await settle(tester, until: () => jobs.length == 0);
      expect(
        tester.widget<OutlinedButton>(find.byKey(const ValueKey('export-preview'))).onPressed,
        isNotNull,
      );
    });

    testWidgets('preview_matches_the_export', (tester) async {
      final s = await pumpSong(
        tester,
        configure: (p) => tappedSong(p)..offset = 0.2,
        source: true,
        instrumental: true,
      );
      // What the export writes ...
      s.savePath = '${s.dir.path}/out.karmp3';
      await tester.tap(find.text('Export .karmp3'));
      await settle(tester, until: () => find.byKey(const ValueKey('export-done')).evaluate().isNotEmpty);
      final exported = readKarMp3(File(s.savePath!).readAsBytesSync()).lines;
      expect(exported.first.seconds, closeTo(1.2, 1e-9));
      // ... is what the preview jumps to when its first line is tapped.
      await tester.tap(find.byKey(const ValueKey('export-preview')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('preview-line-0')));
      await tester.pump();
      expect(s.player.seeks.last, const Duration(milliseconds: 1200));
      expect(exported.map((l) => l.text), ['a', 'b']);
      await closePreview(tester);
    });
  });
}
