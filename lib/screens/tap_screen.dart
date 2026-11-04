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
enum TapAction { stamp, undo, playPause, seekBack, seekForward, shift }

/// The action for [key], or null. Key repeats are ignored: a held key must not stamp
/// line after line.
TapAction? tapActionFor(LogicalKeyboardKey key, {required bool isRepeat}) {
  if (isRepeat) return null;
  if (key == LogicalKeyboardKey.space) return TapAction.stamp;
  if (key == LogicalKeyboardKey.backspace) return TapAction.undo;
  if (key == LogicalKeyboardKey.keyP) return TapAction.playPause;
  if (key == LogicalKeyboardKey.arrowLeft) return TapAction.seekBack;
  if (key == LogicalKeyboardKey.arrowRight) return TapAction.seekForward;
  if (key == LogicalKeyboardKey.keyS) return TapAction.shift;
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

  /// Sets the volume: [volume] from 0 (silent) to 1 (full).
  Future<void> setVolume(double volume);
  Future<void> dispose();
}

/// media_kit takes a volume from 0 to 100; the app uses 0 to 1. Out-of-range values are
/// cut to the range.
double mediaKitVolume(double volume) => volume.clamp(0.0, 1.0) * 100;

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
  Future<void> setVolume(double volume) => _player.setVolume(mediaKitVolume(volume));
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

  /// Null until vocal splitting has finished; the preview switch is off until then.
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

  // True right after the selection moved on by itself because a line got all its words, so
  // that Backspace goes back to that line. A click (or the switch) clears it: Backspace then
  // belongs to the line the user chose.
  bool _selectionAdvanced = false;
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
      _selectionAdvanced = true;
    }
  }

  /// Takes back the last word tap. Right after a line was finished the selection has
  /// moved on, so it is the previous line that is taken back.
  void _undoWord() {
    var line = _wordLine;
    if (_selectionAdvanced &&
        line > 0 &&
        _session.wordTimes[line] == null &&
        _session.wordTimes[line - 1] != null) {
      line--;
    }
    _selectionAdvanced = false;
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

  /// Takes back all the word taps of the selected line (it keeps its own tap) and goes to its
  /// start, so it can be timed again at once.
  void _resetWords() {
    final line = _wordLine;
    if (line < 0 || _preview) return;
    _selectionAdvanced = false;
    _mutate(() => _session.resetWords(line));
    final t = _session.times[line];
    if (t != null) unawaited(_player.seek(_secondsToDuration(t)));
  }

  /// Dialog to type the time of line [i] and of each of its words (see _TimesDialog).
  Future<void> _editTimes(int i) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _TimesDialog(
        parts: splitWords(widget.lines[i]),
        lineTime: _session.times[i],
        wordTimes: _session.wordTimes[i],
        apply: (t, words) => _mutate(() => _session.setTimes(i, t, words)),
      ),
    );
    if (mounted) _focus.requestFocus();
  }

  void _setWordMode(bool on) => setState(() {
    _selectionAdvanced = false;
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
      case TapAction.shift:
        _shiftToNow();
      case TapAction.seekBack:
        _seekBy(-_seekStep);
      case TapAction.seekForward:
        _seekBy(_seekStep);
    }
    return KeyEventResult.handled;
  }

  /// Asks for a number of seconds and moves every tapped time by it (see _ShiftAllDialog).
  Future<void> _shiftAll() => showDialog<void>(
    context: context,
    builder: (context) => _ShiftAllDialog(
      apply: (delta) => _mutate(() => _session.shiftBy(delta)),
    ),
  );

  /// Makes the first line start now and moves every other tapped line along with it.
  void _shiftToNow() {
    if (!_preview) _mutate(() => _session.shiftTo(_now));
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
      setState(() {
        _wordLine = i;
        _selectionAdvanced = false;
      });
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

  /// The text of line [i]. In word timing the selected line shows which words are timed (lit)
  /// and the one being sung, the last timed (underlined); while the song plays, the
  /// words of the line being sung with a time light up as they are sung. Colour only, so a
  /// line never reflows. Any other line is plain text.
  Widget _lineTitle(int i, List<double?>? words, double seconds) {
    final line = widget.lines[i];
    final key = ValueKey('line-text-$i');
    final wordTiming = _wordMode && !_preview;
    final selected = wordTiming && i == _wordLine && _session.times[i] != null;
    // In word timing every line with word times shows what was timed; only the selected one
    // also underlines the current word. Otherwise the line being sung lights up as it plays.
    final tapped = wordTiming && words != null;
    final playing = !wordTiming && words != null && i == _session.activeLine(seconds);
    if (!selected && !tapped && !playing) return Text(line, key: key);
    final parts = splitWords(line);
    final marks = [
      for (final m in wordMarks(
        wordCount: parts.length,
        times: words,
        timing: selected || tapped,
        position: seconds,
        offset: _session.offset,
      ))
        m == WordMark.current && !selected ? WordMark.lit : m,
    ];
    if (marks.every((m) => m == WordMark.plain)) return Text(line, key: key);
    final scheme = Theme.of(context).colorScheme;
    return Text.rich(
      key: key,
      TextSpan(
        children: [
          for (var k = 0; k < parts.length; k++)
            TextSpan(
              text: parts[k],
              style: switch (marks[k]) {
                WordMark.lit => TextStyle(color: scheme.primary),
                WordMark.current => TextStyle(
                  color: scheme.primary,
                  decoration: TextDecoration.underline,
                ),
                WordMark.plain => TextStyle(color: scheme.onSurface),
              },
            ),
        ],
      ),
    );
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
                    IconButton.outlined(
                      key: const ValueKey('shift'),
                      tooltip: 'First line starts here, the rest move with it (S)',
                      onPressed: _preview || times.isEmpty || times[0] == null
                          ? null
                          : _shiftToNow,
                      icon: const Icon(Icons.vertical_align_top),
                    ),
                    const SizedBox(width: 8),
                    IconButton.outlined(
                      key: const ValueKey('shift-all'),
                      tooltip: 'Move all times by a number of seconds',
                      onPressed: _preview || times.every((t) => t == null)
                          ? null
                          : _shiftAll,
                      icon: const Icon(Icons.swap_vert),
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
                      ? 'Available when vocal splitting has finished'
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
              if (_wordMode)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      key: const ValueKey('word-reset'),
                      onPressed:
                          !_preview && _wordLine >= 0 && wordTimes[_wordLine] != null
                          ? _resetWords
                          : null,
                      child: const Text('Reset the words of this line'),
                    ),
                  ),
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
                          title: _lineTitle(i, wordTimes[i], seconds),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (wordTimes[i] != null)
                                Text(
                                  '${wordTimes[i]!.where((t) => t != null).length}/'
                                  '${wordTimes[i]!.length} words',
                                ),
                              IconButton(
                                key: ValueKey('edit-times-$i'),
                                tooltip: 'Enter the times',
                                onPressed: _preview ? null : () => _editTimes(i),
                                icon: const Icon(Icons.edit_outlined),
                              ),
                            ],
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

/// Types the time of a line (mm:ss.xx) and of each of its words. [apply] sets them and throws
/// ArgumentError when they would break the order; the dialog then stays open with the reason.
/// Moving only the line moves its words along with it.
class _TimesDialog extends StatefulWidget {
  const _TimesDialog({
    required this.parts,
    required this.lineTime,
    required this.wordTimes,
    required this.apply,
  });

  final List<String> parts;
  final double? lineTime;
  final List<double?>? wordTimes;
  final void Function(double t, List<double>? words) apply;

  @override
  State<_TimesDialog> createState() => _TimesDialogState();
}

class _TimesDialogState extends State<_TimesDialog> {
  late final bool _hasWords = widget.parts.length > 1;
  late final String _lineText = widget.lineTime == null
      ? ''
      : stampLabel(widget.lineTime);
  late final List<String> _wordText = [
    for (var k = 0; k < widget.parts.length; k++)
      widget.wordTimes == null || widget.wordTimes![k] == null
          ? ''
          : stampLabel(widget.wordTimes![k]),
  ];
  late final _lineCtrl = TextEditingController(text: _lineText);
  late final _wordCtrls = [
    for (final t in _wordText) TextEditingController(text: t),
  ];
  String? _error;

  @override
  void dispose() {
    _lineCtrl.dispose();
    for (final c in _wordCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  void _fail(String message) => setState(() => _error = message);

  void _save() {
    final typedLine = karmp3.parseStamp(_lineCtrl.text);
    if (typedLine == null) return _fail('Type the line time as mm:ss.xx');
    final filled = [for (final c in _wordCtrls) c.text.trim().isNotEmpty];
    final anyWord = _hasWords && filled.contains(true);
    if (anyWord && !filled.every((f) => f)) {
      return _fail(
        'Fill in every word, or clear them all to time the line as a whole',
      );
    }
    final typedWords = [for (final c in _wordCtrls) karmp3.parseStamp(c.text)];
    if (anyWord && typedWords.contains(null)) {
      return _fail('Type each word time as mm:ss.xx');
    }
    final lineChanged = _lineCtrl.text != _lineText;
    final wordsChanged = [
      for (var k = 0; k < _wordCtrls.length; k++)
        _wordCtrls[k].text != _wordText[k],
    ].contains(true);
    if (!lineChanged && !wordsChanged) return Navigator.pop(context);
    // Words that were not edited keep their exact times; the line never moves them.
    final List<double>? words = !anyWord
        ? null
        : !wordsChanged && widget.wordTimes != null
        ? [for (final w in widget.wordTimes!) w!]
        : [for (final t in typedWords) t!];
    try {
      widget.apply(typedLine, words);
    } on ArgumentError catch (e) {
      return _fail('${e.message}');
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enter the times'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('edit-line-time'),
                controller: _lineCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Line starts at (mm:ss.xx)',
                ),
              ),
              if (_hasWords) ...[
                const SizedBox(height: 12),
                for (var k = 0; k < widget.parts.length; k++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      key: ValueKey('edit-word-$k'),
                      controller: _wordCtrls[k],
                      decoration: InputDecoration(
                        labelText: widget.parts[k].trim(),
                      ),
                    ),
                  ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    key: const ValueKey('edit-error'),
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('edit-cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('edit-save'),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Types a number of seconds to move every tapped time by (negative: earlier). [apply] throws
/// ArgumentError when a time would go below 0:00; the dialog then stays open with the reason.
class _ShiftAllDialog extends StatefulWidget {
  const _ShiftAllDialog({required this.apply});

  final void Function(double delta) apply;

  @override
  State<_ShiftAllDialog> createState() => _ShiftAllDialogState();
}

class _ShiftAllDialogState extends State<_ShiftAllDialog> {
  final _ctrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _fail(String message) => setState(() => _error = message);

  void _apply() {
    final text = _ctrl.text.trim().replaceFirst('+', '');
    final delta = double.tryParse(text);
    if (delta == null) return _fail('Type the seconds, e.g. -1 or 0.5');
    if (delta == 0) return Navigator.pop(context);
    try {
      widget.apply(delta);
    } on ArgumentError catch (e) {
      return _fail('${e.message}');
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Move all times'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('shift-by'),
              controller: _ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Seconds to add (negative moves earlier, e.g. -1)',
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  key: const ValueKey('shift-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('shift-cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('shift-apply'),
          onPressed: _apply,
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
