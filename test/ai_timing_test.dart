import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/ai_timing.dart';

// Made-up lyrics only.
HeardWord h(String w, double start, {double confidence = 1}) =>
    HeardWord(word: w, start: start, end: start + 0.3, confidence: confidence);

void main() {
  group('alignLyrics', () {
    test('align_exact', () {
      final r = alignLyrics(
        ['a b', 'c'],
        [h('a', 1), h('b', 2), h('c', 3)],
      );
      expect(r.times[0], closeTo(1 - aiLeadSeconds, 1e-9));
      expect(r.times[1], closeTo(3 - aiLeadSeconds, 1e-9));
      expect(r.wordTimes[0]![1], closeTo(2 - aiLeadSeconds, 1e-9));
      expect(r.wordTimes[1], hasLength(1));
      expect(r.matched, 3);
      expect(r.total, 3);
      expect(aiLeadSeconds, 0.2);
    });

    test('align_interpolates_unheard_words', () {
      final r = alignLyrics(['a x b'], [h('a', 1), h('b', 3)]);
      expect(r.wordTimes[0]![1], closeTo(2 - aiLeadSeconds, 1e-9));
      expect(r.matched, 2);
      expect(r.total, 3);
    });

    test('align_words_before_and_after_the_heard_ones', () {
      final r = alignLyrics(['x a b y'], [h('a', 5), h('b', 6)]);
      final w = r.wordTimes[0]!;
      expect(w[0], lessThan(w[1]!));
      expect(w[3]!, greaterThan(w[2]!));
      expect(w[1], closeTo(5 - aiLeadSeconds, 1e-9));
    });

    test('align_ignores_punctuation_and_case', () {
      final r = alignLyrics(['Hello, World!'], [h('hello', 1), h('world', 2)]);
      expect(r.matched, 2);
      expect(r.wordTimes[0]![1], closeTo(2 - aiLeadSeconds, 1e-9));
    });

    test('align_repeated_chorus_in_order', () {
      final r = alignLyrics(
        ['la la', 'na', 'la la'],
        [h('la', 1), h('la', 2), h('na', 3), h('la', 4), h('la', 5)],
      );
      expect(r.times[0], lessThan(r.times[1]!));
      expect(r.times[1], lessThan(r.times[2]!));
      expect(r.times[2], closeTo(4 - aiLeadSeconds, 1e-9));
    });

    test('align_clamps_at_zero_and_never_goes_back', () {
      final r = alignLyrics(['a b'], [h('a', 0.1), h('b', 0.15)]);
      expect(r.wordTimes[0]![0], 0);
      expect(r.wordTimes[0]![1], 0);
      final all = [for (final w in r.wordTimes) ...w!];
      for (var i = 1; i < all.length; i++) {
        expect(all[i]!, greaterThanOrEqualTo(all[i - 1]!));
      }
    });

    test('align_line_time_is_its_first_word', () {
      final r = alignLyrics(['a b', 'c d'], [h('a', 1), h('b', 2), h('c', 3), h('d', 4)]);
      for (var i = 0; i < 2; i++) {
        expect(r.times[i], r.wordTimes[i]![0]);
      }
    });

    test('align_reports_unheard_lines', () {
      final r = alignLyrics(['x y', 'a b'], [h('a', 1), h('b', 2)]);
      expect(r.unheardLines, [0]);
      expect(alignLyrics(['a b'], [h('a', 1), h('b', 2)]).unheardLines, isEmpty);
    });

    test('align_nothing_heard_is_an_error', () {
      expect(() => alignLyrics(['a b'], [h('x', 1)]), throwsA(isA<AiTimingException>()));
      expect(() => alignLyrics(['a b'], const []), throwsA(isA<AiTimingException>()));
    });
  });

  group('missing words', () {
    final lines = ['a b', 'e f'];

    test('missing_words_found_between_lines', () {
      final heard = [h('a', 1), h('b', 2), h('c', 3), h('d', 4), h('x', 5), h('e', 6), h('f', 7)];
      final m = findMissingWords(lines, heard);
      expect(m, hasLength(1));
      expect(m.single.line, 1);
      expect(m.single.wordIndex, 0);
      expect(m.single.text, 'c d x');
      expect(m.single.start, 3);
    });

    test('missing_words_need_three_words', () {
      final heard = [h('a', 1), h('b', 2), h('c', 3), h('d', 4), h('e', 6), h('f', 7)];
      expect(findMissingWords(lines, heard), isEmpty);
    });

    test('missing_words_ignore_a_misheard_word', () {
      // "own" heard as "owe" is a replacement, not something missing.
      expect(
        findMissingWords(['i own it'], [h('i', 1), h('owe', 2), h('it', 3)]),
        isEmpty,
      );
    });

    test('missing_words_ignore_low_confidence', () {
      final heard = [
        h('a', 1), h('b', 2), h('c', 3, confidence: 0.3), h('d', 4), h('x', 5), h('e', 6), h('f', 7),
      ];
      expect(findMissingWords(lines, heard), isEmpty);
    });

    test('missing_words_inside_a_line_and_at_the_end', () {
      final heard = [
        h('a', 1), h('p', 2), h('q', 3), h('r', 4), h('b', 5), h('e', 6), h('f', 7), h('s', 8), h('t', 9), h('u', 10),
      ];
      final m = findMissingWords(lines, heard);
      expect(m.map((x) => (x.line, x.wordIndex, x.text)).toList(), [
        (0, 1, 'p q r'),
        (2, 0, 's t u'),
      ]);
    });

    test('with_missing_words', () {
      final out = withMissingWords(lines, [
        const MissingWords(line: 0, wordIndex: 1, text: 'p q r', start: 2),
        const MissingWords(line: 1, wordIndex: 0, text: 'c d x', start: 3),
        const MissingWords(line: 2, wordIndex: 0, text: 's t u', start: 8),
      ]);
      expect(out, ['a p q r b', 'C d x', 'e f', 'S t u']);
    });

    test('with_no_missing_words_changes_nothing', () {
      expect(withMissingWords(lines, const []), lines);
    });

    test('added_words_are_timed_afterwards', () {
      final heard = [h('a', 1), h('b', 2), h('c', 3), h('d', 4), h('x', 5), h('e', 6), h('f', 7)];
      final m = findMissingWords(lines, heard);
      final r = alignLyrics(withMissingWords(lines, m), heard);
      expect(r.lines, ['a b', 'C d x', 'e f']);
      expect(r.matched, r.total);
      expect(r.times[1], closeTo(3 - aiLeadSeconds, 1e-9));
    });
  });

  group('transcribeWords', () {
    late HttpServer server;
    late List<({String path, String? auth, String? type, int bytes, String query})> seen;
    late int status;
    late Object body;

    setUp(() async {
      seen = [];
      status = 200;
      body = {
        'result': {
          'results': {
            'channels': [
              {
                'alternatives': [
                  {
                    'words': [
                      {'word': 'hello', 'start': 1.5, 'end': 1.9, 'confidence': 0.9},
                      {'word': 'world', 'start': 2.0, 'end': 2.4, 'confidence': 0.8},
                    ],
                  },
                ],
              },
            ],
          },
        },
        'success': true,
      };
      server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) async {
        final data = await req.fold<int>(0, (n, c) => n + c.length);
        seen.add((
          path: req.uri.path,
          auth: req.headers.value('authorization'),
          type: req.headers.contentType?.mimeType,
          bytes: data,
          query: req.uri.query,
        ));
        req.response.statusCode = status;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(body));
        await req.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    Uri base() => Uri.parse('http://127.0.0.1:${server.port}/client/v4');

    Future<List<HeardWord>> run() => transcribeWords(
      Uint8List.fromList([1, 2, 3, 4]),
      accountId: 'acc1',
      token: 'secret-token',
      baseUri: base(),
    );

    test('transcribe_parses_and_unwraps', () async {
      final words = await run();
      expect(words.map((w) => w.word), ['hello', 'world']);
      expect(words.first.start, 1.5);
      expect(words.first.confidence, 0.9);
      expect(seen.single.path, '/client/v4/accounts/acc1/ai/run/@cf/deepgram/nova-3');
      expect(seen.single.auth, 'Bearer secret-token');
      expect(seen.single.type, 'audio/mpeg');
      expect(seen.single.bytes, 4);
      expect(seen.single.query, isEmpty, reason: 'no language detection: it drops quiet intros');
      // The same words without the "result" envelope.
      body = (body as Map)['result']!;
      expect((await run()).map((w) => w.word), ['hello', 'world']);
    });

    test('transcribe_sends_no_language_detection', () async {
      await run();
      expect(seen.single.query, isEmpty);
      await transcribeWords(
        Uint8List.fromList([1]),
        accountId: 'acc1',
        token: 'secret-token',
        baseUri: base(),
        language: 'tl',
      );
      expect(seen.last.query, 'language=tl');
    });

    test('transcribe_errors_never_show_the_token', () async {
      status = 401;
      body = {
        'success': false,
        'errors': [
          {'code': 10000, 'message': 'Authentication error'},
        ],
      };
      try {
        await run();
        fail('should throw');
      } on AiTimingException catch (e) {
        expect(e.message, isNot(contains('secret-token')));
        expect(e.message, contains('token'));
        expect(e.message, contains('Authentication error'));
      }
    });

    test('transcribe_server_error_says_the_status', () async {
      status = 500;
      body = {'success': false, 'errors': []};
      expect(run, throwsA(predicate((e) => e is AiTimingException && e.message.contains('500'))));
    });

    test('transcribe_no_words_is_an_error', () async {
      body = {
        'result': {
          'results': {
            'channels': [
              {'alternatives': [{'words': []}]},
            ],
          },
        },
      };
      expect(run, throwsA(predicate((e) => e is AiTimingException && e.message.contains('no words'))));
    });

    test('transcribe_unreadable_answer_is_an_error', () async {
      body = 'not what we expected';
      expect(run, throwsA(isA<AiTimingException>()));
    });
  });

  group('verifyCloudflare', () {
    late HttpServer server;
    late List<({String method, String path, String? auth, String query})> seen;
    late int status;
    late Object body;

    setUp(() async {
      seen = [];
      status = 200;
      body = {'success': true, 'result': []};
      server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) async {
        seen.add((
          method: req.method,
          path: req.uri.path,
          auth: req.headers.value('authorization'),
          query: req.uri.query,
        ));
        req.response.statusCode = status;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(body));
        await req.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    Future<void> run() => verifyCloudflare(
      accountId: ' acc1 ',
      token: 'secret-token',
      baseUri: Uri.parse('http://127.0.0.1:${server.port}/client/v4'),
    );

    test('verify_ok', () async {
      await run();
      expect(seen.single.method, 'GET');
      expect(seen.single.path, '/client/v4/accounts/acc1/ai/models/search');
      expect(seen.single.query, 'per_page=1');
      expect(seen.single.auth, 'Bearer secret-token');
    });

    test('verify_errors_never_show_the_token', () async {
      status = 401;
      body = {
        'success': false,
        'errors': [
          {'code': 10000, 'message': 'Authentication error'},
        ],
      };
      try {
        await run();
        fail('should throw');
      } on AiTimingException catch (e) {
        expect(e.message, isNot(contains('secret-token')));
        expect(e.message, contains('Authentication error'));
      }
    });

    test('verify_success_false_is_a_failure', () async {
      body = {'success': false, 'errors': []};
      expect(run, throwsA(isA<AiTimingException>()));
    });

    test('verify_unreachable_server_is_a_failure', () async {
      final port = server.port;
      await server.close(force: true);
      expect(
        () => verifyCloudflare(
          accountId: 'acc1',
          token: 'secret-token',
          baseUri: Uri.parse('http://127.0.0.1:$port/client/v4'),
        ),
        throwsA(isA<AiTimingException>()),
      );
    });
  });
}
