import 'dart:io';

/// Runs [action], trying again when it fails with a FileSystemException. Windows refuses
/// to replace, delete or open a file while another program has it open (a virus scanner
/// checking a file just written, an indexer, a player still closing, a reader of
/// project.json), usually only for a moment. Gives up after 10 attempts (about 4.5 s)
/// and rethrows the last error. Other errors are not retried.
Future<T> retryBusy<T>(Future<T> Function() action) async {
  for (var attempt = 1; ; attempt++) {
    try {
      return await action();
    } on FileSystemException {
      if (attempt >= 10) rethrow;
      await Future<void>.delayed(Duration(milliseconds: 100 * attempt));
    }
  }
}

/// Deletes [entity] (with its contents) if it exists, and ignores a failure. Only for
/// cleanup after an error or of temporary files, where a leftover does no harm: every
/// .part file is overwritten the next time.
void deleteQuietly(FileSystemEntity entity) {
  try {
    if (entity.existsSync()) entity.deleteSync(recursive: true);
  } on FileSystemException {
    // left behind; see above
  }
}
