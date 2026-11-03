import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/cdp.dart';
import 'package:kantahe_maker/spotsaver.dart';
import 'package:kantahe_maker/tools.dart';
import 'package:path/path.dart' as p;

import 'support/process.dart';

/// A tiny file that is an MP3 as far as readMp3Info can tell (a 128 kbps frame header).
final tinyMp3 = [0xFF, 0xFB, 0x90, 0x00, ...List.filled(1996, 7)];

/// An ID3v2.4 tag with [body] bytes after its header.
List<int> id3Tag(int body) => [
  ...'ID3'.codeUnits, 4, 0, 0,
  body >> 21 & 0x7F, body >> 14 & 0x7F, body >> 7 & 0x7F, body & 0x7F,
  ...List.filled(body, 0),
];

/// What spotsaver.net sent for one song: cover art in a tag over 64 KB, a second tag, then audio.
final bigTagMp3 = [...id3Tag(65673), ...id3Tag(177), ...tinyMp3];

/// A browser to test with: KANTAHE_TEST_BROWSER, else one installed in the usual place.
String? testBrowser() {
  final named = Platform.environment['KANTAHE_TEST_BROWSER'];
  if (named != null && File(named).existsSync()) return named;
  final (os, _) = parseHost(Platform.version);
  return findBrowser(os, Platform.environment);
}

final browser = testBrowser();
final noBrowser = browser == null
    ? 'no Chromium-based browser installed (set KANTAHE_TEST_BROWSER)'
    : false;

/// A site that behaves like spotsaver.net as far as the app uses it: a page with a link
/// box, a results page with a "Download" button that converts (its text changes) and then
/// downloads, and the file. [mode] decides how it ends.
class FakeSite {
  FakeSite(this.mode);

  /// ok, bigtag (the MP3 starts with two ID3 tags, 65,870 bytes), html (the file is a web page), failed, slow (never finishes converting), nobox,
  /// nobutton, late (the first load of the home page is not ready for the form for 2.5 s:
  /// a submit before that is a plain page load, as on a real page that is not hydrated yet).
  final String mode;
  late HttpServer server;
  final paths = <String>[];
  final links = <String>[];
  var earlyClicks = 0;
  var decoyClicks = 0;
  var homeLoads = 0;
  Uri get base => Uri.parse('http://127.0.0.1:${server.port}/');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      paths.add(req.uri.path);
      final r = req.response;
      switch (req.uri.path) {
        case '/':
          final notReady = mode == 'late' && ++homeLoads == 1;
          r.headers.contentType = ContentType.html;
          r.write(
            mode == 'nobox'
                ? '<html><title>SpotSaver fake</title><body>nothing to type into</body></html>'
                : '''<!doctype html><html><head><title>SpotSaver fake</title></head><body>
<form id="f"><input type="text" id="q"><button type="submit">Go</button></form>
<script>
function ready() {
  document.getElementById('f').addEventListener('submit', function (e) {
    e.preventDefault();
    sessionStorage.setItem('q', document.getElementById('q').value);
    location.href = '/results/';
  });
}
${notReady ? 'setTimeout(ready, 2500);' : 'ready();'}
</script></body></html>''',
          );
        case '/results/':
          r.headers.contentType = ContentType.html;
          final end = switch (mode) {
            'failed' => "b.disabled = false; b.textContent = 'Failed'; state = 'failed';",
            'slow' => '',
            _ => "b.disabled = false; b.textContent = 'Download'; state = 'ready';",
          };
          r.write(
            mode == 'nobutton'
                ? '<html><body><form><input type="text"><button type="button">Download</button></form>'
                      '<button>Multi Download</button></body></html>'
                : '''<!doctype html><html><body>
<!-- Like the real page: the search form is still there, with its own Download button. -->
<form id="sf"><input type="text"><button type="button" id="decoy">Download</button></form>
<button id="other">Multi Download</button>
<div><button id="b"><span>Convert</span></button><button id="pv">Preview</button><span>320 kbps</span></div>
<script>
fetch('/seen?q=' + encodeURIComponent(sessionStorage.getItem('q')));
document.getElementById('decoy').addEventListener('click', function () { fetch('/decoy'); });
var state = 'idle', b = document.getElementById('b');
b.addEventListener('click', function () {
  if (state === 'idle') {
    // Like a real page: the button still says Convert for a moment after the press.
    state = 'pending';
    setTimeout(function () {
      state = 'working'; b.disabled = true; b.textContent = 'Converting... 50%';
      setTimeout(function () { $end }, 1000);
    }, 800);
  } else if (state === 'pending') {
    fetch('/early');
  } else if (state === 'ready') {
    var a = document.createElement('a');
    a.href = '/file.mp3'; a.download = 'x.mp3';
    document.body.appendChild(a); a.click();
  }
});
</script></body></html>''',
          );
        case '/decoy':
          decoyClicks++;
          r.write('ok');
        case '/early':
          earlyClicks++;
          r.write('ok');
        case '/seen':
          links.add(req.uri.queryParameters['q'] ?? '');
          r.write('ok');
        case '/file.mp3':
          if (mode == 'html') {
            r.headers.contentType = ContentType.html;
            r.headers.set('Content-Disposition', 'attachment; filename="x.mp3"');
            r.write('<html>this is not an MP3</html>');
          } else {
            r.headers.contentType = ContentType('audio', 'mpeg');
            r.headers.set('Content-Disposition', 'attachment; filename="x.mp3"');
            r.add(mode == 'bigtag' ? bigTagMp3 : tinyMp3);
          }
        default:
          r.statusCode = 404;
      }
      r.close();
    });
  }

  Future<void> stop() => server.close(force: true);
}


void main() {
  const link = 'https://open.spotify.com/track/4u7EnebtmKWzUH433cf5Qv';

  test('check_page_detection', () {
    expect(looksLikeCheckPage('Just a moment...', ''), isTrue);
    expect(looksLikeCheckPage('SpotSaver', 'Please Verify you are human first'), isTrue);
    expect(looksLikeCheckPage('x', 'Checking your browser before accessing'), isTrue);
    expect(looksLikeCheckPage('x', 'Solve the CAPTCHA'), isTrue);
    expect(looksLikeCheckPage('SpotSaver', 'Download'), isFalse);
  });

  test('browser_launch_modes', () {
    void mode(bool headless, bool forUser, bool wantHeadless, List<String> wantArgs) {
      final m = browserLaunch(headless: headless, forUser: forUser);
      expect(m.headless, wantHeadless, reason: 'headless $headless forUser $forUser');
      expect(m.args, wantArgs, reason: 'headless $headless forUser $forUser');
    }

    // A check the user must do: a normal window in front, whatever else is asked.
    mode(false, true, false, []);
    mode(true, true, false, []);
    // Tests: no window. The real thing: a minimized window (the site refuses headless).
    mode(true, false, true, []);
    mode(false, false, false, ['--start-minimized']);
  });

  test('no_browser', () async {
    final into = Directory.systemTemp.createTempSync('ss_test');
    addTearDown(() => into.deleteSync(recursive: true));
    await expectLater(
      downloadWithSpotsaver(link, into, browserExists: (_) => false),
      throwsA(
        isA<SpotsaverException>().having(
          (e) => e.message,
          'message',
          'Kantahe Maker needs Google Chrome or Microsoft Edge to download from '
              'spotsaver.net. Install one of them, or choose an MP3 file.',
        ),
      ),
    );
    expect(into.listSync(), isEmpty);
  });

  group('against a fake site and a real browser', () {
    late FakeSite site;
    late Directory into;
    final statuses = <String>[];
    final logs = <String>[];
    CdpBrowser? started;

    Future<void> startSite(String mode) async {
      site = FakeSite(mode);
      await site.start();
    }

    setUp(() {
      statuses.clear();
      logs.clear();
      started = null;
      into = Directory.systemTemp.createTempSync('ss_test');
    });
    tearDown(() async {
      await site.stop();
      into.deleteSync(recursive: true);
    });

    Future<File> run({
      Future<void>? cancel,
      Duration timeout = const Duration(seconds: 60),
      Duration findTimeout = const Duration(seconds: 20),
      bool headless = true,
    }) => downloadWithSpotsaver(
      link,
      into,
      site: site.base,
      browserPath: browser,
      timeout: timeout,
      findTimeout: findTimeout,
      headless: headless,
      cancel: cancel,
      onStatus: (s, received, total) => statuses.add(s),
      onBrowser: (b) => started = b,
      onLog: logs.add,
    );

    void expectBrowserGone() {
      final b = started!;
      expect(b.pid, isNotNull);
      expect(processAlive(b.pid!), isFalse, reason: 'the browser is still running');
      expect(Directory(b.profilePath!).existsSync(), isFalse, reason: 'profile left');
    }

    test('full_flow_against_a_fake_site', () async {
      await startSite('ok');
      final file = await run();
      expect(file.path, p.join(into.path, 'download.mp3'));
      expect(file.readAsBytesSync(), tinyMp3);
      expect(into.listSync().map((e) => e.path), [file.path], reason: 'nothing else is left');
      expect(site.links, [link]);
      expect(site.earlyClicks, 0, reason: 'pressed again before the conversion began');
      expect(site.decoyClicks, 0, reason: 'pressed the search form\'s Download button');
      expect(statuses, contains('Converting on spotsaver.net... 50%'));
      // The debug log tells each step.
      final text = logs.join('\n');
      expect(text, contains('launching the browser (hidden)'));
      expect(text, contains('page loaded'));
      expect(text, contains('link entered and submitted'));
      expect(text, contains('button "Convert"'));
      expect(text, contains('button "Converting... 50%" (disabled)'));
      expect(text, contains('button "Download"'));
      expect(RegExp(r'click #\d').allMatches(text).length, 2);
      expect(text, contains('download completed'));
      expect(text, contains('128 kbps'));
      expect(text, contains('done: saved as download.mp3'));
      expect(text, contains('closing the browser'));
      expect(logs.every((l) => l.startsWith('spotsaver +')), isTrue);
      expectBrowserGone();
    }, skip: noBrowser, timeout: const Timeout(Duration(seconds: 90)));

    test('a_page_not_ready_for_the_form_gets_the_link_again', () async {
      await startSite('late');
      final file = await run();
      expect(file.readAsBytesSync(), tinyMp3);
      expect(site.links, [link]);
      expect(site.homeLoads, greaterThan(1), reason: 'the first submit reloaded the page');
      expect(logs.join('\n'), contains('still on the start page, sending the link again'));
      expectBrowserGone();
    }, skip: noBrowser, timeout: const Timeout(Duration(seconds: 90)));

    test('an_mp3_whose_tags_are_longer_than_64_kb_is_accepted', () async {
      await startSite('bigtag');
      final file = await run();
      expect(file.readAsBytesSync(), bigTagMp3);
      expect(logs.join('\n'), contains('file: ${bigTagMp3.length} bytes, MP3, 44.1 kHz, 128 kbps'));
      expectBrowserGone();
    }, skip: noBrowser, timeout: const Timeout(Duration(seconds: 90)));

    test('fake_site_sends_html_instead', () async {
      await startSite('html');
      await expectLater(
        run(),
        throwsA(
          isA<SpotsaverException>().having(
            (e) => e.message,
            'message',
            'spotsaver.net did not send an MP3',
          ),
        ),
      );
      expect(into.listSync(), isEmpty);
      expectBrowserGone();
    }, skip: noBrowser, timeout: const Timeout(Duration(seconds: 90)));

    // Opens a (minimized) window on the machine, so only when asked for.
    test('full_flow_in_a_minimized_window', () async {
      await startSite('ok');
      final file = await run(headless: false);
      expect(file.readAsBytesSync(), tinyMp3);
      expect(logs.join('\n'), contains('launching the browser (minimized window)'));
      expectBrowserGone();
    }, skip: browser == null
        ? 'no browser installed'
        : Platform.environment['KANTAHE_TEST_WINDOW'] == '1'
        ? false
        : 'opens a window; set KANTAHE_TEST_WINDOW=1',
        timeout: const Timeout(Duration(seconds: 90)));

    test('failures_are_logged', () async {
      await startSite('failed');
      await expectLater(run(), throwsA(isA<SpotsaverException>()));
      expect(logs.join('\n'), contains('failed: SpotsaverException'));
    }, skip: noBrowser, timeout: const Timeout(Duration(seconds: 90)));

    test('fake_site_failed_state', () async {
      await startSite('failed');
      await expectLater(
        run(),
        throwsA(
          isA<SpotsaverException>().having(
            (e) => e.message,
            'message',
            startsWith('spotsaver.net could not convert this song (Failed)'),
          ),
        ),
      );
      expect(into.listSync(), isEmpty);
      expectBrowserGone();
    }, skip: noBrowser, timeout: const Timeout(Duration(seconds: 90)));

    test('site_without_a_link_box', () async {
      await startSite('nobox');
      await expectLater(
        run(findTimeout: const Duration(seconds: 2)),
        throwsA(
          isA<SpotsaverException>().having(
            (e) => e.message,
            'message',
            'spotsaver.net looks different than expected (no link box)',
          ),
        ),
      );
      expectBrowserGone();
    }, skip: noBrowser, timeout: const Timeout(Duration(seconds: 90)));

    test('site_without_a_download_button', () async {
      await startSite('nobutton');
      await expectLater(
        run(findTimeout: const Duration(seconds: 2)),
        throwsA(
          isA<SpotsaverException>().having(
            (e) => e.message,
            'message',
            'spotsaver.net did not show the song',
          ),
        ),
      );
      expectBrowserGone();
    }, skip: noBrowser, timeout: const Timeout(Duration(seconds: 90)));

    test('cancel_kills_the_browser', () async {
      await startSite('slow');
      final cancel = Completer<void>();
      final future = run(cancel: cancel.future);
      // Wait until the conversion runs, then cancel.
      for (var i = 0; i < 300 && !statuses.any((s) => s.startsWith('Converting')); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(statuses.any((s) => s.startsWith('Converting')), isTrue);
      cancel.complete();
      await expectLater(
        future,
        throwsA(
          isA<SpotsaverException>().having((e) => e.message, 'message', 'Cancelled'),
        ),
      );
      expect(into.listSync(), isEmpty);
      expectBrowserGone();
    }, skip: noBrowser, timeout: const Timeout(Duration(seconds: 90)));

    test('the_whole_run_has_a_time_limit', () async {
      await startSite('slow');
      await expectLater(
        run(timeout: const Duration(seconds: 6)),
        throwsA(
          isA<SpotsaverException>().having(
            (e) => e.message,
            'message',
            'spotsaver.net took too long. Try again later.',
          ),
        ),
      );
      expectBrowserGone();
    }, skip: noBrowser, timeout: const Timeout(Duration(seconds: 90)));
  });
}
