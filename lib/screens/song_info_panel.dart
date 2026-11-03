import 'dart:async';

import 'package:flutter/material.dart';

import '../export.dart' show oneLine;
import '../song_info.dart';

typedef SongInfoFinder =
    Future<List<SongInfoCandidate>> Function(String title, String artist);

/// Searches musicbrainz.org for the song (at once when [autoSearch]) and lists what it
/// finds; tapping one calls [onPicked]. [loadingId] is the recording whose details are
/// still being fetched.
class SongInfoPanel extends StatefulWidget {
  const SongInfoPanel({
    super.key,
    required this.title,
    required this.artist,
    required this.finder,
    required this.onPicked,
    required this.autoSearch,
    this.loadingId,
  });

  final String title, artist;
  final SongInfoFinder finder;
  final void Function(SongInfoCandidate picked) onPicked;
  final bool autoSearch;
  final String? loadingId;

  @override
  State<SongInfoPanel> createState() => _SongInfoPanelState();
}

enum _Phase { idle, searching, results, empty, error }

class _SongInfoPanelState extends State<SongInfoPanel> {
  _Phase _phase = _Phase.idle;
  List<SongInfoCandidate> _results = const [];
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

  Widget _tile(int i, SongInfoCandidate c) {
    final detail = [
      if (c.album.isNotEmpty) c.album,
      if (c.year.isNotEmpty) c.year,
      if (c.seconds != null) _clock(c.seconds!),
    ].join(' · ');
    return ListTile(
      key: ValueKey('info-result-$i'),
      title: Text('${c.title} - ${c.artist}'),
      subtitle: detail.isEmpty ? null : Text(detail),
      trailing: widget.loadingId != null && widget.loadingId == c.recordingId
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                key: ValueKey('info-loading'),
                strokeWidth: 2,
              ),
            )
          : null,
      onTap: () => widget.onPicked(c),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _title, artist = _artist;
    if (title.isEmpty) {
      return const Text('Type a title to search musicbrainz.org.');
    }
    // Also shown while searching, to start over when musicbrainz.org is slow.
    final searchAgain = TextButton.icon(
      key: const ValueKey('info-search'),
      onPressed: () => setState(_start),
      icon: const Icon(Icons.search),
      label: Text(_searches == 0 ? 'Search musicbrainz.org' : 'Search again'),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Searching musicbrainz.org sends the title and artist (or the file name); nothing else.',
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
                    key: ValueKey('info-searching'),
                    strokeWidth: 2,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Searching musicbrainz.org for "$title"'
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
              'No match on musicbrainz.org. Fill in the details below.',
            ),
            searchAgain,
          ],
          _Phase.error => [
            SelectableText(_error),
            const SizedBox(height: 8),
            searchAgain,
          ],
        },
      ],
    );
  }
}
