import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/fs_retry.dart';

void main() {
  group('retryBusy', () {
    test('retry_busy_returns_after_failures', () async {
      var calls = 0;
      final result = await retryBusy(() async {
        if (++calls <= 3) throw const FileSystemException('sharing violation', 'f');
        return 7;
      });
      expect(result, 7);
      expect(calls, 4);
    });

    test('retry_busy_gives_up', () async {
      var calls = 0;
      await expectLater(
        retryBusy<void>(() async {
          calls++;
          throw const FileSystemException('sharing violation', 'f');
        }),
        throwsA(isA<FileSystemException>()),
      );
      expect(calls, 10);
    });

    test('retry_busy_does_not_retry_other_errors', () async {
      var calls = 0;
      await expectLater(
        retryBusy<void>(() async {
          calls++;
          throw StateError('no');
        }),
        throwsStateError,
      );
      expect(calls, 1);
    });
  });

  group('deleteQuietly', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('fs_retry_test'));
    tearDown(() => deleteQuietly(tmp));

    test('delete_quietly_ignores_a_missing_file', () {
      deleteQuietly(File('${tmp.path}/missing'));
    });

    test('delete_quietly_removes_a_file', () {
      final f = File('${tmp.path}/a')..writeAsStringSync('x');
      deleteQuietly(f);
      expect(f.existsSync(), isFalse);
    });

    test('delete_quietly_ignores_a_failure', () {
      final d = Directory('${tmp.path}/ro')..createSync();
      final f = File('${d.path}/kept')..writeAsStringSync('x');
      // A read-only folder cannot lose a file. Restored before the temp folder goes.
      addTearDown(() => Process.runSync('chmod', ['755', d.path]));
      Process.runSync('chmod', ['555', d.path]);
      deleteQuietly(f);
      expect(f.existsSync(), isTrue);
    }, skip: Platform.isWindows); // needs a read-only folder

    test('delete_quietly_removes_a_folder', () {
      final d = Directory('${tmp.path}/d')..createSync();
      File('${d.path}/inner').writeAsStringSync('x');
      deleteQuietly(d);
      expect(d.existsSync(), isFalse);
    });
  });
}
