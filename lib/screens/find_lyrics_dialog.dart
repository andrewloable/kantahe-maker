import 'package:flutter/material.dart';

import '../export.dart' show oneLine;
import '../lyrics_lookup.dart';

typedef LyricsFinder = Future<List<LyricsCandidate>> Function(
  String title,
  String artist,
);

/// Says what will be sent, searches when the user agrees, and lets them pick a result.
/// Returns the picked candidate, or null when the user cancels.
Future<LyricsCandidate?> showFindLyricsDialog(
  BuildContext context, {
  required String title,
  required String artist,
  required LyricsFinder finder,
}) => showDialog<LyricsCandidate>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      _FindLyricsDialog(title: title, artist: artist, finder: finder),
);

enum _Phase { ask, searching, results, empty, error }

class _FindLyricsDialog extends StatefulWidget {
  const _FindLyricsDialog({
    required this.title,
    required this.artist,
    required this.finder,
  });
  final String title, artist;
  final LyricsFinder finder;

  @override
  State<_FindLyricsDialog> createState() => _FindLyricsDialogState();
}

class _FindLyricsDialogState extends State<_FindLyricsDialog> {
  _Phase _phase = _Phase.ask;
  List<LyricsCandidate> _results = const [];
  String _error = '';

  Future<void> _search() async {
    setState(() => _phase = _Phase.searching);
    try {
      final found = await widget.finder(widget.title, widget.artist);
      if (!mounted) return;
      setState(() {
        _results = found;
        _phase = found.isEmpty ? _Phase.empty : _Phase.results;
      });
    } catch (e) {
      // A search the user cancelled meanwhile has no one to tell.
      if (!mounted) return;
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
      onTap: () => Navigator.of(context).pop(c),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cancel = TextButton(
      onPressed: () => Navigator.of(context).pop(),
      child: const Text('Cancel'),
    );
    final close = TextButton(
      onPressed: () => Navigator.of(context).pop(),
      child: const Text('Close'),
    );
    final wantedArtist = oneLine(widget.artist);
    final (Widget content, List<Widget> actions) = switch (_phase) {
      _Phase.ask => (
        Text(
          'Search lrclib.net, a free lyrics database, for '
          '"${oneLine(widget.title)}"'
          '${wantedArtist.isEmpty ? '' : ' by "$wantedArtist"'}? '
          'The title and artist are sent over the internet; nothing else is.',
        ),
        [
          cancel,
          FilledButton(
            key: const ValueKey('lyrics-search'),
            onPressed: _search,
            child: const Text('Search'),
          ),
        ],
      ),
      _Phase.searching => (
        const Center(
          child: CircularProgressIndicator(key: ValueKey('lyrics-searching')),
        ),
        [cancel],
      ),
      _Phase.results => (
        ListView(
          shrinkWrap: true,
          children: [
            for (var i = 0; i < _results.length; i++) _tile(i, _results[i]),
          ],
        ),
        [cancel],
      ),
      _Phase.empty => (
        const Text('No lyrics found for this title and artist.'),
        [close],
      ),
      _Phase.error => (
        Text(_error),
        [
          close,
          FilledButton(
            key: const ValueKey('lyrics-retry'),
            onPressed: _search,
            child: const Text('Try again'),
          ),
        ],
      ),
    };
    return AlertDialog(
      title: const Text('Find lyrics online'),
      content: SizedBox(width: 480, child: content),
      actions: actions,
    );
  }
}
