import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/windows_dialogs.dart';

void main() {
  test('open_dialog_command', () {
    final c = dialogCommand(
      label: 'Audio or video',
      extensions: ['mp3', 'mp4'],
    );
    expect(c.environment['KM_MODE'], 'open');
    expect(c.environment['KM_FILTER'], 'Audio or video (*.mp3;*.mp4)|*.mp3;*.mp4');
    expect(c.args, containsAllInOrder(['-STA', '-EncodedCommand']));
  });

  test('save_dialog_command_carries_the_name_unquoted', () {
    const name = r'''01 - O'Brien "Live" & co.karmp3''';
    final c = dialogCommand(
      label: 'Karaoke',
      extensions: ['karmp3'],
      suggestedName: name,
    );
    expect(c.environment['KM_MODE'], 'save');
    expect(c.environment['KM_NAME'], name);
    // the script never contains the name: it only reads it from the environment
    final bytes = base64.decode(c.args.last);
    final script = String.fromCharCodes([
      for (var i = 0; i < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8),
    ]);
    expect(script, contains(r'$env:KM_NAME'));
    expect(script, isNot(contains('Brien')));
  });
}
