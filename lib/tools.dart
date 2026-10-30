// Pure helpers for the external tools (ffmpeg, ffprobe, uv, audio-separator): host
// detection, the tools folder layout, finding an installed tool, parsing checksum
// files, and the I/O that installs them: verified download, extraction, the uv
// install of audio-separator. No Flutter imports.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'tool_pins.dart';

enum HostOs { macos, linux, windows }

enum HostArch { x64, arm64 }

final _hostPattern = RegExp(r'on "(\w+)_(\w+)"');

/// Reads the OS and CPU from Platform.version, which ends in e.g. `on "macos_arm64"`.
/// Anything that is not macOS/Linux/Windows on x64/arm64 is unsupported.
(HostOs, HostArch) parseHost(String platformVersion) {
  final m = _hostPattern.firstMatch(platformVersion);
  if (m == null) {
    throw UnsupportedError('Cannot read the platform from: $platformVersion');
  }
  final os = HostOs.values.where((o) => o.name == m[1]);
  final arch = HostArch.values.where((a) => a.name == m[2]);
  if (os.isEmpty || arch.isEmpty) {
    throw UnsupportedError('Unsupported platform: ${m[1]}_${m[2]}');
  }
  return (os.first, arch.first);
}

/// Key into [toolDownloads], e.g. "macos-arm64".
String targetKey(HostOs os, HostArch arch) => '${os.name}-${arch.name}';

List<PinnedDownload> downloadsFor(HostOs os, HostArch arch) =>
    toolDownloads[targetKey(os, arch)]!;

/// The file name of a program: "uv" becomes "uv.exe" on Windows.
String exeName(String name, HostOs os) => os == HostOs.windows ? '$name.exe' : name;

/// The folder the app keeps its downloaded tools in (APP_SUPPORT/tools).
class ToolsDir {
  final String root;
  ToolsDir(this.root);

  String get bin => p.join(root, 'bin');
  String get python => p.join(root, 'python');
  String get uvCache => p.join(root, 'uv-cache');
  String get uvTools => p.join(root, 'uv-tools');
  String get models => p.join(root, 'models');
  String get downloads => p.join(root, 'downloads');
}

/// Environment that keeps everything uv downloads or installs inside the tools folder.
Map<String, String> uvEnv(ToolsDir d) => {
      'UV_CACHE_DIR': d.uvCache,
      'UV_PYTHON_INSTALL_DIR': d.python,
      'UV_TOOL_DIR': d.uvTools,
      'UV_TOOL_BIN_DIR': d.bin,
    };

/// Apps started from Finder do not get the shell's PATH, so these two Homebrew
/// folders are searched by name on macOS.
const macExtraDirs = <String>['/opt/homebrew/bin', '/usr/local/bin'];

/// The path of the program [name], or null. Searched in this order: the tools folder,
/// each folder of PATH, then [extraDirs]. Only a file counts, not a directory.
String? findExecutable(
  String name, {
  required HostOs os,
  required ToolsDir tools,
  required Map<String, String> env,
  List<String> extraDirs = const [],
}) {
  final pathVar = env['PATH'] ?? env['Path'] ?? '';
  final pathDirs = pathVar.split(os == HostOs.windows ? ';' : ':');
  for (final dir in [tools.bin, ...pathDirs, ...extraDirs]) {
    if (dir.isEmpty) continue;
    final candidate = p.join(dir, exeName(name, os));
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

final _sha256 = RegExp(r'^[0-9a-fA-F]{64}$');
final _checksumLine = RegExp(r'^(\S+)\s+\*?(.+?)\s*$');

/// The SHA-256 (lower case) listed for [fileName] in a checksum file. Lines look like
/// "HASH  NAME" or "HASH *NAME". A file holding only one bare hash applies to any name.
/// Null when the file is not listed or the hash is not 64 hex digits.
String? expectedSha256(String checksumText, String fileName) {
  for (final line in LineSplitter.split(checksumText)) {
    final m = _checksumLine.firstMatch(line.trim());
    if (m != null && m[2] == fileName && _sha256.hasMatch(m[1]!)) {
      return m[1]!.toLowerCase();
    }
  }
  final bare = checksumText.trim();
  return _sha256.hasMatch(bare) ? bare.toLowerCase() : null;
}

/// Where the tools the pipeline needs are.
class ToolPaths {
  final String ffmpeg, ffprobe, separator, modelDir;
  const ToolPaths({
    required this.ffmpeg,
    required this.ffprobe,
    required this.separator,
    required this.modelDir,
  });
}

/// Folders searched besides PATH: the Homebrew ones on macOS, none elsewhere.
List<String> defaultExtraDirs(HostOs os) =>
    os == HostOs.macos ? macExtraDirs : const [];

// ------------------------------------------------------------------ download

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

Future<HttpClientResponse> _get(
  HttpClient http,
  String url,
  Duration idleTimeout,
) async {
  final request = await http.getUrl(Uri.parse(url)).timeout(idleTimeout);
  request.followRedirects = true;
  request.maxRedirects = 10;
  final response = await request.close().timeout(idleTimeout);
  if (response.statusCode != HttpStatus.ok) {
    await response.drain<void>();
    throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
  }
  return response;
}

/// Downloads [d] into [dest] and returns the file, named like the last part of the
/// URL. The SHA-256 listed in the checksum file must match, otherwise nothing is
/// kept and a StateError is thrown. The body is not fetched if the checksum file
/// does not list the file. It is written to NAME.part and renamed only after the
/// hash matched, so a file with the final name is always verified.
///
/// A connection that stays silent for [idleTimeout] ends the download with a
/// TimeoutException (and removes the partial file). The limit restarts with every
/// chunk, so a slow but steady download is fine.
Future<File> download(
  PinnedDownload d,
  Directory dest, {
  void Function(int received, int? total)? onProgress,
  HttpClient? client,
  Duration idleTimeout = const Duration(seconds: 60),
}) async {
  final fileName = Uri.parse(d.url).pathSegments.last;
  final http = client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 30));
  try {
    final sums = await (await _get(http, d.checksumUrl, idleTimeout))
        .transform(utf8.decoder)
        .timeout(idleTimeout)
        .join();
    final expected = expectedSha256(sums, fileName);
    if (expected == null) throw StateError('no checksum for $fileName');

    final response = await _get(http, d.url, idleTimeout);
    await dest.create(recursive: true);
    final part = File(p.join(dest.path, '$fileName.part'));
    final out = part.openWrite();
    final digest = _DigestSink();
    final hash = sha256.startChunkedConversion(digest);
    try {
      var received = 0;
      final total = response.contentLength >= 0 ? response.contentLength : null;
      await for (final chunk in response.timeout(idleTimeout)) {
        hash.add(chunk);
        out.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      hash.close();
      await out.close();
    } catch (_) {
      try {
        await out.close();
      } catch (_) {}
      _deleteIfExists(part.path);
      rethrow;
    }
    if (digest.value.toString() != expected) {
      _deleteIfExists(part.path);
      throw StateError('checksum mismatch for $fileName');
    }
    return await part.rename(p.join(dest.path, fileName));
  } finally {
    if (client == null) http.close(force: true);
  }
}

void _deleteIfExists(String path) {
  final f = File(path);
  if (f.existsSync()) f.deleteSync();
}

// ---------------------------------------------------------------- extraction

const _found = 0, _missing = 1, _unsupported = 2;

String _baseName(String entryName) => entryName.split('/').last;

int _fromZip(String archivePath, String member, String outPath) {
  final input = InputFileStream(archivePath);
  try {
    for (final entry in ZipDecoder().decodeStream(input).files) {
      if (entry.isFile && _baseName(entry.name) == member) {
        final out = OutputFileStream(outPath);
        try {
          entry.writeContent(out);
        } finally {
          out.closeSync();
        }
        return _found;
      }
    }
    return _missing;
  } finally {
    input.closeSync();
  }
}

int _fromTar(String tarPath, String member, String outPath) {
  final input = InputFileStream(tarPath);
  var result = _missing;
  try {
    TarDecoder().decodeStream(input, keepEntries: false, callback: (entry) {
      if (result == _found ||
          !entry.isFile ||
          entry.isSymbolicLink ||
          _baseName(entry.name) != member) {
        return;
      }
      final out = OutputFileStream(outPath);
      try {
        entry.writeContent(out);
      } finally {
        out.closeSync();
      }
      result = _found;
    });
  } finally {
    input.closeSync();
  }
  return result;
}

/// Runs in an isolate: decoding a big archive takes seconds and must not freeze the
/// UI. Streams from and to files, so memory stays small. Returns a status code
/// rather than throwing, because exceptions do not reliably cross isolates.
int _extractSync(String archivePath, String member, String outPath) {
  final name = archivePath.toLowerCase();
  if (name.endsWith('.zip')) return _fromZip(archivePath, member, outPath);
  final gz = name.endsWith('.tar.gz') || name.endsWith('.tgz');
  if (!gz && !name.endsWith('.tar.xz')) return _unsupported;
  final tarPath = '$archivePath.tar';
  try {
    final input = InputFileStream(archivePath);
    final output = OutputFileStream(tarPath);
    try {
      if (gz) {
        GZipDecoder().decodeStream(input, output);
      } else {
        XZDecoder().decodeStream(input, output, throwOnError: true);
      }
    } finally {
      input.closeSync();
      output.closeSync();
    }
    return _fromTar(tarPath, member, outPath);
  } finally {
    _deleteIfExists(tarPath);
  }
}

/// Takes the file called [member] (matched on its file name, at any depth) out of a
/// .zip, .tar.gz/.tgz or .tar.xz [archive] and writes it to [bin]/[member]. The name
/// written is always [member], whatever the archive says. On macOS and Linux the
/// file is made executable. Throws StateError if the member is not in the archive.
Future<File> extractMember(File archive, String member, Directory bin) async {
  await bin.create(recursive: true);
  final target = p.join(bin.path, member);
  final part = '$target.part';
  final int status;
  try {
    status = await Isolate.run(() => _extractSync(archive.path, member, part));
  } catch (_) {
    _deleteIfExists(part);
    rethrow;
  }
  if (status != _found) {
    _deleteIfExists(part);
    throw StateError(status == _unsupported
        ? 'unsupported archive type: ${p.basename(archive.path)}'
        : '$member not found in ${p.basename(archive.path)}');
  }
  final out = await File(part).rename(target);
  if (!Platform.isWindows) {
    final r = await Process.run('chmod', ['+x', out.path]);
    if (r.exitCode != 0) throw StateError('chmod failed for ${out.path}: ${r.stderr}');
  }
  return out;
}

// ----------------------------------------------------------------- processes

/// A program that exited with a non-zero code. [lastLines] is the end of its output.
class ProcessFailure implements Exception {
  final int exitCode;
  final List<String> lastLines;
  ProcessFailure(this.exitCode, this.lastLines);

  @override
  String toString() => 'ProcessFailure: exit code $exitCode\n${lastLines.join('\n')}';
}

/// Runs [exe] with [args] (never through a shell), passing each line of stdout and
/// stderr to [onLine]. Carriage returns count as line ends, so progress bars arrive
/// line by line. [onStart] gets the running process (to cancel it). Throws
/// [ProcessFailure] (with the last 20 lines) on a non-zero exit. Output still arriving
/// more than [outputGrace] after the program ended is dropped.
Future<void> runLogged(
  String exe,
  List<String> args, {
  Map<String, String>? environment,
  void Function(String line)? onLine,
  void Function(Process process)? onStart,
  Duration outputGrace = const Duration(seconds: 5),
}) async {
  final proc = await Process.start(exe, args, environment: environment);
  onStart?.call(proc);
  final last = <String>[];
  void handle(String line) {
    last.add(line);
    if (last.length > 20) last.removeAt(0);
    onLine?.call(line);
  }

  Future<void> pump(Stream<List<int>> s) => s
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .forEach(handle);

  final pumped = Future.wait([pump(proc.stdout), pump(proc.stderr)]);
  final code = await proc.exitCode;
  // A background process that outlives the program can keep its output open for ever;
  // do not wait for that.
  await pumped.timeout(outputGrace, onTimeout: () => <void>[]);
  if (code != 0) throw ProcessFailure(code, List.unmodifiable(last));
}

/// Installs audio-separator with uv (uv downloads its own Python, so none is needed
/// on the machine) and then downloads the model. Everything stays in the tools folder.
Future<void> installSeparator(
  String uvPath,
  ToolsDir d,
  HostOs os, {
  void Function(String line)? onLine,
}) async {
  final env = uvEnv(d);
  await runLogged(
    uvPath,
    [
      'tool',
      'install',
      '--managed-python',
      '--python',
      pythonVersion,
      for (final package in separatorExtraPackages) ...['--with', package],
      'audio-separator[cpu]==$audioSeparatorVersion',
    ],
    environment: env,
    onLine: onLine,
  );
  await Directory(d.models).create(recursive: true);
  await runLogged(
    p.join(d.bin, exeName('audio-separator', os)),
    ['--download_model_only', '--model_filename', separatorModel, '--model_file_dir', d.models],
    environment: env,
    onLine: onLine,
  );
}

// -------------------------------------------------------------------- status

/// Where each tool is, or null if it is missing. ffmpeg and ffprobe may come from the
/// system (PATH, Homebrew folders on macOS). uv and audio-separator count only when
/// they are in the tools folder, because the app needs its own copies.
Map<String, String?> toolStatus(
  ToolsDir d,
  HostOs os,
  Map<String, String> env, {
  List<String>? extraDirs,
}) {
  extraDirs ??= defaultExtraDirs(os);
  String? system(String name) =>
      findExecutable(name, os: os, tools: d, env: env, extraDirs: extraDirs!);
  String? onlyInBin(String name) {
    final path = p.join(d.bin, exeName(name, os));
    return File(path).existsSync() ? path : null;
  }

  final model = p.join(d.models, separatorModel);
  return {
    'ffmpeg': system('ffmpeg'),
    'ffprobe': system('ffprobe'),
    'uv': onlyInBin('uv'),
    'audio-separator': onlyInBin('audio-separator'),
    'model': File(model).existsSync() ? model : null,
  };
}

/// The tools the pipeline needs, or null if any is missing. uv is not needed once
/// audio-separator is installed.
ToolPaths? resolve(
  ToolsDir d,
  HostOs os,
  Map<String, String> env, {
  List<String>? extraDirs,
}) {
  final s = toolStatus(d, os, env, extraDirs: extraDirs);
  final ffmpeg = s['ffmpeg'], ffprobe = s['ffprobe'], separator = s['audio-separator'];
  if (ffmpeg == null || ffprobe == null || separator == null || s['model'] == null) {
    return null;
  }
  return ToolPaths(
      ffmpeg: ffmpeg, ffprobe: ffprobe, separator: separator, modelDir: d.models);
}

// ------------------------------------------------------------------- install

/// Installs whatever is missing: downloads and extracts ffmpeg, ffprobe and uv for
/// this host (skipping what [toolStatus] already finds), then uses uv to install
/// audio-separator and the model. An archive that holds two members is downloaded
/// once. The downloads folder is removed at the end, also after a failure.
///
/// [downloads], [env], [extraDirs] and [client] exist for tests; by default the
/// pinned downloads for ([os], [arch]), the process environment and the real network
/// are used.
Future<void> installTools(
  ToolsDir d,
  HostOs os,
  HostArch arch, {
  Map<String, String>? env,
  List<String>? extraDirs,
  List<PinnedDownload>? downloads,
  void Function(String file, int received, int? total)? onProgress,
  void Function(String line)? onLine,
  HttpClient? client,
  Duration idleTimeout = const Duration(seconds: 60),
}) async {
  env ??= Platform.environment;
  extraDirs ??= defaultExtraDirs(os);
  final before = toolStatus(d, os, env, extraDirs: extraDirs);
  final http = client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 30));
  try {
    final archives = <String, File>{};
    for (final dl in downloads ?? downloadsFor(os, arch)) {
      if (before[dl.member.replaceFirst(RegExp(r'\.exe$'), '')] != null) continue;
      final name = Uri.parse(dl.url).pathSegments.last;
      final archive = archives[dl.url] ??= await download(
        dl,
        Directory(d.downloads),
        client: http,
        idleTimeout: idleTimeout,
        onProgress: (received, total) => onProgress?.call(name, received, total),
      );
      await extractMember(archive, dl.member, Directory(d.bin));
    }
  } finally {
    if (client == null) http.close(force: true);
    final dir = Directory(d.downloads);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
  final after = toolStatus(d, os, env, extraDirs: extraDirs);
  if (after['audio-separator'] == null || after['model'] == null) {
    final uv = after['uv'];
    if (uv == null) throw StateError('uv is missing, cannot install audio-separator');
    await installSeparator(uv, d, os, onLine: onLine);
  }
}
