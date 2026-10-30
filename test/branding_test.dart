import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/branding.dart';
import 'package:kantahe_maker/main.dart';
import 'package:kantahe_maker/widgets/brand_header.dart';

// The Flutter template's own icons, which this task replaces.
const flutterDefaultIcon1024 = '6232e5815af17e25e0268b2fec7aea9e068cc92ec709e9605c2b31df4ff2a313';
const flutterDefaultIco = 'c098d3fc85cacff98b8e69811b48e9f0d852fcee278132d794411d978869cbf8';
const brandSource = '/Volumes/mandark-1Tb/projects/loabletech/kantahe/branding/export';

String sha(String path) => sha256.convert(File(path).readAsBytesSync()).toString();
bool isPng(Uint8List b) =>
    b.length > 24 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 && b[4] == 0x0D && b[5] == 0x0A && b[6] == 0x1A && b[7] == 0x0A;
int pngWidth(Uint8List b) => (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
int pngHeight(Uint8List b) => (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
String read(String path) => File(path).readAsStringSync();

void main() {
  test('brand_constants', () {
    expect(appName, 'Kantahe Maker');
    expect(brandSung, const Color(0xFFFFD23F));
    expect(brandUnsung, const Color(0xFFFFFFFF));
    expect(brandAccent, const Color(0xFF4FD1FF));
    expect(brandInk, const Color(0xFF0C1230));
    expect(brandLightSung, const Color(0xFFC98A00));
    expect(brandLightInk, const Color(0xFF1D2550));
  });

  test('contrast_ratio_math', () {
    expect(contrastRatio(Colors.black, Colors.white), closeTo(21.0, 0.01));
    expect(contrastRatio(Colors.white, Colors.black), closeTo(21.0, 0.01));
    expect(contrastRatio(brandSung, brandSung), closeTo(1.0, 1e-9));
    expect(contrastRatio(brandSung, brandInk), contrastRatio(brandInk, brandSung));
  });

  test('theme_colors', () {
    final dark = brandTheme(Brightness.dark).colorScheme;
    expect(dark.brightness, Brightness.dark);
    expect(dark.primary, brandSung);
    expect(dark.onPrimary, brandInk);
    expect(dark.secondary, brandAccent);
    expect(dark.surface, brandInk);
    expect(dark.onSurface, brandUnsung);
    final light = brandTheme(Brightness.light).colorScheme;
    expect(light.brightness, Brightness.light);
    expect(light.primary, brandLightInk);
    expect(light.onPrimary, brandUnsung);
    expect(light.secondary, brandLightSung);
    expect(light.surface, brandUnsung);
    expect(light.onSurface, brandLightInk);
    expect(brandTheme(Brightness.dark).useMaterial3, isTrue);
  });

  test('theme_contrast', () {
    for (final b in Brightness.values) {
      final s = brandTheme(b).colorScheme;
      for (final (name, bg, fg) in [
        ('primary', s.primary, s.onPrimary),
        ('secondary', s.secondary, s.onSecondary),
        ('surface', s.surface, s.onSurface),
        ('error', s.error, s.onError),
      ]) {
        expect(contrastRatio(bg, fg), greaterThanOrEqualTo(4.5), reason: '$b $name');
      }
    }
  });

  testWidgets('app_uses_brand', (tester) async {
    await tester.pumpWidget(const KantaheApp(home: SizedBox()));
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.title, appName);
    expect(app.theme!.colorScheme.primary, brandLightInk);
    expect(app.darkTheme!.colorScheme.primary, brandSung);
    expect(app.themeMode, ThemeMode.system);
  });

  group('BrandHeader', () {
    Future<Image> pumpHeader(WidgetTester tester, Brightness b) async {
      await tester.pumpWidget(MaterialApp(
        theme: brandTheme(b),
        home: const Scaffold(body: BrandHeader()),
      ));
      await tester.pumpAndSettle(); // a theme change is animated
      return tester.widget<Image>(find.byType(Image));
    }

    testWidgets('header_shows_logo', (tester) async {
      final dark = await pumpHeader(tester, Brightness.dark);
      expect((dark.image as AssetImage).assetName, 'assets/branding/lockup-dark.png');
      expect(dark.semanticLabel, 'Kantahe Maker');
      expect(find.text('Maker'), findsOneWidget);
      final light = await pumpHeader(tester, Brightness.light);
      expect((light.image as AssetImage).assetName, 'assets/branding/lockup-light.png');
      expect(light.semanticLabel, 'Kantahe Maker');
    });
  });

  group('assets', () {
    const files = [
      'icon-1024.png', 'icon-512.png', 'icon-256.png', 'icon-128.png',
      'lockup-dark.png', 'lockup-light.png', 'mark-512.png',
    ];

    test('assets_are_the_brand_files', () {
      for (final f in files) {
        final bytes = File('assets/branding/$f').readAsBytesSync();
        expect(isPng(bytes), isTrue, reason: f);
      }
      final icon = File('assets/branding/icon-1024.png').readAsBytesSync();
      expect(pngWidth(icon), 1024);
      expect(pngHeight(icon), 1024);
      expect(read('pubspec.yaml'), contains('- assets/branding/'));
      expect(File('assets/branding/README.md').existsSync(), isTrue);
      final total = files.fold<int>(0, (n, f) => n + File('assets/branding/$f').lengthSync());
      expect(total, lessThan(2 * 1024 * 1024));
    });

    test('assets_match_the_brand_repo', () {
      for (final f in files) {
        expect(sha('assets/branding/$f'), sha('$brandSource/$f'), reason: f);
      }
    }, skip: Directory(brandSource).existsSync() ? false : 'the brand repo is not on this machine');
  });

  group('platform icons and names', () {
    test('macos_icon_set', () {
      const dir = 'macos/Runner/Assets.xcassets/AppIcon.appiconset';
      final json = jsonDecode(read('$dir/Contents.json')) as Map<String, dynamic>;
      final images = (json['images'] as List).cast<Map<String, dynamic>>();
      expect(images, isNotEmpty);
      for (final img in images) {
        final size = int.parse((img['size'] as String).split('x').first);
        final scale = int.parse((img['scale'] as String).replaceAll('x', ''));
        final bytes = File('$dir/${img['filename']}').readAsBytesSync();
        expect(isPng(bytes), isTrue, reason: '${img['filename']}');
        expect(pngWidth(bytes), size * scale, reason: '${img['filename']} width');
        expect(pngHeight(bytes), size * scale, reason: '${img['filename']} height');
      }
      expect(sha('$dir/app_icon_1024.png'), isNot(flutterDefaultIcon1024));
    });

    test('windows_icon', () {
      final b = File('windows/runner/resources/app_icon.ico').readAsBytesSync();
      expect(b.sublist(0, 4), [0, 0, 1, 0]);
      final count = b[4] | (b[5] << 8);
      expect(count, greaterThanOrEqualTo(6));
      final widths = {
        for (var i = 0; i < count; i++) b[6 + 16 * i] == 0 ? 256 : b[6 + 16 * i],
      };
      expect(widths, containsAll([16, 32, 48, 256]));
      expect(sha('windows/runner/resources/app_icon.ico'), isNot(flutterDefaultIco));
    });

    test('platform_names', () {
      final xcconfig = read('macos/Runner/Configs/AppInfo.xcconfig');
      expect(xcconfig, contains('PRODUCT_NAME = Kantahe Maker'));
      expect(xcconfig, contains('PRODUCT_BUNDLE_IDENTIFIER = tech.loable.kantaheMaker'));

      final rc = read('windows/runner/Runner.rc');
      expect(rc, contains('VALUE "ProductName", "Kantahe Maker"'));
      expect(rc, contains('VALUE "FileDescription", "Kantahe Maker"'));
      expect(rc, contains('VALUE "OriginalFilename", "kantahe_maker.exe"'));
      expect(rc, contains('VALUE "InternalName", "kantahe_maker"'));
      expect(read('windows/runner/main.cpp'), contains('L"Kantahe Maker"'));
      expect(read('windows/CMakeLists.txt'), contains('set(BINARY_NAME "kantahe_maker")'));

      final cc = read('linux/runner/my_application.cc');
      expect('"Kantahe Maker"'.allMatches(cc).length, greaterThanOrEqualTo(2));
      expect(cc, contains('gtk_window_set_icon_from_file'));
      final cmake = read('linux/CMakeLists.txt');
      expect(cmake, contains('set(BINARY_NAME "kantahe_maker")'));
      expect(cmake, contains('set(APPLICATION_ID "tech.loable.kantahe_maker")'));
      expect(read('pubspec.yaml'), contains('name: kantahe_maker'));
    });

    test('readme_is_not_the_flutter_boilerplate', () {
      final readme = read('README.md');
      expect(readme, isNot(contains('A new Flutter project')));
      expect(readme, contains('Kantahe Maker'));
      expect(readme, contains('assets/branding/lockup-light.png'));
    });
  });
}
