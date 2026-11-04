// The preview of a .karmp3 on the Export step: the song as the export would make it, playing
// with its lyrics moving at their exported times. It plays the song folder's own MP3s and shows
// the lines the export writes (see preview.dart), so nothing is written and nothing is built
// first. With vocals in the export, a switch and a level control them, and the two players are
// kept in step the way the Kantahe web player does.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../karmp3.dart' show LrcLine;
import '../preview.dart';
import 'tap_screen.dart';

class PreviewDialog extends StatefulWidget {
  const PreviewDialog({
    super.key,
    required this.title,
    required this.lines,
    required this.instrumentalPath,
    this.vocalsPath,
    this.createPlayer,
  });

  /// "Title - Artist".
  final String title;

  /// The lyric lines as the export writes them (see [previewLines]).
  final List<LrcLine> lines;
  final String instrumentalPath;

  /// The vocals MP3, null when the export has no vocals (then there are no vocals controls
  /// and only one player).
  final String? vocalsPath;

  /// Makes a player; null means [MediaKitTapPlayer]. Called once, or twice with vocals.
  final TapPlayer Function()? createPlayer;

  @override
  State<PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends State<PreviewDialog> {
  late final TapPlayer _inst;
  TapPlayer? _vocals;
  final _subs = <StreamSubscription<Object?>>[];
  Timer? _drift;
  final _sync = VocalsSync();

  /// Time as the drift timer counts it (500 ms a tick), so the rule never reads a clock.
  Duration _tick = Duration.zero;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _vocalsOn = true;
  int _vocalsPct = 100;
  String? _error;
  late final List<GlobalKey> _lineKeys = List.generate(widget.lines.length, (_) => GlobalKey());
  int _shownLine = -1;

  @override
  void initState() {
    super.initState();
    final make = widget.createPlayer ?? MediaKitTapPlayer.new;
    _inst = make();
    if (widget.vocalsPath != null) _vocals = make();
    _duration = _inst.duration;
    _subs.add(
      _inst.positionStream.listen((d) {
        if (mounted) setState(() => _position = d);
      }),
    );
    _subs.add(
      _inst.durationStream.listen((d) {
        if (mounted) setState(() => _duration = d);
      }),
    );
    _subs.add(_inst.playingStream.listen(_onPlaying));
    unawaited(_open());
  }

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _drift?.cancel();
    unawaited(_inst.dispose());
    final vocals = _vocals;
    if (vocals != null) unawaited(vocals.dispose());
    super.dispose();
  }

  Future<void> _open() async {
    try {
      await _inst.open(widget.instrumentalPath);
      await _vocals?.open(widget.vocalsPath!);
      if (mounted) setState(() => _duration = _inst.duration);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not play the song: $e');
    }
  }

  /// The instrumental says it started or stopped (it stops by itself at the end of the song).
  void _onPlaying(bool playing) {
    if (!mounted || playing == _playing) return;
    setState(() => _playing = playing);
    if (!playing) {
      _drift?.cancel();
      unawaited(_vocals?.pause());
    }
  }

  Future<void> _play() async {
    setState(() => _playing = true);
    final atEnd =
        _duration > Duration.zero &&
        _position >= _duration - const Duration(milliseconds: 300);
    if (atEnd) {
      await _seekTo(Duration.zero);
    } else if (_vocalsOn) {
      await _vocals?.seek(_inst.position);
    }
    await _inst.play();
    if (_vocalsOn) await _vocals?.play();
    _startDrift();
  }

  Future<void> _pause() async {
    setState(() => _playing = false);
    _drift?.cancel();
    await _inst.pause();
    await _vocals?.pause();
  }

  /// Both players always go to the same place.
  Future<void> _seekTo(Duration to) async {
    setState(() => _position = to);
    await _inst.seek(to);
    await _vocals?.seek(to);
  }

  /// While both play, every 500 ms the vocals are moved to the instrumental's position when
  /// they have drifted (see [VocalsSync]).
  void _startDrift() {
    _drift?.cancel();
    if (_vocals == null) return;
    _drift = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _tick += const Duration(milliseconds: 500);
      final vocals = _vocals;
      if (vocals == null || !_playing || !_vocalsOn) return;
      if (_sync.shouldReseek(
        instrumental: _inst.position,
        vocals: vocals.position,
        now: _tick,
      )) {
        unawaited(vocals.seek(_inst.position));
      }
    });
  }

  Future<void> _setVocals(bool on) async {
    setState(() => _vocalsOn = on);
    final vocals = _vocals;
    if (vocals == null) return;
    _sync.reset();
    if (!on) {
      await vocals.pause();
      await vocals.setVolume(0);
    } else {
      await vocals.seek(_inst.position);
      await vocals.setVolume(vocalsLevel(_vocalsPct));
      if (_playing) await vocals.play();
    }
  }

  Future<void> _setLevel(double percent) async {
    setState(() => _vocalsPct = percent.round());
    if (_vocalsOn) await _vocals?.setVolume(vocalsLevel(_vocalsPct));
  }

  Widget _lineText(int i, bool current, double seconds) {
    final line = widget.lines[i];
    if (current && line.words.isNotEmpty) {
      final sung = previewWordAt(line, seconds);
      return Text.rich(
        key: ValueKey('preview-text-$i'),
        TextSpan(
          children: [
            for (var w = 0; w < line.words.length; w++)
              TextSpan(
                text: line.words[w].$2,
                style: TextStyle(fontWeight: w <= sung ? FontWeight.bold : FontWeight.normal),
              ),
          ],
        ),
      );
    }
    return Text(
      line.text,
      key: ValueKey('preview-text-$i'),
      style: TextStyle(fontWeight: current ? FontWeight.bold : FontWeight.normal),
    );
  }

  Widget _lyrics(int current, double seconds) {
    if (widget.lines.isEmpty) return const Center(child: Text('No lyrics'));
    // Keep the line being sung in view.
    if (current != _shownLine) {
      _shownLine = current;
      if (current >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final context = _lineKeys[current].currentContext;
          if (context != null && mounted) {
            unawaited(
              Scrollable.ensureVisible(
                context,
                alignment: 0.3,
                duration: const Duration(milliseconds: 250),
              ),
            );
          }
        });
      }
    }
    return SingleChildScrollView(
      child: Column(
        children: [
          for (var i = 0; i < widget.lines.length; i++)
            KeyedSubtree(
              key: _lineKeys[i],
              child: ListTile(
                key: ValueKey('preview-line-$i'),
                dense: true,
                selected: i == current,
                title: _lineText(i, i == current, seconds),
                onTap: () => unawaited(
                  _seekTo(Duration(milliseconds: (widget.lines[i].seconds * 1000).round())),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final seconds = _position.inMilliseconds / 1000;
    final current = previewLineAt(widget.lines, seconds);
    final max = math.max(1, _duration.inMilliseconds).toDouble();
    return AlertDialog(
      key: const ValueKey('preview-dialog'),
      title: Text(widget.title),
      content: SizedBox(
        width: 560,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_error != null)
              Text(_error!, key: const ValueKey('preview-error'))
            else
              Row(
                children: [
                  IconButton(
                    key: const ValueKey('preview-play'),
                    icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                    onPressed: () => unawaited(_playing ? _pause() : _play()),
                  ),
                  Expanded(
                    child: Slider(
                      key: const ValueKey('preview-seek'),
                      value: _position.inMilliseconds.toDouble().clamp(0, max),
                      max: max,
                      onChanged: (v) => setState(() => _position = Duration(milliseconds: v.round())),
                      onChangeEnd: (v) => unawaited(_seekTo(Duration(milliseconds: v.round()))),
                    ),
                  ),
                  Text(
                    '${clockLabel(_position)} / ${clockLabel(_duration)}',
                    key: const ValueKey('preview-time'),
                  ),
                ],
              ),
            if (_vocals != null)
              Row(
                children: [
                  Switch(
                    key: const ValueKey('preview-vocals'),
                    value: _vocalsOn,
                    onChanged: (v) => unawaited(_setVocals(v)),
                  ),
                  const Text('Vocals'),
                  Expanded(
                    child: Slider(
                      key: const ValueKey('preview-vocals-level'),
                      value: _vocalsPct.toDouble(),
                      max: 100,
                      divisions: 10,
                      onChanged: (v) => unawaited(_setLevel(v)),
                    ),
                  ),
                  Text('$_vocalsPct %'),
                ],
              ),
            const Divider(),
            Expanded(child: _lyrics(current, seconds)),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('preview-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
