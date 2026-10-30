import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'branding.dart';
import 'jobs.dart';
import 'screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const KantaheApp());
}

class KantaheApp extends StatefulWidget {
  /// [home] replaces the song list (used by tests that need the real app shell).
  const KantaheApp({super.key, this.home});

  final Widget? home;

  @override
  State<KantaheApp> createState() => _KantaheAppState();
}

class _KantaheAppState extends State<KantaheApp> {
  // When the app is asked to quit, programs it started (vocal removal) are ended first,
  // so none is left running; a stuck one is given up on after a few seconds.
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onExitRequested: () async {
      await jobs.cancelAll(); // never throws, and gives up on a stuck job
      return AppExitResponse.exit;
    },
  );

  @override
  void initState() {
    super.initState();
    _lifecycle; // starts listening
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      theme: brandTheme(Brightness.light),
      darkTheme: brandTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: widget.home ?? const HomeScreen(),
    );
  }
}
