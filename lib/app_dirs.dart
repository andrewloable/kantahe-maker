// Where the app keeps its files: <app support>/projects/<id>/ for each song and
// <app support>/tools/ for the downloaded tools. The app support folder is per user and
// named after the bundle identifier (path_provider decides).

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'tools.dart';

Future<Directory> appProjectsRoot() async =>
    Directory(p.join((await getApplicationSupportDirectory()).path, 'projects'));

Future<ToolsDir> appToolsDir() async =>
    ToolsDir(p.join((await getApplicationSupportDirectory()).path, 'tools'));
