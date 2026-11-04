// The few settings the user can change, kept in <app support>/settings.json. A missing or
// unreadable file means the defaults. Pure Dart: no Flutter imports.

import 'dart:convert';
import 'dart:io';

import 'fs_retry.dart';

class AppSettings {
  /// Vocal splitting on the graphics card (Windows, through DirectML) instead of the
  /// processor. Off until the user turns it on.
  final bool useGraphicsCard;

  /// The Cloudflare account ID and an API token with the Workers AI permission, for the
  /// automatic lyric timing. The token is a secret: it is only ever kept in this file.
  final String cloudflareAccountId, cloudflareToken;

  /// True when Cloudflare accepted exactly these two values the last time they were saved
  /// (Settings tests them). Changing either value starts again from false.
  final bool cloudflareVerified;

  const AppSettings({
    this.useGraphicsCard = false,
    this.cloudflareAccountId = '',
    this.cloudflareToken = '',
    this.cloudflareVerified = false,
  });

  bool get hasCloudflare =>
      cloudflareAccountId.trim().isNotEmpty && cloudflareToken.trim().isNotEmpty;

  /// Whether the AI timing may be offered: both values there and tested working.
  bool get cloudflareReady => hasCloudflare && cloudflareVerified;

  AppSettings copyWith({
    bool? useGraphicsCard,
    String? cloudflareAccountId,
    String? cloudflareToken,
    bool? cloudflareVerified,
  }) => AppSettings(
    useGraphicsCard: useGraphicsCard ?? this.useGraphicsCard,
    cloudflareAccountId: cloudflareAccountId ?? this.cloudflareAccountId,
    cloudflareToken: cloudflareToken ?? this.cloudflareToken,
    cloudflareVerified: cloudflareVerified ?? this.cloudflareVerified,
  );

  /// Empty Cloudflare values are left out.
  Map<String, dynamic> toJson() => {
    'useGraphicsCard': useGraphicsCard,
    if (cloudflareAccountId.isNotEmpty) 'cloudflareAccountId': cloudflareAccountId,
    if (cloudflareToken.isNotEmpty) 'cloudflareToken': cloudflareToken,
    if (cloudflareVerified) 'cloudflareVerified': true,
  };

  /// Anything that is not what is expected counts as the default: the file comes from disk.
  factory AppSettings.fromJson(Object? json) {
    String text(String key) =>
        json is Map && json[key] is String ? json[key] as String : '';
    return AppSettings(
      useGraphicsCard: json is Map && json['useGraphicsCard'] == true,
      cloudflareAccountId: text('cloudflareAccountId'),
      cloudflareToken: text('cloudflareToken'),
      cloudflareVerified: json is Map && json['cloudflareVerified'] == true,
    );
  }
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
  // The file may hold an API token: only its owner may read it (not on Windows, where the
  // profile folder is private already).
  if (!Platform.isWindows) {
    try {
      await Process.run('chmod', ['600', part.path]);
    } on ProcessException {
      // Best effort.
    }
  }
  await retryBusy(() => part.rename(file.path));
}
