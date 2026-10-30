import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/jobs.dart';
import 'package:kantahe_maker/main.dart';
import 'package:kantahe_maker/widgets/brand_header.dart';

void main() {
  testWidgets('smoke_title', (tester) async {
    await tester.pumpWidget(const KantaheApp());
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).title, 'Kantahe Maker');
    expect(find.byType(BrandHeader), findsOneWidget, reason: 'the home screen shows the logo');
  });

  testWidgets('smoke_material3', (tester) async {
    await tester.pumpWidget(const KantaheApp());
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.theme?.useMaterial3, isTrue);
  });

  testWidgets('app_shows_the_given_home_instead_of_the_song_list', (tester) async {
    await tester.pumpWidget(const KantaheApp(home: Text('custom home')));
    expect(find.text('custom home'), findsOneWidget);
    expect(find.text('New song'), findsNothing);
  });

  testWidgets('exit_request_cancels_running_jobs_first', (tester) async {
    final job = _Job();
    jobs.track(job);
    await tester.pumpWidget(const KantaheApp());
    // ignore: invalid_use_of_protected_member
    final response = await tester.binding.handleRequestAppExit();
    expect(job.cancelled, isTrue, reason: 'running programs are ended before quitting');
    expect(response, AppExitResponse.exit);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('exit_with_a_job_that_fails_when_cancelled_raises_no_error', (tester) async {
    // The real vocal-removal job ends with an error (SeparationCancelled) when cancelled.
    final job = _Job(failsOnCancel: true);
    jobs.track(job);
    await tester.pumpWidget(const KantaheApp(home: SizedBox()));
    // ignore: invalid_use_of_protected_member
    final response = await tester.runAsync(() => tester.binding.handleRequestAppExit());
    await tester.pump();
    expect(job.cancelled, isTrue);
    expect(response, AppExitResponse.exit);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('exit_still_happens_when_cancelling_a_job_throws', (tester) async {
    final bad = _Job(finishesOnCancel: false, cancelThrows: true);
    jobs.track(bad);
    await tester.pumpWidget(const KantaheApp(home: SizedBox()));
    // ignore: invalid_use_of_protected_member
    final response = await tester.runAsync(() => tester.binding.handleRequestAppExit());
    expect(response, AppExitResponse.exit, reason: 'a failing cancel must not keep the app open');
    bad.finish();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('exit_is_not_held_up_by_a_stuck_job', (tester) async {
    final job = _Job(finishesOnCancel: false);
    jobs.track(job);
    await tester.pumpWidget(const KantaheApp());
    // Real time: the registry gives up on a stuck job after 5 s, which a fake clock never reaches.
    final sw = Stopwatch()..start();
    // ignore: invalid_use_of_protected_member
    final response = await tester.runAsync(() => tester.binding.handleRequestAppExit());
    expect(sw.elapsed, lessThan(const Duration(seconds: 9)));
    expect(job.cancelled, isTrue);
    expect(response, AppExitResponse.exit);
    job.finish(); // let the registry forget it
    await tester.pumpWidget(const SizedBox());
  });
}

class _Job implements CancellableJob {
  _Job({this.finishesOnCancel = true, this.failsOnCancel = false, this.cancelThrows = false});
  final bool cancelThrows;
  final bool finishesOnCancel;
  final bool failsOnCancel; // like the real job: done completes with an error
  final _done = Completer<void>();
  bool cancelled = false;

  @override
  Future<void> get done => _done.future;

  @override
  void cancel() {
    cancelled = true;
    if (cancelThrows) throw StateError('cannot cancel');
    if (failsOnCancel) {
      if (!_done.isCompleted) _done.completeError(StateError('cancelled'));
    } else if (finishesOnCancel) {
      finish();
    }
  }

  void finish() {
    if (!_done.isCompleted) _done.complete();
  }
}
