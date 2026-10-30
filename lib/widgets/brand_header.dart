import 'package:flutter/material.dart';

import '../branding.dart';

/// The app's name in the app bar: the Kantahe wordmark (the version for the current
/// light or dark appearance) followed by "Maker".
class BrandHeader extends StatelessWidget {
  const BrandHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          dark
              ? 'assets/branding/lockup-dark.png'
              : 'assets/branding/lockup-light.png',
          height: 28,
          semanticLabel: appName,
          gaplessPlayback: true,
        ),
        const SizedBox(width: 8),
        const Text('Maker', style: TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
  }
}
