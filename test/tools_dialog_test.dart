import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/screens/tools_dialog.dart';
import 'package:kantahe_maker/tools.dart';

const _paths = ToolPaths(
    ffmpeg: '/t/ffmpeg', ffprobe: '/t/ffprobe', separator: '/t/sep', modelDir: '/t/m');

class _Run {
  ToolPaths? result;
  bool done = false;
  int installCalls = 0;
}

Widget _app(_Run run, Future<ToolPaths?> Function(BuildContext) go) => MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                run.result = await go(ctx);
                run.done = true;
              },
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
}

void main() {
  group('toolItems', () {
    test('items_for_mac', () {
      final items = toolItems(HostOs.macos, HostArch.arm64);
      expect(items, hasLength(4));
      expect(items.map((i) => i.name), [
        'ffmpeg and ffprobe',
        'uv (Python manager)',
        'Python and audio-separator',
        'Vocal-removal model (UVR)',
      ]);
      expect(items[0].source, 'ffmpeg.martin-riedl.de');
      expect(items[1].source, 'github.com');
      expect(items[2].source, 'pypi.org');
      expect(items[3].source, 'github.com (UVR models)');
      expect(items.every((i) => i.sizeMb > 0 && i.license.isNotEmpty), isTrue);
    });

    test('items_for_linux_use_the_linux_ffmpeg_host', () {
      expect(toolItems(HostOs.linux, HostArch.x64)[0].source, 'github.com');
    });
  });

  testWidgets('present_no_dialog', (tester) async {
    final run = _Run();
    await tester.pumpWidget(_app(
        run,
        (ctx) => ensureTools(ctx,
            resolve: () async => _paths,
            install: (l, p) async => run.installCalls++)));
    await _open(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(run.done, isTrue);
    expect(run.result, isNotNull);
    expect(run.installCalls, 0);
  });

  testWidgets('missing_shows_items', (tester) async {
    final run = _Run();
    await tester.pumpWidget(_app(
        run,
        (ctx) => ensureTools(ctx,
            resolve: () async => null,
            install: (l, p) async => run.installCalls++)));
    await _open(tester);
    expect(find.text('Download required tools?'), findsOneWidget);
    expect(find.byType(ListTile), findsNWidgets(4));
    expect(find.textContaining('MB'), findsNWidgets(4));
    expect(find.textContaining('Nothing is downloaded until you click Download'),
        findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    expect(run.installCalls, 0, reason: 'opening the dialog must not install');
  });

  testWidgets('not_now_no_download', (tester) async {
    final run = _Run();
    await tester.pumpWidget(_app(
        run,
        (ctx) => ensureTools(ctx,
            resolve: () async => null,
            install: (l, p) async => run.installCalls++)));
    await _open(tester);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(run.done, isTrue);
    expect(run.result, isNull);
    expect(run.installCalls, 0);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('download_success', (tester) async {
    final run = _Run();
    var resolves = 0;
    await tester.pumpWidget(_app(
        run,
        (ctx) => ensureTools(ctx,
            resolve: () async => ++resolves >= 2 ? _paths : null,
            install: (onLine, onProgress) async {
              run.installCalls++;
              onProgress('uv.tar.gz', 5, 10);
              onLine('ok');
            })));
    await _open(tester);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(run.installCalls, 1);
    expect(run.done, isTrue);
    expect(run.result, isNotNull);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('download_shows_progress_and_log', (tester) async {
    final run = _Run();
    final finish = Completer<void>();
    await tester.pumpWidget(_app(
        run,
        (ctx) => ensureTools(ctx,
            resolve: () async => run.installCalls > 0 && finish.isCompleted ? _paths : null,
            install: (onLine, onProgress) async {
              run.installCalls++;
              onProgress('uv.tar.gz', 5, 10);
              onLine('Downloading python');
              await finish.future;
            })));
    await _open(tester);
    await tester.tap(find.text('Download'));
    await tester.pump();
    await tester.pump();
    expect(find.text('uv.tar.gz'), findsOneWidget);
    expect(find.text('Downloading python'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(bar.value, 0.5);
    expect(find.text('Not now'), findsNothing, reason: 'cannot cancel mid-install');
    expect(find.text('Download'), findsNothing);
    finish.complete();
    await tester.pumpAndSettle();
    expect(run.result, isNotNull);
  });

  testWidgets('progress_without_total_is_indeterminate', (tester) async {
    final run = _Run();
    final finish = Completer<void>();
    await tester.pumpWidget(_app(
        run,
        (ctx) => ensureTools(ctx,
            resolve: () async => finish.isCompleted ? _paths : null,
            install: (onLine, onProgress) async {
              onProgress('a.zip', 5, null);
              await finish.future;
            })));
    await _open(tester);
    await tester.tap(find.text('Download'));
    await tester.pump();
    await tester.pump();
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value,
        isNull);
    finish.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('download_error_retry', (tester) async {
    final run = _Run();
    var resolves = 0;
    await tester.pumpWidget(_app(
        run,
        (ctx) => ensureTools(ctx,
            resolve: () async => ++resolves >= 2 ? _paths : null,
            install: (l, p) async {
              if (++run.installCalls == 1) throw Exception('boom');
            })));
    await _open(tester);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(find.textContaining('boom'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    expect(run.done, isFalse);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(run.installCalls, 2);
    expect(run.result, isNotNull);
  });

  testWidgets('error_close_returns_null', (tester) async {
    final run = _Run();
    await tester.pumpWidget(_app(
        run,
        (ctx) => ensureTools(ctx,
            resolve: () async => null,
            install: (l, p) async => throw Exception('boom'))));
    await _open(tester);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(run.done, isTrue);
    expect(run.result, isNull);
  });

  testWidgets('install_ok_but_tools_still_missing', (tester) async {
    final run = _Run();
    await tester.pumpWidget(_app(
        run,
        (ctx) => ensureTools(ctx,
            resolve: () async => null, install: (l, p) async => run.installCalls++)));
    await _open(tester);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(find.textContaining('still missing'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(run.done, isFalse);
  });

  testWidgets('dialog_cannot_be_dismissed_by_tapping_outside', (tester) async {
    final run = _Run();
    await tester.pumpWidget(_app(
        run, (ctx) => ensureTools(ctx, resolve: () async => null, install: (l, p) async {})));
    await _open(tester);
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(run.done, isFalse);
  });

  testWidgets('log_keeps_last_200_lines', (tester) async {
    final run = _Run();
    final finish = Completer<void>();
    await tester.pumpWidget(_app(
        run,
        (ctx) => ensureTools(ctx,
            resolve: () async => null,
            install: (onLine, onProgress) async {
              for (var i = 1; i <= 250; i++) {
                onLine('line $i');
              }
              await finish.future;
            })));
    await _open(tester);
    await tester.tap(find.text('Download'));
    await tester.pump();
    await tester.pump();
    expect(find.text('line 250'), findsOneWidget);
    expect(find.text('line 51'), findsOneWidget, reason: 'the oldest of the last 200');
    expect(find.text('line 50'), findsNothing, reason: 'older than the last 200');
    finish.complete();
    await tester.pumpAndSettle();
  });
}
