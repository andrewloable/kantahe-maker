import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/cdp.dart';
import 'package:kantahe_maker/tools.dart';

import 'support/process.dart';

void main() {
  group('browserCandidates', () {
    test('candidates_macos', () {
      expect(browserCandidates(HostOs.macos, {'HOME': '/data/someone'}), [
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
        '/Applications/Chromium.app/Contents/MacOS/Chromium',
        '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
        '/data/someone/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '/data/someone/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
        '/data/someone/Applications/Chromium.app/Contents/MacOS/Chromium',
        '/data/someone/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
      ]);
    });

    test('candidates_macos_without_home', () {
      final list = browserCandidates(HostOs.macos, {});
      expect(list, hasLength(4));
      expect(list.every((p) => p.startsWith('/Applications/')), isTrue);
    });

    test('candidates_windows', () {
      expect(
        browserCandidates(HostOs.windows, {
          'ProgramFiles': r'C:\Program Files',
          'ProgramFiles(x86)': r'C:\Program Files (x86)',
          'LOCALAPPDATA': r'C:\Profiles\x\AppData\Local',
        }),
        [
          r'C:\Program Files\Google\Chrome\Application\chrome.exe',
          r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
          r'C:\Profiles\x\AppData\Local\Google\Chrome\Application\chrome.exe',
          r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
          r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
        ],
      );
    });

    test('candidates_windows_skip_missing_variables', () {
      final list = browserCandidates(HostOs.windows, {
        'ProgramFiles': r'C:\Program Files',
      });
      expect(list, [
        r'C:\Program Files\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
      ]);
      expect(list.any((p) => p.contains('null')), isFalse);
    });

    test('candidates_linux', () {
      final list = browserCandidates(HostOs.linux, {'PATH': '/usr/bin:/opt/b'});
      expect(list.take(3), [
        '/usr/bin/google-chrome',
        '/usr/bin/google-chrome-stable',
        '/usr/bin/chromium',
      ]);
      expect(list, contains('/opt/b/microsoft-edge'));
      expect(list, hasLength(12));
    });

    test('find_browser_takes_the_first_that_exists', () {
      final found = findBrowser(
        HostOs.macos,
        {},
        exists: (p) => p.contains('Edge') || p.contains('Brave'),
      );
      expect(found, '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge');
      expect(findBrowser(HostOs.macos, {}, exists: (_) => false), isNull);
    });
  });

  group('parseDevToolsActivePort', () {
    test('devtools_port_parse', () {
      expect(
        parseDevToolsActivePort('9222\n/devtools/browser/abc\n'),
        (9222, '/devtools/browser/abc'),
      );
    });

    test('devtools_port_parse_rejects_other_text', () {
      expect(() => parseDevToolsActivePort('x'), throwsFormatException);
      expect(() => parseDevToolsActivePort('abc\n/p'), throwsFormatException);
      expect(() => parseDevToolsActivePort(''), throwsFormatException);
    });
  });

  group('readPortFile', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('portfile'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('port_file_missing_is_null', () {
      expect(readPortFile(File('${dir.path}/DevToolsActivePort')), isNull);
    });

    test('port_file_half_written_is_null', () {
      final f = File('${dir.path}/DevToolsActivePort');
      f.writeAsStringSync('');
      expect(readPortFile(f), isNull);
      f.writeAsStringSync('9222');
      expect(readPortFile(f), isNull);
      f.writeAsStringSync('9222\n');
      expect(readPortFile(f), isNull);
    });

    test('port_file_is_read', () {
      final f = File('${dir.path}/DevToolsActivePort')
        ..writeAsStringSync('9222\n/devtools/browser/abc\n');
      expect(readPortFile(f), (9222, '/devtools/browser/abc'));
    });

    test('port_file_that_cannot_be_opened_is_null', () {
      // A file the browser still holds locked (Windows) cannot be read; without read
      // permission it fails the same way (a FileSystemException).
      final f = File('${dir.path}/DevToolsActivePort')
        ..writeAsStringSync('9222\n/devtools/browser/abc\n');
      Process.runSync('chmod', ['000', f.path]);
      addTearDown(() => Process.runSync('chmod', ['600', f.path]));
      try {
        f.readAsStringSync();
        markTestSkipped('this user can read the file anyway (running as root?)');
        return;
      } on FileSystemException {
        // As intended.
      }
      expect(readPortFile(f), isNull);
    }, skip: Platform.isWindows ? 'chmod does not exist on Windows' : false);
  });

  group('CdpBrowser with a real browser', () {
    String? exe() {
      final named = Platform.environment['KANTAHE_TEST_BROWSER'];
      if (named != null && File(named).existsSync()) return named;
      final (os, _) = parseHost(Platform.version);
      return findBrowser(os, Platform.environment);
    }

    final found = exe();

    test('cdp_cancel_closes_a_real_browser', () async {
      final b = await CdpBrowser.launch(found!);
      final pid = b.pid!;
      final profile = b.profilePath!;
      expect(processAlive(pid), isTrue);
      expect(Directory(profile).existsSync(), isTrue);
      b.cancel();
      await b.done.timeout(const Duration(seconds: 20));
      expect(processAlive(pid), isFalse);
      expect(Directory(profile).existsSync(), isFalse);
    }, skip: found == null ? 'no Chromium-based browser installed' : false,
        timeout: const Timeout(Duration(seconds: 60)));

    test('cdp_new_page_and_evaluate', () async {
      final b = await CdpBrowser.launch(found!);
      addTearDown(b.close);
      final session = await b.newPage();
      expect(await b.evaluate(session, '6 * 7'), 42);
      expect(await b.evaluate(session, "document.location.href"), 'about:blank');
      await expectLater(b.evaluate(session, 'throw new Error("x")'), throwsA(isA<CdpException>()));
    }, skip: found == null ? 'no Chromium-based browser installed' : false,
        timeout: const Timeout(Duration(seconds: 60)));
  });

  group('CdpBrowser messages (a fake browser on a local WebSocket)', () {
    late HttpServer server;
    late WebSocket fake;
    late CdpBrowser browser;
    final received = <Map<String, dynamic>>[];
    // Called with each message the app sends; the test answers through [fake].
    late void Function(Map<String, dynamic>) onMessage;

    setUp(() async {
      received.clear();
      onMessage = (_) {};
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final connected = Completer<WebSocket>();
      server.listen((req) async {
        connected.complete(await WebSocketTransformer.upgrade(req));
      });
      final client = await WebSocket.connect('ws://127.0.0.1:${server.port}');
      fake = await connected.future;
      fake.listen((data) {
        final m = jsonDecode(data as String) as Map<String, dynamic>;
        received.add(m);
        onMessage(m);
      });
      browser = CdpBrowser.attach(client);
    });
    tearDown(() async {
      await browser.close();
      await fake.close();
      await server.close(force: true);
    });

    test('cdp_send_matches_ids', () async {
      final answers = <int, Map<String, dynamic>>{};
      onMessage = (m) {
        answers[m['id'] as int] = m;
        if (answers.length == 2) {
          // The second request is answered first.
          fake.add(jsonEncode({'id': 2, 'result': {'v': 'second'}}));
          fake.add(jsonEncode({'id': 1, 'result': {'v': 'first'}}));
        }
      };
      final a = browser.send('A.one');
      final b = browser.send('B.two', {'x': 1}, 'sess');
      expect((await a)['v'], 'first');
      expect((await b)['v'], 'second');
      expect(received[0], {'id': 1, 'method': 'A.one'});
      expect(received[1], {
        'id': 2,
        'method': 'B.two',
        'params': {'x': 1},
        'sessionId': 'sess',
      });
    });

    test('cdp_error_reply_throws', () async {
      onMessage = (m) =>
          fake.add(jsonEncode({'id': m['id'], 'error': {'code': -32601, 'message': 'nope'}}));
      await expectLater(
        browser.send('X.y'),
        throwsA(isA<CdpException>().having((e) => e.message, 'message', contains('nope'))),
      );
    });

    test('cdp_events_are_separate_from_replies', () async {
      final event = browser.events.first;
      fake.add(jsonEncode({'method': 'Page.loadEventFired', 'params': {'timestamp': 1}}));
      expect((await event)['method'], 'Page.loadEventFired');
    });

    test('cdp_evaluate_returns_the_value', () async {
      onMessage = (m) => fake.add(
        jsonEncode({
          'id': m['id'],
          'result': {
            'result': {'type': 'string', 'value': 'hi'},
          },
        }),
      );
      expect(await browser.evaluate('s1', '1+1'), 'hi');
      expect(received.single['method'], 'Runtime.evaluate');
      expect(received.single['sessionId'], 's1');
      expect(received.single['params'], {
        'expression': '1+1',
        'returnByValue': true,
        'awaitPromise': true,
      });
    });

    test('cdp_evaluate_throws_on_a_script_error', () async {
      onMessage = (m) => fake.add(
        jsonEncode({
          'id': m['id'],
          'result': {
            'exceptionDetails': {'text': 'Uncaught', 'exception': {'description': 'boom'}},
          },
        }),
      );
      await expectLater(browser.evaluate('s1', 'x'), throwsA(isA<CdpException>()));
    });

    test('cdp_pending_sends_fail_when_the_socket_closes', () async {
      // The matcher is attached first: the error may arrive before the next line runs.
      final pending = expectLater(
        browser.send('Never.answered'),
        throwsA(isA<CdpException>()),
      );
      await fake.close();
      await pending;
    });
  });
}
