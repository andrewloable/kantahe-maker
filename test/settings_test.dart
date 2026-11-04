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

  test('settings_cloudflare_round_trip', () async {
    await writeSettings(
      file,
      const AppSettings(cloudflareAccountId: 'acc', cloudflareToken: 'tok'),
    );
    final back = await readSettings(file);
    expect(back.cloudflareAccountId, 'acc');
    expect(back.cloudflareToken, 'tok');
    expect(back.hasCloudflare, isTrue);
  });

  test('settings_cloudflare_bad_values', () {
    final s = AppSettings.fromJson({'cloudflareToken': 5, 'cloudflareAccountId': ['x']});
    expect(s.cloudflareToken, '');
    expect(s.cloudflareAccountId, '');
    expect(s.hasCloudflare, isFalse);
    expect(const AppSettings(cloudflareAccountId: 'a', cloudflareToken: '  ').hasCloudflare, isFalse);
    expect(const AppSettings(cloudflareAccountId: ' ', cloudflareToken: 't').hasCloudflare, isFalse);
  });

  test('settings_copy_with_keeps_the_rest', () {
    const s = AppSettings(useGraphicsCard: true, cloudflareAccountId: 'a', cloudflareToken: 't');
    final c = s.copyWith(useGraphicsCard: false);
    expect(c.useGraphicsCard, isFalse);
    expect(c.cloudflareAccountId, 'a');
    expect(c.cloudflareToken, 't');
  });

  test('settings_file_with_a_token_is_private', () async {
    if (Platform.isWindows) return;
    await writeSettings(file, const AppSettings(cloudflareToken: 'tok'));
    expect(file.statSync().mode & 0x1ff, 384, reason: '0600');
  });

  test('settings_verified_round_trip', () async {
    await writeSettings(
      file,
      const AppSettings(cloudflareAccountId: 'a', cloudflareToken: 't', cloudflareVerified: true),
    );
    final back = await readSettings(file);
    expect(back.cloudflareVerified, isTrue);
    expect(back.cloudflareReady, isTrue);
  });

  test('settings_verified_default_false', () {
    expect(const AppSettings().cloudflareVerified, isFalse);
    expect(AppSettings.fromJson({'cloudflareVerified': 'yes'}).cloudflareVerified, isFalse);
    expect(const AppSettings().toJson().containsKey('cloudflareVerified'), isFalse);
  });

  test('settings_ready_needs_keys_and_the_test', () {
    expect(const AppSettings(cloudflareAccountId: 'a', cloudflareToken: 't').cloudflareReady, isFalse);
    expect(const AppSettings(cloudflareVerified: true).cloudflareReady, isFalse, reason: 'no keys');
    expect(
      const AppSettings(cloudflareAccountId: 'a', cloudflareToken: 't', cloudflareVerified: true)
          .copyWith(useGraphicsCard: true)
          .cloudflareReady,
      isTrue,
    );
  });
}
