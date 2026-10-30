import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The screens read and write real files, so the real event loop has to run between
/// pumps (testWidgets uses a fake clock). Without [until] it waits for the first load
/// (about 160 ms and no spinner); with [until] it waits, for up to [seconds] s, for
/// that condition, because a reload takes a few hundred milliseconds. [describe] adds
/// details to the failure message.
Future<void> settle(
  WidgetTester tester, {
  bool Function()? until,
  String Function()? describe,
  int seconds = 5,
}) async {
  for (var i = 0; i < seconds * 50; i++) {
    // The fake clock moves with the real one, so timers in the screens (the save delay)
    // fire as well.
    await tester.pump(const Duration(milliseconds: 20));
    // Check only after real time has passed: the app's file calls started in the pump
    // above have finished by then, and no new ones start before the next pump. On
    // Windows, reading project.json while a save renames over it makes the rename fail.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    if (until != null) {
      if (until()) return;
    } else if (i >= 7 &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      return;
    }
  }
  if (until != null) {
    // Messages on screen (a failed save shows "Could not save: <error>").
    final snacks = [
      for (final t in tester.widgetList<Text>(
        find.descendant(of: find.byType(SnackBar), matching: find.byType(Text)),
      ))
        t.data ?? '',
    ];
    fail(
      'the screen did not reach the expected state within $seconds s'
      '\nsnack bars: $snacks'
      '${describe == null ? '' : '\n${describe()}'}',
    );
  }
}
