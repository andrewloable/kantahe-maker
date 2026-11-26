import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/autofill.dart';
import 'package:kantahe_maker/cdp.dart';
import 'package:kantahe_maker/export.dart';
import 'package:kantahe_maker/project.dart';
import 'package:kantahe_maker/screens/home_screen.dart';
import 'package:kantahe_maker/screens/song_screen.dart';
import 'package:kantahe_maker/spotify_link.dart';
import 'package:kantahe_maker/tools.dart';
import 'package:kantahe_maker/youtube_rank.dart';
import 'package:kantahe_maker/youtube_search.dart';
import 'package:kantahe_maker/ytdlp.dart';
import 'package:kantahe_maker/widgets/brand_header.dart';

import 'support/settle.dart';

import 'package:path/path.dart' as p;

import 'support/windows_safe.dart';

class Calls {
  final opened = <String>[];
  String? picked;
  int pickCalls = 0;
}

Future<Directory> makeRoot(WidgetTester tester) async {
  final root = Directory.systemTemp.createTempSync('home_test');
  addTearDown(() => deleteTemp(root));
  return root;
}

Future<void> saveProject(
  WidgetTester tester,
  Directory root,
  String id, {
  String title = '',
  String artist = '',
  String input = '/x/song.mp3',
}) async {
  await tester.runAsync(() async {
    await (SongProject(id: id, inputPath: input)
          ..title = title
          ..artist = artist)
        .save(Directory('${root.path}/$id'));
  });
}

Future<Calls> pumpHome(
  WidgetTester tester,
  Directory root, {
  String? pick,
  DateTime Function()? now,
  Future<Directory> Function()? projectsRoot,
  Object? pickError,
  Future<SpotifyTrack> Function(String)? spotifyFinder,
  Future<ToolPaths?> Function(BuildContext)? ensureToolsFn,
  YoutubeSearcher? youtubeSearch,
  AudioDownloader? audioDownloader,
  VideoInfoReader? videoInfo,
  Future<AutofillResult> Function(SpotifyTrack, Future<double?>)? autofill,
  String? clipboard,
  void Function(BuildContext, Directory)? openOverride,
  void Function(String)? onLog,
  String? karmp3,
}) async {
  final calls = Calls()..picked = pick;
  await tester.binding.setSurfaceSize(const Size(900, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: HomeScreen(
        projectsRoot: projectsRoot ?? () async => root,
        pickFile: () async {
          calls.pickCalls++;
          if (pickError != null) throw pickError;
          return calls.picked;
        },
        onOpen: (context, dir) {
          calls.opened.add(p.basename(dir.path));
          openOverride?.call(context, dir);
        },
        settingsBuilder: (_) => const Scaffold(body: Text('SETTINGS PAGE')),
        now: now,
        spotifyFinder: spotifyFinder,
        ensureToolsFn: ensureToolsFn ?? (_) async => fakeTools,
        youtubeSearch: youtubeSearch ?? foundOnYoutube,
        audioDownloader: audioDownloader,
        videoInfo: videoInfo,
        autofill: autofill,
        readClipboard: () async => clipboard,
        onLog: onLog,
        pickKarMp3: () async => karmp3,
      ),
    ),
  );
  await settle(tester);
  return calls;
}

const spotifyLink = 'https://open.spotify.com/track/4u7EnebtmKWzUH433cf5Qv?si=x1';
const track = SpotifyTrack(id: 'i', title: 'Song', artist: 'Singer', seconds: 200);

/// Installed tools, as ensureTools gives them (nothing runs them in these tests).
const fakeTools = ToolPaths(
  ffmpeg: '/t/bin/ffmpeg',
  ffprobe: '/t/bin/ffprobe',
  separator: '/t/bin/audio-separator',
  modelDir: '/t/models',
  ytDlp: '/t/bin/yt-dlp',
);

// Made-up YouTube results for the song above: the VEVO upload is the one to pick.
const lyricVideo = YoutubeResult(
  videoId: 'lllllllllll',
  title: 'Singer - Song (Lyrics)',
  channel: 'Lyrics Hub',
  seconds: 200,
);
const vevoVideo = YoutubeResult(
  videoId: 'vvvvvvvvvvv',
  title: 'Singer - Song (Official Video)',
  channel: 'SingerVEVO',
  seconds: 200,
);

Future<List<YoutubeResult>> foundOnYoutube(
  String query, {
  Future<void>? cancel,
  void Function(CdpBrowser browser)? onBrowser,
  void Function(String status)? onStatus,
}) async => [lyricVideo, vevoVideo];

/// An MP3 whose Info tag says 1000 frames of 1152 samples at 44100 Hz (26.122 s).
List<int> tinyMp3() {
  List<int> u32(int v) => [v >> 24 & 255, v >> 16 & 255, v >> 8 & 255, v & 255];
  return [
    0xFF, 0xFB, 0x70, 0x00, ...List.filled(32, 0),
    ...'Info'.codeUnits, ...u32(3), ...u32(1000), ...u32(313000),
    ...List.filled(100, 0),
  ];
}

// Made-up lyrics only.
const timedResult = AutofillResult(
  title: 'Song',
  artist: 'Singer',
  composer: 'C',
  lyricist: 'L',
  lines: [(1.0, 'la la'), (2.5, 'na na')],
  timingSource: 'lrclib',
);

Future<void> openRobot(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('new-from-spotify')));
  await settle(
    tester,
    until: () => find.byKey(const ValueKey('spotify-dialog')).evaluate().isNotEmpty,
  );
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pump();
}

Map<String, dynamic> readProject(Directory dir) =>
    jsonDecode(readText(File('${dir.path}/project.json'))) as Map<String, dynamic>;

void main() {
  testWidgets('home_lists_newest_first', (tester) async {
    final root = await makeRoot(tester);
    await saveProject(
      tester,
      root,
      '20260101-000000',
      title: 'Old',
      artist: 'A',
    );
    await saveProject(
      tester,
      root,
      '20260102-000000',
      title: 'New',
      artist: 'B',
    );
    await pumpHome(tester, root);
    expect(find.text('New - B'), findsOneWidget);
    expect(find.text('Old - A'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('New - B')).dy,
      lessThan(tester.getTopLeft(find.text('Old - A')).dy),
    );
    expect(
      find.text('20260102-000000'),
      findsOneWidget,
      reason: 'the id is the subtitle',
    );
  });

  testWidgets('home_fallback_name', (tester) async {
    final root = await makeRoot(tester);
    await saveProject(tester, root, '20260101-000000', input: '/x/a.mp4');
    await saveProject(
      tester,
      root,
      '20260102-000000',
      title: 'OnlyTitle',
      input: '/y/b.mp3',
    );
    await pumpHome(tester, root);
    expect(find.text('a.mp4'), findsOneWidget);
    expect(
      find.text('b.mp3'),
      findsOneWidget,
      reason: 'a title without an artist is not used',
    );
    expect(find.text('OnlyTitle'), findsNothing);
  });

  testWidgets('home_empty_state', (tester) async {
    final root = await makeRoot(tester);
    await pumpHome(tester, root);
    expect(find.textContaining('No songs yet'), findsOneWidget);
    expect(find.text('New song'), findsOneWidget);
  });

  testWidgets('home_missing_root_is_an_empty_list', (tester) async {
    final root = await makeRoot(tester);
    await pumpHome(
      tester,
      root,
      projectsRoot: () async => Directory('${root.path}/none'),
    );
    expect(find.textContaining('No songs yet'), findsOneWidget);
  });

  testWidgets('home_new_song', (tester) async {
    final root = await makeRoot(tester);
    final calls = await pumpHome(tester, root, pick: '/x/a.mp4');
    await tester.tap(find.text('New song'));
    await settle(tester, until: () => find.text('a.mp4').evaluate().isNotEmpty);
    final dirs = root.listSync().whereType<Directory>().toList();
    expect(dirs, hasLength(1));
    final json = jsonDecode(
      readText(File('${dirs.single.path}/project.json')),
    ) as Map<String, dynamic>;
    expect(json['inputPath'], '/x/a.mp4');
    expect(calls.opened, [p.basename(dirs.single.path)]);
    expect(
      find.text('a.mp4'),
      findsOneWidget,
      reason: 'the list was refreshed',
    );
  });

  testWidgets('home_pick_cancel', (tester) async {
    final root = await makeRoot(tester);
    final calls = await pumpHome(tester, root, pick: null);
    await tester.tap(find.text('New song'));
    await settle(tester);
    expect(calls.pickCalls, 1);
    expect(root.listSync(), isEmpty);
    expect(calls.opened, isEmpty);
  });

  testWidgets('home_new_song_in_the_same_second_does_not_overwrite', (
    tester,
  ) async {
    final root = await makeRoot(tester);
    final calls = await pumpHome(
      tester,
      root,
      pick: '/x/first.mp3',
      now: () => DateTime(2026, 1, 2, 3, 4, 5),
    );
    await tester.tap(find.text('New song'));
    await settle(
      tester,
      until: () => find.text('first.mp3').evaluate().isNotEmpty,
    );
    calls.picked = '/x/second.mp3';
    await tester.tap(find.text('New song'));
    await settle(
      tester,
      until: () => find.text('second.mp3').evaluate().isNotEmpty,
    );
    final names = root.listSync().map((e) => p.basename(e.path)).toList()
      ..sort();
    expect(names, hasLength(2));
    expect(names.first, '20260102-030405');
    final inputs = [
      for (final n in names)
        (jsonDecode(readText(File('${root.path}/$n/project.json')))
            as Map)['inputPath'],
    ];
    expect(inputs, ['/x/first.mp3', '/x/second.mp3']);
  });

  testWidgets('home_new_song_failure_is_shown', (tester) async {
    final tmp = await makeRoot(tester);
    // The "projects folder" is a regular file, so creating a song folder in it fails
    // the same way on every OS.
    final notAFolder = File('${tmp.path}/afile')..writeAsStringSync('x');
    final calls = await pumpHome(
      tester,
      tmp,
      pick: '/x/a.mp4',
      projectsRoot: () async => Directory(notAFolder.path),
    );
    await tester.tap(find.text('New song'));
    await settle(
      tester,
      until: () => find.byType(SnackBar).evaluate().isNotEmpty,
      // the save tries again for about 4.5 s before it gives up
      seconds: 10,
    );
    expect(find.textContaining('Could not create the song'), findsOneWidget);
    expect(calls.opened, isEmpty);
    expect(
      find.text('New song'),
      findsOneWidget,
      reason: 'the screen still works',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('home_delete_failure_is_shown', (tester) async {
    final root = await makeRoot(tester);
    await saveProject(tester, root, '20260101-000000', title: 'T', artist: 'A');
    await pumpHome(tester, root);
    // A read-only parent folder cannot lose a child. Restored before the temp dir goes.
    addTearDown(() => Process.runSync('chmod', ['-R', '755', root.path]));
    Process.runSync('chmod', ['555', root.path]);
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settle(
      tester,
      until: () => find.byType(SnackBar).evaluate().isNotEmpty,
      // the delete tries again for about 4.5 s before it gives up
      seconds: 10,
    );
    expect(find.textContaining('Could not delete the song'), findsOneWidget);
    expect(
      find.text('T - A'),
      findsOneWidget,
      reason: 'the song is still there',
    );
    expect(tester.takeException(), isNull);
  }, skip: Platform.isWindows); // needs a read-only folder

  testWidgets('home_pick_failure_is_shown', (tester) async {
    final root = await makeRoot(tester);
    await pumpHome(tester, root, pickError: StateError('dialog crashed'));
    await tester.tap(find.text('New song'));
    await settle(
      tester,
      until: () => find.byType(SnackBar).evaluate().isNotEmpty,
    );
    expect(find.textContaining('dialog crashed'), findsOneWidget);
    expect(root.listSync(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home_open_on_tap', (tester) async {
    final root = await makeRoot(tester);
    await saveProject(tester, root, '20260101-000000', title: 'T', artist: 'A');
    final calls = await pumpHome(tester, root);
    await tester.tap(find.text('T - A'));
    await tester.pump();
    expect(calls.opened, ['20260101-000000']);
  });

  testWidgets('home_row_opens_the_song_screen_by_default', (tester) async {
    final root = await makeRoot(tester);
    // No title: the song opens on Details, so no lyrics search goes online.
    await saveProject(tester, root, '20260101-000000');
    // A finished song needs no tools, so the song screen starts nothing here.
    for (final f in ['source.mp3', 'source.wav', 'instrumental.mp3']) {
      File('${root.path}/20260101-000000/$f').writeAsStringSync('x');
    }
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(projectsRoot: () async => root)),
    );
    await settle(tester);
    await tester.tap(find.text('song.mp3'));
    await settle(
      tester,
      until: () => find.byType(SongScreen).evaluate().isNotEmpty,
    );
    // Loaded: a finished song without a title opens on the Details step.
    await settle(
      tester,
      until: () => find.byKey(const ValueKey('title')).evaluate().isNotEmpty,
    );
    expect(find.byType(SongScreen), findsOneWidget);
  });

  testWidgets('home_list_shows_the_new_title_after_editing_a_song', (
    tester,
  ) async {
    final root = await makeRoot(tester);
    await saveProject(tester, root, '20260101-000000');
    for (final f in ['source.mp3', 'source.wav', 'instrumental.mp3']) {
      File('${root.path}/20260101-000000/$f').writeAsStringSync('x');
    }
    await tester.binding.setSurfaceSize(const Size(900, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(projectsRoot: () async => root)),
    );
    await settle(tester);
    expect(
      find.text('song.mp3'),
      findsOneWidget,
      reason: 'no title yet: the file name',
    );
    await tester.tap(find.text('song.mp3'));
    await settle(
      tester,
      until: () => find.byKey(const ValueKey('title')).evaluate().isNotEmpty,
    );
    await tester.enterText(find.byKey(const ValueKey('title')), 'New Title');
    await tester.enterText(find.byKey(const ValueKey('artist')), 'New Artist');
    // the song screen saves after a short pause
    await settle(
      tester,
      until: () =>
          readText(File('${root.path}/20260101-000000/project.json'))
              .contains('New Artist'),
      describe: () => [
        for (final e in Directory('${root.path}/20260101-000000').listSync())
          '${e.path}: ${e is File ? '${e.lengthSync()} bytes' : 'dir'}',
        readText(File('${root.path}/20260101-000000/project.json')),
        'snack bars: ${find.byType(SnackBar).evaluate().length}',
      ].join('\n'),
    );
    await tester.pageBack();
    await settle(
      tester,
      until: () => find.byType(SongScreen).evaluate().isEmpty,
    );
    // (while the route slides away the song screen's own app bar shows the same text)
    await settle(
      tester,
      until: () => find.text('New Title - New Artist').evaluate().isNotEmpty,
    );
    expect(find.byType(SongScreen), findsNothing);
    expect(
      find.text('New Title - New Artist'),
      findsOneWidget,
      reason: 'the song list',
    );
  });

  testWidgets('home_delete_confirm', (tester) async {
    final root = await makeRoot(tester);
    await saveProject(tester, root, '20260101-000000', title: 'T', artist: 'A');
    await pumpHome(tester, root);
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete this song project?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(Directory('${root.path}/20260101-000000').existsSync(), isTrue);
    expect(find.text('T - A'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settle(tester, until: () => find.text('T - A').evaluate().isEmpty);
    expect(Directory('${root.path}/20260101-000000').existsSync(), isFalse);
  });

  testWidgets('home_delete_removes_the_audio_files_too', (tester) async {
    final root = await makeRoot(tester);
    await saveProject(tester, root, '20260101-000000', title: 'T', artist: 'A');
    File('${root.path}/20260101-000000/source.mp3').writeAsStringSync('x');
    Directory('${root.path}/20260101-000000/sep').createSync();
    await pumpHome(tester, root);
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settle(tester, until: () => find.text('T - A').evaluate().isEmpty);
    expect(Directory('${root.path}/20260101-000000').existsSync(), isFalse);
  });

  testWidgets('home_unreadable', (tester) async {
    final root = await makeRoot(tester);
    Directory('${root.path}/20260101-000000').createSync();
    File('${root.path}/20260101-000000/project.json').writeAsStringSync('{');
    await saveProject(
      tester,
      root,
      '20260102-000000',
      title: 'Fine',
      artist: 'A',
    );
    await pumpHome(tester, root);
    expect(find.text('Unreadable project'), findsOneWidget);
    expect(
      find.text('Fine - A'),
      findsOneWidget,
      reason: 'one bad project does not hide the rest',
    );
    // and it can be deleted (the broken folder is the older one, so the second row)
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('project-20260101-000000')),
        matching: find.byTooltip('Delete'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settle(
      tester,
      until: () => find.text('Unreadable project').evaluate().isEmpty,
    );
    expect(Directory('${root.path}/20260101-000000').existsSync(), isFalse);
    expect(
      find.text('Fine - A'),
      findsOneWidget,
      reason: 'the other song is untouched',
    );
  });

  testWidgets('home_load_error_shows_retry', (tester) async {
    final root = await makeRoot(tester);
    var calls = 0;
    await pumpHome(
      tester,
      root,
      projectsRoot: () async {
        if (++calls == 1) throw StateError('no plugin');
        return root;
      },
    );
    expect(find.textContaining('no plugin'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await settle(
      tester,
      until: () => find.textContaining('No songs yet').evaluate().isNotEmpty,
    );
  });

  testWidgets('home_settings_button_opens_settings', (tester) async {
    final root = await makeRoot(tester);
    await pumpHome(tester, root);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('SETTINGS PAGE'), findsOneWidget);
  });

  testWidgets('home_app_bar_shows_the_brand_header', (tester) async {
    final root = await makeRoot(tester);
    await pumpHome(tester, root);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(BrandHeader),
      ),
      findsOneWidget,
    );
  });

  group('song from a Spotify link (robot icon)', () {
    const notice =
        'The song is downloaded from YouTube with yt-dlp. For a Spotify link, a Chrome or Edge '
        'window opens minimized for a few seconds to search YouTube for the official video. '
        'Use it only for songs you have the right to use.';

    Future<File> fakeDownload(Directory into) async {
      final file = File('${into.path}/download.mp3')..writeAsBytesSync(tinyMp3());
      return file;
    }

    testWidgets('robot_prefills_from_clipboard', (tester) async {
      final root = await makeRoot(tester);
      await pumpHome(tester, root, clipboard: 'Listen: $spotifyLink');
      await openRobot(tester);
      expect(
        tester.widget<TextField>(find.byKey(const ValueKey('spotify-dialog-link'))).controller!.text,
        'Listen: $spotifyLink',
      );
      expect(
        tester.widget<FilledButton>(find.byKey(const ValueKey('spotify-dialog-download'))).onPressed,
        isNotNull,
      );
    });

    testWidgets('robot_ignores_a_clipboard_without_a_link', (tester) async {
      final root = await makeRoot(tester);
      await pumpHome(tester, root, clipboard: 'hello');
      await openRobot(tester);
      expect(
        tester.widget<TextField>(find.byKey(const ValueKey('spotify-dialog-link'))).controller!.text,
        '',
      );
      expect(
        tester.widget<FilledButton>(find.byKey(const ValueKey('spotify-dialog-download'))).onPressed,
        isNull,
      );
    });

    testWidgets('robot_notice_shown', (tester) async {
      final root = await makeRoot(tester);
      await pumpHome(tester, root);
      await openRobot(tester);
      expect(find.text(notice), findsOneWidget);
    });

    testWidgets('robot_success_creates_and_opens', (tester) async {
      final root = await makeRoot(tester);
      Directory? temp;
      final logs = <String>[];
      final calls = await pumpHome(
        tester,
        root,
        onLog: logs.add,
        clipboard: spotifyLink,
        spotifyFinder: (l) async => track,
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async {
          temp = into;
          return fakeDownload(into);
        },
        autofill: (t, audio) async => timedResult,
      );
      await openRobot(tester);
      await tapKey(tester, 'spotify-dialog-download');
      await settle(tester, until: () => calls.opened.isNotEmpty);
      final dirs = root.listSync().whereType<Directory>().toList();
      expect(dirs, hasLength(1));
      final j = readProject(dirs.single);
      expect(j['inputPath'], p.join(dirs.single.path, 'download.mp3'));
      expect((j['title'], j['artist'], j['composer'], j['lyricist']), ('Song', 'Singer', 'C', 'L'));
      expect(j['lyrics'], 'la la\nna na');
      expect(j['times'], [1.0, 2.5]);
      expect(j['timingSource'], 'lrclib');
      expect(File(p.join(dirs.single.path, 'download.mp3')).readAsBytesSync(), tinyMp3());
      expect(calls.opened, [p.basename(dirs.single.path)]);
      expect(temp!.existsSync(), isFalse, reason: 'the temporary folder is deleted');
      final log = logs.join('\n');
      expect(log, contains('[spotify] flow start (track link)'));
      expect(log, contains('[spotify] link read: "Song" by "Singer", 200.0 s'));
      expect(log, contains('[spotify] download starts'));
      expect(log, contains('[spotify] download finished:'));
      expect(log, contains('[spotify] song created:'));
      expect(log, contains('2 lyric lines, source lrclib'));
      expect(log, contains('[spotify] flow over'));
      expect(log, isNot(contains('la la')), reason: 'no lyrics in the log');
      await settle(
        tester,
        until: () => find.byKey(const ValueKey('spotify-dialog')).evaluate().isEmpty,
      );
    });

    testWidgets('robot_lookups_run_during_download', (tester) async {
      final root = await makeRoot(tester);
      final order = <String>[];
      final gate = Completer<void>();
      final calls = await pumpHome(
        tester,
        root,
        clipboard: spotifyLink,
        spotifyFinder: (l) async => track,
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async {
          order.add('download started');
          await gate.future;
          order.add('download done');
          return fakeDownload(into);
        },
        autofill: (t, audio) async {
          order.add('lookups started');
          return timedResult;
        },
      );
      await openRobot(tester);
      await tapKey(tester, 'spotify-dialog-download');
      await settle(tester, until: () => order.contains('lookups started'));
      expect(order, isNot(contains('download done')));
      expect(root.listSync(), isEmpty, reason: 'no song before the audio exists');
      gate.complete();
      await settle(tester, until: () => calls.opened.isNotEmpty);
      expect(order.indexOf('lookups started'), lessThan(order.indexOf('download done')));
    });

    testWidgets('robot_audio_length_comes_from_the_download', (tester) async {
      final root = await makeRoot(tester);
      double? length;
      final calls = await pumpHome(
        tester,
        root,
        clipboard: spotifyLink,
        spotifyFinder: (l) async => track,
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async => fakeDownload(into),
        autofill: (t, audio) async {
          length = await audio;
          return timedResult;
        },
      );
      await openRobot(tester);
      await tapKey(tester, 'spotify-dialog-download');
      await settle(tester, until: () => calls.opened.isNotEmpty);
      expect(length, closeTo(26.122, 0.001));
    });

    testWidgets('robot_download_failure_offers_a_file', (tester) async {
      final root = await makeRoot(tester);
      var downloads = 0;
      double? length;
      final chosen = File('${root.path}/mine.mp3')..writeAsBytesSync(tinyMp3());
      final calls = await pumpHome(
        tester,
        root,
        pick: chosen.path,
        clipboard: spotifyLink,
        spotifyFinder: (l) async => track,
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async {
          downloads++;
          throw const YtDlpException('yt-dlp took too long. Try again later.');
        },
        autofill: (t, audio) async {
          length = await audio;
          return timedResult;
        },
      );
      await openRobot(tester);
      await tapKey(tester, 'spotify-dialog-download');
      await settle(
        tester,
        until: () => find.byKey(const ValueKey('spotify-dialog-choose')).evaluate().isNotEmpty,
      );
      expect(find.text('yt-dlp took too long. Try again later.'), findsOneWidget);
      expect(root.listSync().whereType<Directory>(), isEmpty, reason: 'no song folder yet');
      await tapKey(tester, 'spotify-dialog-choose');
      await settle(tester, until: () => calls.opened.isNotEmpty);
      final dir = root.listSync().whereType<Directory>().single;
      final j = readProject(dir);
      expect(j['inputPath'], chosen.path);
      expect((j['title'], j['artist']), ('Song', 'Singer'));
      expect(length, closeTo(26.122, 0.001), reason: 'the length of the chosen file');
      expect(downloads, 1);
    });

    testWidgets('robot_try_again_downloads_again', (tester) async {
      final root = await makeRoot(tester);
      var downloads = 0;
      final calls = await pumpHome(
        tester,
        root,
        clipboard: spotifyLink,
        spotifyFinder: (l) async => track,
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async {
          if (++downloads == 1) throw const YtDlpException('yt-dlp took too long. Try again later.');
          return fakeDownload(into);
        },
        autofill: (t, audio) async => timedResult,
      );
      await openRobot(tester);
      await tapKey(tester, 'spotify-dialog-download');
      await settle(
        tester,
        until: () => find.byKey(const ValueKey('spotify-dialog-again')).evaluate().isNotEmpty,
      );
      await tapKey(tester, 'spotify-dialog-again');
      await settle(tester, until: () => calls.opened.isNotEmpty);
      expect(downloads, 2);
      expect(root.listSync().whereType<Directory>(), hasLength(1));
    });

    testWidgets('robot_cancel_leaves_nothing', (tester) async {
      final root = await makeRoot(tester);
      Directory? temp;
      var sawCancel = false;
      final started = Completer<void>();
      final calls = await pumpHome(
        tester,
        root,
        clipboard: spotifyLink,
        spotifyFinder: (l) async => track,
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async {
          temp = into;
          started.complete();
          await cancel;
          sawCancel = true;
          throw const YtDlpException('Cancelled');
        },
        autofill: (t, audio) async => timedResult,
      );
      await openRobot(tester);
      await tapKey(tester, 'spotify-dialog-download');
      await settle(tester, until: () => started.isCompleted);
      await tapKey(tester, 'spotify-dialog-cancel');
      await settle(
        tester,
        until: () => find.byKey(const ValueKey('spotify-dialog')).evaluate().isEmpty,
      );
      expect(sawCancel, isTrue);
      expect(root.listSync(), isEmpty);
      expect(calls.opened, isEmpty);
      expect(temp!.existsSync(), isFalse);
    });

    testWidgets('robot_spotify_error', (tester) async {
      final root = await makeRoot(tester);
      var downloads = 0;
      await pumpHome(
        tester,
        root,
        clipboard: spotifyLink,
        spotifyFinder: (l) async =>
            throw const SpotifyLinkException('Spotify has no song with this link'),
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async {
          downloads++;
          return fakeDownload(into);
        },
        autofill: (t, audio) async => timedResult,
      );
      await openRobot(tester);
      await tapKey(tester, 'spotify-dialog-download');
      await settle(
        tester,
        until: () => find.text('Spotify has no song with this link').evaluate().isNotEmpty,
      );
      expect(downloads, 0);
      expect(find.byKey(const ValueKey('spotify-dialog-choose')), findsNothing);
      expect(root.listSync(), isEmpty);
    });

    testWidgets('robot_closes_the_dialog_before_the_song_opens', (tester) async {
      final root = await makeRoot(tester);
      final calls = await pumpHome(
        tester,
        root,
        clipboard: spotifyLink,
        spotifyFinder: (l) async => track,
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async => fakeDownload(into),
        autofill: (t, audio) async => timedResult,
        // A real route on top, like the song screen: popping the dialog afterwards would
        // pop this instead.
        openOverride: (context, dir) => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('SONG OPENED'))),
        ),
      );
      await openRobot(tester);
      await tapKey(tester, 'spotify-dialog-download');
      await settle(tester, until: () => calls.opened.isNotEmpty);
      await settle(tester, until: () => find.text('SONG OPENED').evaluate().isNotEmpty);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('SONG OPENED'), findsOneWidget, reason: 'the song stays open');
      expect(find.byKey(const ValueKey('spotify-dialog')), findsNothing);
    });

    testWidgets('robot_shows_the_note_after_opening', (tester) async {
      final root = await makeRoot(tester);
      final calls = await pumpHome(
        tester,
        root,
        clipboard: spotifyLink,
        spotifyFinder: (l) async => track,
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async => fakeDownload(into),
        autofill: (t, audio) async => const AutofillResult(
          title: 'Song',
          artist: 'Singer',
          note: 'Tap the timing in Timing.',
        ),
      );
      await openRobot(tester);
      await tapKey(tester, 'spotify-dialog-download');
      await settle(tester, until: () => calls.opened.isNotEmpty);
      await settle(tester, until: () => find.textContaining('Tap the timing').evaluate().isNotEmpty);
    });

    testWidgets('robot_searches_ranks_and_downloads_the_best', (tester) async {
      final root = await makeRoot(tester);
      final queries = <String>[];
      final urls = <String>[];
      final toolsSeen = <ToolPaths>[];
      final gate = Completer<void>();
      final calls = await pumpHome(
        tester,
        root,
        clipboard: spotifyLink,
        spotifyFinder: (l) async => track,
        youtubeSearch: (q, {cancel, onBrowser, onStatus}) async {
          queries.add(q);
          await gate.future;
          return [lyricVideo, vevoVideo];
        },
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async {
          urls.add(url);
          toolsSeen.add(tools);
          return fakeDownload(into);
        },
        autofill: (t, audio) async => timedResult,
      );
      await openRobot(tester);
      await tapKey(tester, 'spotify-dialog-download');
      await settle(tester, until: () => find.text('Searching YouTube...').evaluate().isNotEmpty);
      expect(queries, ['Singer Song']);
      gate.complete();
      await settle(tester, until: () => calls.opened.isNotEmpty);
      expect(urls, [vevoVideo.url], reason: 'the official upload, not the lyric video');
      expect(toolsSeen, [fakeTools]);
    });

    testWidgets('robot_search_status_is_shown', (tester) async {
      // A consent or check page: searchYoutube tells the user to finish it in the window.
      final root = await makeRoot(tester);
      final gate = Completer<void>();
      await pumpHome(
        tester,
        root,
        clipboard: spotifyLink,
        spotifyFinder: (l) async => track,
        youtubeSearch: (q, {cancel, onBrowser, onStatus}) async {
          onStatus!('Finish it in the browser window.');
          await gate.future;
          return [];
        },
        autofill: (t, audio) async => timedResult,
      );
      await openRobot(tester);
      await tapKey(tester, 'spotify-dialog-download');
      await settle(
        tester,
        until: () => find.text('Finish it in the browser window.').evaluate().isNotEmpty,
      );
      gate.complete();
      await settle(tester);
    });

    testWidgets('robot_no_match_offers_a_file', (tester) async {
      final root = await makeRoot(tester);
      var downloads = 0;
      await pumpHome(
        tester,
        root,
        clipboard: spotifyLink,
        spotifyFinder: (l) async => track,
        youtubeSearch: (q, {cancel, onBrowser, onStatus}) async => [
          const YoutubeResult(videoId: 'ccccccccccc', title: 'Song (Karaoke)', channel: 'K', seconds: 300),
        ],
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async {
          downloads++;
          return fakeDownload(into);
        },
        autofill: (t, audio) async => timedResult,
      );
      await openRobot(tester);
      await tapKey(tester, 'spotify-dialog-download');
      await settle(
        tester,
        until: () => find.byKey(const ValueKey('spotify-dialog-choose')).evaluate().isNotEmpty,
      );
      expect(
        find.text('No official YouTube upload found for this song. Choose an MP3 file, or try again.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('spotify-dialog-again')), findsOneWidget);
      expect(downloads, 0);
      expect(root.listSync(), isEmpty);
    });

    testWidgets('robot_search_error_shows_message_and_try_again_searches_again', (tester) async {
      final root = await makeRoot(tester);
      var searches = 0;
      final calls = await pumpHome(
        tester,
        root,
        clipboard: spotifyLink,
        spotifyFinder: (l) async => track,
        youtubeSearch: (q, {cancel, onBrowser, onStatus}) async {
          if (++searches == 1) {
            throw const YoutubeSearchException('YouTube did not show any results');
          }
          return [vevoVideo];
        },
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async => fakeDownload(into),
        autofill: (t, audio) async => timedResult,
      );
      await openRobot(tester);
      await tapKey(tester, 'spotify-dialog-download');
      await settle(
        tester,
        until: () => find.text('YouTube did not show any results').evaluate().isNotEmpty,
      );
      await tapKey(tester, 'spotify-dialog-again');
      await settle(tester, until: () => calls.opened.isNotEmpty);
      expect(searches, 2);
    });

    testWidgets('robot_cancel_during_search_leaves_nothing', (tester) async {
      final root = await makeRoot(tester);
      final started = Completer<void>();
      var downloads = 0;
      final calls = await pumpHome(
        tester,
        root,
        clipboard: spotifyLink,
        spotifyFinder: (l) async => track,
        youtubeSearch: (q, {cancel, onBrowser, onStatus}) async {
          started.complete();
          await cancel;
          throw const YoutubeSearchException('Cancelled');
        },
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async {
          downloads++;
          return fakeDownload(into);
        },
        autofill: (t, audio) async => timedResult,
      );
      await openRobot(tester);
      await tapKey(tester, 'spotify-dialog-download');
      await settle(tester, until: () => started.isCompleted);
      await tapKey(tester, 'spotify-dialog-cancel');
      await settle(
        tester,
        until: () => find.byKey(const ValueKey('spotify-dialog')).evaluate().isEmpty,
      );
      expect(downloads, 0);
      expect(root.listSync(), isEmpty);
      expect(calls.opened, isEmpty);
    });

    testWidgets('robot_without_tools_opens_nothing', (tester) async {
      // The user said "Not now" to the tools download: no dialog, no search, no download.
      final root = await makeRoot(tester);
      var searches = 0;
      await pumpHome(
        tester,
        root,
        clipboard: spotifyLink,
        ensureToolsFn: (_) async => null,
        spotifyFinder: (l) async => track,
        youtubeSearch: (q, {cancel, onBrowser, onStatus}) async {
          searches++;
          return [vevoVideo];
        },
        autofill: (t, audio) async => timedResult,
      );
      await tester.tap(find.byKey(const ValueKey('new-from-spotify')));
      await settle(tester);
      expect(find.byKey(const ValueKey('spotify-dialog')), findsNothing);
      expect(searches, 0);
      expect(root.listSync(), isEmpty);
    });

    testWidgets('robot_cancel_as_the_download_finishes_creates_nothing', (tester) async {
      // km-8bh: the cancel comes in while yt-dlp is finishing; the file still arrives.
      final root = await makeRoot(tester);
      final started = Completer<void>();
      final finish = Completer<void>();
      final calls = await pumpHome(
        tester,
        root,
        clipboard: spotifyLink,
        spotifyFinder: (l) async => track,
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async {
          started.complete();
          await finish.future;
          return fakeDownload(into);
        },
        autofill: (t, audio) async => timedResult,
      );
      await openRobot(tester);
      await tapKey(tester, 'spotify-dialog-download');
      await settle(tester, until: () => started.isCompleted);
      await tapKey(tester, 'spotify-dialog-cancel');
      finish.complete();
      await settle(
        tester,
        until: () => find.byKey(const ValueKey('spotify-dialog')).evaluate().isEmpty,
      );
      expect(root.listSync(), isEmpty, reason: 'no song after a cancel');
      expect(calls.opened, isEmpty);
    });

    testWidgets('robot_cancel_while_creating_creates_nothing', (tester) async {
      // km-n68: the download is done, the lookups are still running ("Creating the song..."),
      // and the user cancels.
      final root = await makeRoot(tester);
      final lookups = Completer<AutofillResult>();
      final calls = await pumpHome(
        tester,
        root,
        clipboard: spotifyLink,
        spotifyFinder: (l) async => track,
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async => fakeDownload(into),
        autofill: (t, audio) => lookups.future,
      );
      await openRobot(tester);
      await tapKey(tester, 'spotify-dialog-download');
      await settle(tester, until: () => find.text('Creating the song...').evaluate().isNotEmpty);
      await tapKey(tester, 'spotify-dialog-cancel');
      lookups.complete(timedResult);
      await settle(
        tester,
        until: () => find.byKey(const ValueKey('spotify-dialog')).evaluate().isEmpty,
      );
      expect(root.listSync(), isEmpty, reason: 'no song after a cancel');
      expect(calls.opened, isEmpty);
    });

    testWidgets('robot_cancel_while_creating_from_a_chosen_file_creates_nothing', (tester) async {
      // km-n68: the same after "Choose an MP3 instead".
      final root = await makeRoot(tester);
      final lookups = Completer<AutofillResult>();
      final chosen = File('${root.path}/mine.mp3')..writeAsBytesSync(tinyMp3());
      final calls = await pumpHome(
        tester,
        root,
        pick: chosen.path,
        clipboard: spotifyLink,
        spotifyFinder: (l) async => track,
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async =>
            throw const YtDlpException('yt-dlp took too long. Try again later.'),
        autofill: (t, audio) => lookups.future,
      );
      await openRobot(tester);
      await tapKey(tester, 'spotify-dialog-download');
      await settle(
        tester,
        until: () => find.byKey(const ValueKey('spotify-dialog-choose')).evaluate().isNotEmpty,
      );
      await tapKey(tester, 'spotify-dialog-choose');
      await settle(tester, until: () => find.text('Creating the song...').evaluate().isNotEmpty);
      await tapKey(tester, 'spotify-dialog-cancel');
      lookups.complete(timedResult);
      await settle(
        tester,
        until: () => find.byKey(const ValueKey('spotify-dialog')).evaluate().isEmpty,
      );
      expect(root.listSync().whereType<Directory>(), isEmpty, reason: 'no song after a cancel');
      expect(calls.opened, isEmpty);
    });

    testWidgets('robot_double_click_opens_one_dialog', (tester) async {
      // km-8bh: a second click while the tools are being checked does nothing.
      final root = await makeRoot(tester);
      final gate = Completer<void>();
      var checks = 0;
      await pumpHome(
        tester,
        root,
        clipboard: spotifyLink,
        ensureToolsFn: (_) async {
          checks++;
          await gate.future;
          return fakeTools;
        },
      );
      await tester.tap(find.byKey(const ValueKey('new-from-spotify')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('new-from-spotify')));
      await tester.pump();
      gate.complete();
      await settle(
        tester,
        until: () => find.byKey(const ValueKey('spotify-dialog')).evaluate().isNotEmpty,
      );
      expect(find.byKey(const ValueKey('spotify-dialog')), findsOneWidget);
      expect(checks, 1);
      // Closing it makes the robot usable again.
      await tapKey(tester, 'spotify-dialog-cancel');
      await settle(
        tester,
        until: () => find.byKey(const ValueKey('spotify-dialog')).evaluate().isEmpty,
      );
      await openRobot(tester);
      expect(checks, 2);
    });

    // ---------------------------------------------------------- a YouTube link
    const youtubeLink = 'https://youtu.be/dQw4w9WgXcQ';
    const video = YoutubeVideo(
      id: 'dQw4w9WgXcQ',
      url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      title: 'Singer - Song (Official Video)',
      channel: 'SingerVEVO',
      seconds: 200,
    );

    testWidgets('youtube_clipboard_autostarts', (tester) async {
      final root = await makeRoot(tester);
      final urls = <String>[];
      final infoUrls = <String>[];
      SpotifyTrack? looked;
      final calls = await pumpHome(
        tester,
        root,
        clipboard: 'Look: $youtubeLink',
        videoInfo: (url, {required tools, cancel}) async {
          infoUrls.add(url);
          return video;
        },
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async {
          urls.add(url);
          return fakeDownload(into);
        },
        autofill: (t, audio) async {
          looked = t;
          return timedResult;
        },
      );
      await openRobot(tester);
      // No tap on Download: a YouTube link from the clipboard starts by itself.
      await settle(tester, until: () => calls.opened.isNotEmpty);
      expect(infoUrls, ['https://www.youtube.com/watch?v=dQw4w9WgXcQ']);
      expect(urls, [video.url]);
      expect((looked!.title, looked!.artist, looked!.seconds), ('Song', 'Singer', 200.0));
      final j = readProject(root.listSync().whereType<Directory>().single);
      expect((j['title'], j['artist']), ('Song', 'Singer'));
    });

    testWidgets('youtube_flow_never_searches', (tester) async {
      final root = await makeRoot(tester);
      final calls = await pumpHome(
        tester,
        root,
        clipboard: youtubeLink,
        videoInfo: (url, {required tools, cancel}) async => video,
        youtubeSearch: (q, {cancel, onBrowser, onStatus}) async =>
            fail('a YouTube link needs no search'),
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async => fakeDownload(into),
        autofill: (t, audio) async => timedResult,
      );
      await openRobot(tester);
      await settle(tester, until: () => calls.opened.isNotEmpty);
    });

    testWidgets('spotify_clipboard_still_waits', (tester) async {
      final root = await makeRoot(tester);
      var reads = 0;
      await pumpHome(
        tester,
        root,
        clipboard: spotifyLink,
        spotifyFinder: (l) async {
          reads++;
          return track;
        },
      );
      await openRobot(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(reads, 0, reason: 'a Spotify link waits for Download');
      expect(find.byKey(const ValueKey('spotify-dialog-download')), findsOneWidget);
    });

    testWidgets('pasted_youtube_link_starts_on_download', (tester) async {
      final root = await makeRoot(tester);
      var infos = 0;
      final calls = await pumpHome(
        tester,
        root,
        videoInfo: (url, {required tools, cancel}) async {
          infos++;
          return video;
        },
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async => fakeDownload(into),
        autofill: (t, audio) async => timedResult,
      );
      await openRobot(tester);
      await tester.enterText(find.byKey(const ValueKey('spotify-dialog-link')), youtubeLink);
      await tester.pump(const Duration(milliseconds: 300));
      expect(infos, 0, reason: 'typed or pasted into the box: no auto-start');
      await tapKey(tester, 'spotify-dialog-download');
      await settle(tester, until: () => calls.opened.isNotEmpty);
      expect(infos, 1);
    });

    testWidgets('youtube_info_error_shows_message', (tester) async {
      final root = await makeRoot(tester);
      var downloads = 0;
      await pumpHome(
        tester,
        root,
        clipboard: youtubeLink,
        videoInfo: (url, {required tools, cancel}) async => throw const YtDlpException(
          'yt-dlp could not download this video: [youtube] dQw4w9WgXcQ: Video unavailable',
        ),
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async {
          downloads++;
          return fakeDownload(into);
        },
      );
      await openRobot(tester);
      await settle(
        tester,
        until: () => find
            .text('yt-dlp could not download this video: [youtube] dQw4w9WgXcQ: Video unavailable')
            .evaluate()
            .isNotEmpty,
      );
      expect(downloads, 0);
      expect(find.byKey(const ValueKey('spotify-dialog-choose')), findsNothing,
          reason: 'without the song details there is nothing to keep');
      expect(root.listSync(), isEmpty);
    });

    testWidgets('youtube_cancel_during_download', (tester) async {
      final root = await makeRoot(tester);
      final started = Completer<void>();
      final calls = await pumpHome(
        tester,
        root,
        clipboard: youtubeLink,
        videoInfo: (url, {required tools, cancel}) async => video,
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async {
          started.complete();
          await cancel;
          throw const YtDlpException('Cancelled');
        },
        autofill: (t, audio) async => timedResult,
      );
      await openRobot(tester);
      await settle(tester, until: () => started.isCompleted);
      await tapKey(tester, 'spotify-dialog-cancel');
      await settle(
        tester,
        until: () => find.byKey(const ValueKey('spotify-dialog')).evaluate().isEmpty,
      );
      expect(root.listSync(), isEmpty);
      expect(calls.opened, isEmpty);
    });

    testWidgets('spotify_link_wins_over_a_youtube_link', (tester) async {
      // km-ows: a text with both links is a Spotify link: no auto-start, no video info.
      final root = await makeRoot(tester);
      var infos = 0, reads = 0;
      final calls = await pumpHome(
        tester,
        root,
        clipboard: '$spotifyLink $youtubeLink',
        spotifyFinder: (l) async {
          reads++;
          return track;
        },
        videoInfo: (url, {required tools, cancel}) async {
          infos++;
          return video;
        },
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async => fakeDownload(into),
        autofill: (t, audio) async => timedResult,
      );
      await openRobot(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect((reads, infos), (0, 0), reason: 'waits for Download');
      await tapKey(tester, 'spotify-dialog-download');
      await settle(tester, until: () => calls.opened.isNotEmpty);
      expect((reads, infos), (1, 0));
    });

    testWidgets('youtube_try_again_after_a_download_error', (tester) async {
      // km-ows: the video stays known; no second info read, no search.
      final root = await makeRoot(tester);
      var infos = 0;
      final urls = <String>[];
      final calls = await pumpHome(
        tester,
        root,
        clipboard: youtubeLink,
        videoInfo: (url, {required tools, cancel}) async {
          infos++;
          return video;
        },
        youtubeSearch: (q, {cancel, onBrowser, onStatus}) async =>
            fail('a YouTube link needs no search'),
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async {
          urls.add(url);
          if (urls.length == 1) throw const YtDlpException('yt-dlp took too long. Try again later.');
          return fakeDownload(into);
        },
        autofill: (t, audio) async => timedResult,
      );
      await openRobot(tester);
      await settle(
        tester,
        until: () => find.byKey(const ValueKey('spotify-dialog-again')).evaluate().isNotEmpty,
      );
      await tapKey(tester, 'spotify-dialog-again');
      await settle(tester, until: () => calls.opened.isNotEmpty);
      expect(infos, 1);
      expect(urls, [video.url, video.url]);
    });

    testWidgets('youtube_choose_a_file_after_a_download_error', (tester) async {
      // km-ows: the details from the video are kept with the chosen file.
      final root = await makeRoot(tester);
      final chosen = File('${root.path}/mine.mp3')..writeAsBytesSync(tinyMp3());
      final calls = await pumpHome(
        tester,
        root,
        pick: chosen.path,
        clipboard: youtubeLink,
        videoInfo: (url, {required tools, cancel}) async => video,
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async =>
            throw const YtDlpException('yt-dlp took too long. Try again later.'),
        autofill: (t, audio) async =>
            AutofillResult(title: t.title, artist: t.artist, composer: 'C', lyricist: 'L'),
      );
      await openRobot(tester);
      await settle(
        tester,
        until: () => find.byKey(const ValueKey('spotify-dialog-choose')).evaluate().isNotEmpty,
      );
      await tapKey(tester, 'spotify-dialog-choose');
      await settle(tester, until: () => calls.opened.isNotEmpty);
      final j = readProject(root.listSync().whereType<Directory>().single);
      expect(j['inputPath'], chosen.path);
      expect((j['title'], j['artist']), ('Song', 'Singer'));
    });

    testWidgets('youtube_cancel_while_reading_the_video', (tester) async {
      // km-ows.
      final root = await makeRoot(tester);
      final started = Completer<void>();
      var downloads = 0;
      final calls = await pumpHome(
        tester,
        root,
        clipboard: youtubeLink,
        videoInfo: (url, {required tools, cancel}) async {
          started.complete();
          await cancel;
          throw const YtDlpException('Cancelled');
        },
        audioDownloader: (url, into, {required tools, onStatus, cancel}) async {
          downloads++;
          return fakeDownload(into);
        },
      );
      await openRobot(tester);
      await settle(tester, until: () => started.isCompleted);
      await tapKey(tester, 'spotify-dialog-cancel');
      await settle(
        tester,
        until: () => find.byKey(const ValueKey('spotify-dialog')).evaluate().isEmpty,
      );
      expect(downloads, 0);
      expect(root.listSync(), isEmpty);
      expect(calls.opened, isEmpty);
    });

    testWidgets('huge_clipboard_text_is_ignored', (tester) async {
      // A blob that big is no song link; reading it must not slow the dialog down.
      final root = await makeRoot(tester);
      var infos = 0;
      await pumpHome(
        tester,
        root,
        clipboard: '${'x' * 10001} $youtubeLink',
        videoInfo: (url, {required tools, cancel}) async {
          infos++;
          return video;
        },
      );
      await openRobot(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.widget<TextField>(find.byKey(const ValueKey('spotify-dialog-link'))).controller!.text,
        '',
      );
      expect(infos, 0);
    });

    testWidgets('robot_dialog_names_both_links', (tester) async {
      final root = await makeRoot(tester);
      await pumpHome(tester, root);
      expect(find.byTooltip('New song from a Spotify or YouTube link'), findsOneWidget);
      await openRobot(tester);
      expect(find.text('New song from a link'), findsOneWidget);
      expect(find.text('Spotify or YouTube link'), findsOneWidget);
    });

    testWidgets('robot_asks_for_the_tools_first', (tester) async {
      final root = await makeRoot(tester);
      final order = <String>[];
      await pumpHome(
        tester,
        root,
        clipboard: spotifyLink,
        ensureToolsFn: (_) async {
          order.add('tools');
          return fakeTools;
        },
      );
      await openRobot(tester);
      expect(order, ['tools']);
    });
  });

  group('open a .karmp3', () {
    // A .karmp3 made the way the app makes them (stand-in MP3 bytes, made-up lyrics), in a
    // folder of its own so it is not mistaken for a song.
    Future<String> makeKarMp3(WidgetTester tester) async {
      final aux = Directory.systemTemp.createTempSync('karmp3_src');
      addTearDown(() => deleteTemp(aux));
      final work = Directory('${aux.path}/work')..createSync();
      File('${work.path}/instrumental.mp3').writeAsBytesSync([1, 2, 3]);
      final dest = '${aux.path}/Singer - Song.karmp3';
      await tester.runAsync(
        () => exportKarMp3(
          SongProject(id: 'x', inputPath: '/x/in.mp3')
            ..title = 'Song'
            ..artist = 'Singer'
            ..lyrics = 'la la\nna na'
            ..times = [1.0, 2.5],
          work,
          dest,
          durationSeconds: 60,
        ),
      );
      return dest;
    }

    testWidgets('open_karmp3_creates_a_song', (tester) async {
      final root = await makeRoot(tester);
      final file = await makeKarMp3(tester);
      final calls = await pumpHome(tester, root, karmp3: file);
      await tester.tap(find.byKey(const ValueKey('open-karmp3')));
      await settle(tester, until: () => calls.opened.isNotEmpty);
      final dirs = root.listSync().whereType<Directory>().toList();
      expect(dirs, hasLength(1));
      final j = readProject(dirs.single);
      expect((j['title'], j['artist']), ('Song', 'Singer'));
      expect(j['karmp3Path'], file);
      expect(j['audioFromKarmp3'], isTrue);
      expect(j['lyrics'], 'la la\nna na');
      expect(File(p.join(dirs.single.path, 'instrumental.mp3')).readAsBytesSync(), [1, 2, 3]);
      expect(calls.opened, [p.basename(dirs.single.path)]);
    });

    testWidgets('open_karmp3_cancel_does_nothing', (tester) async {
      final root = await makeRoot(tester);
      final calls = await pumpHome(tester, root, karmp3: null);
      await tester.tap(find.byKey(const ValueKey('open-karmp3')));
      await settle(tester);
      expect(root.listSync(), isEmpty);
      expect(calls.opened, isEmpty);
    });

    testWidgets('open_karmp3_bad_file_shows_message', (tester) async {
      final root = await makeRoot(tester);
      final aux = Directory.systemTemp.createTempSync('karmp3_bad');
      addTearDown(() => deleteTemp(aux));
      final bad = File('${aux.path}/bad.karmp3')..writeAsStringSync('not a zip');
      final calls = await pumpHome(tester, root, karmp3: bad.path);
      await tester.tap(find.byKey(const ValueKey('open-karmp3')));
      await settle(
        tester,
        until: () => find
            .textContaining('Could not open bad.karmp3: This is not a .karmp3 file')
            .evaluate()
            .isNotEmpty,
      );
      expect(root.listSync(), isEmpty, reason: 'no folder is left');
      expect(calls.opened, isEmpty);
    });

    testWidgets('open_karmp3_missing_file_message_is_not_doubled', (tester) async {
      final root = await makeRoot(tester);
      final calls = await pumpHome(tester, root, karmp3: '${root.path}/../gone.karmp3');
      await tester.tap(find.byKey(const ValueKey('open-karmp3')));
      await settle(
        tester,
        until: () => find.textContaining('Could not read gone.karmp3').evaluate().isNotEmpty,
      );
      expect(find.textContaining('Could not open'), findsNothing);
      expect(root.listSync(), isEmpty, reason: 'no folder is left');
      expect(calls.opened, isEmpty);
    });

    testWidgets('empty_text_mentions_open', (tester) async {
      final root = await makeRoot(tester);
      await pumpHome(tester, root);
      expect(
        find.text('No songs yet. Click "New song" to start, or "Open .karmp3" to edit a karaoke file.'),
        findsOneWidget,
      );
    });

    testWidgets('new_song_button_is_still_there', (tester) async {
      final root = await makeRoot(tester);
      await pumpHome(tester, root);
      expect(find.text('New song'), findsOneWidget);
      expect(find.byKey(const ValueKey('new-from-spotify')), findsOneWidget);
      expect(find.text('Open .karmp3'), findsOneWidget);
    });
  });
}
