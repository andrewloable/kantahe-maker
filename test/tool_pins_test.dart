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
    // Only BtbN's stable "latest" tag may be used, and only with the release line (n9.0)
    // in the file name: dated BtbN tags are deleted after about two weeks.
    for (final entry in toolDownloads.entries) {
      for (final d in entry.value) {
        final btbn = d.url.contains('BtbN/FFmpeg-Builds');
        if (!btbn) {
          expect(d.url, isNot(contains('/latest/')), reason: d.url);
          expect(d.checksumUrl, isNot(contains('/latest/')), reason: d.url);
        } else {
          expect(d.url, contains('ffmpeg-n9.0-latest-'), reason: d.url);
        }
      }
    }
  });

  test('btbn_urls_do_not_use_a_dated_tag', () {
    for (final entry in toolDownloads.entries) {
      for (final d in entry.value) {
        for (final u in [d.url, d.checksumUrl]) {
          if (u.contains('BtbN/FFmpeg-Builds')) {
            expect(u, isNot(contains('/autobuild-')), reason: '${entry.key} $u');
            expect(u, contains('/releases/download/latest/'), reason: u);
          }
        }
      }
    }
  });

  test('btbn_archive_names_per_target', () {
    String archive(String target) => toolDownloads[target]!.first.url.split('/').last;
    expect(archive('windows-x64'), 'ffmpeg-n9.0-latest-win64-gpl-9.0.zip');
    expect(archive('windows-arm64'), 'ffmpeg-n9.0-latest-winarm64-gpl-9.0.zip');
    expect(archive('linux-x64'), 'ffmpeg-n9.0-latest-linux64-gpl-9.0.tar.xz');
    expect(archive('linux-arm64'), 'ffmpeg-n9.0-latest-linuxarm64-gpl-9.0.tar.xz');
  });

  test('licenses_and_sizes', () {
    expect(toolLicenses.length, 6);
    expect(toolLicenses.values.every((v) => v.isNotEmpty), isTrue);
    expect(toolLicenses['yt-dlp'], 'Unlicense');
    expect(approxSizeMb.length, 6);
    expect(approxSizeMb['yt-dlp'], greaterThan(0));
    expect(approxSizeMb['graphics card'], 650);
    expect(approxSizeMb.values.every((v) => v > 0), isTrue);
  });

  test('yt_dlp_settings', () {
    expect(ytDlpVersion, matches(RegExp(r'^\d{4}\.\d{2}\.\d{2}(\.\d+)?$')));
    // Without a JavaScript runtime yt-dlp warns that YouTube support is deprecated (spike km-65t.9).
    expect(ytDlpJsRuntime, 'deno');
  });

  test('separator_settings', () {
    expect(separatorModel, 'UVR-MDX-NET-Inst_HQ_3.onnx');
    // audio-separator imports audioread but does not declare it (found by hand).
    expect(separatorExtraPackages, contains('audioread'));
  });
}
