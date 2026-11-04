import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/karmp3.dart' show LrcLine;
import 'package:kantahe_maker/preview.dart';
import 'package:kantahe_maker/project.dart';
import 'package:kantahe_maker/tap_session.dart';

// Made-up lyrics only.
SongProject song({
  List<double?> times = const [1.0, 3.0],
  List<List<double?>?>? wordTimes,
  double offset = 0.2,
}) =>
    SongProject(id: 'x', inputPath: '/x/in.mp3')
      ..lyrics = 'la la\nna na'
      ..times = List.of(times)
      ..wordTimes = wordTimes ?? [[1.0, 1.4], null]
      ..offset = offset;

Duration ms(int v) => Duration(milliseconds: v);

void main() {
  group('previewLines', () {
    test('preview_lines_are_the_export_lines', () {
      final lines = previewLines(song());
      expect(lines, hasLength(2));
      expect(lines[0].seconds, closeTo(1.2, 1e-9));
      expect(lines[0].text, 'la la');
      expect(lines[0].words.map((w) => w.$2), ['la ', 'la']);
      expect(lines[0].words[0].$1, closeTo(1.2, 1e-9));
      expect(lines[0].words[1].$1, closeTo(1.6, 1e-9));
      expect(lines[1].seconds, closeTo(3.2, 1e-9));
      expect(lines[1].words, isEmpty);
      // The very lines the export writes.
      final p = song();
      final expected = TapSession(
        p.lyricLines(),
        times: p.times,
        wordTimes: p.wordTimes,
        offset: p.offset,
      ).exportLines();
      String show(LrcLine l) => '${l.seconds}|${l.text}|${l.words}';
      expect(lines.map(show).toList(), expected.map(show).toList());
    });

    test('preview_lines_use_the_offset', () {
      expect(previewLines(song(offset: 0, wordTimes: [null, null])).first.seconds, 1.0);
      expect(previewLines(song(offset: -0.5, wordTimes: [null, null])).first.seconds, 0.5);
    });

    test('preview_lines_throw_when_untimed', () {
      expect(() => previewLines(song(times: [1.0, null])), throwsStateError);
    });
  });

  group('previewLineAt', () {
    const lines = [LrcLine(1.0, 'a'), LrcLine(3.0, 'b'), LrcLine(5.0, 'c')];

    test('line_at', () {
      expect(previewLineAt(lines, -1), -1);
      expect(previewLineAt(lines, 0.5), -1);
      expect(previewLineAt(lines, 1.0), 0);
      expect(previewLineAt(lines, 2.99), 0);
      expect(previewLineAt(lines, 3.0), 1);
      expect(previewLineAt(lines, 99), 2);
      expect(previewLineAt(const [], 5), -1);
    });
  });

  group('previewWordAt', () {
    const line = LrcLine(1.0, 'x', [(1.0, 'la '), (1.5, 'la '), (2.0, 'la')]);

    test('word_at', () {
      expect(previewWordAt(line, 0.9), -1);
      expect(previewWordAt(line, 1.0), 0);
      expect(previewWordAt(line, 1.7), 1);
      expect(previewWordAt(line, 5), 2);
    });

    test('word_at_for_a_line_without_words', () {
      expect(previewWordAt(const LrcLine(1.0, 'la'), 5), -1);
    });
  });

  group('VocalsSync', () {
    test('vocals_sync_inside_the_limit', () {
      final sync = VocalsSync();
      expect(sync.shouldReseek(instrumental: ms(10000), vocals: ms(10150), now: ms(0)), isFalse);
      expect(sync.shouldReseek(instrumental: ms(10000), vocals: ms(10000), now: ms(0)), isFalse);
      expect(sync.shouldReseek(instrumental: ms(10000), vocals: ms(10151), now: ms(0)), isTrue);
    });

    test('vocals_sync_either_direction', () {
      expect(VocalsSync().shouldReseek(instrumental: ms(10000), vocals: ms(9700), now: ms(0)), isTrue);
      expect(VocalsSync().shouldReseek(instrumental: ms(10000), vocals: ms(10300), now: ms(0)), isTrue);
    });

    test('vocals_sync_pause', () {
      final sync = VocalsSync();
      expect(sync.shouldReseek(instrumental: ms(0), vocals: ms(400), now: ms(10000)), isTrue);
      expect(sync.shouldReseek(instrumental: ms(0), vocals: ms(200), now: ms(10500)), isFalse);
      expect(sync.shouldReseek(instrumental: ms(0), vocals: ms(200), now: ms(10999)), isFalse);
      expect(sync.shouldReseek(instrumental: ms(0), vocals: ms(200), now: ms(11000)), isTrue);
    });

    test('vocals_sync_no_reseek_means_no_pause_started', () {
      final sync = VocalsSync();
      // In step: nothing happens, and it does not start the pause.
      expect(sync.shouldReseek(instrumental: ms(0), vocals: ms(50), now: ms(10000)), isFalse);
      expect(sync.shouldReseek(instrumental: ms(0), vocals: ms(400), now: ms(10100)), isTrue);
    });

    test('vocals_sync_reset', () {
      final sync = VocalsSync();
      expect(sync.shouldReseek(instrumental: ms(0), vocals: ms(400), now: ms(10000)), isTrue);
      sync.reset();
      expect(sync.shouldReseek(instrumental: ms(0), vocals: ms(400), now: ms(10100)), isTrue);
    });
  });

  test('clock_label', () {
    expect(clockLabel(const Duration(seconds: 7)), '0:07');
    expect(clockLabel(ms(227900)), '3:47');
    expect(clockLabel(const Duration(seconds: 3725)), '62:05');
    expect(clockLabel(const Duration(seconds: -3)), '0:00');
    expect(clockLabel(Duration.zero), '0:00');
  });

  test('vocals_level', () {
    expect(vocalsLevel(100), 1.0);
    expect(vocalsLevel(55), 0.5);
    expect(vocalsLevel(50), 0.5);
    expect(vocalsLevel(9), 0.0);
    expect(vocalsLevel(0), 0.0);
    expect(vocalsLevel(-4), 0.0);
    expect(vocalsLevel(250), 1.0);
  });
}
