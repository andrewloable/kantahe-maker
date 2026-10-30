import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/tool_pins.dart';

void main() {
  const targets = {
    'macos-arm64',
    'macos-x64',
    'linux-x64',
    'linux-arm64',
    'windows-x64',
    'windows-arm64',
  };

  test('all_targets', () {
    expect(toolDownloads.keys.toSet(), targets);
  });

  test('members_per_target', () {
    expect(toolDownloads, isNotEmpty);
    for (final entry in toolDownloads.entries) {
      final exe = entry.key.startsWith('windows') ? '.exe' : '';
      expect(
        entry.value.map((d) => d.member).toSet(),
        {'ffmpeg$exe', 'ffprobe$exe', 'uv$exe'},
        reason: entry.key,
      );
    }
  });

  test('https_and_checksums', () {
    expect(toolDownloads, isNotEmpty);
    for (final entry in toolDownloads.entries) {
      for (final d in entry.value) {
        expect(d.url, startsWith('https://'), reason: entry.key);
        expect(d.checksumUrl, startsWith('https://'), reason: entry.key);
        expect(Uri.parse(d.url).pathSegments.last, isNotEmpty);
      }
    }
  });

  test('uv_target_names', () {
    String uvUrl(String target) =>
        toolDownloads[target]!.firstWhere((d) => d.member.startsWith('uv')).url;
    expect(uvUrl('macos-arm64'), contains('uv-aarch64-apple-darwin'));
    expect(uvUrl('macos-x64'), contains('uv-x86_64-apple-darwin'));
    expect(uvUrl('linux-x64'), contains('uv-x86_64-unknown-linux-gnu'));
    expect(uvUrl('linux-arm64'), contains('uv-aarch64-unknown-linux-gnu'));
    expect(uvUrl('windows-x64'), endsWith('uv-x86_64-pc-windows-msvc.zip'));
    expect(uvUrl('windows-arm64'), endsWith('uv-aarch64-pc-windows-msvc.zip'));
  });

  test('versions_pinned', () {
    for (final v in [
      uvVersion,
      ffmpegVersion,
      pythonVersion,
      audioSeparatorVersion,
    ]) {
      expect(v, isNotEmpty);
      expect(v.toLowerCase(), isNot('latest'));
    }
    for (final entry in toolDownloads.entries) {
      for (final d in entry.value) {
        expect(d.url, isNot(contains('/latest/')), reason: d.url);
        expect(d.checksumUrl, isNot(contains('/latest/')), reason: d.url);
      }
    }
  });

  test('licenses_and_sizes', () {
    expect(toolLicenses.length, 5);
    expect(toolLicenses.values.every((v) => v.isNotEmpty), isTrue);
    expect(approxSizeMb.length, 4);
    expect(approxSizeMb.values.every((v) => v > 0), isTrue);
  });

  test('separator_settings', () {
    expect(separatorModel, 'UVR-MDX-NET-Inst_HQ_3.onnx');
    expect(singleStemInstrumental, 'Instrumental');
    // audio-separator imports audioread but does not declare it (found by hand).
    expect(separatorExtraPackages, contains('audioread'));
  });
}
