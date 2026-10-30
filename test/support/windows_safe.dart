import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Matches a path string whatever separator it uses: on Windows the app builds paths
/// with backslashes while tests write them with slashes.
Matcher samePath(String expected) => predicate<Object?>(
  (actual) => actual is String && p.normalize(actual) == p.normalize(expected),
  'is the path $expected',
);

/// Reads [file] as text. Windows refuses to open a file while the app is replacing it
/// (project.json is saved through a rename), so try again for a moment.
String readText(File file) {
  for (var attempt = 0; ; attempt++) {
    try {
      return file.readAsStringSync();
    } on FileSystemException {
      if (attempt >= 100) rethrow;
      sleep(const Duration(milliseconds: 10));
    }
  }
}
