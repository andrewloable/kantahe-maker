// Where the app keeps its files: <app support>/projects/<id>/ for each song and
// <app support>/tools/ for the downloaded tools. The app support folder is per user and
// named after the bundle identifier (path_provider decides).

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'tools.dart';

/// The other places an older version kept its app support folder, from the one this
/// version uses ([support]): a version before 1.1.0 was called tech.loable.
List<Directory> legacySupportDirs(Directory support, HostOs os) {
  final parent = p.dirname(support.path);
  return switch (os) {
    // <Application Support>/<bundle id>, and $XDG_DATA_HOME/<application id>.
    HostOs.macos => [Directory(p.join(parent, 'tech.loable.kantaheMaker'))],
    HostOs.linux => [Directory(p.join(parent, 'tech.loable.kantahe_maker'))],
    // %APPDATA%/<company>/<product>: only the company folder differs.
    HostOs.windows => [
      Directory(p.join(p.dirname(parent), 'tech.loable', p.basename(support.path))),
    ],
  };
}

/// The folder [name] ("projects" or "tools") of the app support folder: the one in
/// [support] when it exists, otherwise the one of an older install when that exists
/// (nothing is moved: the tools folder holds absolute links), otherwise the new one.
Directory appFolder(Directory support, HostOs os, String name) {
  for (final dir in [support, ...legacySupportDirs(support, os)]) {
    final folder = Directory(p.join(dir.path, name));
    if (folder.existsSync()) return folder;
  }
  return Directory(p.join(support.path, name));
}

Future<Directory> appProjectsRoot() async => appFolder(
  await getApplicationSupportDirectory(),
  parseHost(Platform.version).$1,
  'projects',
);

Future<ToolsDir> appToolsDir() async => ToolsDir(
  appFolder(
    await getApplicationSupportDirectory(),
    parseHost(Platform.version).$1,
    'tools',
  ).path,
);
