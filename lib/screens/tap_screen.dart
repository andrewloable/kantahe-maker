import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import '../karmp3.dart' as karmp3;
import '../tap_session.dart';

/// What a key press does on the tap screen.
enum TapAction { stamp, undo, playPause, seekBack, seekForward }

/// The action for [key], or null. Key repeats are ignored: a held key must not stamp
/// line after line.
TapAction? tapActionFor(LogicalKeyboardKey key, {required bool isRepeat}) {
  if (isRepeat) return null;
  if (key == LogicalKeyboardKey.space) return TapAction.stamp;
  if (key == LogicalKeyboardKey.backspace) return TapAction.undo;
  if (key == LogicalKeyboardKey.keyP) return TapAction.playPause;
  if (key == LogicalKeyboardKey.arrowLeft) return TapAction.seekBack;
  if (key == LogicalKeyboardKey.arrowRight) return TapAction.seekForward;
  return null;
}

/// "mm:ss.xx" for a tapped time, "--" for a line that is not tapped yet.
String stampLabel(double? t) => t == null ? '--' : karmp3.stamp(t);

/// The part of an audio player the tap screen needs. [MediaKitTapPlayer] is the real
/// one; tests pass a fake through [TapScreen.createPlayer].
abstract class TapPlayer {
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<bool> get playingStream;
  Duration get position;
  Duration get duration;
  bool get playing;

  /// Opens [path] at [start]; it plays at once only if [play] is true.
  Future<void> open(
    String path, {
    Duration start = Duration.zero,
    bool play = false,
  });
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);
  Future<void> dispose();
}

class MediaKitTapPlayer implements TapPlayer {
  MediaKitTapPlayer() : _player = Player();
  final Player _player;

  @override
  Stream<Duration> get positionStream => _player.stream.position;
  @override
  Stream<Duration> get durationStream => _player.stream.duration;
  @override
  Stream<bool> get playingStream => _player.stream.playing;
  @override
  Duration get position => _player.state.position;
  @override
  Duration get duration => _player.state.duration;
  @override
  bool get playing => _player.state.playing;

  @override
  Future<void> open(
    String path, {
    Duration start = Duration.zero,
    bool play = false,
  }) => _player.open(Media(path, start: start), play: play);
  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> setRate(double rate) => _player.setRate(rate);
  @override
  Future<void> dispose() => _player.dispose();
}

/// Tap the start of each lyric line while the song plays (Space), undo with Backspace,
/// click a line to tap it again, preview the result with the instrumental.
class TapScreen extends StatefulWidget {
  const TapScreen({
    super.key,
    required this.lines,
    required this.sourcePath,
    required this.instrumentalPath,
    required this.initialTimes,
    this.initialWordTimes = const [],
    required this.initialOffset,
    required this.onChanged,
    this.onWordTimesChanged,
    this.createPlayer,
  });

  final List<String> lines;
  final String sourcePath;

  /// Null until vocal removal has finished; the preview switch is off until then.
  final String? instrumentalPath;
  final List<double?> initialTimes;

  /// The word times of each line (null for a line timed as a whole).
  final List<List<double?>?> initialWordTimes;
  final double initialOffset;

  /// Called after every change of the taps or the offset.
  final void Function(List<double?> times, double offset) onChanged;

  /// Called after every change of the word times.
  final void Function(List<List<double?>?> wordTimes)? onWordTimesChanged;
  final TapPlayer Function()? createPlayer;

  @override
  State<TapScreen> createState() => _TapScreenState();
}

class _TapScreenState extends State<TapScreen> {
  static const _rowHeight = 56.0;
  static const _seekStep = Duration(seconds: 2);

  late final TapPlayer _player =
      (widget.createPlayer ?? MediaKitTapPlayer.new)();
  late final TapSession _session = TapSession(
    widget.lines,
    times: [
      for (var i = 0; i < widget.lines.length; i++)
        i < widget.initialTimes.length ? widget.initialTimes[i] : null,
    ],
    wordTimes: widget.initialWordTimes,
    offset: widget.initialOffset,
  );
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _scroll = ScrollController();
  // The keyboard focus of this screen. A click anywhere inside takes it (the controls
  // cannot hold it, see ExcludeFocus below), so Space still stamps after the user
  // typed in a text field elsewhere on the page and clicked Play.
  final _focus = FocusNode(debugLabel: 'tap screen');
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _preview = false;
  // Word timing: Space times the next word of [_wordLine] instead of the next line.
  bool _wordMode = false;
  int _wordLine = -1;
  double _rate = 1;
  int _lastShownRow = -2;

  @override
  void initState() {
    super.initState();
    _position = _player.position;
    _duration = _player.duration;
    _playing = _player.playing;
    _subscriptions.addAll([
      _player.positionStream.listen((d) => _update(() => _position = d)),
      _player.durationStream.listen((d) => _update(() => _duration = d)),
      _player.playingStream.listen((p) => _update(() => _playing = p)),
    ]);
    unawaited(_player.open(widget.sourcePath));
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    unawaited(_player.dispose());
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _update(VoidCallback change) {
    if (mounted) setState(change);
  }

  double get _now => _player.position.inMicroseconds / 1e6;

  /// Runs [change] on the session and, if the taps or the offset moved, redraws and
  /// tells the owner.
  void _mutate(VoidCallback change) {
    final before = _session.times;
    final offsetBefore = _session.offset;
    final wordsBefore = jsonEncode(_session.wordTimes);
    change();
    final sameTaps =
        listEquals(before, _session.times) && offsetBefore == _session.offset;
    final sameWords = wordsBefore == jsonEncode(_session.wordTimes);
    if (sameTaps && sameWords) return;
    setState(() {});
    if (!sameTaps) widget.onChanged(_session.times, _session.offset);
    if (!sameWords) widget.onWordTimesChanged?.call(_session.wordTimes);
  }

  /// Times the next word of the selected line, then moves to the next line once this
  /// one has all its words.
  void _stampWord() {
    final line = _wordLine;
    if (line < 0 || _session.times[line] == null) return;
    _session.wordStamp(line, _now);
    final words = _session.wordTimes[line];
    if ((words == null || !words.contains(null)) &&
        line + 1 < widget.lines.length) {
      _wordLine = line + 1;
    }
  }

  /// Takes back the last word tap. Right after a line was finished the selection has
  /// moved on, so it is the previous line that is taken back.
  void _undoWord() {
    var line = _wordLine;
    if (line > 0 &&
        _session.wordTimes[line] == null &&
        _session.wordTimes[line - 1] != null) {
      line--;
    }
    if (line < 0) return;
    _wordLine = line;
    _session.undoWord(line);
  }

  /// The first tapped line with more than one word that still lacks word times.
  int _firstLineToWord() {
    final words = _session.wordTimes;
    for (var i = 0; i < widget.lines.length; i++) {
      if (_session.times[i] != null &&
          splitWords(widget.lines[i]).length > 1 &&
          (words[i] == null || words[i]!.contains(null))) {
        return i;
      }
    }
    return -1;
  }

  void _setWordMode(bool on) => setState(() {
    _wordMode = on;
    if (on && _wordLine < 0) _wordLine = _firstLineToWord();
  });

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final action = tapActionFor(
      event.logicalKey,
      isRepeat: event is KeyRepeatEvent,
    );
    if (action == null) return KeyEventResult.ignored;
    switch (action) {
      case TapAction.stamp:
        if (!_preview) {
          _mutate(_wordMode ? _stampWord : () => _session.stamp(_now));
        }
      case TapAction.undo:
        if (!_preview) _mutate(_wordMode ? _undoWord : _session.undo);
      case TapAction.playPause:
        _togglePlay();
      case TapAction.seekBack:
        _seekBy(-_seekStep);
      case TapAction.seekForward:
        _seekBy(_seekStep);
    }
    return KeyEventResult.handled;
  }

  void _togglePlay() =>
      unawaited(_player.playing ? _player.pause() : _player.play());

  void _seekBy(Duration delta) {
    var target = _player.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    final end = _player.duration;
    if (end > Duration.zero && target > end) target = end;
    unawaited(_player.seek(target));
  }

  void _onRowTap(int i) {
    if (_preview) {
      // Previewing only moves around: it never changes the taps.
      final t = _session.times[i];
      if (t != null) {
        unawaited(_player.seek(_secondsToDuration(t + _session.offset)));
      }
      return;
    }
    if (_wordMode) {
      // Word timing only chooses the line: its taps stay.
      setState(() => _wordLine = i);
      final t = _session.times[i];
      if (t != null) unawaited(_player.seek(_secondsToDuration(t)));
      return;
    }
    _mutate(() => _session.select(i));
    final previous = i > 0 ? _session.times[i - 1] : null;
    unawaited(_player.seek(_secondsToDuration(previous ?? 0)));
  }

  Duration _secondsToDuration(double s) =>
      Duration(microseconds: (math.max(0, s) * 1e6).round());

  Future<void> _setPreview(bool on) async {
    final path = on ? widget.instrumentalPath! : widget.sourcePath;
    final position = _player.position;
    final wasPlaying = _player.playing;
    setState(() => _preview = on);
    await _player.open(path, start: position, play: wasPlaying);
    if (_rate != 1) await _player.setRate(_rate);
  }

  void _setRate(double rate) {
    setState(() => _rate = rate);
    unawaited(_player.setRate(rate));
  }

  String _offsetLabel(double v) =>
      '${v >= 0 ? '+' : '-'}${v.abs().toStringAsFixed(2)} s';

  int get _highlighted => _preview
      ? _session.activeLine(_position.inMicroseconds / 1e6)
      : _wordMode
      ? _wordLine
      : (_session.next < widget.lines.length ? _session.next : -1);

  void _keepVisible(int row) {
    if (row == _lastShownRow) return;
    _lastShownRow = row;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || row < 0 || !_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      final target = (row * _rowHeight - 3 * _rowHeight).clamp(0.0, max);
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final times = _session.times;
    final wordTimes = _session.wordTimes;
    final highlighted = _highlighted;
    _keepVisible(highlighted);
    final seconds = _position.inMicroseconds / 1e6;
    final total = _duration.inMicroseconds / 1e6;
    final mono = Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
      fontFamily: 'monospace',
    );

    // The key handler sits above ExcludeFocus: buttons and sliders must not take the
    // focus, otherwise Space would press them instead of stamping a line.
    return Listener(
      // A click anywhere on this screen takes the keyboard focus. It is claimed on
      // pointer-up because a text field elsewhere on the page gives up its focus to the
      // window's focus scope when clicked outside, during pointer-down, which would
      // undo a request made then.
      onPointerUp: (_) => _focus.requestFocus(),
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: ExcludeFocus(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton.filled(
                      key: const ValueKey('play-pause'),
                      tooltip: _playing ? 'Pause (P)' : 'Play (P)',
                      onPressed: _togglePlay,
                      icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '${stampLabel(seconds)} / ${stampLabel(total)}',
                      key: const ValueKey('time'),
                      style: mono,
                    ),
                    Expanded(
                      child: Slider(
                        key: const ValueKey('seek'),
                        min: 0,
                        max: math.max(total, 1),
                        value: seconds.clamp(0, math.max(total, 1)).toDouble(),
                        onChanged: (v) =>
                            unawaited(_player.seek(_secondsToDuration(v))),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 24,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SegmentedButton<double>(
                      segments: const [
                        ButtonSegment(value: 0.5, label: Text('0.5x')),
                        ButtonSegment(value: 0.75, label: Text('0.75x')),
                        ButtonSegment(value: 1.0, label: Text('1x')),
                      ],
                      selected: {_rate},
                      onSelectionChanged: (s) => _setRate(s.first),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Tap offset'),
                        SizedBox(
                          width: 220,
                          child: Slider(
                            key: const ValueKey('offset'),
                            min: -TapSession.maxOffset,
                            max: TapSession.maxOffset,
                            divisions: 100,
                            value: _session.offset,
                            label: _offsetLabel(_session.offset),
                            onChanged: (v) =>
                                _mutate(() => _session.offset = v),
                          ),
                        ),
                        SizedBox(
                          width: 64,
                          child: Text(
                            _offsetLabel(_session.offset),
                            style: mono,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              SwitchListTile(
                key: const ValueKey('preview'),
                dense: true,
                title: const Text('Preview with the instrumental'),
                subtitle: Text(
                  widget.instrumentalPath == null
                      ? 'Available when vocal removal has finished'
                      : 'Space, Backspace and line clicks are off while previewing',
                ),
                value: _preview,
                onChanged: widget.instrumentalPath == null ? null : _setPreview,
              ),
              SwitchListTile(
                key: const ValueKey('word-mode'),
                dense: true,
                title: const Text('Word timing'),
                subtitle: const Text(
                  'Space times the next word of the selected line; click a line to select it',
                ),
                value: _wordMode,
                onChanged: _setWordMode,
              ),
              const Divider(height: 1),
              Expanded(
                child: widget.lines.isEmpty
                    ? const Center(
                        child: Text(
                          'Add the lyrics first; the lines appear here to be tapped.',
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        itemExtent: _rowHeight,
                        itemCount: widget.lines.length,
                        itemBuilder: (context, i) => ListTile(
                          key: ValueKey('line-$i'),
                          selected: i == highlighted,
                          leading: SizedBox(
                            width: 84,
                            child: Text(stampLabel(times[i]), style: mono),
                          ),
                          title: Text(widget.lines[i]),
                          trailing: wordTimes[i] == null
                              ? null
                              : Text(
                                  '${wordTimes[i]!.where((t) => t != null).length}/'
                                  '${wordTimes[i]!.length} words',
                                ),
                          onTap: () => _onRowTap(i),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
