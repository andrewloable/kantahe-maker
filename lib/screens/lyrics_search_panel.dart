import 'dart:async';

import 'package:flutter/material.dart';

import '../export.dart' show oneLine;
import '../lyrics_lookup.dart';

typedef LyricsFinder = Future<List<LyricsCandidate>> Function(
  String title,
  String artist,
);

/// Searches lrclib.net for the song's lyrics (at once when [autoSearch]) and lists
/// what it finds; tapping one calls [onPicked].
class LyricsSearchPanel extends StatefulWidget {
  const LyricsSearchPanel({
    super.key,
    required this.title,
    required this.artist,
    required this.finder,
    required this.onPicked,
    required this.autoSearch,
  });

  final String title, artist;
  final LyricsFinder finder;
  final void Function(LyricsCandidate picked) onPicked;
  final bool autoSearch;

  @override
  State<LyricsSearchPanel> createState() => _LyricsSearchPanelState();
}

enum _Phase { idle, searching, results, empty, error }

class _LyricsSearchPanelState extends State<LyricsSearchPanel> {
  _Phase _phase = _Phase.idle;
  List<LyricsCandidate> _results = const [];
  String _error = '';

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
    unawaited(_search(++_searches));
  }

  Future<void> _search(int number) async {
    try {
      final found = await widget.finder(_title, _artist);
      if (!mounted || number != _searches) return;
      setState(() {
        _results = found;
        _phase = found.isEmpty ? _Phase.empty : _Phase.results;
      });
    } catch (e) {
      if (!mounted || number != _searches) return;
      setState(() {
        _error = e.toString();
        _phase = _Phase.error;
      });
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
          'Searching lrclib.net sends the title and artist; nothing else.',
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
                    'Searching lrclib.net for "$title"'
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
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  key: const ValueKey('lyrics-retry'),
                  onPressed: () => setState(_start),
                  child: const Text('Try again'),
                ),
                searchAgain,
              ],
            ),
          ],
        },
      ],
    );
  }
}
