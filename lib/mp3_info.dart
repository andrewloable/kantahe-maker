// What an MP3 file says about itself in its first frame header: bitrate, sampling rate and
// channels. Used to describe the instrumental in the .nfo as it really is.
// Pure Dart: no Flutter imports.

class Mp3Info {
  final int kbps, hertz, channels;
  const Mp3Info({
    required this.kbps,
    required this.hertz,
    required this.channels,
  });
}

/// The bitrate, sampling rate and channels in the first MPEG-1 Layer III frame header of
/// [bytes] (after an ID3v2 tag, if any), or null when there is none. Never throws.
Mp3Info? readMp3Info(List<int> bytes) {
  var start = 0;
  if (bytes.length >= 10 &&
      bytes[0] == 0x49 && // "ID3"
      bytes[1] == 0x44 &&
      bytes[2] == 0x33) {
    // Four "syncsafe" bytes: 7 bits each. A footer (flag 0x10) adds 10 more bytes.
    final size = (bytes[6] & 0x7F) << 21 |
        (bytes[7] & 0x7F) << 14 |
        (bytes[8] & 0x7F) << 7 |
        (bytes[9] & 0x7F);
    start = 10 + size + ((bytes[5] & 0x10) != 0 ? 10 : 0);
  }
  // A few bytes of padding may sit between the tag and the first frame.
  for (var i = start; i + 4 <= bytes.length && i < start + 4096; i++) {
    // 0xFF, then 111 + version 11 (MPEG-1) + layer 01 (III) + any CRC flag.
    if (bytes[i] != 0xFF || (bytes[i + 1] & 0xFE) != 0xFA) continue;
    final kbps = _kbps[bytes[i + 2] >> 4];
    final hertz = _hertz[(bytes[i + 2] >> 2) & 3];
    if (kbps == 0 || hertz == 0) continue;
    return Mp3Info(
      kbps: kbps,
      hertz: hertz,
      channels: (bytes[i + 3] >> 6) == 3 ? 1 : 2,
    );
  }
  return null;
}

// MPEG-1 Layer III, by the 4-bit index (0 is free format, 15 is not valid).
const _kbps = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0];
const _hertz = [44100, 48000, 32000, 0];

/// "MP3, 44.1 kHz, 128 kbps".
String describeMp3(Mp3Info info) {
  final khz = info.hertz / 1000;
  final text = khz == khz.roundToDouble() ? khz.toInt().toString() : khz.toString();
  return 'MP3, $text kHz, ${info.kbps} kbps';
}
