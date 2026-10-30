// One song being worked on. Each song has its own folder, <app support>/projects/<id>/,
// which holds project.json (this file's data) plus the audio files. Everything is saved
// on every change so closing the app never loses the lyrics or the taps.
// Pure Dart: no Flutter imports.

import 'dart:convert';
import 'dart:io';

class SongProject {
  SongProject({required this.id, required this.inputPath});

  /// Also the folder name, see [newProjectId].
  String id;

  /// The file the user picked (an .mp3 or .mp4); kept to show it in the list.
  String inputPath;
  String title = '';
  String artist = '';
  int? number;
  String composer = '';
  String lyricist = '';

  /// The lyrics as typed.
  String lyrics = '';

  /// The tapped time of each lyric line (see [lyricLines]), null where not tapped.
  List<double?> times = [];

  /// The tapped time of each word of each lyric line; null for a line timed as a whole.
  List<List<double?>?> wordTimes = [];

  /// The tap offset in seconds.
  double offset = 0;

  Map<String, dynamic> toJson() => {
    'id': id,
    'inputPath': inputPath,
    'title': title,
    'artist': artist,
    'number': number,
    'composer': composer,
    'lyricist': lyricist,
    'lyrics': lyrics,
    'times': times,
    'wordTimes': wordTimes,
    'offset': offset,
  };

  /// Reads a project. Missing optional keys get their defaults and unknown keys are
  /// ignored, so older and newer files still load. Throws FormatException for a missing
  /// id or inputPath or a value of the wrong type.
  factory SongProject.fromJson(Map<String, dynamic> json) {
    T read<T>(String key, T fallback) {
      final v = json[key];
      if (v == null) return fallback;
      if (v is T) return v;
      throw FormatException('"$key" must be a ${T.toString()}', json[key]);
    }

    double asDouble(Object? v, String key) {
      if (v is num) return v.toDouble();
      throw FormatException('"$key" must be a number', v);
    }

    final id = json['id'], input = json['inputPath'];
    if (id is! String || input is! String) {
      throw const FormatException('"id" and "inputPath" must be strings');
    }
    final p = SongProject(id: id, inputPath: input)
      ..title = read('title', '')
      ..artist = read('artist', '')
      ..composer = read('composer', '')
      ..lyricist = read('lyricist', '')
      ..lyrics = read('lyrics', '');
    final number = json['number'];
    if (number != null) {
      if (number is! int) {
        throw FormatException('"number" must be an integer', number);
      }
      p.number = number;
    }
    final times = json['times'];
    if (times != null) {
      if (times is! List) {
        throw FormatException('"times" must be a list', times);
      }
      p.times = [
        for (final t in times) t == null ? null : asDouble(t, 'times'),
      ];
    }
    final words = json['wordTimes'];
    if (words == null) {
      p.wordTimes = List.filled(p.times.length, null);
    } else {
      if (words is! List) {
        throw FormatException('"wordTimes" must be a list', words);
      }
      p.wordTimes = [
        for (final line in words)
          if (line == null)
            null
          else if (line is List)
            [for (final t in line) t == null ? null : asDouble(t, 'wordTimes')]
          else
            throw FormatException(
              '"wordTimes" entries must be lists or null',
              line,
            ),
      ];
    }
    final offset = json['offset'];
    if (offset != null) p.offset = asDouble(offset, 'offset');
    return p;
  }

  /// The lyric lines: [lyrics] split on line breaks, each trimmed, blank ones dropped.
  List<String> lyricLines() => [
    for (final line in lyrics.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];

  /// Replaces the lyrics. A line keeps its tapped time and word times only if the same
  /// text is still at the same position; every other line becomes untapped.
  void setLyrics(String text) {
    final before = lyricLines();
    lyrics = text;
    final after = lyricLines();
    bool kept(int i) => i < before.length && before[i] == after[i];
    times = [
      for (var i = 0; i < after.length; i++)
        (kept(i) && i < times.length) ? times[i] : null,
    ];
    wordTimes = [
      for (var i = 0; i < after.length; i++)
        (kept(i) && i < wordTimes.length) ? wordTimes[i] : null,
    ];
  }

  Future<void> _saveQueue = Future.value();

  /// Writes dir/project.json through project.json.part and a rename, so the file is
  /// never half written. Creates [dir] if needed. Safe to call again before an earlier
  /// call has finished: the saves of one project run one after the other, each writing
  /// the project as it is when its turn comes, so the newest state is what ends up on
  /// disk. The returned future fails only for its own save.
  Future<void> save(Directory dir) {
    final turn = _saveQueue.then((_) => _write(dir));
    // The next save must go on even if this one fails (the failure goes to the caller).
    _saveQueue = turn.then((_) {}, onError: (Object _) {});
    return turn;
  }

  Future<void> _write(Directory dir) async {
    await dir.create(recursive: true);
    final part = File('${dir.path}/project.json.part');
    await part.writeAsString(
      const JsonEncoder.withIndent('  ').convert(toJson()),
      flush: true,
    );
    await part.rename('${dir.path}/project.json');
  }

  /// Reads dir/project.json. Throws FormatException if it is not valid, and
  /// FileSystemException if it cannot be read.
  static Future<SongProject> load(Directory dir) async {
    final text = await File('${dir.path}/project.json').readAsString();
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException catch (e) {
      throw FormatException('project.json is not valid JSON: ${e.message}');
    }
    if (json is! Map<String, dynamic>) {
      throw const FormatException('project.json must hold a JSON object');
    }
    return SongProject.fromJson(json);
  }
}

/// A new project id from the time: "yyyyMMdd-HHmmss" (sorts by age).
String newProjectId(DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${now.year.toString().padLeft(4, '0')}${two(now.month)}${two(now.day)}'
      '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
}

/// The project folders in [root] (subfolders that hold a project.json), newest first.
/// An empty list if [root] does not exist.
Future<List<Directory>> listProjectDirs(Directory root) async {
  if (!await root.exists()) return [];
  final dirs = [
    await for (final e in root.list(followLinks: false))
      if (e is Directory && await File('${e.path}/project.json').exists()) e,
  ];
  dirs.sort((a, b) => b.path.compareTo(a.path));
  return dirs;
}
