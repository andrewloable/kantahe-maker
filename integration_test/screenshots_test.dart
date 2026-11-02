// Makes the screenshots of the README (docs/screenshots) by running the real app on this
// computer with a demo song: the Home list and every wizard step, drawn by the app itself.
// Nothing here uses the network or the real tools, and no personal data: the songs are in
// the public domain and the "online" results are made up from the same data.
//
//   flutter test integration_test/screenshots_test.dart -d macos \
//     --dart-define=SCREENSHOT_DIR="$PWD/docs/screenshots"
//
// (The folder is a dart-define because the app is started by the Flutter tool and has no
// way to know where the repository is.)

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kantahe_maker/branding.dart';
import 'package:kantahe_maker/jobs.dart';
import 'package:kantahe_maker/pipeline.dart';
import 'package:kantahe_maker/lyrics_lookup.dart';
import 'package:kantahe_maker/project.dart';
import 'package:kantahe_maker/screens/home_screen.dart';
import 'package:kantahe_maker/screens/lyrics_search_panel.dart';
import 'package:kantahe_maker/screens/song_info_panel.dart';
import 'package:kantahe_maker/screens/song_screen.dart';
import 'package:kantahe_maker/song_info.dart';
import 'package:kantahe_maker/tools.dart';

import '../test/support/fake_player.dart';

const outDirName = String.fromEnvironment('SCREENSHOT_DIR');

/// The size of every picture, in logical pixels (the files are twice as many pixels).
const shotWidth = 1200.0, shotHeight = 760.0;
const pixelRatio = 2.0;

/// How long the app may take to draw a frame (normally 16 ms; the first one after a build
/// can take a few seconds). When its window is not being drawn (the display asleep or
/// locked, the window covered by other windows) Flutter makes no frames and a pump would
/// wait for ever.
const drawTimeout = Duration(seconds: 20);

Future<void> drawn(Future<void> pending) => pending.timeout(
  drawTimeout,
  onTimeout: () => throw StateError(
    'The app window is not drawing (display asleep or locked, or the window '
    'covered by other windows?). Wake and unlock the display, leave the app '
    'window visible and run the command again.',
  ),
);

const verse = [
  'Amazing grace! How sweet the sound',
  'That saved a wretch like me!',
  'I once was lost, but now am found;',
  'Was blind, but now I see.',
];

const fakeTools = ToolPaths(
  ffmpeg: '/demo/ffmpeg',
  ffprobe: '/demo/ffprobe',
  separator: '/demo/separator',
  modelDir: '/demo/models',
);

/// Vocal removal that never finishes (the screenshot shows it running).
class DemoJob implements CancellableJob {
  final _done = Completer<void>();
  @override
  Future<void> get done => _done.future;
  @override
  void cancel() {
    if (!_done.isCompleted) _done.completeError(const SeparationCancelled());
  }
}

class Shots {
  Shots(this.tester, this.dir, this.work);
  final WidgetTester tester;
  final Directory dir, work;
  final key = GlobalKey();
  final written = <String>[];
  int folders = 0;

  /// A new song folder in the work folder, with the files of the steps already done.
  Future<Directory> song({
    String id = '',
    String title = 'Amazing Grace',
    String artist = 'Traditional',
    int? number = 101,
    String composer = 'John Newton',
    String lyricist = 'John Newton',
    String input = '/demo/amazing-grace.mp4',
    List<String> lyrics = const [],
    List<double?> times = const [],
    bool source = true,
    bool instrumental = true,
    bool vocals = false,
    bool includeVocals = false,
  }) async {
    final name = id.isEmpty ? '20261102-12${(folders++).toString().padLeft(2, '0')}00' : id;
    final d = Directory('${work.path}/$name')..createSync(recursive: true);
    final p = SongProject(id: name, inputPath: input)
      ..title = title
      ..artist = artist
      ..number = number
      ..composer = composer
      ..lyricist = lyricist
      ..lyrics = lyrics.join('\n')
      ..times = List.of(times)
      ..wordTimes = List.filled(times.length, null)
      ..includeVocals = includeVocals;
    await p.save(d);
    if (source) {
      File('${d.path}/source.mp3').writeAsBytesSync([0]);
      File('${d.path}/source.wav').writeAsBytesSync([0]);
    }
    if (instrumental) File('${d.path}/instrumental.mp3').writeAsBytesSync([0]);
    if (vocals) File('${d.path}/vocals.mp3').writeAsBytesSync([0]);
    return d;
  }

  Widget app(Widget home, {Brightness brightness = Brightness.light}) => OverflowBox(
    alignment: Alignment.topLeft,
    minWidth: shotWidth,
    maxWidth: shotWidth,
    minHeight: shotHeight,
    maxHeight: shotHeight,
    child: RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: appName,
        theme: brandTheme(Brightness.light),
        darkTheme: brandTheme(Brightness.dark),
        themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        home: home,
      ),
    ),
  );

  Widget songScreen(
    Directory d, {
    CancellableJob Function(ToolPaths, Directory, void Function(String))? separate,
    double? duration,
    Future<String?> Function(String)? saveLocation,
    LyricsFinder? lyricsFinder,
    SongInfoFinder? songInfoFinder,
  }) => SongScreen(
    dir: d,
    saveDelay: const Duration(milliseconds: 50),
    ensureToolsFn: (context) async => fakeTools,
    importFn: (tools, input, work, onLine) async {},
    separateFn: separate,
    durationFn: (tools, file) async => 227.0,
    saveLocation: saveLocation,
    revealFile: (path) async {},
    createPlayer: () => FakePlayer()..duration = const Duration(seconds: 227),
    lyricsFinder: lyricsFinder ?? (title, artist) async => const [],
    songInfoFinder: songInfoFinder ?? (title, artist) async => const [],
    songInfoDetailsFn: (id) async => (composer: 'John Newton', lyricist: 'John Newton'),
    tagsFn: (tools, input) async => (title: '', artist: ''),
  );

  /// Lets the app run for [ms] milliseconds (real time: files are read and written).
  Future<void> wait([int ms = 1200]) async {
    for (var t = 0; t < ms; t += 100) {
      await drawn(tester.pump(const Duration(milliseconds: 100)));
    }
  }

  Future<void> show(Widget home, {Brightness brightness = Brightness.light, int ms = 1500}) async {
    await drawn(tester.pumpWidget(app(home, brightness: brightness)));
    await wait(ms);
  }

  Future<void> tapKey(String k, {int ms = 800}) async {
    await tester.tap(find.byKey(ValueKey(k)));
    await wait(ms);
  }

  /// Saves the picture as [name] in the output folder.
  Future<void> shoot(String name) async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('${dir.path}/$name')..writeAsBytesSync(data!.buffer.asUint8List());
    written.add(file.path);
  }

  /// Leaves the screen, so the job of vocal removal and the timers end.
  Future<void> leave() async {
    await drawn(tester.pumpWidget(const SizedBox()));
    await drawn(tester.pump(const Duration(milliseconds: 200)));
  }
}

({int width, int height}) pngSize(Uint8List bytes) {
  final d = ByteData.sublistView(bytes);
  return (width: d.getUint32(16), height: d.getUint32(20));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // On macOS a program that uses the accessibility interface (a screen reader, an
  // automation tool) can switch the app's semantics on while the test runs, and the test
  // framework then fails the test for "a SemanticsHandle active at the end". The framework
  // only counts handles that were added during the test, so one that exists before it
  // starts and is released at the end of the body makes the count the same either way.
  SemanticsHandle? beforeTest;
  setUp(() => beforeTest = SemanticsBinding.instance.ensureSemantics());

  testWidgets('screenshots', semanticsEnabled: false, (tester) async {
    if (outDirName.isEmpty) {
      fail('pass --dart-define=SCREENSHOT_DIR=<folder> (see the top of this file)');
    }
    final dir = Directory(outDirName)..createSync(recursive: true);
    final work = Directory.systemTemp.createTempSync('kantahe_shots');
    addTearDown(() => work.deleteSync(recursive: true));
    final s = Shots(tester, dir, work);

    // 01 Home: four songs, all in the public domain.
    for (final (id, title, input) in [
      ('20261101-100000', 'Amazing Grace - Traditional', '/demo/amazing-grace.mp4'),
      ('20261030-190000', 'Auld Lang Syne - Traditional', '/demo/auld-lang-syne.mp3'),
      ('20261028-210000', 'Silent Night - Traditional', '/demo/silent-night.mp3'),
      ('20261025-180000', 'Danny Boy - Traditional', '/demo/danny-boy.mp3'),
    ]) {
      await s.song(
        id: id,
        title: title.split(' - ').first,
        input: input,
        lyrics: verse,
        times: const [12.5, 17.8, 23.1, 28.0],
        vocals: true,
      );
    }
    await s.show(HomeScreen(projectsRoot: () async => work, now: () => DateTime(2026, 11, 2, 12)));
    expect(find.byKey(const ValueKey('project-20261101-100000')), findsOneWidget, reason: '01-home');
    expect(find.text('New song'), findsOneWidget, reason: '01-home');
    await s.shoot('01-home.png');
    await s.leave();

    // 02 Remove vocals, while it runs.
    final running = await s.song(instrumental: false);
    await s.show(
      s.songScreen(
        running,
        separate: (tools, work, onLine) {
          Timer(const Duration(milliseconds: 300), () => onLine('Separating vocals: 43%'));
          return DemoJob();
        },
      ),
    );
    await s.wait(1000);
    expect(find.text('Removing vocals...'), findsOneWidget, reason: '02-remove-vocals');
    expect(find.text('Cancel'), findsOneWidget, reason: '02-remove-vocals');
    await s.shoot('02-remove-vocals.png');
    await s.leave();

    // 03 Details: matches from MusicBrainz (made up from public-domain data).
    final details = await s.song();
    await s.show(
      s.songScreen(
        details,
        songInfoFinder: (title, artist) async => const [
          SongInfoCandidate(
            title: 'Amazing Grace',
            artist: 'Traditional',
            album: '',
            year: '1779',
            recordingId: 'demo-1',
            seconds: 227,
          ),
          SongInfoCandidate(
            title: 'Amazing Grace (instrumental)',
            artist: 'Traditional',
            album: '',
            year: '1779',
            recordingId: 'demo-2',
            seconds: 215,
          ),
          SongInfoCandidate(
            title: 'Amazing Grace (a cappella)',
            artist: 'Traditional',
            album: '',
            year: '1779',
            recordingId: 'demo-3',
            seconds: 190,
          ),
        ],
      ),
    );
    await s.tapKey('step-details', ms: 1500);
    expect(find.byKey(const ValueKey('info-result-0')), findsOneWidget, reason: '03-details');
    expect(find.byKey(const ValueKey('title')), findsOneWidget, reason: '03-details');
    await s.shoot('03-details.png');
    await s.leave();

    // 04 Lyrics: results (one with times), then the first one picked.
    final lyrics = await s.song();
    await s.show(
      s.songScreen(
        lyrics,
        lyricsFinder: (title, artist) async => [
          LyricsCandidate(
            title: 'Amazing Grace',
            artist: 'Traditional',
            album: '',
            lyrics: verse.join('\n'),
            seconds: 227,
            synced: [for (var i = 0; i < verse.length; i++) (12.5 + i * 5.2, verse[i])],
          ),
          LyricsCandidate(
            title: 'Amazing Grace',
            artist: 'Traditional',
            album: '',
            lyrics: verse.join('\n'),
            seconds: 227,
          ),
          LyricsCandidate(
            title: 'Amazing Grace',
            artist: 'Traditional',
            album: '',
            lyrics: verse.join('\n'),
            source: 'lyrics.ovh',
          ),
        ],
      ),
    );
    await s.wait(1000);
    await s.tapKey('lyrics-result-0', ms: 1200);
    expect(find.byKey(const ValueKey('lyrics-result-0')), findsOneWidget, reason: '04-lyrics');
    expect(
      tester.widget<TextField>(find.byKey(const ValueKey('lyrics'))).controller!.text,
      verse.join('\n'),
      reason: '04-lyrics: the picked verse is in the box',
    );
    await s.shoot('04-lyrics.png');
    await s.leave();

    // 05 Timing, part-way through tapping; 07 the same in the dark theme.
    final timing = await s.song(lyrics: verse, times: const [12.5, 17.8, null, null]);
    await s.show(s.songScreen(timing), ms: 1500);
    String status() => tester.widget<Text>(find.byKey(const ValueKey('timing-status'))).data!;
    Brightness theme() => Theme.of(tester.element(find.byType(Scaffold).first)).brightness;
    expect(status(), '2 line(s) not tapped yet', reason: '05-timing');
    expect(theme(), Brightness.light, reason: '05-timing');
    await s.shoot('05-timing.png');
    await s.show(s.songScreen(timing), brightness: Brightness.dark, ms: 1500);
    expect(status(), '2 line(s) not tapped yet', reason: '07-timing-dark');
    expect(theme(), Brightness.dark, reason: '07-timing-dark');
    await s.shoot('07-timing-dark.png');
    await s.leave();

    // 06 Export, with the vocals, after the file was written.
    final done = await s.song(
      lyrics: verse,
      times: const [12.5, 17.8, 23.1, 28.0],
      vocals: true,
      includeVocals: true,
    );
    final out = Directory('${work.path}/out')..createSync();
    await s.show(
      s.songScreen(
        done,
        saveLocation: (name) async => '${out.path}/$name',
      ),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Export .karmp3'));
    await s.wait(2000);
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first)).clearSnackBars();
    await s.wait(600);
    expect(find.byKey(const ValueKey('export-done')), findsOneWidget, reason: '06-export');
    expect(
      tester.widget<CheckboxListTile>(find.byKey(const ValueKey('export-vocals'))).value,
      isTrue,
      reason: '06-export: the vocals are included',
    );
    await s.shoot('06-export.png');
    await s.leave();
    expect(
      out.listSync().map((e) => e.path.split('/').last),
      ['00101 - Traditional - Amazing Grace.karmp3'],
      reason: 'the demo export was written',
    );

    // The seven files exist and have the size of the picture (screenshots_written).
    for (final name in [
      '01-home.png',
      '02-remove-vocals.png',
      '03-details.png',
      '04-lyrics.png',
      '05-timing.png',
      '06-export.png',
      '07-timing-dark.png',
    ]) {
      final file = File('${dir.path}/$name');
      expect(file.existsSync(), isTrue, reason: name);
      final size = pngSize(file.readAsBytesSync());
      expect((size.width, size.height), (2400, 1520), reason: name);
    }
    expect(jobs.length, 0, reason: 'no vocal removal left running');
    beforeTest!.dispose();
  });
}
