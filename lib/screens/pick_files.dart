// The file dialogs of the app: an audio or video file to make a song from, and a .karmp3 to
// open. On Windows they run in a process of their own (see windows_dialogs.dart), so a stuck
// dialog cannot freeze the app.

import 'dart:io';

import 'package:file_selector/file_selector.dart';

import '../windows_dialogs.dart';

const audioTypes = XTypeGroup(
  label: 'Audio or video',
  extensions: ['mp3', 'mp4', 'm4a', 'mkv', 'webm', 'wav', 'flac'],
);

const karMp3Types = XTypeGroup(label: 'Karaoke', extensions: ['karmp3']);

Future<String?> _pick(XTypeGroup types) async {
  if (Platform.isWindows) {
    return showWindowsDialog(label: types.label!, extensions: types.extensions!);
  }
  return (await openFile(acceptedTypeGroups: [types]))?.path;
}

/// Asks the user for an audio or video file; null if they cancel.
Future<String?> pickAudioFile() => _pick(audioTypes);

/// Asks the user for a .karmp3 file; null if they cancel.
Future<String?> pickKarMp3File() => _pick(karMp3Types);
