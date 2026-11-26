// Searching YouTube for a song the way a person does: YouTube's results page opens in a
// minimized Chrome or Edge window that the app drives (see cdp.dart), and the videos are
// read out of the page's data (ytInitialData, the JSON the page is built from). That data
// is not a documented interface, so a change on YouTube's side shows as an error message,
// never as wrong results. The app never changes how the browser presents itself and never
// clicks through a consent or check page: when YouTube shows one, a window opens in front
// and the user does it. Pure Dart: no Flutter imports.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cdp.dart';
import 'tools.dart' show parseHost;
import 'youtube_rank.dart';

class YoutubeSearchException implements Exception {
  final String message;
  const YoutubeSearchException(this.message);
  @override
  String toString() => message;
}

const _different = YoutubeSearchException('YouTube looks different than expected');

/// The text of a `{runs: [{text}, ...]}` or `{simpleText}` value, or null.
String? _text(Object? v) {
  if (v is! Map) return null;
  final simple = v['simpleText'];
  if (simple is String) return simple;
  final runs = v['runs'];
  if (runs is! List) return null;
  final parts = [
    for (final r in runs)
      if (r is Map && r['text'] is String) r['text'] as String,
  ];
  return parts.isEmpty ? null : parts.join();
}

/// '3:45' is 225 s, '1:02:03' is 3723 s; anything else is null.
double? _seconds(String? length) {
  if (length == null) return null;
  final parts = length.trim().split(':');
  if (parts.length < 2 || parts.length > 3) return null;
  var total = 0;
  for (final part in parts) {
    final n = int.tryParse(part);
    if (n == null || n < 0) return null;
    total = total * 60 + n;
  }
  return total.toDouble();
}

Object? _at(Object? v, String key) => v is Map ? v[key] : null;

/// A result from the older item kind (videoRenderer), which a plain page fetch gets; null
/// when [video] is not one or has no id or title.
YoutubeResult? _fromVideoRenderer(Object? video) {
  if (video is! Map) return null;
  final id = video['videoId'];
  final title = _text(video['title'])?.trim();
  if (id is! String || id.isEmpty || title == null || title.isEmpty) return null;
  final badges = video['ownerBadges'];
  return YoutubeResult(
    videoId: id,
    title: title,
    channel: (_text(video['ownerText']) ?? '').trim(),
    seconds: _seconds(_text(video['lengthText'])),
    officialArtist: badges is List &&
        badges.any((b) =>
            _at(_at(b, 'metadataBadgeRenderer'), 'style') == 'BADGE_STYLE_TYPE_VERIFIED_ARTIST'),
  );
}

/// A result from the newer item kind (lockupViewModel), which a real browser gets (seen on
/// 2026-11-26); null when [lockup] is not a video (playlists, mixes) or has no id or title.
/// The channel is the first part of the first metadata row, and its icon AUDIO_BADGE marks
/// the official artist channel; the length is the badge on the thumbnail.
YoutubeResult? _fromLockup(Object? lockup) {
  if (lockup is! Map || lockup['contentType'] != 'LOCKUP_CONTENT_TYPE_VIDEO') return null;
  final id = lockup['contentId'];
  final meta = _at(_at(lockup, 'metadata'), 'lockupMetadataViewModel');
  final title = _at(_at(meta, 'title'), 'content');
  if (id is! String || id.isEmpty || title is! String || title.trim().isEmpty) return null;
  final rows = _at(_at(_at(meta, 'metadata'), 'contentMetadataViewModel'), 'metadataRows');
  final parts = rows is List && rows.isNotEmpty ? _at(rows.first, 'metadataParts') : null;
  final byline = parts is List && parts.isNotEmpty ? parts.first : null;
  final channel = _at(_at(_at(_at(byline, 'avatarStack'), 'avatarStackViewModel'), 'text'), 'content') ??
      _at(_at(byline, 'text'), 'content');
  String? length;
  final overlays = _at(_at(_at(lockup, 'contentImage'), 'thumbnailViewModel'), 'overlays');
  if (overlays is List) {
    for (final overlay in overlays) {
      final badges = _at(_at(overlay, 'thumbnailBottomOverlayViewModel'), 'badges');
      if (badges is! List) continue;
      for (final badge in badges) {
        final text = _at(_at(badge, 'thumbnailBadgeViewModel'), 'text');
        if (text is String && _seconds(text) != null) length ??= text;
      }
    }
  }
  return YoutubeResult(
    videoId: id,
    title: title.trim(),
    channel: channel is String ? channel.trim() : '',
    seconds: _seconds(length),
    officialArtist: _at(_at(byline, 'icon'), 'name') == 'AUDIO_BADGE',
  );
}

/// The videos in a results page's ytInitialData, in page order. Ads, shelves, channels,
/// playlists and videos without an id or a title are skipped. Throws
/// [YoutubeSearchException] when the page is not built the way this was written for.
List<YoutubeResult> parseYtInitialData(Object? data) {
  Object? at(Object? v, String key) => _at(v, key);
  final sections = at(
    at(at(at(data, 'contents'), 'twoColumnSearchResultsRenderer'), 'primaryContents'),
    'sectionListRenderer',
  );
  final contents = at(sections, 'contents');
  if (contents is! List) throw _different;
  final results = <YoutubeResult>[];
  for (final section in contents) {
    final items = at(at(section, 'itemSectionRenderer'), 'contents');
    if (items is! List) continue;
    for (final item in items) {
      final found = _fromVideoRenderer(at(item, 'videoRenderer')) ??
          _fromLockup(at(item, 'lockupViewModel'));
      if (found != null) results.add(found);
    }
  }
  return results;
}

// ------------------------------------------------------------------- the browser

const _cancelled = YoutubeSearchException('Cancelled');
const _noResults = YoutubeSearchException('YouTube did not show any results');
const _noBrowser = YoutubeSearchException(
  'Kantahe Maker needs Google Chrome or Microsoft Edge to search YouTube. '
  'Install one of them, or choose an MP3 file.',
);

/// Whether the page (on [host], with [title] and [text]) needs the user: YouTube's consent
/// page (consent.youtube.com, in Europe) or a check ("are you human") page.
bool youtubeNeedsUser(String host, String title, String text) =>
    host.startsWith('consent.') || looksLikeCheckPage(title, text);

/// Where the page is, what it says, and its results data as JSON ("null" until it is there).
const _pageJs = '''
(() => ({
  host: location.host,
  title: document.title,
  text: (document.body ? document.body.innerText : '').slice(0, 2000),
  data: JSON.stringify(window.ytInitialData || null),
}))()
''';

/// Returned by the wait when the user has to do something first.
final _handOver = Object();

/// Searches YouTube for [query] in a minimized Chrome or Edge window and returns the videos
/// of the results page, in YouTube's order. [onBrowser] gets the browser so the caller can
/// register it in the app's job list; [onStatus] hears when the user has to finish something
/// in a window; [onLog] gets one line per step (never the query). [cancel] completing stops
/// everything with 'Cancelled'. The browser is always closed and its profile deleted. Throws
/// [YoutubeSearchException]. [browserPath], [browserExists], [site], [headless] and
/// [findTimeout] (how long to wait for the results) are for tests.
Future<List<YoutubeResult>> searchYoutube(
  String query, {
  Future<void>? cancel,
  void Function(CdpBrowser browser)? onBrowser,
  void Function(String status)? onStatus,
  void Function(String line)? onLog,
  String? browserPath,
  bool Function(String path)? browserExists,
  Uri? site,
  bool headless = false,
  Duration findTimeout = const Duration(seconds: 30),
}) async {
  final (os, _) = parseHost(Platform.version);
  final exe = browserPath ?? findBrowser(os, Platform.environment, exists: browserExists);
  if (exe == null) throw _noBrowser;
  final url = (site ?? Uri.https('www.youtube.com', '/')).replace(
    path: '/results',
    queryParameters: {'search_query': query},
  );

  final clock = Stopwatch()..start();
  void log(String line) {
    final seconds = (clock.elapsedMilliseconds / 1000).toStringAsFixed(1);
    onLog?.call('youtube +${seconds}s $line');
  }

  var cancelled = false;
  CdpBrowser? browser;
  unawaited(cancel?.then((_) {
    cancelled = true;
    // Closing is safe more than once, also after the search is over.
    browser?.cancel();
  }, onError: (Object _) {}));

  /// Starts a browser on the results page and returns the session of its page.
  Future<String> open({required bool forUser}) async {
    // [headless] is for tests only: there the hand-over window stays hidden too, so tests
    // run without a display.
    final mode = browserLaunch(headless: headless, forUser: forUser && !headless);
    log('launching the browser (${mode.headless ? 'hidden' : forUser ? 'visible window' : 'minimized window'})');
    final b = await CdpBrowser.launch(exe, headless: mode.headless, extraArgs: mode.args);
    browser = b;
    onBrowser?.call(b);
    if (cancelled) throw _cancelled;
    final session = await b.newPage();
    await b.send('Page.navigate', {'url': '$url'}, session);
    log('page opened on ${url.host}');
    return session;
  }

  /// Reads the page every half second until it has its results data (returned decoded), for
  /// at most [within] (then null). With [handOver], a page that needs the user gives
  /// [_handOver]. A read that fails while the page changes counts as "not yet".
  Future<Object?> waitForData(String session, Duration within, {required bool handOver}) async {
    final end = clock.elapsed + within;
    while (true) {
      if (cancelled) throw _cancelled;
      try {
        final page = await browser!.evaluate(session, _pageJs);
        if (page is Map) {
          final data = page['data'];
          if (data is String && data != 'null') return jsonDecode(data);
          if (handOver &&
              youtubeNeedsUser('${page['host']}', '${page['title']}', '${page['text']}')) {
            return _handOver;
          }
        }
      } on CdpException {
        // The page is changing: try again.
      } on FormatException {
        throw const YoutubeSearchException('YouTube looks different than expected');
      }
      if (clock.elapsed >= end) {
        log('no results after ${within.inSeconds}s');
        return null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  try {
    var session = await open(forUser: false);
    var data = await waitForData(session, findTimeout, handOver: true);
    if (identical(data, _handOver)) {
      log('consent or check page: the user finishes it in a visible window');
      onStatus?.call(
        'YouTube wants you to confirm something. Finish it in the browser window; '
        'the search then continues by itself.',
      );
      await browser!.close();
      session = await open(forUser: true);
      data = await waitForData(session, const Duration(minutes: 2), handOver: false);
    }
    if (data == null) throw _noResults;
    final results = parseYtInitialData(data);
    log('${results.length} videos');
    return results;
  } on YoutubeSearchException {
    if (cancelled) throw _cancelled;
    rethrow;
  } on CdpException catch (e) {
    if (cancelled) throw _cancelled;
    throw YoutubeSearchException('Could not control the browser: ${e.message}');
  } finally {
    final b = browser;
    if (b != null) {
      log('closing the browser');
      await b.close();
    }
  }
}
