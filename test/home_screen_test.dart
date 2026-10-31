import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/project.dart';
import 'package:kantahe_maker/screens/home_screen.dart';
import 'package:kantahe_maker/screens/song_screen.dart';
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
        onOpen: (context, dir) => calls.opened.add(p.basename(dir.path)),
        settingsBuilder: (_) => const Scaffold(body: Text('SETTINGS PAGE')),
        now: now,
      ),
    ),
  );
  await settle(tester);
  return calls;
}

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
}
