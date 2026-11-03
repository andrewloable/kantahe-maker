import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../export.dart' show oneLine;
import '../lyrics_lookup.dart';
import '../tools.dart' show parseHost;
import 'settings_screen.dart' show openFolderCommand;

typedef LyricsFinder = Future<List<LyricsCandidate>> Function(
  String title,
  String artist,
);

/// How many times a search is tried when lrclib.net has a server problem (HTTP 503...)
/// before the panel offers a Google search instead.
const lyricsSearchAttempts = 5;

/// Opens [url] in the default browser (the command that opens a folder opens a link too).
Future<void> openInBrowser(Uri url) async {
  final command = openFolderCommand(parseHost(Platform.version).$1, url.toString());
  // explorer.exe exits with 1 even when it worked, so the exit code is not checked.
  await Process.run(command.first, command.sublist(1));
}

/// Searches lrclib.net for the song's lyrics (at once when [autoSearch]) and lists
/// what it finds; tapping one calls [onPicked]. A server problem is tried again by itself,
/// up to [lyricsSearchAttempts] times, after [retryDelay]; then a link opens a Google search.
class LyricsSearchPanel extends StatefulWidget {
  const LyricsSearchPanel({
    super.key,
    required this.title,
    required this.artist,
    required this.finder,
    required this.onPicked,
    required this.autoSearch,
    this.retryDelay = const Duration(seconds: 2),
    this.openUrl = openInBrowser,
  });

  final String title, artist;
  final LyricsFinder finder;
  final void Function(LyricsCandidate picked) onPicked;
  final bool autoSearch;
  final Duration retryDelay;
  final Future<void> Function(Uri url) openUrl;

  @override
  State<LyricsSearchPanel> createState() => _LyricsSearchPanelState();
}

enum _Phase { idle, searching, results, empty, error }

class _LyricsSearchPanelState extends State<LyricsSearchPanel> {
  _Phase _phase = _Phase.idle;
  List<LyricsCandidate> _results = const [];
  String _error = '';

  /// The attempt a search is on after a server problem (0 until one happened), and whether
  /// every attempt failed that way.
  int _attempt = 0;
  bool _gaveUp = false;

  /// Counts the searches; only the answer to the latest one is shown.
  int _searches = 0;

  String get _title => oneLine(widget.title);
  String get _artist => oneLine(widget.artist);

  @override
  void initState() {
    super.initState();
    if (widget.autoSearch && _title.isNotEmpty) _start();
  }

  /// Starts a search; call inside setState once the panel is built.
  void _start() {
    _phase = _Phase.searching;
    _attempt = 0;
    _gaveUp = false;
    unawaited(_search(++_searches));
  }

  Future<void> _search(int number) async {
    for (var attempt = 1;; attempt++) {
      try {
        final found = await widget.finder(_title, _artist);
        if (!mounted || number != _searches) return;
        setState(() {
          _results = found;
          _phase = found.isEmpty ? _Phase.empty : _Phase.results;
        });
        return;
      } catch (e) {
        if (!mounted || number != _searches) return;
        final busy = e is LyricsLookupException && e.isServerError;
        if (busy && attempt < lyricsSearchAttempts) {
          setState(() => _attempt = attempt + 1);
          await Future<void>.delayed(widget.retryDelay);
          if (!mounted || number != _searches) return;
          continue;
        }
        setState(() {
          _error = e.toString();
          _gaveUp = busy;
          _phase = _Phase.error;
        });
        return;
      }
    }
  }

  Future<void> _searchOnGoogle() async {
    try {
      await widget.openUrl(googleLyricsUri(_title, _artist));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not open the browser: $e')));
      }
    }
  }

  static String _clock(double seconds) {
    final s = seconds.round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Widget _tile(int i, LyricsCandidate c) {
    final detail = [
      if (c.album.isNotEmpty) c.album,
      if (c.seconds != null) _clock(c.seconds!),
      if (c.synced.isNotEmpty) 'timed',
      if (c.source != lyricsHost) 'from ${c.source}',
    ].join(' · ');
    final firstLine = c.lyrics.split('\n').first;
    return ListTile(
      key: ValueKey('lyrics-result-$i'),
      title: Text('${c.title} - ${c.artist}'),
      subtitle: Text(
        [if (detail.isNotEmpty) detail, firstLine].join('\n'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: detail.isNotEmpty,
      onTap: () => widget.onPicked(c),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _title, artist = _artist;
    if (title.isEmpty) {
      return const Text('Fill in the title in Details to search online.');
    }
    // Also shown while searching, to start over when lrclib.net is slow.
    final searchAgain = TextButton.icon(
      key: const ValueKey('lyrics-search'),
      onPressed: () => setState(_start),
      icon: const Icon(Icons.search),
      label: Text(_searches == 0 ? 'Search lrclib.net' : 'Search again'),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Searching lrclib.net (and lyrics.ovh when it finds nothing) sends the title and artist; nothing else.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        ...switch (_phase) {
          _Phase.idle => [searchAgain],
          _Phase.searching => [
            Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    key: ValueKey('lyrics-searching'),
                    strokeWidth: 2,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _attempt > 1
                        ? 'lrclib.net is busy. Trying again '
                            '(attempt $_attempt of $lyricsSearchAttempts)...'
                        : 'Searching lrclib.net for "$title"'
                            '${artist.isEmpty ? '' : ' by "$artist"'}...',
                  ),
                ),
              ],
            ),
            searchAgain,
          ],
          _Phase.results => [
            for (var i = 0; i < _results.length; i++) _tile(i, _results[i]),
            searchAgain,
          ],
          _Phase.empty => [
            const Text(
              'No lyrics found for this title and artist. Paste them below.',
            ),
            searchAgain,
          ],
          _Phase.error => [
            SelectableText(_error),
            if (_gaveUp) ...[
              const SizedBox(height: 4),
              const Text('lrclib.net did not answer after $lyricsSearchAttempts tries.'),
              TextButton.icon(
                key: const ValueKey('lyrics-google'),
                onPressed: _searchOnGoogle,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Search for the lyrics on Google'),
              ),
            ],
            const SizedBox(height: 8),
            searchAgain,
          ],
        },
      ],
    );
  }
}
