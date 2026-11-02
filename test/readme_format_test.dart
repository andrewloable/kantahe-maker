import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/karmp3.dart';
import 'package:kantahe_maker/mp3_info.dart';
import 'package:kantahe_maker/tool_pins.dart';

// README.md, section "The .karmp3 format", is the source of truth of the format (for
// developers and AI agents). These tests keep its examples and its list of .nfo rows in
// step with the code that writes them.

String readmeSection() {
  // A Windows checkout may turn the line ends into CRLF.
  final text = File('README.md').readAsStringSync().replaceAll('\r\n', '\n');
  final start = text.indexOf('## The .karmp3 format');
  if (start < 0) fail('README.md has no section "The .karmp3 format"');
  final next = text.indexOf(RegExp(r'^## ', multiLine: true), start + 5);
  return text.substring(start, next < 0 ? text.length : next);
}

/// The text of the code block tagged [tag] in the section.
String block(String tag) {
  final m = RegExp(
    '```$tag\\n(.*?)```',
    dotAll: true,
  ).firstMatch(readmeSection());
  if (m == null) fail('README.md has no code block tagged "$tag"');
  return m.group(1)!;
}

final name = karMp3Name(
  number: 101,
  artist: 'Traditional',
  title: 'Amazing Grace',
);

Nfo exampleNfo() => Nfo(
  title: 'Amazing Grace',
  artist: 'Traditional',
  number: 101,
  composer: 'John Newton',
  lyricist: 'John Newton',
  seconds: 227,
  audio: describeMp3(const Mp3Info(kbps: 96, hertz: 44100, channels: 2)),
  separator: separatorModel.replaceAll(RegExp(r'\.onnx$'), ''),
  instrumental: '$name.mp3',
  vocals: '$name.vocals.mp3',
  vocalsAudio: 'MP3, 44.1 kHz, 48 kbps, mono',
  lyricLines: 4,
);

void main() {
  test('readme_nfo_example_matches_the_code', () {
    expect(block('nfo'), exampleNfo().toString());
  });

  test('readme_lrc_example_matches_the_code', () {
    final lrc = buildLrc(
      title: 'Amazing Grace',
      artist: 'Traditional',
      composer: 'John Newton',
      lines: const [
        LrcLine(12.5, 'Amazing grace, how sweet the sound'),
        LrcLine(17.8, 'That saved a wretch like me'),
        LrcLine(23.1, '', [
          (23.1, 'I '),
          (23.4, 'once '),
          (23.8, 'was '),
          (24.1, 'lost,'),
        ]),
        LrcLine(28.0, 'But now am found'),
      ],
    );
    expect(block('lrc'), lrc);
  });

  test('readme_listing_names_match_the_code', () {
    final listing = block('text');
    for (final entry in [
      '$name.mp3',
      '$name.lrc',
      '$name.nfo',
      '$name.vocals.mp3',
    ]) {
      expect(listing, contains(entry));
    }
    // In the order the writer uses.
    final at = [
      for (final e in [
        '$name.mp3',
        '$name.lrc',
        '$name.nfo',
        '$name.vocals.mp3',
      ])
        listing.indexOf(RegExp('${RegExp.escape(e)}\$', multiLine: true)),
    ];
    expect(at, [...at]..sort());
    expect(at.every((i) => i >= 0), isTrue);
  });

  test('readme_lists_every_nfo_key', () {
    final keys = [
      for (final line in exampleNfo().toString().trimRight().split('\n'))
        RegExp(r'^(.+?)\s+:\s').firstMatch(line)!.group(1)!,
    ];
    final section = readmeSection();
    final start = section.indexOf('### The .nfo file');
    expect(start, greaterThanOrEqualTo(0), reason: 'section "The .nfo file"');
    final end = section.indexOf('\n### ', start + 5);
    final table = section.substring(start, end < 0 ? section.length : end);
    final documented = [
      for (final m in RegExp(
        r'^\| `([^`]+)` \|',
        multiLine: true,
      ).allMatches(table))
        m.group(1)!,
    ];
    expect(
      documented,
      keys,
      reason:
          'the README table lists the .nfo rows in the order they are written',
    );
  });

  // ---- the part of the README for people who just want to use the app

  String readme() => File('README.md').readAsStringSync();

  /// The text of the "## [heading]" section of the README.
  String part(String heading) {
    final text = readme();
    final start = text.indexOf('## $heading');
    if (start < 0) fail('README.md has no section "$heading"');
    final next = text.indexOf(RegExp(r'^## ', multiLine: true), start + 5);
    return text.substring(start, next < 0 ? text.length : next);
  }

  test('readme_images_exist', () {
    final text = readme();
    final paths = [
      for (final m in RegExp(r'(?:src|srcset)="([^"]+)"').allMatches(text))
        m.group(1)!,
      for (final m in RegExp(r'!\[[^\]]*\]\(([^)\s]+)\)').allMatches(text))
        m.group(1)!,
    ];
    expect(paths, isNotEmpty);
    for (final path in paths) {
      if (path.startsWith('http')) continue;
      expect(File(path).existsSync(), isTrue, reason: 'README.md shows $path');
    }
  });

  test('readme_sections_are_in_order', () {
    final text = readme();
    final at = [
      for (final h in [
        '## Why Kantahe Maker',
        '## Download',
        '## How it works',
        '## Your privacy',
        '## FAQ',
        '## For developers',
        '## The .karmp3 format',
      ])
        text.indexOf(h),
    ];
    expect(
      at.every((i) => i >= 0),
      isTrue,
      reason: 'every section is there: $at',
    );
    expect(at, [...at]..sort(), reason: 'in this order');
    expect(text, contains('kantahe.party'));
  });

  test('readme_shows_every_screenshot', () {
    final text = readme();
    for (final name in [
      '01-home.png',
      '02-remove-vocals.png',
      '03-details.png',
      '04-lyrics.png',
      '05-timing.png',
      '06-export.png',
      '07-timing-dark.png',
    ]) {
      expect(text, contains('docs/screenshots/$name'), reason: name);
    }
  });

  test('readme_privacy_names_every_service', () {
    final privacy = part('Your privacy');
    for (final word in [
      'musicbrainz.org',
      'lrclib.net',
      'lyrics.ovh',
      '1.4 GB',
    ]) {
      expect(privacy, contains(word), reason: word);
    }
  });

  test('readme_download_names_every_file', () {
    final download = part('Download');
    for (final word in [
      'releases/latest',
      'macos.zip',
      'windows.zip',
      'linux.tar.gz',
      'libmpv',
    ]) {
      expect(download, contains(word), reason: word);
    }
  });

  test('readme_lists_the_file_types', () {
    final source = File('lib/screens/home_screen.dart').readAsStringSync();
    final list = RegExp(r"extensions:\s*\[([^\]]+)\]")
        .firstMatch(source)!
        .group(1)!;
    final types = [
      for (final m in RegExp(r"'([a-z0-9]+)'").allMatches(list)) m.group(1)!,
    ];
    expect(types, isNotEmpty);
    final faq = part('FAQ');
    final start = faq.indexOf('**Which files can I use?**');
    expect(start, greaterThanOrEqualTo(0));
    final end = faq.indexOf('\n\n', start);
    final answer = faq.substring(start, end < 0 ? faq.length : end);
    for (final t in types) {
      expect(answer, contains('.$t'), reason: 'the picker offers .$t');
    }
    expect(readme(), isNot(contains('ffmpeg can read')));
  });
}
