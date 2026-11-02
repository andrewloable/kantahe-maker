// The Windows Open and Save dialogs, run in a PowerShell process of their own.
// file_selector shows them on the app's UI thread, and every so often the dialog thread
// and the UI thread wait for each other: the window freezes with no dialog on screen.
// In another process a stuck dialog cannot freeze the app.
// Pure Dart: no Flutter imports.

import 'dart:convert';
import 'dart:io';

// The settings come in the environment, so no file name or path is ever quoted into
// the script. STA is required by the Windows Forms dialogs.
const _script = r'''
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$save = $env:KM_MODE -eq 'save'
$dlg = if ($save) { New-Object System.Windows.Forms.SaveFileDialog } else { New-Object System.Windows.Forms.OpenFileDialog }
$dlg.Filter = $env:KM_FILTER
if ($save) {
  $dlg.FileName = $env:KM_NAME
  $dlg.OverwritePrompt = $true
}
$owner = New-Object System.Windows.Forms.Form
$owner.TopMost = $true
if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::Out.Write($dlg.FileName)
}
''';

/// How to run the dialog: the arguments for powershell.exe and the environment that
/// holds its settings. A [suggestedName] makes it a Save dialog.
({List<String> args, Map<String, String> environment}) dialogCommand({
  required String label,
  required List<String> extensions,
  String? suggestedName,
}) {
  final masks = extensions.map((e) => '*.$e').join(';');
  // PowerShell takes -EncodedCommand as base64 of UTF-16LE text.
  final utf16 = [
    for (final unit in _script.codeUnits) ...[unit & 0xff, unit >> 8],
  ];
  return (
    args: [
      '-NoProfile',
      '-NonInteractive',
      '-STA',
      '-WindowStyle',
      'Hidden',
      '-EncodedCommand',
      base64.encode(utf16),
    ],
    environment: {
      'KM_MODE': suggestedName == null ? 'open' : 'save',
      'KM_FILTER': '$label ($masks)|$masks',
      'KM_NAME': suggestedName ?? '',
    },
  );
}

/// The path the user chose, or null when they cancelled. Throws if the dialog could not
/// be run.
Future<String?> showWindowsDialog({
  required String label,
  required List<String> extensions,
  String? suggestedName,
}) async {
  final command = dialogCommand(
    label: label,
    extensions: extensions,
    suggestedName: suggestedName,
  );
  final result = await Process.run(
    'powershell.exe',
    command.args,
    environment: command.environment,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      'powershell.exe',
      const [],
      '${result.stderr}'.trim(),
      result.exitCode,
    );
  }
  final path = '${result.stdout}'.trim();
  return path.isEmpty ? null : path;
}
