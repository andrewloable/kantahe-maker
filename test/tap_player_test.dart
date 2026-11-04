import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/screens/tap_screen.dart';

import 'support/fake_player.dart';

void main() {
  test('fake_player_records_volume', () async {
    final p = FakePlayer();
    expect(p.volume, 1, reason: 'a player starts at full volume');
    await p.setVolume(0.3);
    await p.setVolume(0);
    expect(p.volumes, [0.3, 0]);
    expect(p.volume, 0);
  });

  test('media_kit_volume_is_scaled', () {
    // media_kit's Player.setVolume takes 0 to 100; the app uses 0 to 1.
    expect(mediaKitVolume(0), 0);
    expect(mediaKitVolume(0.5), 50);
    expect(mediaKitVolume(1), 100);
    expect(mediaKitVolume(2), 100, reason: 'never louder than full');
    expect(mediaKitVolume(-1), 0, reason: 'never below silent');
  });
}
