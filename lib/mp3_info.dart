// What an MP3 file says about itself in its first frame header: bitrate, sampling rate and
// channels; and, for a variable-bitrate file (the app made those in version 1.2.0 only), its
// average from the Xing tag. Used to describe the MP3s in the .nfo as they really are.
// Pure Dart: no Flutter imports.

class Mp3Info {
  /// The bitrate of the first frame header, or the average when [variable].
  final int kbps, hertz, channels;

  /// True for a variable-bitrate file (a Xing tag with its frame and byte counts), whose
  /// first frame header says nothing about the average.
  final bool variable;
  const Mp3Info({
    required this.kbps,
    required this.hertz,
    required this.channels,
    this.variable = false,
  });
}

/// The bitrate, sampling rate and channels in the first MPEG-1 Layer III frame header of
/// [bytes] (after an ID3v2 tag, if any), or null when there is none. A Xing or Info tag after
/// the header with both its counts gives the bitrate of the stream instead, because the frame
/// that holds the tag may have a larger bitrate than the audio (ffmpeg does that when the
/// tag does not fit): Xing means variable bitrate, and the average is given; Info means
/// constant bitrate, and the nearest standard bitrate is given. Never throws.
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
    final mono = (bytes[i + 3] >> 6) == 3;
    final tag = _tagAverage(
      bytes,
      i + 4 + ((bytes[i + 1] & 1) == 0 ? 2 : 0) + (mono ? 17 : 32),
      hertz,
    );
    return Mp3Info(
      kbps: tag == null ? kbps : (tag.variable ? tag.kbps : _nearestStandard(tag.kbps)),
      hertz: hertz,
      channels: mono ? 1 : 2,
      variable: tag?.variable ?? false,
    );
  }
  return null;
}

/// The average kbps from a Xing or Info tag at [at] and whether it is a Xing (variable
/// bitrate) one, or null when there is no tag, it lacks the frame or byte count, or [bytes]
/// ends inside it. One MPEG-1 Layer III frame is 1152 samples.
({int kbps, bool variable})? _tagAverage(List<int> bytes, int at, int hertz) {
  if (at + 8 > bytes.length) return null;
  final name = String.fromCharCodes(bytes.sublist(at, at + 4));
  if (name != 'Xing' && name != 'Info') return null;
  final flags = _u32(bytes, at + 4);
  if (flags & 3 != 3 || at + 16 > bytes.length) return null;
  final frames = _u32(bytes, at + 8), size = _u32(bytes, at + 12);
  if (frames == 0 || size == 0) return null;
  return (kbps: (size * 8 * hertz / (frames * 1152 * 1000)).round(), variable: name == 'Xing');
}

/// The standard MPEG-1 Layer III bitrate closest to [kbps].
int _nearestStandard(int kbps) => _kbps
    .where((k) => k > 0)
    .reduce((a, b) => (a - kbps).abs() <= (b - kbps).abs() ? a : b);

int _u32(List<int> b, int i) => b[i] << 24 | b[i + 1] << 16 | b[i + 2] << 8 | b[i + 3];

// MPEG-1 Layer III, by the 4-bit index (0 is free format, 15 is not valid).
const _kbps = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0];
const _hertz = [44100, 48000, 32000, 0];

/// "MP3, 44.1 kHz, 128 kbps"; "MP3, 44.1 kHz, 95 kbps average (VBR)" for a variable-bitrate
/// file. With [withChannels] it ends with ", mono" or ", stereo".
String describeMp3(Mp3Info info, {bool withChannels = false}) {
  final khz = info.hertz / 1000;
  final text = khz == khz.roundToDouble() ? khz.toInt().toString() : khz.toString();
  final rate = info.variable ? '${info.kbps} kbps average (VBR)' : '${info.kbps} kbps';
  return 'MP3, $text kHz, $rate${withChannels ? ', ${info.channels == 1 ? 'mono' : 'stereo'}' : ''}';
}
