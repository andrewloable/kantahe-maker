// km-755: the app uses package:material_ui, Flutter's Material library as its own package.
// The deprecated legacy library (flutter's material.dart, deprecated since Flutter 3.47) is a
// separate copy of the same classes: mixing the two splits themes and widget types, so
// nothing may import or export it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// An import or export of the legacy library, in either quote style (km-5ms). The escaped
/// dot keeps this line from matching itself.
final _legacy = RegExp(r'''^\s*(?:import|export)\s+['"]package:flutter/material\.dart['"]''',
    multiLine: true);

bool usesLegacyMaterial(String source) => _legacy.hasMatch(source);

void main() {
  test('the_check_sees_every_spelling', () {
    const lib = 'package:flutter/' 'material.dart';
    for (final line in [
      "import '$lib';",
      'import "$lib";',
      "import '$lib' show Tooltip;",
      "import '$lib' as legacy;",
      'export "$lib";',
      "  import '$lib';",
    ]) {
      expect(usesLegacyMaterial('// x\n$line\n'), isTrue, reason: line);
    }
    expect(usesLegacyMaterial("import 'package:material_ui/material_ui.dart';"), isFalse);
    expect(usesLegacyMaterial("// see $lib for history"), isFalse);
  });

  test('nothing_imports_the_deprecated_material_library', () {
    final offenders = [
      for (final dir in ['lib', 'test', 'integration_test'])
        if (Directory(dir).existsSync())
          for (final f in Directory(dir).listSync(recursive: true).whereType<File>())
            if (f.path.endsWith('.dart') && usesLegacyMaterial(f.readAsStringSync()))
              p.normalize(f.path),
    ];
    expect(offenders, isEmpty);
  });
}
