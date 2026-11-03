import 'dart:io';

/// Whether the process [pid] is still running. "kill" does not exist on Windows, where
/// "tasklist" lists the process when it is there.
bool processAlive(int pid) {
  if (Platform.isWindows) {
    final out = Process.runSync('tasklist', ['/FI', 'PID eq $pid', '/NH']).stdout as String;
    return RegExp('\\b$pid\\b').hasMatch(out);
  }
  return Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
}
