import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/screens/settings_screen.dart';
import 'package:kantahe_maker/tools.dart';

class Calls {
  int status = 0, repair = 0, open = 0, delete = 0;
  Map<String, String?> toolStatus = {
    'ffmpeg': '/opt/homebrew/bin/ffmpeg',
    'ffprobe': null,
    'uv': null,
    'audio-separator': null,
    'model': null,
  };
}

Future<Calls> pumpSettings(WidgetTester tester,
    {Object? statusError, Object? repairError, Object? openError}) async {
  final c = Calls();
  await tester.binding.setSurfaceSize(const Size(900, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: SettingsScreen(
      status: () async {
        c.status++;
        if (statusError != null) throw statusError;
        return c.toolStatus;
      },
      repair: (context) async {
        c.repair++;
        if (repairError != null) throw repairError;
      },
      openFolder: () async {
        c.open++;
        if (openError != null) throw openError;
      },
      deleteTools: () async => c.delete++,
    ),
  ));
  await tester.pumpAndSettle();
  return c;
}

void main() {
  testWidgets('settings_status', (tester) async {
    await pumpSettings(tester);
    expect(find.text('/opt/homebrew/bin/ffmpeg'), findsOneWidget);
    expect(find.text('Missing'), findsNWidgets(4));
    for (final label in ['ffmpeg', 'ffprobe', 'uv', 'audio-separator', 'Vocal-removal model']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('settings_status_error', (tester) async {
    await pumpSettings(tester, statusError: StateError('boom'));
    expect(find.textContaining('boom'), findsOneWidget);
    expect(find.text('Download / repair tools'), findsOneWidget,
        reason: 'the buttons stay usable');
  });

  testWidgets('settings_repair_refreshes', (tester) async {
    final c = await pumpSettings(tester);
    c.toolStatus = {...c.toolStatus, 'uv': '/t/bin/uv'};
    await tester.tap(find.text('Download / repair tools'));
    await tester.pumpAndSettle();
    expect(c.repair, 1);
    expect(c.status, 2, reason: 'the status is read again afterwards');
    expect(find.text('/t/bin/uv'), findsOneWidget);
  });

  testWidgets('settings_action_errors_are_shown', (tester) async {
    await pumpSettings(tester, repairError: StateError('no network'));
    await tester.tap(find.text('Download / repair tools'));
    await tester.pumpAndSettle();
    expect(find.textContaining('no network'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('settings_open_folder_error_is_shown', (tester) async {
    await pumpSettings(tester, openError: StateError('no file manager'));
    await tester.tap(find.text('Open tools folder'));
    await tester.pumpAndSettle();
    expect(find.textContaining('no file manager'), findsOneWidget);
  });

  testWidgets('settings_open_folder', (tester) async {
    final c = await pumpSettings(tester);
    await tester.tap(find.text('Open tools folder'));
    await tester.pumpAndSettle();
    expect(c.open, 1);
  });

  testWidgets('settings_delete_confirm', (tester) async {
    final c = await pumpSettings(tester);
    await tester.tap(find.text('Delete downloaded tools'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Delete the downloaded tools?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(c.delete, 0);

    await tester.tap(find.text('Delete downloaded tools'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(c.delete, 1);
    expect(c.status, 2, reason: 'refreshed after deleting');
  });

  group('openFolderCommand', () {
    test('open_folder_command', () {
      expect(openFolderCommand(HostOs.macos, '/a b/tools'), ['open', '/a b/tools']);
      expect(openFolderCommand(HostOs.linux, '/a b/tools'), ['xdg-open', '/a b/tools']);
      expect(openFolderCommand(HostOs.windows, r'C:\a b\tools'), ['explorer', r'C:\a b\tools']);
    });
  });

  group('label', () {
    test('tool_labels', () {
      expect(toolLabel('model'), 'Vocal-removal model');
      expect(toolLabel('ffmpeg'), 'ffmpeg');
      expect(toolLabel('something-new'), 'something-new');
    });
  });
}
