import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/screens/tap_screen.dart';

void main() {
  test('keys_map', () {
    TapAction? a(LogicalKeyboardKey k) => tapActionFor(k, isRepeat: false);
    expect(a(LogicalKeyboardKey.space), TapAction.stamp);
    expect(a(LogicalKeyboardKey.backspace), TapAction.undo);
    expect(a(LogicalKeyboardKey.keyP), TapAction.playPause);
    expect(a(LogicalKeyboardKey.arrowLeft), TapAction.seekBack);
    expect(a(LogicalKeyboardKey.arrowRight), TapAction.seekForward);
    expect(a(LogicalKeyboardKey.keyA), isNull);
    expect(a(LogicalKeyboardKey.enter), isNull);
  });

  test('keys_repeat', () {
    for (final k in [
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.backspace,
      LogicalKeyboardKey.keyP,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
    ]) {
      expect(tapActionFor(k, isRepeat: true), isNull, reason: '$k');
    }
  });

  test('stamp_label', () {
    expect(stampLabel(null), '--');
    expect(stampLabel(65.5), '01:05.50');
    expect(stampLabel(0), '00:00.00');
  });
}
