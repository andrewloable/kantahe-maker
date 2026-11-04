import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/ai_timing.dart';
import 'package:kantahe_maker/screens/settings_screen.dart';
import 'package:kantahe_maker/settings.dart';
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
    for (final label in ['ffmpeg', 'ffprobe', 'uv', 'audio-separator', 'Vocal-splitting model']) {
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

  group('graphics card switch', () {
    final switchKey = find.byKey(const ValueKey('graphics-card'));

    /// A settings screen with the switch, and what it did.
    Future<({List<bool> saved, List<String> calls})> pumpGraphics(
      WidgetTester tester, {
      bool? show = true,
      bool saved = false,
      bool hasSupport = false,
      bool installs = true,
      Object? installError,
    }) async {
      final out = (saved: <bool>[], calls: <String>[]);
      await tester.binding.setSurfaceSize(const Size(900, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          status: () async => {'ffmpeg': null, 'ffprobe': null, 'uv': null, 'audio-separator': null, 'model': null},
          showGraphicsCard: show,
          loadSettings: () async => AppSettings(useGraphicsCard: saved),
          saveSettings: (settings) async => out.saved.add(settings.useGraphicsCard),
          hasGraphicsSupport: () async {
            out.calls.add('has');
            return hasSupport;
          },
          installGraphics: (context) async {
            out.calls.add('install');
            if (installError != null) throw installError;
            return installs;
          },
        ),
      ));
      await tester.pumpAndSettle();
      return out;
    }

    bool isOn(WidgetTester tester) => tester.widget<SwitchListTile>(switchKey).value;

    testWidgets('off_by_default', (tester) async {
      await pumpGraphics(tester);
      expect(switchKey, findsOneWidget);
      expect(find.text('Use the graphics card'), findsOneWidget);
      expect(isOn(tester), isFalse);
    });

    testWidgets('hidden_where_there_is_no_directml', (tester) async {
      await pumpGraphics(tester, show: false);
      expect(switchKey, findsNothing);
    });

    testWidgets('shows_what_was_saved', (tester) async {
      await pumpGraphics(tester, saved: true);
      expect(isOn(tester), isTrue);
    });

    testWidgets('turning_on_downloads_the_support_first', (tester) async {
      final r = await pumpGraphics(tester);
      await tester.tap(switchKey);
      await tester.pumpAndSettle();
      expect(r.calls, ['has', 'install']);
      expect(r.saved, [true]);
      expect(isOn(tester), isTrue);
    });

    testWidgets('turning_on_skips_the_download_when_it_is_there', (tester) async {
      final r = await pumpGraphics(tester, hasSupport: true);
      await tester.tap(switchKey);
      await tester.pumpAndSettle();
      expect(r.calls, ['has']);
      expect(r.saved, [true]);
    });

    testWidgets('declining_the_download_leaves_it_off', (tester) async {
      final r = await pumpGraphics(tester, installs: false);
      await tester.tap(switchKey);
      await tester.pumpAndSettle();
      expect(r.saved, isEmpty);
      expect(isOn(tester), isFalse);
    });

    testWidgets('a_failed_download_leaves_it_off_and_says_why', (tester) async {
      final r = await pumpGraphics(tester, installError: 'no network');
      await tester.tap(switchKey);
      await tester.pumpAndSettle();
      expect(r.saved, isEmpty);
      expect(isOn(tester), isFalse);
      expect(find.text('no network'), findsOneWidget);
    });

    testWidgets('turning_off_only_saves', (tester) async {
      final r = await pumpGraphics(tester, saved: true);
      await tester.tap(switchKey);
      await tester.pumpAndSettle();
      expect(r.calls, isEmpty);
      expect(r.saved, [false]);
      expect(isOn(tester), isFalse);
    });
  });

  group('cloudflare keys', () {
    Future<({List<AppSettings> saved, List<(String, String)> verified})> pumpKeys(
      WidgetTester tester, {
      AppSettings loaded = const AppSettings(),
      Object? verifyError,
    }) async {
      final out = (saved: <AppSettings>[], verified: <(String, String)>[]);
      await tester.binding.setSurfaceSize(const Size(900, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          status: () async => {'ffmpeg': null},
          showGraphicsCard: true,
          loadSettings: () async => loaded,
          saveSettings: (s) async => out.saved.add(s),
          hasGraphicsSupport: () async => true,
          verifyCloudflare: (account, token) async {
            out.verified.add((account, token));
            if (verifyError != null) throw verifyError;
          },
        ),
      ));
      await tester.pumpAndSettle();
      return out;
    }

    Future<void> save(WidgetTester tester, {String? account, String? token}) async {
      if (account != null) await tester.enterText(find.byKey(const ValueKey('cf-account')), account);
      if (token != null) await tester.enterText(find.byKey(const ValueKey('cf-token')), token);
      await tester.ensureVisible(find.byKey(const ValueKey('cf-save')));
      await tester.tap(find.byKey(const ValueKey('cf-save')));
      await tester.pumpAndSettle();
    }

    String status(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const ValueKey('cf-status'))).data!;

    testWidgets('settings_cloudflare_save_tests_then_saves', (tester) async {
      final r = await pumpKeys(tester, loaded: const AppSettings(useGraphicsCard: true));
      await save(tester, account: '  acc123 ', token: ' tok456  ');
      expect(r.verified, [('acc123', 'tok456')]);
      expect(r.saved, hasLength(2), reason: 'the values first, the result of the test after');
      expect(r.saved.first.cloudflareVerified, isFalse);
      expect(r.saved.last.cloudflareAccountId, 'acc123');
      expect(r.saved.last.cloudflareToken, 'tok456');
      expect(r.saved.last.cloudflareVerified, isTrue);
      expect(r.saved.last.useGraphicsCard, isTrue, reason: 'the other setting is kept');
      expect(status(tester), contains('works'));
    });

    testWidgets('settings_cloudflare_failed_test_keeps_values_unverified', (tester) async {
      final r = await pumpKeys(
        tester,
        loaded: const AppSettings(
          cloudflareAccountId: 'old', cloudflareToken: 'oldtok', cloudflareVerified: true),
        verifyError: const AiTimingException('Cloudflare refused the request'),
      );
      await save(tester, token: 'newtok');
      expect(r.saved.last.cloudflareAccountId, 'old');
      expect(r.saved.last.cloudflareToken, 'newtok');
      expect(r.saved.last.cloudflareVerified, isFalse, reason: 'changed values are tested again');
      expect(status(tester), contains('Cloudflare refused the request'));
      expect(status(tester), contains('hidden'));
      expect(status(tester), isNot(contains('newtok')));
    });

    testWidgets('settings_cloudflare_unexpected_error_is_shown', (tester) async {
      await pumpKeys(tester, verifyError: StateError('boom'));
      await save(tester, account: 'a', token: 't');
      expect(status(tester), contains('test failed'));
    });

    testWidgets('settings_cloudflare_empty_values_skip_the_test', (tester) async {
      final r = await pumpKeys(
        tester,
        loaded: const AppSettings(
          cloudflareAccountId: 'a', cloudflareToken: 't', cloudflareVerified: true),
      );
      await save(tester, token: '');
      expect(r.verified, isEmpty);
      expect(r.saved.last.cloudflareVerified, isFalse);
      expect(status(tester), contains('off'));
    });

    testWidgets('settings_cloudflare_shows_what_was_saved', (tester) async {
      await pumpKeys(
        tester,
        loaded: const AppSettings(cloudflareAccountId: 'acc', cloudflareToken: 'tok'),
      );
      expect(find.text('acc'), findsOneWidget);
    });

    testWidgets('settings_token_is_obscured', (tester) async {
      await pumpKeys(tester, loaded: const AppSettings(cloudflareToken: 'secret-token'));
      final field = tester.widget<TextField>(find.byKey(const ValueKey('cf-token')));
      expect(field.obscureText, isTrue);
    });

    testWidgets('settings_graphics_save_keeps_cloudflare', (tester) async {
      final r = await pumpKeys(
        tester,
        loaded: const AppSettings(
          cloudflareAccountId: 'acc', cloudflareToken: 'tok', cloudflareVerified: true),
      );
      await tester.tap(find.byKey(const ValueKey('graphics-card')));
      await tester.pumpAndSettle();
      expect(r.saved.single.useGraphicsCard, isTrue);
      expect(r.saved.single.cloudflareAccountId, 'acc');
      expect(r.saved.single.cloudflareToken, 'tok');
      expect(r.saved.single.cloudflareVerified, isTrue);
    });
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
      expect(toolLabel('model'), 'Vocal-splitting model');
      expect(toolLabel('ffmpeg'), 'ffmpeg');
      expect(toolLabel('something-new'), 'something-new');
    });
  });
}
