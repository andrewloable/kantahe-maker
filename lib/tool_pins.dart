// Pinned versions, download URLs and checksum URLs of the external tools the app
// downloads (PLAN.md "Dependency manager"). Pure Dart: no Flutter imports.
//
// Every URL below was fetched on 2026-10-30, and each archive was downloaded once
// and its SHA-256 compared with the published value. To update a pin, repeat that
// check (see the notes of beads task km-v2o.1) and update the tests.

/// One file to download, the URL of the file that lists its SHA-256, and the name of
/// the binary to take out of the archive ([member] is matched on the file name, at
/// any depth inside the archive).
class PinnedDownload {
  final String url;
  final String checksumUrl;
  final String member;
  const PinnedDownload(this.url, this.checksumUrl, this.member);
}

/// https://github.com/astral-sh/uv/releases (checked 2026-10-30). MIT or Apache-2.0.
const uvVersion = '0.13.5';

/// FFmpeg 9.0.2. Windows and Linux: BtbN FFmpeg-Builds, dated tag below, GPL builds
/// (https://github.com/BtbN/FFmpeg-Builds/releases). macOS: Martin Riedl's release
/// builds (https://ffmpeg.martin-riedl.de). Checked 2026-10-30.
const ffmpegVersion = '9.0.2';

/// Python for audio-separator. uv downloads its own copy of it (--managed-python), so
/// no Python is needed on the machine. 3.12 is supported by audio-separator
/// (requires >=3.10, !=3.14.1).
const pythonVersion = '3.12';

/// https://pypi.org/project/audio-separator/ (checked 2026-10-30). MIT.
/// 0.47.1 was released on 2026-10-19; 0.47.2 and 0.48.0 are newer but only a day old.
const audioSeparatorVersion = '0.47.1';

/// The vocal-removal model, fetched by audio-separator itself on first use
/// (64 MB, from github.com/TRvlvr/model_repo).
const separatorModel = 'UVR-MDX-NET-Inst_HQ_3.onnx';

/// Value for audio-separator's --single_stem that gives only the instrumental
/// ("Instrumental" and "instrumental" both work in 0.47.1; this is the documented form).
/// The output is named "INPUT_(Instrumental)_UVR-MDX-NET-Inst_HQ_3.wav".
const singleStemInstrumental = 'Instrumental';

/// Extra packages that must be installed with audio-separator (uv's --with).
/// audio-separator 0.47.1 imports "audioread" but does not declare it, so the CLI
/// crashes with ModuleNotFoundError without it (found by installing it by hand).
const separatorExtraPackages = <String>['audioread'];

const _uv = 'https://github.com/astral-sh/uv/releases/download/$uvVersion';
const _btbnTag = 'autobuild-2026-10-27-18-38';
const _btbn = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/$_btbnTag';
const _btbnSums = '$_btbn/checksums.sha256';
const _btbnName = 'ffmpeg-n9.0.2-36-g6882969ce9';
const _macArm = 'https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2';
const _macX64 = 'https://ffmpeg.martin-riedl.de/download/macos/amd64/1789931006_9.0.2';

/// Downloads that provide ffmpeg, ffprobe and uv, keyed by 'OS-ARCH'. Where one
/// archive holds both ffmpeg and ffprobe it is listed twice, once per member.
const Map<String, List<PinnedDownload>> toolDownloads = {
  'macos-arm64': [
    PinnedDownload('$_macArm/ffmpeg.zip', '$_macArm/ffmpeg.zip.sha256', 'ffmpeg'),
    PinnedDownload('$_macArm/ffprobe.zip', '$_macArm/ffprobe.zip.sha256', 'ffprobe'),
    PinnedDownload('$_uv/uv-aarch64-apple-darwin.tar.gz',
        '$_uv/uv-aarch64-apple-darwin.tar.gz.sha256', 'uv'),
  ],
  'macos-x64': [
    PinnedDownload('$_macX64/ffmpeg.zip', '$_macX64/ffmpeg.zip.sha256', 'ffmpeg'),
    PinnedDownload('$_macX64/ffprobe.zip', '$_macX64/ffprobe.zip.sha256', 'ffprobe'),
    PinnedDownload('$_uv/uv-x86_64-apple-darwin.tar.gz',
        '$_uv/uv-x86_64-apple-darwin.tar.gz.sha256', 'uv'),
  ],
  'linux-x64': [
    PinnedDownload('$_btbn/$_btbnName-linux64-gpl-9.0.tar.xz', _btbnSums, 'ffmpeg'),
    PinnedDownload('$_btbn/$_btbnName-linux64-gpl-9.0.tar.xz', _btbnSums, 'ffprobe'),
    PinnedDownload('$_uv/uv-x86_64-unknown-linux-gnu.tar.gz',
        '$_uv/uv-x86_64-unknown-linux-gnu.tar.gz.sha256', 'uv'),
  ],
  'linux-arm64': [
    PinnedDownload('$_btbn/$_btbnName-linuxarm64-gpl-9.0.tar.xz', _btbnSums, 'ffmpeg'),
    PinnedDownload('$_btbn/$_btbnName-linuxarm64-gpl-9.0.tar.xz', _btbnSums, 'ffprobe'),
    PinnedDownload('$_uv/uv-aarch64-unknown-linux-gnu.tar.gz',
        '$_uv/uv-aarch64-unknown-linux-gnu.tar.gz.sha256', 'uv'),
  ],
  'windows-x64': [
    PinnedDownload('$_btbn/$_btbnName-win64-gpl-9.0.zip', _btbnSums, 'ffmpeg.exe'),
    PinnedDownload('$_btbn/$_btbnName-win64-gpl-9.0.zip', _btbnSums, 'ffprobe.exe'),
    PinnedDownload('$_uv/uv-x86_64-pc-windows-msvc.zip',
        '$_uv/uv-x86_64-pc-windows-msvc.zip.sha256', 'uv.exe'),
  ],
  'windows-arm64': [
    PinnedDownload('$_btbn/$_btbnName-winarm64-gpl-9.0.zip', _btbnSums, 'ffmpeg.exe'),
    PinnedDownload('$_btbn/$_btbnName-winarm64-gpl-9.0.zip', _btbnSums, 'ffprobe.exe'),
    PinnedDownload('$_uv/uv-aarch64-pc-windows-msvc.zip',
        '$_uv/uv-aarch64-pc-windows-msvc.zip.sha256', 'uv.exe'),
  ],
};

/// Shown in the consent dialog.
const Map<String, String> toolLicenses = {
  'ffmpeg': 'GPL (BtbN / Martin Riedl builds)',
  'uv': 'MIT or Apache-2.0',
  'Python': 'PSF',
  'audio-separator': 'MIT',
  'UVR model':
      'UVR project is MIT; the weights (github.com/TRvlvr/model_repo) state no license',
};

/// Approximate download sizes in MB, measured on 2026-10-30: ffmpeg+ffprobe are
/// 55 MB on macOS and 160-190 MB on Windows/Linux (the biggest is shown); uv 14-15 MB;
/// Python 70 MB plus the wheels (torch, numpy, ...) about 1.1 GB; the model 64 MB.
const Map<String, int> approxSizeMb = {
  'ffmpeg': 190,
  'uv': 15,
  'python+audio-separator': 1100,
  'model': 64,
};
