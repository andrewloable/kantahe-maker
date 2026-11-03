// Driving a Chromium-based browser (Chrome, Edge, Chromium, Brave) that is already installed
// on the computer, through the Chrome DevTools Protocol (CDP): finding the program, starting
// it with a profile of its own, and a small client for CDP's JSON messages over a WebSocket.
// No browser is bundled or downloaded. Pure Dart: no Flutter imports.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'fs_retry.dart';
import 'jobs.dart';
import 'tools.dart' show HostOs;

/// Where a Chromium-based browser may be installed, the best candidate first. Nothing is
/// checked here; entries that need a missing environment variable are left out.
List<String> browserCandidates(HostOs os, Map<String, String> env) {
  switch (os) {
    case HostOs.macos:
      const apps = [
        'Google Chrome.app/Contents/MacOS/Google Chrome',
        'Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
        'Chromium.app/Contents/MacOS/Chromium',
        'Brave Browser.app/Contents/MacOS/Brave Browser',
      ];
      final home = env['HOME'];
      return [
        for (final root in ['/Applications', if (home != null) '$home/Applications'])
          for (final app in apps) '$root/$app',
      ];
    case HostOs.windows:
      String? under(String variable, String tail) {
        final base = env[variable];
        return base == null ? null : '$base$tail';
      }

      const chrome = r'\Google\Chrome\Application\chrome.exe';
      const edge = r'\Microsoft\Edge\Application\msedge.exe';
      return [
        ?under('ProgramFiles', chrome),
        ?under('ProgramFiles(x86)', chrome),
        ?under('LOCALAPPDATA', chrome),
        ?under('ProgramFiles(x86)', edge),
        ?under('ProgramFiles', edge),
      ];
    case HostOs.linux:
      const names = [
        'google-chrome',
        'google-chrome-stable',
        'chromium',
        'chromium-browser',
        'microsoft-edge',
        'brave-browser',
      ];
      return [
        for (final dir in (env['PATH'] ?? '').split(':'))
          if (dir.isNotEmpty)
            for (final name in names) '$dir/$name',
      ];
  }
}

/// The first browser of [browserCandidates] that exists, or null. [exists] is for tests.
String? findBrowser(
  HostOs os,
  Map<String, String> env, {
  bool Function(String path)? exists,
}) {
  final check = exists ?? (String path) => File(path).existsSync();
  for (final candidate in browserCandidates(os, env)) {
    if (check(candidate)) return candidate;
  }
  return null;
}

/// The port and the browser WebSocket path in the DevToolsActivePort file a browser writes
/// into its profile folder when started with --remote-debugging-port=0 (the first line is
/// the port, the second the path). Throws [FormatException] for anything else.
(int, String) parseDevToolsActivePort(String text) {
  final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  final port = lines.isEmpty ? null : int.tryParse(lines.first);
  if (port == null || lines.length < 2 || !lines[1].startsWith('/')) {
    throw const FormatException('Not a DevToolsActivePort file');
  }
  return (port, lines[1]);
}

/// The port and path in the DevToolsActivePort [file], or null while it is not there, only
/// half written, or cannot be opened: on Windows the browser keeps the file locked while it
/// writes it, so a failed read means "try again", not "broken".
(int, String)? readPortFile(File file) {
  try {
    if (!file.existsSync()) return null;
    return parseDevToolsActivePort(file.readAsStringSync());
  } on FormatException {
    return null;
  } on FileSystemException {
    return null;
  }
}

class CdpException implements Exception {
  final String message;
  const CdpException(this.message);
  @override
  String toString() => message;
}

/// A running browser and the CDP connection to it. It is a [CancellableJob], so the app can
/// end it when it quits (register it in [jobs]); [cancel] closes the browser, kills it when
/// it does not end by itself and deletes its profile folder.
class CdpBrowser implements CancellableJob {
  CdpBrowser._(this._socket, this._process, this._profile) {
    _socket.listen(_onMessage, onDone: _onClosed, onError: (Object _) => _onClosed());
  }

  /// A connection that is already open, without a program of its own (for tests).
  factory CdpBrowser.attach(WebSocket socket) => CdpBrowser._(socket, null, null);

  /// Starts [exe] with a profile folder of its own and connects to it. [headless] runs it
  /// without a window; [extraArgs] are more command-line flags for the browser. Throws
  /// [CdpException] when it does not come up within [startTimeout].
  static Future<CdpBrowser> launch(
    String exe, {
    bool headless = true,
    List<String> extraArgs = const [],
    Duration startTimeout = const Duration(seconds: 40),
  }) async {
    final profile = await Directory.systemTemp.createTemp('kantahe_cdp');
    Process? process;
    try {
      process = await Process.start(exe, [
        if (headless) '--headless=new',
        '--remote-debugging-port=0',
        '--user-data-dir=${profile.path}',
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-extensions',
        ...extraArgs,
        'about:blank',
      ]);
      // Unread output could fill the pipe and stop the browser.
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      var exited = false;
      unawaited(process.exitCode.then((_) => exited = true));
      final file = File('${profile.path}/DevToolsActivePort');
      final deadline = DateTime.now().add(startTimeout);
      while (true) {
        if (exited) throw const CdpException('The browser ended before it was ready');
        if (DateTime.now().isAfter(deadline)) {
          throw const CdpException('The browser did not start in time');
        }
        final found = readPortFile(file);
        if (found != null) {
          final (port, path) = found;
          final socket = await WebSocket.connect('ws://127.0.0.1:$port$path');
          return CdpBrowser._(socket, process, profile);
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } catch (e) {
      process?.kill();
      deleteQuietly(profile);
      if (e is CdpException) rethrow;
      throw CdpException('Could not start the browser: $e');
    }
  }

  final WebSocket _socket;
  final Process? _process;
  final Directory? _profile;
  int _id = 0;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _done = Completer<void>();
  bool _closing = false;

  /// The process id of the browser, null for a connection made with [attach].
  int? get pid => _process?.pid;

  /// The profile folder the browser uses; deleted when it is closed.
  String? get profilePath => _profile?.path;

  /// The messages CDP sends by itself (they have a "method"): page loads, downloads...
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<void> get done => _done.future;

  void _onMessage(Object? data) {
    final Object? m;
    try {
      m = jsonDecode(data as String);
    } catch (_) {
      return;
    }
    if (m is! Map<String, dynamic>) return;
    final id = m['id'];
    if (id is int) {
      final waiting = _pending.remove(id);
      if (waiting == null) return;
      final error = m['error'];
      if (error != null) {
        final text = error is Map ? error['message'] : error;
        waiting.completeError(CdpException('The browser refused a command: $text'));
      } else {
        final result = m['result'];
        waiting.complete(result is Map<String, dynamic> ? result : <String, dynamic>{});
      }
    } else if (m['method'] is String) {
      _events.add(m);
    }
  }

  void _onClosed() {
    for (final waiting in _pending.values) {
      waiting.completeError(const CdpException('The browser closed the connection'));
    }
    _pending.clear();
  }

  /// Sends a command and returns its result. [sessionId] addresses a page.
  Future<Map<String, dynamic>> send(
    String method, [
    Map<String, dynamic>? params,
    String? sessionId,
  ]) {
    final id = ++_id;
    final waiting = _pending[id] = Completer<Map<String, dynamic>>();
    try {
      _socket.add(
        jsonEncode({
          'id': id,
          'method': method,
          'params': ?params,
          'sessionId': ?sessionId,
        }),
      );
    } catch (e) {
      _pending.remove(id);
      waiting.completeError(CdpException('The browser closed the connection'));
    }
    return waiting.future;
  }

  /// Opens an empty tab and returns the session id that addresses it.
  Future<String> newPage() async {
    final target = await send('Target.createTarget', {'url': 'about:blank'});
    final attached = await send('Target.attachToTarget', {
      'targetId': target['targetId'],
      'flatten': true,
    });
    final session = attached['sessionId'] as String;
    await send('Page.enable', null, session);
    await send('Runtime.enable', null, session);
    return session;
  }

  /// Runs [js] in the page of [sessionId] and returns its value (a promise is awaited). Throws
  /// [CdpException] when the script throws.
  Future<Object?> evaluate(String sessionId, String js) async {
    final r = await send('Runtime.evaluate', {
      'expression': js,
      'returnByValue': true,
      'awaitPromise': true,
    }, sessionId);
    final problem = r['exceptionDetails'];
    if (problem != null) {
      final text = problem is Map
          ? (problem['exception'] is Map
                ? (problem['exception'] as Map)['description']
                : problem['text'])
          : problem;
      throw CdpException('The page script failed: $text');
    }
    final result = r['result'];
    return result is Map ? result['value'] : null;
  }

  /// Closes the browser: asks it to quit, kills it when it does not end within 3 seconds,
  /// and deletes its profile folder. Safe to call more than once.
  Future<void> close() async {
    if (_closing) return done;
    _closing = true;
    try {
      await send('Browser.close').timeout(const Duration(seconds: 2));
    } catch (_) {
      // The browser may close the connection before it answers.
    }
    try {
      await _socket.close();
    } catch (_) {}
    final process = _process;
    if (process != null) {
      var ended = false;
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
        ended = true;
      } catch (_) {}
      if (!ended) {
        if (Platform.isWindows) {
          // The browser's own helper programs are children of it.
          await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
        }
        process.kill(ProcessSignal.sigkill);
        try {
          await process.exitCode.timeout(const Duration(seconds: 3));
        } catch (_) {}
      }
    }
    final profile = _profile;
    if (profile != null) {
      // The browser may still hold a file for a moment after it ended.
      for (var i = 0; i < 10 && profile.existsSync(); i++) {
        deleteQuietly(profile);
        if (profile.existsSync()) await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    unawaited(_events.close());
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void cancel() => unawaited(close());
}
