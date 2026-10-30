import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The screens read and write real files, so the real event loop has to run between
/// pumps (testWidgets uses a fake clock). Without [until] it waits for the first load
/// (about 160 ms and no spinner); with [until] it waits, for up to 5 s, for that
/// condition, because a reload takes a few hundred milliseconds. [describe] adds
/// details to the failure message.
Future<void> settle(
  WidgetTester tester, {
  bool Function()? until,
  String Function()? describe,
}) async {
  for (var i = 0; i < 250; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    // The fake clock moves with the real one, so timers in the screens (the save delay)
    // fire as well.
    await tester.pump(const Duration(milliseconds: 20));
    if (until != null) {
      if (until()) return;
    } else if (i >= 7 &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      return;
    }
  }
  if (until != null) {
    fail(
      'the screen did not reach the expected state within 5 s'
      '${describe == null ? '' : '\n${describe()}'}',
    );
  }
}
