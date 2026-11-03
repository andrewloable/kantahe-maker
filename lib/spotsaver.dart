// Getting the MP3 of a Spotify song from spotsaver.net the way a person does, in a minimized
// Chrome or Edge window that the app drives (see cdp.dart): open the site, enter the link,
// press Download, wait while the page converts the song, press Download again, keep the file.
// spotsaver.net converts a YouTube video of the song; it is not Spotify's audio, and the site
// is not connected to Spotify or to Kantahe Maker. It can change or refuse at any time, so
// every problem ends in a message for the user. The app never changes how the browser
// presents itself and never solves a check page; when the site shows one, a window is opened
// in front and the user does it. The window is minimized rather than hidden because
// spotsaver.net refuses a headless browser (its own calls answer HTTP 403). Pure Dart: no Flutter imports.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'cdp.dart';
import 'fs_retry.dart';
import 'mp3_info.dart';
import 'tools.dart' show parseHost;

class SpotsaverException implements Exception {
  final String message;
  const SpotsaverException(this.message);
  @override
  String toString() => message;
}

final _checkPage = RegExp(
  r'just a moment|verify you are human|checking your browser|captcha',
  caseSensitive: false,
);

/// Whether a page with this [title] and [text] is a check ("are you human") page.
bool looksLikeCheckPage(String title, String text) =>
    _checkPage.hasMatch(title) || _checkPage.hasMatch(text);

const _tooLong = SpotsaverException('spotsaver.net took too long. Try again later.');
const _noBrowser = SpotsaverException(
  'Kantahe Maker needs Google Chrome or Microsoft Edge to download from spotsaver.net. '
  'Install one of them, or choose an MP3 file.',
);

// What the page shows in the main button, by state: "Convert" (at the start), something with
// "Converting..." (working), "Queued", "Download" (converted: press it again), "Downloading...",
// "Downloaded"; anything else that reads like a failure ends the run.
final _converting = RegExp('converting', caseSensitive: false);
final _queued = RegExp('queued', caseSensitive: false);
final _downloading = RegExp(r'downloading', caseSensitive: false);
final _failure = RegExp(r'fail|error|retry|try again|rate|limit|busy', caseSensitive: false);

/// Types [link] into the page's link box and submits the form a moment later (so this call
/// returns before the page moves on). Returns the page's path, or null without a link box.
String _fillJs(String link) =>
    '''
(() => {
  const input = [...document.querySelectorAll('form input')].find(
    (i) => ['', 'text', 'url', 'search'].includes((i.getAttribute('type') || '').toLowerCase()),
  );
  if (!input || !input.form) return null;
  const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
  set.call(input, ${jsonEncode(link)});
  input.dispatchEvent(new Event('input', { bubbles: true }));
  const form = input.form;
  setTimeout(() => form.requestSubmit(), 0);
  return location.pathname;
})()
''';

/// The page's path and its main button: on the results page the song card holds the main
/// button next to a "Preview" button (the search form above it has a "Download" button of its
/// own, which must never be taken). The main button is marked, so it is found again after its
/// text changes: "Convert" at first, then "Converting...", then "Download". "button" is null
/// when there is none yet.
const _stateJs = '''
(() => {
  let b = document.querySelector('[data-kantahe-dl]');
  if (!b) {
    const outside = (x) => !x.closest('form');
    const preview = [...document.querySelectorAll('button')].find(
      (x) => outside(x) && x.textContent.trim() === 'Preview',
    );
    if (preview && preview.parentElement) b = preview.parentElement.querySelector('button');
    if (b === preview) b = null;
    if (!b) {
      b = [...document.querySelectorAll('button')].find(
        (x) => outside(x) && ['Convert', 'Download'].includes(x.textContent.trim()),
      );
    }
    if (b) b.setAttribute('data-kantahe-dl', '1');
  }
  return {
    path: location.pathname,
    button: b ? { text: b.textContent.trim(), disabled: !!b.disabled } : null,
  };
})()
''';

/// Whether the link box is empty. After a submit that worked it still holds the link; after
/// one the page dropped, the page has been reloaded and the box is empty again.
const _boxEmptyJs = "(() => { const i = document.querySelector('form input'); return !!i && i.value === ''; })()";

const _clickJs = "(() => { const b = document.querySelector('[data-kantahe-dl]'); if (b) b.click(); return !!b; })()";

const _pageTextJs =
    "({ title: document.title, text: (document.body ? document.body.innerText : '').slice(0, 2000) })";

/// How to start the browser. [forUser]: a normal window in front, for a check the user has to
/// do. Otherwise a minimized window, or no window at all when [headless] (tests only: the real
/// site refuses headless browsers).
({bool headless, List<String> args}) browserLaunch({
  required bool headless,
  required bool forUser,
}) {
  if (forUser) return (headless: false, args: const []);
  if (headless) return (headless: true, args: const []);
  return (headless: false, args: const ['--start-minimized']);
}

/// Gets the MP3 of the Spotify song at [spotifyLink] from spotsaver.net into [into] as
/// download.mp3 and returns it. [onStatus] hears what is going on (and, while the file
/// arrives, how many bytes came of how many). [cancel] completing stops everything at
/// once with "Cancelled". [onBrowser] gets the browser so the caller can register it in the
/// app's job list. [onLog] gets one line per step (with the seconds since the start) for the
/// debug log; it never holds song text. The browser is always closed and its profile folder deleted, and nothing
/// but download.mp3 is left in [into]. [site], [browserPath], [browserExists] and
/// [findTimeout] (how long to wait for the link box and the song to show), [resubmitAfter]
/// (how long the page may stay on the start page before the link is sent again) and
/// [headless] are for tests.
Future<File> downloadWithSpotsaver(
  String spotifyLink,
  Directory into, {
  void Function(String status, int? received, int? total)? onStatus,
  Future<void>? cancel,
  String? browserPath,
  bool Function(String path)? browserExists,
  Uri? site,
  Duration timeout = const Duration(minutes: 5),
  Duration findTimeout = const Duration(seconds: 45),
  Duration resubmitAfter = const Duration(seconds: 6),
  bool headless = false,
  void Function(CdpBrowser browser)? onBrowser,
  void Function(String line)? onLog,
}) async {
  final (os, _) = parseHost(Platform.version);
  final exe = browserPath ?? findBrowser(os, Platform.environment, exists: browserExists);
  if (exe == null) throw _noBrowser;
  final address = (site ?? Uri.parse('https://spotsaver.net/')).toString();

  final clock = Stopwatch()..start();
  void log(String line) {
    final seconds = (clock.elapsedMilliseconds / 1000).toStringAsFixed(1);
    onLog?.call('spotsaver +${seconds}s $line');
  }

  log('start: site $address, browser $exe, time limit ${timeout.inSeconds}s');
  var cancelled = false;
  CdpBrowser? browser;
  final guids = <String>[];
  var finished = Completer<String>();
  String lastStatus = '';

  void say(String status, [int? received, int? total]) {
    if (status == lastStatus && received == null) return;
    lastStatus = status;
    if (received == null) log('status: $status');
    onStatus?.call(status, received, total);
  }

  void check() {
    if (cancelled) throw const SpotsaverException('Cancelled');
    if (clock.elapsed > timeout) throw _tooLong;
  }

  unawaited(
    cancel?.then((_) {
      log('cancel requested');
      cancelled = true;
      browser?.cancel();
    }),
  );

  /// Calls [probe] every half second until it gives something, for at most [within].
  /// A probe that fails (the page is changing, the connection is closing) counts as
  /// "nothing yet"; a cancel or the time limit ends the wait through [check].
  Future<T?> poll<T>(Future<T?> Function() probe, Duration within) async {
    final end = clock.elapsed + within;
    while (true) {
      check();
      try {
        final found = await probe();
        if (found != null) return found;
      } on CdpException {
        // Try again.
      }
      if (clock.elapsed >= end) {
        log('gave up waiting after ${within.inSeconds}s');
        return null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  /// Starts a browser on the site and returns the session of its page.
  Future<(CdpBrowser, String)> open({required bool forUser}) async {
    final mode = browserLaunch(headless: headless, forUser: forUser);
    log('launching the browser (${forUser ? 'visible window' : headless ? 'hidden' : 'minimized window'})');
    final b = await CdpBrowser.launch(exe, headless: mode.headless, extraArgs: mode.args);
    log('browser up, pid ${b.pid}');
    browser = b;
    onBrowser?.call(b);
    if (cancelled) b.cancel();
    finished = Completer<String>();
    final mine = finished;
    unawaited(mine.future.then((_) {}, onError: (Object _) {}));
    b.events.listen((e) {
      final params = e['params'];
      if (params is! Map) return;
      final guid = params['guid'];
      if (e['method'] == 'Browser.downloadWillBegin' && guid is String) {
        guids.add(guid);
        log('download begins: $guid (${params['suggestedFilename']})');
      } else if (e['method'] == 'Browser.downloadProgress' && guid is String) {
        final state = params['state'];
        if (state == 'completed' && !mine.isCompleted) {
          log('download completed: ${params['receivedBytes']} bytes');
          mine.complete(guid);
        } else if (state == 'canceled' && !mine.isCompleted) {
          log('download cancelled by the browser');
          mine.completeError(const SpotsaverException('The download was cancelled by the browser'));
        } else if (state == 'inProgress') {
          final received = params['receivedBytes'], total = params['totalBytes'];
          say(
            'Downloading the MP3...',
            received is num ? received.toInt() : null,
            total is num && total > 0 ? total.toInt() : null,
          );
        }
      }
    });
    await b.send('Browser.setDownloadBehavior', {
      'behavior': 'allowAndName',
      'downloadPath': into.path,
      'eventsEnabled': true,
    });
    final session = await b.newPage();
    final loaded = b.events
        .firstWhere((e) => e['method'] == 'Page.loadEventFired' && e['sessionId'] == session)
        .timeout(const Duration(seconds: 30));
    await b.send('Page.navigate', {'url': address}, session);
    await loaded;
    log('page loaded');
    return (b, session);
  }

  try {
    say('Opening spotsaver.net...');
    var (b, session) = await open(forUser: false);
    var linkBoxWait = findTimeout;

    final page = await b.evaluate(session, _pageTextJs);
    final checkPage = page is Map && looksLikeCheckPage('${page['title']}', '${page['text']}');
    log('home page title "${page is Map ? page['title'] : '?'}", check page: $checkPage');
    if (checkPage) {
      say('spotsaver.net wants a check. Finish it in the browser window; the download then continues by itself.');
      await b.close();
      (b, session) = await open(forUser: true);
      linkBoxWait = const Duration(minutes: 2);
    }

    var fills = 0;
    var lastFill = clock.elapsed;
    Future<String?> fill() async {
      final r = await b.evaluate(session, _fillJs(spotifyLink));
      if (r is String) {
        fills++;
        lastFill = clock.elapsed;
      }
      return r is String ? r : null;
    }

    final startPath = await poll<String>(fill, linkBoxWait);
    log('link entered and submitted (page path $startPath)');
    if (startPath == null) {
      throw const SpotsaverException('spotsaver.net looks different than expected (no link box)');
    }

    say('Finding the song on spotsaver.net...');
    var lastSeen = '';
    Future<({String text, bool disabled})?> state() async {
      final r = await b.evaluate(session, _stateJs);
      if (r is! Map) return null;
      final button = r['button'];
      final seen = 'path ${r['path']}, button ${button is Map ? '"${button['text']}"${button['disabled'] == true ? ' (disabled)' : ''}' : 'none'}';
      if (seen != lastSeen) {
        lastSeen = seen;
        log('page: $seen');
      }
      if (r['path'] == startPath) {
        // The results page is not open yet. A page that was not ready for the form (fast
        // browsers are ready for it before the page's scripts are) drops the first submit
        // and reloads: the link is then sent again, at once when the box is empty, or when
        // nothing has happened for [resubmitAfter].
        if (fills < 3) {
          final waited = clock.elapsed - lastFill;
          final emptied =
              waited > const Duration(seconds: 1) && await b.evaluate(session, _boxEmptyJs) == true;
          if (emptied || waited > resubmitAfter) {
            log('still on the start page, sending the link again');
            await fill();
          }
        }
        return null;
      }
      if (button is! Map) return null;
      return (text: '${button['text']}', disabled: button['disabled'] == true);
    }

    if (await poll(state, findTimeout) == null) {
      throw const SpotsaverException('spotsaver.net did not show the song');
    }

    var clicks = 0;
    var sawWork = false;
    var lastClick = clock.elapsed;
    Future<void> click() async {
      final found = await b.evaluate(session, _clickJs);
      log('click #${clicks + 1} (button found: $found)');
      clicks++;
      sawWork = false;
      lastClick = clock.elapsed;
    }

    await click();
    while (!finished.isCompleted) {
      check();
      ({String text, bool disabled})? now;
      try {
        now = await state();
      } on CdpException {
        now = null;
      }
      if (now != null) {
        final text = now.text;
        if (_converting.hasMatch(text)) {
          sawWork = true;
          final progress = text.replaceAll(RegExp('converting\\.*', caseSensitive: false), '').trim();
          say('Converting on spotsaver.net...${progress.isEmpty ? '' : ' $progress'}');
        } else if (_queued.hasMatch(text)) {
          sawWork = true;
          say('Waiting in line on spotsaver.net...');
        } else if (text == 'Convert') {
          // Still at the start: the first press did nothing, press again after a while.
          final idle = clock.elapsed - lastClick > const Duration(seconds: 10);
          if (!now.disabled && idle && clicks < 4) await click();
        } else if (text == 'Download') {
          // Ready: press again once the page has been working (or the first press did nothing
          // for a while, which is also how a page that is already done looks).
          final idle = clock.elapsed - lastClick > const Duration(seconds: 10);
          if (!now.disabled && (sawWork || idle) && clicks < 4) await click();
        } else if (_downloading.hasMatch(text) && text != 'Downloaded') {
          sawWork = true;
          say('Preparing the file...');
        } else if (text != 'Downloaded' && _failure.hasMatch(text)) {
          throw SpotsaverException(
            'spotsaver.net could not convert this song ($text). Try again later.',
          );
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (finished.isCompleted) break;
    }

    final guid = await finished.future.timeout(
      timeout - clock.elapsed > Duration.zero ? timeout - clock.elapsed : const Duration(milliseconds: 1),
      onTimeout: () => throw _tooLong,
    );
    final received = File(p.join(into.path, guid));
    if (!received.existsSync()) {
      throw const SpotsaverException('spotsaver.net did not send an MP3');
    }
    final length = received.lengthSync();
    final reader = received.openSync();
    final head = reader.readSync(64 * 1024);
    reader.closeSync();
    final info = readMp3Info(head);
    log('file: $length bytes, ${info == null ? 'not an MP3' : describeMp3(info, withChannels: true)}');
    if (length > 50 * 1024 * 1024 || info == null) {
      throw const SpotsaverException('spotsaver.net did not send an MP3');
    }
    final dest = File(p.join(into.path, 'download.mp3'));
    deleteQuietly(dest);
    await retryBusy(() => received.rename(dest.path));
    log('done: saved as download.mp3');
    return dest;
  } catch (e) {
    log('failed: ${e.runtimeType}: $e${cancelled ? ' (cancelled)' : ''}');
    if (cancelled) throw const SpotsaverException('Cancelled');
    if (e is SpotsaverException) rethrow;
    if (e is CdpException) {
      throw SpotsaverException('Could not control the browser: ${e.message}');
    }
    if (e is TimeoutException) throw _tooLong;
    throw SpotsaverException('The download failed: $e');
  } finally {
    final b = browser;
    if (b != null) {
      log('closing the browser');
      await b.close();
    }
    for (final guid in guids) {
      deleteQuietly(File(p.join(into.path, guid)));
      deleteQuietly(File(p.join(into.path, '$guid.crdownload')));
    }
  }
}
