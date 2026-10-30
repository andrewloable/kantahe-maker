import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/jobs.dart';

class FakeJob implements CancellableJob {
  final _done = Completer<void>();
  bool cancelled = false;
  final bool finishesOnCancel;
  final bool cancelThrows;
  FakeJob({this.finishesOnCancel = true, this.cancelThrows = false});

  @override
  Future<void> get done => _done.future;

  @override
  void cancel() {
    cancelled = true;
    if (cancelThrows) throw StateError('cannot cancel');
    if (finishesOnCancel && !_done.isCompleted) _done.completeError(StateError('cancelled'));
  }

  void finish() => _done.complete();
}

void main() {
  test('track_and_untrack_when_done', () async {
    final r = JobRegistry();
    final a = FakeJob(), b = FakeJob();
    r.track(a);
    r.track(b);
    expect(r.length, 2);
    a.finish();
    await Future<void>.delayed(Duration.zero);
    expect(r.length, 1);
    b.cancel(); // fails with an error: it must be forgotten as well, without an uncaught error
    await Future<void>.delayed(Duration.zero);
    expect(r.length, 0);
  });

  test('cancel_all_cancels_every_job_and_waits_for_them', () async {
    final r = JobRegistry();
    final a = FakeJob(finishesOnCancel: false), b = FakeJob(finishesOnCancel: false);
    r.track(a);
    r.track(b);
    var returned = false;
    final all = r.cancelAll().then((_) => returned = true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(a.cancelled && b.cancelled, isTrue);
    expect(returned, isFalse, reason: 'it waits until the jobs have finished');
    a.finish();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(returned, isFalse, reason: 'one job is still running');
    b.finish();
    await all;
    expect(returned, isTrue);
  });

  test('cancel_all_gives_up_on_a_stuck_job', () async {
    final r = JobRegistry();
    final stuck = FakeJob(finishesOnCancel: false);
    r.track(stuck);
    final sw = Stopwatch()..start();
    await r.cancelAll(timeout: const Duration(milliseconds: 200));
    expect(stuck.cancelled, isTrue);
    expect(sw.elapsedMilliseconds, inInclusiveRange(150, 2000));
  }, timeout: const Timeout(Duration(seconds: 6)));

  test('cancel_all_ignores_failures', () async {
    final r = JobRegistry();
    final j = FakeJob(); // completes with an error when cancelled
    r.track(j);
    await r.cancelAll();
    expect(j.cancelled, isTrue);
  });

  test('a_job_that_already_failed_does_not_break_tracking', () async {
    final r = JobRegistry();
    final j = FakeJob()..cancel();
    r.track(j);
    await Future<void>.delayed(Duration.zero);
    expect(r.length, 0);
  });

  test('cancel_all_survives_a_job_whose_cancel_throws', () async {
    final r = JobRegistry();
    final bad = FakeJob(finishesOnCancel: false, cancelThrows: true);
    final good = FakeJob();
    r.track(bad);
    r.track(good);
    await r.cancelAll(timeout: const Duration(milliseconds: 200));
    expect(good.cancelled, isTrue, reason: 'the other jobs are still cancelled');
  });
}
