import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/jobs.dart';
import 'package:kantahe_maker/pipeline.dart';
import 'package:kantahe_maker/project.dart';
import 'package:kantahe_maker/screens/song_screen.dart';
import 'package:kantahe_maker/screens/tap_screen.dart';
import 'package:kantahe_maker/tools.dart';

import 'support/fake_player.dart';
import 'support/settle.dart';

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
  String? savePath;
  final suggested = <String>[];
  final revealed = <String>[];
  final player = FakePlayer();

  Map<String, dynamic> json() =>
      jsonDecode(File('${dir.path}/project.json').readAsStringSync())
          as Map<String, dynamic>;

  FakeSepJob get sep => seps.last;
}

Future<Song> pumpSong(
  WidgetTester tester, {
  void Function(SongProject)? configure,
  bool source = false,
  bool instrumental = false,
  bool settleAtOnce = true,
  String? corruptJson,
  bool toolsAvailable = true,
  Object? importError,
}) async {
  final s = Song()
    ..toolsResult = toolsAvailable ? fakeTools : null
    ..importError = importError;
  s.root = Directory.systemTemp.createTempSync('song_test');
  addTearDown(() => s.root.deleteSync(recursive: true));
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
  if (instrumental) {
    File('${s.dir.path}/instrumental.mp3').writeAsBytesSync([9, 9]);
  }
  await tester.binding.setSurfaceSize(const Size(1000, 3600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: SongScreen(
        dir: s.dir,
        saveDelay: const Duration(milliseconds: 50),
        createPlayer: () => s.player,
        ensureToolsFn: (context) async {
          s.ensureCalls++;
          return s.toolsResult;
        },
        importFn: (tools, input, work, onLine) async {
          s.imports.add(input);
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
      ),
    ),
  );
  if (settleAtOnce) await settle(tester);
  return s;
}

bool shown(String text) => find.textContaining(text).evaluate().isNotEmpty;

Future<void> typeInto(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(ValueKey(key)), text);
  await tester.pump();
}

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
      expect(text('title'), 'My Title');
      expect(text('artist'), 'My Artist');
      expect(text('number'), '7');
      expect(text('composer'), 'Comp');
      expect(text('lyricist'), 'Lyr');
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
      s.sep.finish();
      await settle(tester, until: () => shown('Vocal removal finished'));
    });

    testWidgets('import_then_separation_flow', (tester) async {
      final s = await pumpSong(tester, configure: (p) => p.lyrics = 'a\nb');
      await settle(tester, until: () => s.seps.isNotEmpty);
      expect(
        find.byType(TapScreen),
        findsOneWidget,
        reason: 'tapping is possible as soon as the song is read, during vocal removal',
      );
      expect(s.ensureCalls, 1);
      expect(s.imports, ['/x/in.mp4']);
      expect(shown('Removing vocals'), isTrue);
      expect(find.text('Cancel'), findsOneWidget);
      s.sep.emit('size=  120KiB time=00:00:12');
      await tester.pump();
      expect(
        shown('size=  120KiB time=00:00:12'),
        isTrue,
        reason: 'the last output line',
      );
      s.sep.finish();
      await settle(tester, until: () => shown('Vocal removal finished'));
      expect(find.text('Cancel'), findsNothing);
      expect(File('${s.dir.path}/instrumental.mp3').existsSync(), isTrue);
    });

    testWidgets('nothing_runs_when_the_files_already_exist', (tester) async {
      final s = await pumpSong(tester, source: true, instrumental: true);
      expect(shown('Vocal removal finished'), isTrue);
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
      await settle(tester, until: () => shown('Vocal removal finished'));
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
      s.sep.finish();
      await settle(tester, until: () => shown('Vocal removal finished'));
    });

    testWidgets('separation_failure_shows_the_error_and_retry_starts_again', (
      tester,
    ) async {
      final s = await pumpSong(tester);
      await settle(tester, until: () => s.seps.isNotEmpty);
      s.sep.fail(ProcessFailure(2, const ['model missing']));
      await settle(tester, until: () => shown('Vocal removal failed'));
      expect(shown('model missing'), isTrue);
      await tester.tap(find.text('Retry'));
      await settle(tester, until: () => s.seps.length == 2);
      expect(shown('Removing vocals'), isTrue);
      s.sep.finish();
      await settle(tester, until: () => shown('Vocal removal finished'));
    });

    testWidgets('cancel_button_stops_the_job_and_start_again_runs_a_new_one', (
      tester,
    ) async {
      final s = await pumpSong(tester);
      await settle(tester, until: () => s.seps.isNotEmpty);
      await tester.tap(find.text('Cancel'));
      await settle(tester, until: () => shown('Vocal removal was cancelled'));
      expect(s.sep.cancelled, isTrue);
      await tester.tap(find.text('Start again'));
      await settle(tester, until: () => s.seps.length == 2);
      expect(
        s.imports,
        hasLength(1),
        reason: 'the song is not read a second time',
      );
      s.sep.finish();
      await settle(tester, until: () => shown('Vocal removal finished'));
    });

    testWidgets(
      'leaving_the_screen_cancels_the_job_and_still_saves_what_was_typed',
      (tester) async {
        final s = await pumpSong(tester);
        await settle(tester, until: () => s.seps.isNotEmpty);
        expect(jobs.length, 1);
        await typeInto(tester, 'title', 'Typed just now');
        await tester.pumpWidget(
          const SizedBox(),
        ); // leave before the save delay has passed
        expect(s.sep.cancelled, isTrue);
        await settle(
          tester,
          until: () => s.json()['title'] == 'Typed just now',
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
        configure: (p) => p
          ..lyrics = 'a\nb'
          ..times = [1, 2],
        source: true,
        instrumental: true,
      );
      await typeInto(tester, 'lyrics', 'a\nX');
      await settle(tester, until: () => s.json()['lyrics'] == 'a\nX');
      expect(s.json()['times'], [1.0, null]);
    });

    testWidgets('details_are_saved', (tester) async {
      final s = await pumpSong(tester, source: true, instrumental: true);
      await typeInto(tester, 'title', 'Song');
      await typeInto(tester, 'artist', 'Singer');
      await typeInto(tester, 'composer', 'Comp');
      await typeInto(tester, 'lyricist', 'Lyr');
      await settle(tester, until: () => s.json()['lyricist'] == 'Lyr');
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
      await settle(tester, until: () => s.json()['number'] == 123);
      await typeInto(tester, 'number', '');
      await settle(tester, until: () => s.json()['number'] == null);
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

  group('timing', () {
    testWidgets('tap_screen_appears_with_source_and_lyrics', (tester) async {
      await pumpSong(
        tester,
        configure: (p) => p.lyrics = 'a\nb',
        source: true,
        instrumental: true,
      );
      expect(find.byType(TapScreen), findsOneWidget);
    });

    testWidgets('source_without_lyrics_asks_for_lyrics', (tester) async {
      await pumpSong(tester, source: true, instrumental: true);
      expect(find.byType(TapScreen), findsNothing);
      expect(shown('Add the lyrics'), isTrue);
    });

    testWidgets('lyrics_without_the_song_say_it_is_not_ready', (tester) async {
      await pumpSong(
        tester,
        configure: (p) => p.lyrics = 'a\nb',
        importError: ImportException('No audio track in this file'),
      );
      await settle(tester, until: () => shown('No audio track in this file'));
      expect(find.byType(TapScreen), findsNothing);
      expect(shown('not ready yet'), isTrue);
    });

    testWidgets('taps_are_saved', (tester) async {
      final s = await pumpSong(
        tester,
        configure: (p) => p.lyrics = 'a\nb',
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
      );
      expect(s.json()['times'], [4.2, null]);
    });

    testWidgets('a_tap_while_the_lyrics_are_being_edited_is_ignored', (
      tester,
    ) async {
      final s = await pumpSong(
        tester,
        configure: (p) => p
          ..lyrics = 'a\nb'
          ..times = [1, null],
        source: true,
        instrumental: true,
      );
      await typeInto(
        tester,
        'lyrics',
        'a\nX\nc',
      ); // the tap screen still shows a, b
      await tester.tap(
        find.text('a'),
      ); // select(0) on the old lines: would clear [1, ...]
      await tester.pump();
      await settle(tester, until: () => s.json()['lyrics'] == 'a\nX\nc');
      expect(s.json()['times'], [
        1.0,
        null,
        null,
      ], reason: 'times belong to the new three lines, not the old two');
    });

    testWidgets('the_offset_is_saved', (tester) async {
      final s = await pumpSong(
        tester,
        configure: (p) => p.lyrics = 'a\nb',
        source: true,
        instrumental: true,
      );
      tester.widget<Slider>(find.byKey(const ValueKey('offset'))).onChanged!(
        -0.25,
      );
      await tester.pump();
      await settle(tester, until: () => s.json()['offset'] == -0.25);
    });

    testWidgets('word_times_are_saved', (tester) async {
      final s = await pumpSong(
        tester,
        configure: (p) => p
          ..lyrics = 'a b\nc d'
          ..times = [1, 2],
        source: true,
        instrumental: true,
      );
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
      );
      expect(s.json()['wordTimes'], [
        [1.0, 1.5],
        null,
      ]);
    });

    testWidgets('editing_the_lyrics_keeps_the_word_times_of_kept_lines', (
      tester,
    ) async {
      final s = await pumpSong(
        tester,
        configure: (p) => p
          ..lyrics = 'a b\nc d'
          ..times = [1, 2]
          ..wordTimes = [
            [1.0, 1.5],
            [2.0, 2.5],
          ],
        source: true,
        instrumental: true,
      );
      await typeInto(tester, 'lyrics', 'a b\nX Y');
      await settle(tester, until: () => s.json()['lyrics'] == 'a b\nX Y');
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
          configure: (p) => p
            ..lyrics = 'a\nb'
            ..times = [1, 2],
          source: true,
          instrumental: true,
        );
        await typeInto(tester, 'lyrics', 'a\nX\nc');
        await settle(tester, until: () => find.text('X').evaluate().isNotEmpty);
        await settle(tester, until: () => s.json()['lyrics'] == 'a\nX\nc');
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
      await pumpSong(tester, source: true, instrumental: true);
      expect(shown('Add lyrics'), isTrue);
      expect(shown('Title is required'), isTrue);
      expect(shown('Artist is required'), isTrue);
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
      await typeInto(tester, 'title', '   ');
      expect(shown('Title is required'), isTrue);
      await typeInto(tester, 'title', 'Back');
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
      expect(s.durationFiles, ['${s.dir.path}/instrumental.mp3']);
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
}
