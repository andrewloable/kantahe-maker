// The Kantahe brand: its name, colors and theme. The colors come from the main Kantahe
// brand (/Volumes/mandark-1Tb/projects/loabletech/kantahe/branding/build.py): a dark navy
// background with the yellow "sung" colour and the cyan accent.

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// What the app is called wherever people see it.
const appName = 'Kantahe Maker';

const brandSung = Color(0xFFFFD23F); // yellow: the sung part of a lyric
const brandUnsung = Color(0xFFFFFFFF); // white: the part still to come
const brandAccent = Color(0xFF4FD1FF); // cyan
const brandInk = Color(0xFF0C1230); // very dark navy
const brandLightSung = Color(
  0xFFC98A00,
); // the yellow, darkened to read on white
const brandLightInk = Color(0xFF1D2550); // the navy for text on white

double _channel(double c) =>
    c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color c) =>
    0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b);

/// The WCAG contrast ratio of two colors, from 1 (equal) to 21 (black on white). Text
/// needs at least 4.5.
double contrastRatio(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// The app theme for a light or dark appearance.
ThemeData brandTheme(Brightness brightness) {
  final base = ColorScheme.fromSeed(
    seedColor: brandAccent,
    brightness: brightness,
  );
  final scheme = brightness == Brightness.dark
      ? base.copyWith(
          primary: brandSung,
          onPrimary: brandInk,
          secondary: brandAccent,
          onSecondary: brandInk,
          surface: brandInk,
          onSurface: brandUnsung,
        )
      : base.copyWith(
          primary: brandLightInk,
          onPrimary: brandUnsung,
          secondary: brandLightSung,
          onSecondary: brandInk,
          surface: brandUnsung,
          onSurface: brandLightInk,
        );
  return ThemeData(useMaterial3: true, colorScheme: scheme);
}
