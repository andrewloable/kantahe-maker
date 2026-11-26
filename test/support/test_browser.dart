import 'dart:io';

import 'package:kantahe_maker/cdp.dart';
import 'package:kantahe_maker/tools.dart';

/// A browser to test with: KANTAHE_TEST_BROWSER, else one installed in the usual place.
String? testBrowser() {
  final named = Platform.environment['KANTAHE_TEST_BROWSER'];
  if (named != null && File(named).existsSync()) return named;
  final (os, _) = parseHost(Platform.version);
  return findBrowser(os, Platform.environment);
}

final browser = testBrowser();
final noBrowser = browser == null
    ? 'no Chromium-based browser installed (set KANTAHE_TEST_BROWSER)'
    : false;
