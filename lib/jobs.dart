// Background jobs the app must end before it quits (vocal removal starts programs that
// would otherwise keep running). Pure Dart: no Flutter imports.

/// What the app needs from a running background job.
abstract interface class CancellableJob {
  /// Completes when the job is over; with an error if it failed or was cancelled.
  Future<void> get done;

  void cancel();
}

class JobRegistry {
  final _jobs = <CancellableJob>{};

  int get length => _jobs.length;

  /// Remembers [job] until it is over, however it ends.
  void track(CancellableJob job) {
    _jobs.add(job);
    job.done
        .then((_) {}, onError: (Object _) {})
        .whenComplete(() => _jobs.remove(job));
  }

  /// Cancels every tracked job and waits for each to finish, at most [timeout] in total
  /// (a stuck job must not keep the app from quitting). Failures, including a job that
  /// throws when cancelled, are ignored.
  Future<void> cancelAll({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final running = List.of(_jobs);
    for (final job in running) {
      try {
        job.cancel();
      } catch (_) {
        // One job that cannot be cancelled must not stop the others (or the app) from ending.
      }
    }
    await Future.wait([
      for (final job in running)
        job.done.then<void>((_) {}, onError: (Object _) {}),
    ]).timeout(timeout, onTimeout: () => <void>[]);
  }
}

/// The jobs of the running app.
final jobs = JobRegistry();
