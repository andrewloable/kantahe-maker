import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_dirs.dart';
import '../project.dart';
import '../widgets/brand_header.dart';
import 'settings_screen.dart';
import 'song_screen.dart';

/// One folder of the song list; [project] is null when its project.json cannot be read.
class _Entry {
  final Directory dir;
  final SongProject? project;
  const _Entry(this.dir, this.project);

  String get id => p.basename(dir.path);

  String get title {
    final p0 = project;
    if (p0 == null) return 'Unreadable project';
    if (p0.title.trim().isNotEmpty && p0.artist.trim().isNotEmpty) {
      return '${p0.title.trim()} - ${p0.artist.trim()}';
    }
    return p.basename(p0.inputPath);
  }
}

/// The song list. The seams (everything that touches the machine) have real defaults
/// and can be replaced in tests.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.projectsRoot,
    this.pickFile,
    this.onOpen,
    this.settingsBuilder,
    this.now,
  });

  /// The folder that holds one sub-folder per song.
  final Future<Directory> Function()? projectsRoot;

  /// Asks the user for an audio or video file; null if they cancel.
  final Future<String?> Function()? pickFile;

  /// Opens a song. (The song screen replaces the placeholder default.)
  final void Function(BuildContext context, Directory dir)? onOpen;
  final WidgetBuilder? settingsBuilder;
  final DateTime Function()? now;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _mediaTypes = XTypeGroup(
    label: 'Audio or video',
    extensions: ['mp3', 'mp4', 'm4a', 'mkv', 'webm', 'wav', 'flac'],
  );

  late Future<List<_Entry>> _entries = _load();

  Future<Directory> _root() => (widget.projectsRoot ?? appProjectsRoot)();

  Future<List<_Entry>> _load() async {
    final dirs = await listProjectDirs(await _root());
    return [for (final dir in dirs) _Entry(dir, await _tryLoad(dir))];
  }

  Future<SongProject?> _tryLoad(Directory dir) async {
    try {
      return await SongProject.load(dir);
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  void _reload() {
    setState(() {
      _entries = _load();
    });
  }

  Future<String?> _defaultPick() async =>
      (await openFile(acceptedTypeGroups: const [_mediaTypes]))?.path;

  void _defaultOpen(BuildContext context, Directory dir) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => SongScreen(dir: dir)))
        .then((_) {
          if (mounted) _reload(); // the title and artist may have changed
        });
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _newSong() async {
    final String? path;
    try {
      path = await (widget.pickFile ?? _defaultPick)();
    } catch (e) {
      _showError('Could not open the file dialog: $e');
      return;
    }
    if (path == null) return;
    final Directory dir;
    try {
      final root = await _root();
      // Ids are timestamps to the second; never overwrite a song made in the same second.
      final base = newProjectId((widget.now ?? DateTime.now)());
      var id = base;
      for (var n = 2; Directory(p.join(root.path, id)).existsSync(); n++) {
        id = '$base-$n';
      }
      dir = Directory(p.join(root.path, id));
      await SongProject(id: id, inputPath: path).save(dir);
    } catch (e) {
      _showError('Could not create the song: $e');
      return;
    }
    if (!mounted) return;
    _reload();
    (widget.onOpen ?? _defaultOpen)(context, dir);
  }

  Future<void> _confirmDelete(_Entry entry) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this song project?'),
        content: Text(
          '"${entry.title}" and its audio files will be removed from this '
          'computer. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await entry.dir.delete(recursive: true);
    } catch (e) {
      _showError('Could not delete the song: $e');
    }
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const BrandHeader(),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder:
                    widget.settingsBuilder ?? (_) => const SettingsScreen(),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newSong,
        icon: const Icon(Icons.add),
        label: const Text('New song'),
      ),
      body: FutureBuilder<List<_Entry>>(
        future: _entries,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Could not read your songs: ${snapshot.error}'),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _reload, child: const Text('Retry')),
                ],
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final entries = snapshot.data!;
          if (entries.isEmpty) {
            return const Center(
              child: Text('No songs yet. Click "New song" to start.'),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              for (final e in entries)
                ListTile(
                  key: ValueKey('project-${e.id}'),
                  title: Text(e.title),
                  subtitle: Text(e.id),
                  onTap: () => (widget.onOpen ?? _defaultOpen)(context, e.dir),
                  trailing: IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _confirmDelete(e),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
