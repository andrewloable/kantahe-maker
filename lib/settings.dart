// The few settings the user can change, kept in <app support>/settings.json. A missing or
// unreadable file means the defaults. Pure Dart: no Flutter imports.

import 'dart:convert';
import 'dart:io';

import 'fs_retry.dart';

class AppSettings {
  /// Vocal splitting on the graphics card (Windows, through DirectML) instead of the
  /// processor. Off until the user turns it on.
  final bool useGraphicsCard;

  const AppSettings({this.useGraphicsCard = false});

  Map<String, dynamic> toJson() => {'useGraphicsCard': useGraphicsCard};

  /// Anything that is not what is expected counts as the default: the file comes from disk.
  factory AppSettings.fromJson(Object? json) => AppSettings(
        useGraphicsCard: json is Map && json['useGraphicsCard'] == true,
      );
}

Future<AppSettings> readSettings(File file) async {
  try {
    return AppSettings.fromJson(jsonDecode(await file.readAsString()));
  } on FormatException {
    return const AppSettings();
  } on FileSystemException {
    return const AppSettings();
  }
}

/// Writes [settings] to a .part file first and renames it, so a crash never leaves half a file.
Future<void> writeSettings(File file, AppSettings settings) async {
  await file.parent.create(recursive: true);
  final part = File('${file.path}.part');
  await part.writeAsString(jsonEncode(settings.toJson()), flush: true);
  await retryBusy(() => part.rename(file.path));
}
