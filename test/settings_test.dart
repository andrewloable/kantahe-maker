import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/settings.dart';

void main() {
  late Directory tmp;
  late File file;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('settings_test');
    file = File('${tmp.path}/sub/settings.json');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('defaults_when_there_is_no_file', () async {
    expect((await readSettings(file)).useGraphicsCard, isFalse);
  });

  test('round_trip', () async {
    await writeSettings(file, const AppSettings(useGraphicsCard: true));
    expect((await readSettings(file)).useGraphicsCard, isTrue);
    await writeSettings(file, const AppSettings());
    expect((await readSettings(file)).useGraphicsCard, isFalse);
  });

  test('written_through_a_part_file', () async {
    await writeSettings(file, const AppSettings(useGraphicsCard: true));
    expect(File('${file.path}.part').existsSync(), isFalse);
    expect(file.readAsStringSync(), '{"useGraphicsCard":true}');
  });

  test('anything_unexpected_means_the_default', () async {
    file.createSync(recursive: true);
    for (final text in ['', 'not json', '[]', '"x"', '{"useGraphicsCard":"yes"}', '{"useGraphicsCard":1}']) {
      file.writeAsStringSync(text);
      expect((await readSettings(file)).useGraphicsCard, isFalse, reason: text);
    }
  });
}
