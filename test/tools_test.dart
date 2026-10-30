import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:kantahe_maker/tool_pins.dart';
import 'package:kantahe_maker/tools.dart';

import 'support/windows_safe.dart';

void main() {
  final h64a = 'a' * 64;
  final h64b = 'b' * 64;

  group('parseHost', () {
    test('parse_host', () {
      expect(parseHost('3.9.0 (stable) on "macos_arm64"'), (
        HostOs.macos,
        HostArch.arm64,
      ));
      expect(parseHost('3.9.0 (stable) (Mon Jan 1) on "windows_x64"'), (
        HostOs.windows,
        HostArch.x64,
      ));
      expect(parseHost('3.9.0 on "linux_arm64"'), (
        HostOs.linux,
        HostArch.arm64,
      ));
    });
    test('parse_host_unsupported', () {
      expect(() => parseHost('3.9.0 on "linux_ia32"'), throwsUnsupportedError);
      expect(
        () => parseHost('3.9.0 on "android_arm64"'),
        throwsUnsupportedError,
      );
      expect(() => parseHost('no platform here'), throwsUnsupportedError);
    });
  });

  test('downloads_for', () {
    expect(downloadsFor(HostOs.linux, HostArch.arm64), hasLength(3));
    expect(targetKey(HostOs.windows, HostArch.x64), 'windows-x64');
  });

  test('exe_name', () {
    expect(exeName('uv', HostOs.windows), 'uv.exe');
    expect(exeName('uv', HostOs.macos), 'uv');
    expect(exeName('uv', HostOs.linux), 'uv');
  });

  group('ToolsDir', () {
    test('folder_names', () {
      final d = ToolsDir('/r');
      expect(d.bin, p.join('/r', 'bin'));
      expect(d.python, p.join('/r', 'python'));
      expect(d.uvCache, p.join('/r', 'uv-cache'));
      expect(d.uvTools, p.join('/r', 'uv-tools'));
      expect(d.models, p.join('/r', 'models'));
      expect(d.downloads, p.join('/r', 'downloads'));
    });
    test('uv_env', () {
      final env = uvEnv(ToolsDir('/r'));
      expect(env.keys.toSet(), {
        'UV_CACHE_DIR',
        'UV_PYTHON_INSTALL_DIR',
        'UV_TOOL_DIR',
        'UV_TOOL_BIN_DIR',
      });
      expect(env.values.every((v) => v.startsWith('/r')), isTrue);
      expect(env['UV_TOOL_BIN_DIR'], p.join('/r', 'bin'));
    });
  });

  group('findExecutable', () {
    late Directory tmp;
    late ToolsDir tools;
    late Directory pathDir;
    late Directory extra;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tools_test');
      tools = ToolsDir('${tmp.path}/tools');
      Directory(tools.bin).createSync(recursive: true);
      pathDir = Directory('${tmp.path}/pathdir')..createSync();
      extra = Directory('${tmp.path}/extra')..createSync();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    String? find(String name, {HostOs os = HostOs.macos, String? path}) =>
        findExecutable(
          name,
          os: os,
          tools: tools,
          env: {'PATH': path ?? pathDir.path},
          extraDirs: [extra.path],
        );

    test('find_order', () {
      // A Windows PATH is split on ';' (a drive letter has a ':'), so use the host's rules.
      final os = Platform.isWindows ? HostOs.windows : HostOs.macos;
      final name = exeName('ffmpeg', os);
      File('${tools.bin}/$name').writeAsStringSync('t');
      File('${pathDir.path}/$name').writeAsStringSync('p');
      File('${extra.path}/$name').writeAsStringSync('e');
      expect(find('ffmpeg', os: os), samePath('${tools.bin}/$name'));
      File('${tools.bin}/$name').deleteSync();
      expect(find('ffmpeg', os: os), samePath('${pathDir.path}/$name'));
      File('${pathDir.path}/$name').deleteSync();
      expect(find('ffmpeg', os: os), samePath('${extra.path}/$name'));
    });

    test('find_windows_path_sep', () {
      File('${pathDir.path}/ffmpeg.exe').writeAsStringSync('p');
      expect(
        find('ffmpeg', os: HostOs.windows, path: 'x;${pathDir.path}'),
        samePath('${pathDir.path}/ffmpeg.exe'),
      );
      // The plain name (no .exe) is not what a Windows host looks for.
      File('${pathDir.path}/ffmpeg.exe').deleteSync();
      File('${pathDir.path}/ffmpeg').writeAsStringSync('p');
      expect(
        find('ffmpeg', os: HostOs.windows, path: 'x;${pathDir.path}'),
        isNull,
      );
    });

    test('find_none', () {
      expect(find('ffmpeg'), isNull);
      Directory('${pathDir.path}/ffmpeg').createSync();
      expect(
        find('ffmpeg'),
        isNull,
        reason: 'a directory is not an executable',
      );
    });

    test('find_empty_path_entries', () {
      expect(
        findExecutable(
          'ffmpeg',
          os: HostOs.macos,
          tools: tools,
          env: const {},
          extraDirs: const [],
        ),
        isNull,
      );
      expect(find('ffmpeg', path: '::${pathDir.path}:'), isNull);
    });

    test('mac_extra_dirs', () {
      expect(macExtraDirs, ['/opt/homebrew/bin', '/usr/local/bin']);
    });
  });

  group('expectedSha256', () {
    test('sha_two_columns', () {
      final text = '$h64a  uv-x.tar.gz\n$h64b *other.zip\n';
      expect(expectedSha256(text, 'other.zip'), h64b);
      expect(expectedSha256(text, 'uv-x.tar.gz'), h64a);
      expect(expectedSha256(text, 'missing'), isNull);
    });
    test('sha_bare', () {
      expect(expectedSha256('${h64a.toUpperCase()}\n', 'anything.zip'), h64a);
      expect(expectedSha256('abc\n', 'anything.zip'), isNull);
    });
    test('sha_name_with_spaces_and_crlf', () {
      final text = '$h64a  my file.zip\r\n$h64b  b.zip\r\n';
      expect(expectedSha256(text, 'my file.zip'), h64a);
      expect(expectedSha256(text, 'b.zip'), h64b);
    });
    test('sha_rejects_bad_hash', () {
      expect(expectedSha256('abc123  f.zip\n', 'f.zip'), isNull);
    });
    test('sha_does_not_match_a_suffix', () {
      expect(expectedSha256('$h64a  xf.zip\n', 'f.zip'), isNull);
    });
  });

  test('tool_paths', () {
    const t = ToolPaths(
      ffmpeg: 'a',
      ffprobe: 'b',
      separator: 'c',
      modelDir: 'd',
    );
    expect(
      [t.ffmpeg, t.ffprobe, t.separator, t.modelDir],
      ['a', 'b', 'c', 'd'],
    );
  });

  // ------------------------------------------------------------------ I/O
  final noSh = Platform.isWindows ? 'needs a POSIX shell' : false;

  group('download', () {
    late Directory tmp;
    late _Server server;
    setUp(() => tmp = Directory.systemTemp.createTempSync('tools_dl'));
    tearDown(() async {
      await server.close();
      tmp.deleteSync(recursive: true);
    });

    Future<PinnedDownload> serve(
      Map<String, List<int>> routes, {
      String? checksumLine,
      String urlPath = '/f.bin',
    }) async {
      final body = routes['/f.bin'];
      if (body != null) {
        routes['/sums.txt'] = utf8.encode(
          checksumLine ?? '${sha256.convert(body)}  f.bin\n',
        );
      }
      server = await _Server.start(routes);
      return PinnedDownload(server.url(urlPath), server.url('/sums.txt'), 'f');
    }

    test('download_ok', () async {
      final d = await serve({'/f.bin': utf8.encode('hello')});
      final dest = Directory('${tmp.path}/dl');
      final got = <int>[];
      final file = await download(
        d,
        dest,
        onProgress: (r, total) {
          got.add(r);
          expect(total, 5);
        },
      );
      expect(file.path, samePath('${dest.path}/f.bin'));
      expect(file.readAsStringSync(), 'hello');
      expect(File('${file.path}.part').existsSync(), isFalse);
      expect(got.last, 5);
    });

    test('download_redirect', () async {
      final d = await serve({
        '/f.bin': utf8.encode('hello'),
      }, urlPath: '/redirect/f.bin');
      final file = await download(d, tmp);
      expect(file.readAsStringSync(), 'hello');
    });

    test('download_mismatch', () async {
      final d = await serve({
        '/f.bin': utf8.encode('hello'),
      }, checksumLine: '${sha256.convert(utf8.encode('other'))}  f.bin\n');
      await expectLater(download(d, tmp), throwsStateError);
      expect(tmp.listSync(), isEmpty, reason: 'no f.bin and no f.bin.part');
    });

    test('download_no_checksum_entry', () async {
      final d = await serve({
        '/f.bin': utf8.encode('hello'),
      }, checksumLine: '${'a' * 64}  other.bin\n');
      await expectLater(download(d, tmp), throwsStateError);
      expect(tmp.listSync(), isEmpty);
      expect(
        server.hits['/f.bin'] ?? 0,
        0,
        reason: 'the body must not be fetched without a checksum',
      );
    });

    test('download_404', () async {
      final d = await serve(
        {'/f.bin': utf8.encode('hello')},
        urlPath: '/missing.bin',
        checksumLine: '${'a' * 64}  missing.bin\n',
      );
      await expectLater(download(d, tmp), throwsA(isA<HttpException>()));
      expect(tmp.listSync(), isEmpty);
    });

    test('download_checksum_404', () async {
      server = await _Server.start({'/f.bin': utf8.encode('hello')});
      final d = PinnedDownload(
        server.url('/f.bin'),
        server.url('/no-sums.txt'),
        'f',
      );
      await expectLater(download(d, tmp), throwsA(isA<HttpException>()));
      expect(tmp.listSync(), isEmpty);
    });
  });

  group('download timeouts', () {
    late Directory tmp;
    late HttpServer server;
    setUp(() => tmp = Directory.systemTemp.createTempSync('tools_to'));
    tearDown(() async {
      await server.close(force: true);
      tmp.deleteSync(recursive: true);
    });

    PinnedDownload dl() => PinnedDownload(
      'http://127.0.0.1:${server.port}/f.bin',
      'http://127.0.0.1:${server.port}/sums.txt',
      'f',
    );

    // The outer 5 s limit only keeps a hung call from stalling the whole run. It also
    // throws a TimeoutException, so each test checks the call failed FAST.
    Future<void> expectFastTimeout(Future<Object?> call) async {
      final sw = Stopwatch()..start();
      await expectLater(
        call.timeout(const Duration(seconds: 5)),
        throwsA(isA<TimeoutException>()),
      );
      expect(
        sw.elapsed,
        lessThan(const Duration(seconds: 3)),
        reason: 'the idle timeout, not the outer limit, must end it',
      );
    }

    test('download_stall_mid_body', () async {
      server = await _timingServer('half');
      await expectFastTimeout(
        download(dl(), tmp, idleTimeout: const Duration(milliseconds: 300)),
      );
      expect(tmp.listSync(), isEmpty, reason: 'no f.bin and no f.bin.part');
    });

    test('download_stall_before_headers', () async {
      server = await _timingServer('silent');
      await expectFastTimeout(
        download(dl(), tmp, idleTimeout: const Duration(milliseconds: 300)),
      );
      expect(tmp.listSync(), isEmpty);
    });

    test('download_stall_in_checksum_file', () async {
      server = await _timingServer('sums-half');
      await expectFastTimeout(
        download(dl(), tmp, idleTimeout: const Duration(milliseconds: 300)),
      );
      expect(tmp.listSync(), isEmpty);
    });

    test('install_tools_passes_idle_timeout', () async {
      server = await _timingServer('half');
      final tools = ToolsDir('${tmp.path}/tools');
      await expectFastTimeout(
        installTools(
          tools,
          HostOs.linux,
          HostArch.x64,
          env: const {'PATH': ''},
          extraDirs: const [],
          downloads: [dl()],
          idleTimeout: const Duration(milliseconds: 300),
        ),
      );
      expect(
        Directory(tools.downloads).existsSync(),
        isFalse,
        reason: 'downloads/ is removed after the failure',
      );
    });

    test('download_slow_but_steady_is_ok', () async {
      server = await _timingServer('slow');
      final sw = Stopwatch()..start();
      final file = await download(
        dl(),
        tmp,
        idleTimeout: const Duration(milliseconds: 400),
      );
      expect(file.lengthSync(), 2000);
      expect(
        sw.elapsed,
        greaterThan(const Duration(milliseconds: 400)),
        reason: 'the whole transfer is longer than the idle limit',
      );
    });
  });

  group('extractMember', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('tools_ex'));
    tearDown(() => tmp.deleteSync(recursive: true));

    Archive archiveOf(Map<String, String> files) {
      final a = Archive();
      files.forEach(
        (name, content) =>
            a.addFile(ArchiveFile.bytes(name, utf8.encode(content))),
      );
      return a;
    }

    File write(String name, List<int> bytes) =>
        File('${tmp.path}/$name')..writeAsBytesSync(bytes);

    bool isExecutable(File f) => f.statSync().mode & 0x49 != 0;

    test('extract_rename_retries_while_the_target_is_busy', () async {
      final a = write(
        'a.zip',
        ZipEncoder().encodeBytes(archiveOf({'bin/ffmpeg': 'x'})),
      );
      final bin = Directory('${tmp.path}/bin')..createSync();
      // A folder where the program goes makes the rename fail until it goes away, like
      // a virus scanner holding the file on Windows.
      final blocker = Directory('${bin.path}/ffmpeg')..createSync();
      Timer(const Duration(milliseconds: 150), blocker.deleteSync);
      final out = await extractMember(a, 'ffmpeg', bin);
      expect(out.readAsStringSync(), 'x');
    });

    test('extract_tar_gz_nested', () async {
      final tar = TarEncoder().encodeBytes(
        archiveOf({'ffmpeg-n7/readme.txt': 'no', 'ffmpeg-n7/bin/ffmpeg': 'x'}),
      );
      final a = write('a.tar.gz', GZipEncoder().encodeBytes(tar));
      final out = await extractMember(
        a,
        'ffmpeg',
        Directory('${tmp.path}/bin'),
      );
      expect(out.path, samePath('${tmp.path}/bin/ffmpeg'));
      expect(out.readAsStringSync(), 'x');
      if (!Platform.isWindows) expect(isExecutable(out), isTrue);
      expect(File('${out.path}.part').existsSync(), isFalse);
    });

    test('extract_zip', () async {
      final a = write(
        'a.zip',
        ZipEncoder().encodeBytes(
          archiveOf({'pkg/bin/ffprobe.exe': 'p', 'pkg/bin/ffmpeg.exe': 'm'}),
        ),
      );
      final out = await extractMember(
        a,
        'ffprobe.exe',
        Directory('${tmp.path}/bin'),
      );
      expect(out.readAsStringSync(), 'p');
    });

    test('extract_tar_xz', () async {
      final tar = TarEncoder().encodeBytes(archiveOf({'d/uv': 'U'}));
      final a = write('a.tar.xz', XZEncoder().encodeBytes(tar));
      final out = await extractMember(a, 'uv', Directory('${tmp.path}/bin'));
      expect(out.readAsStringSync(), 'U');
      expect(tmp.listSync().whereType<File>().map((f) => p.normalize(f.path)), [
        p.normalize(a.path),
      ], reason: 'no temp .tar left next to the archive');
    });

    test('extract_missing', () async {
      final a = write(
        'a.zip',
        ZipEncoder().encodeBytes(archiveOf({'x/y': '1'})),
      );
      await expectLater(
        extractMember(a, 'ffmpeg', Directory('${tmp.path}/bin')),
        throwsStateError,
      );
      expect(Directory('${tmp.path}/bin').listSync(), isEmpty);
    });

    test('extract_matches_whole_name', () async {
      final a = write(
        'a.zip',
        ZipEncoder().encodeBytes(archiveOf({'bin/myffmpeg': '1'})),
      );
      await expectLater(
        extractMember(a, 'ffmpeg', Directory('${tmp.path}/bin')),
        throwsStateError,
      );
    });

    test('extract_overwrites_existing', () async {
      final bin = Directory('${tmp.path}/bin')..createSync();
      File('${bin.path}/uv').writeAsStringSync('old');
      final a = write(
        'a.zip',
        ZipEncoder().encodeBytes(archiveOf({'uv': 'new'})),
      );
      final out = await extractMember(a, 'uv', bin);
      expect(out.readAsStringSync(), 'new');
    });

    test('extract_skips_symlink_entry', () async {
      final a = Archive()
        ..addFile(
          ArchiveFile.bytes('d/ffmpeg', <int>[])..symbolicLink = '/etc/hosts',
        )
        ..addFile(ArchiveFile.bytes('e/ffmpeg', utf8.encode('real')));
      final f = write(
        'a.tar.gz',
        GZipEncoder().encodeBytes(TarEncoder().encodeBytes(a)),
      );
      final out = await extractMember(
        f,
        'ffmpeg',
        Directory('${tmp.path}/bin'),
      );
      expect(out.readAsStringSync(), 'real');
    });

    test('extract_only_symlink_is_missing', () async {
      final a = Archive()
        ..addFile(
          ArchiveFile.bytes('d/ffmpeg', <int>[])..symbolicLink = '/etc/hosts',
        );
      final f = write(
        'a.tar.gz',
        GZipEncoder().encodeBytes(TarEncoder().encodeBytes(a)),
      );
      await expectLater(
        extractMember(f, 'ffmpeg', Directory('${tmp.path}/bin')),
        throwsStateError,
      );
      expect(Directory('${tmp.path}/bin').listSync(), isEmpty);
    });

    test('extract_unknown_type', () async {
      final a = write('a.rar', [1, 2, 3]);
      await expectLater(
        extractMember(a, 'uv', Directory('${tmp.path}/bin')),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('unsupported archive type'),
          ),
        ),
      );
    });
  });

  group('runLogged', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('tools_run'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('run_logged_failure', () async {
      final script = _script(
        tmp.path,
        'f.sh',
        'echo one; echo two >&2; exit 3',
      );
      final lines = <String>[];
      try {
        await runLogged(script, const [], onLine: lines.add);
        fail('should have thrown');
      } on ProcessFailure catch (e) {
        expect(e.exitCode, 3);
        expect(e.lastLines, containsAll(['one', 'two']));
        expect(e.toString(), allOf(contains('3'), contains('two')));
      }
      expect(lines, containsAll(['one', 'two']));
    }, skip: noSh);

    test('run_logged_keeps_last_20', () async {
      final script = _script(
        tmp.path,
        's.sh',
        r'i=1; while [ $i -le 30 ]; do echo line $i; i=$((i+1)); done; exit 1',
      );
      try {
        await runLogged(script, const []);
        fail('should have thrown');
      } on ProcessFailure catch (e) {
        expect(e.lastLines, hasLength(20));
        expect(e.lastLines.first, 'line 11');
        expect(e.lastLines.last, 'line 30');
      }
    }, skip: noSh);

    test('run_logged_success_and_env', () async {
      final script = _script(tmp.path, 'e.sh', r'echo "$MY_TEST_VAR $1"');
      final lines = <String>[];
      await runLogged(
        script,
        const ['arg'],
        environment: {'MY_TEST_VAR': 'v'},
        onLine: lines.add,
      );
      expect(lines, ['v arg']);
    }, skip: noSh);

    test('run_logged_on_start_gives_the_process', () async {
      final script = _script(tmp.path, 'p.sh', 'echo hi');
      Process? started;
      await runLogged(script, const [], onStart: (proc) => started = proc);
      expect(started, isNotNull);
      expect(started!.pid, greaterThan(0));
    }, skip: noSh);

    test('run_logged_does_not_hang_on_an_orphaned_output_pipe', () async {
      // A background process outlives the script and keeps its stdout open.
      final script = _script(tmp.path, 'o.sh', 'sleep 3002.5 &\necho started');
      final lines = <String>[];
      final sw = Stopwatch()..start();
      try {
        await runLogged(
          script,
          const [],
          onLine: lines.add,
          outputGrace: const Duration(milliseconds: 300),
        ).timeout(const Duration(seconds: 5));
        expect(lines, ['started']);
        expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
      } finally {
        Process.runSync('pkill', ['-f', 'sleep 3002.5']);
      }
    }, skip: noSh);

    test('run_logged_carriage_returns', () async {
      final script = _script(tmp.path, 'c.sh', r'printf "a\rb\n"');
      final lines = <String>[];
      await runLogged(script, const [], onLine: lines.add);
      expect(lines, ['a', 'b'], reason: 'progress bars use a carriage return');
    }, skip: noSh);
  });

  group('installSeparator', () {
    late Directory tmp;
    late ToolsDir tools;
    late File log;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tools_sep');
      tools = ToolsDir('${tmp.path}/tools');
      Directory(tools.bin).createSync(recursive: true);
      log = File('${tmp.path}/log.txt')..writeAsStringSync('');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('install_separator_args', () async {
      final uv = _script(tmp.path, 'uv', _fakeUv(log.path, checkEnv: true));
      _script(tools.bin, 'audio-separator', _fakeSeparator(log.path));
      await installSeparator(uv, tools, HostOs.linux);
      expect(log.readAsLinesSync(), [
        'uv tool install --managed-python --python $pythonVersion '
            '--with audioread audio-separator[cpu]==$audioSeparatorVersion',
        'sep --download_model_only --model_filename $separatorModel '
            '--model_file_dir ${tools.models}',
      ]);
    }, skip: noSh);

    test('install_separator_uv_failure', () async {
      final uv = _script(tmp.path, 'uv', 'echo "no network" >&2; exit 2');
      await expectLater(
        installSeparator(uv, tools, HostOs.linux),
        throwsA(isA<ProcessFailure>()),
      );
    }, skip: noSh);
  });

  group('toolStatus and resolve', () {
    late Directory tmp;
    late ToolsDir tools;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tools_st');
      tools = ToolsDir('${tmp.path}/tools');
      Directory(tools.bin).createSync(recursive: true);
      Directory(tools.models).createSync(recursive: true);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    void touch(String path) => File(path).writeAsStringSync('x');
    Map<String, String?> status({List<String> extra = const []}) =>
        toolStatus(tools, HostOs.linux, const {'PATH': ''}, extraDirs: extra);
    ToolPaths? res({List<String> extra = const []}) =>
        resolve(tools, HostOs.linux, const {'PATH': ''}, extraDirs: extra);

    test('tool_status_keys_and_missing', () {
      expect(status(), {
        'ffmpeg': null,
        'ffprobe': null,
        'uv': null,
        'audio-separator': null,
        'model': null,
      });
      expect(res(), isNull);
    });

    test('resolve_present', () {
      for (final n in ['ffmpeg', 'ffprobe', 'audio-separator']) {
        touch('${tools.bin}/$n');
      }
      touch('${tools.models}/$separatorModel');
      final r = res()!;
      expect(r.ffmpeg, samePath('${tools.bin}/ffmpeg'));
      expect(r.ffprobe, samePath('${tools.bin}/ffprobe'));
      expect(r.separator, samePath('${tools.bin}/audio-separator'));
      expect(r.modelDir, tools.models);
    });

    test('resolve_requires_model', () {
      for (final n in ['ffmpeg', 'ffprobe', 'audio-separator']) {
        touch('${tools.bin}/$n');
      }
      expect(res(), isNull);
      touch('${tools.models}/$separatorModel');
      expect(res(), isNotNull);
    });

    test('resolve_does_not_need_uv', () {
      for (final n in ['ffmpeg', 'ffprobe', 'audio-separator']) {
        touch('${tools.bin}/$n');
      }
      touch('${tools.models}/$separatorModel');
      expect(status()['uv'], isNull);
      expect(res(), isNotNull);
    });

    test('status_uv_and_separator_only_from_tools_bin', () {
      final other = Directory('${tmp.path}/other')..createSync();
      touch('${other.path}/uv');
      touch('${other.path}/audio-separator');
      touch('${other.path}/ffmpeg');
      final s = toolStatus(
        tools,
        HostOs.linux,
        {'PATH': other.path},
        extraDirs: [other.path],
      );
      expect(
        s['ffmpeg'],
        samePath('${other.path}/ffmpeg'),
        reason: 'control: PATH works',
      );
      expect(s['uv'], isNull);
      expect(s['audio-separator'], isNull);
    });

    test('status_ffmpeg_from_system_dirs', () {
      final sys = Directory('${tmp.path}/sys')..createSync();
      touch('${sys.path}/ffmpeg');
      touch('${sys.path}/ffprobe');
      expect(
        status(extra: [sys.path])['ffmpeg'],
        samePath('${sys.path}/ffmpeg'),
      );
    });

    test('default_extra_dirs', () {
      expect(defaultExtraDirs(HostOs.macos), macExtraDirs);
      expect(defaultExtraDirs(HostOs.linux), isEmpty);
      expect(defaultExtraDirs(HostOs.windows), isEmpty);
    });
  });

  group('installTools', () {
    late Directory tmp;
    late ToolsDir tools;
    late _Server server;
    late File log;
    late List<PinnedDownload> downloads;

    Uint8List tarGz(Map<String, String> files) {
      final a = Archive();
      files.forEach((n, c) => a.addFile(ArchiveFile.bytes(n, utf8.encode(c))));
      return GZipEncoder().encodeBytes(TarEncoder().encodeBytes(a));
    }

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('tools_inst');
      tools = ToolsDir('${tmp.path}/tools');
      log = File('${tmp.path}/log.txt')..writeAsStringSync('');
      final a = tarGz({
        'ffmpeg-x/bin/ffmpeg': 'FF',
        'ffmpeg-x/bin/ffprobe': 'FP',
      });
      final b = tarGz({'uv-x/uv': '#!/bin/sh\n${_fakeUv(log.path)}'});
      server = await _Server.start({
        '/a.tar.gz': a,
        '/b.tar.gz': b,
        '/sums.txt': utf8.encode(
          '${sha256.convert(a)}  a.tar.gz\n${sha256.convert(b)}  b.tar.gz\n',
        ),
      });
      PinnedDownload dl(String path, String member) =>
          PinnedDownload(server.url(path), server.url('/sums.txt'), member);
      downloads = [
        dl('/a.tar.gz', 'ffmpeg'),
        dl('/a.tar.gz', 'ffprobe'),
        dl('/b.tar.gz', 'uv'),
      ];
    });
    tearDown(() async {
      await server.close();
      tmp.deleteSync(recursive: true);
    });

    Future<void> install({List<String> extra = const []}) => installTools(
      tools,
      HostOs.linux,
      HostArch.x64,
      env: const {'PATH': ''},
      extraDirs: extra,
      downloads: downloads,
    );

    test('install_tools_end_to_end', () async {
      final progress = <String>{};
      await installTools(
        tools,
        HostOs.linux,
        HostArch.x64,
        env: const {'PATH': ''},
        extraDirs: const [],
        downloads: downloads,
        onProgress: (file, r, total) => progress.add(file),
      );
      expect(
        resolve(tools, HostOs.linux, const {'PATH': ''}, extraDirs: const []),
        isNotNull,
      );
      expect(File('${tools.bin}/ffmpeg').readAsStringSync(), 'FF');
      expect(File('${tools.bin}/ffprobe').readAsStringSync(), 'FP');
      expect(File('${tools.bin}/uv').existsSync(), isTrue);
      expect(File('${tools.models}/$separatorModel').existsSync(), isTrue);
      expect(Directory(tools.downloads).existsSync(), isFalse);
      expect(progress, {'a.tar.gz', 'b.tar.gz'});
      expect(
        server.hits['/a.tar.gz'],
        1,
        reason: 'ffmpeg and ffprobe share one archive: fetch it once',
      );
      expect(server.hits['/b.tar.gz'], 1);
    }, skip: noSh);

    test('install_tools_skips_system_ffmpeg', () async {
      final sys = Directory('${tmp.path}/sys')..createSync();
      File('${sys.path}/ffmpeg').writeAsStringSync('s');
      File('${sys.path}/ffprobe').writeAsStringSync('s');
      await install(extra: [sys.path]);
      expect(server.hits['/a.tar.gz'] ?? 0, 0);
      expect(File('${tools.bin}/ffmpeg').existsSync(), isFalse);
      expect(File('${tools.bin}/uv').existsSync(), isTrue);
    }, skip: noSh);

    test('install_tools_nothing_missing_does_nothing', () async {
      await install();
      final before = Map.of(server.hits);
      final logBefore = log.readAsStringSync();
      await install();
      expect(server.hits, before, reason: 'no request when all is installed');
      expect(log.readAsStringSync(), logBefore, reason: 'uv is not run again');
    }, skip: noSh);

    test('install_tools_checksum_failure_leaves_no_binary', () async {
      server.routes['/bad-sums.txt'] = utf8.encode('${'0' * 64}  b.tar.gz\n');
      final bad = [
        PinnedDownload(
          server.url('/b.tar.gz'),
          server.url('/bad-sums.txt'),
          'uv',
        ),
      ];
      await expectLater(
        installTools(
          tools,
          HostOs.linux,
          HostArch.x64,
          env: const {'PATH': ''},
          extraDirs: const [],
          downloads: bad,
        ),
        throwsStateError,
      );
      expect(File('${tools.bin}/uv').existsSync(), isFalse);
      expect(
        Directory(tools.downloads).existsSync(),
        isFalse,
        reason: 'downloads/ is cleaned up even on failure',
      );
    }, skip: noSh);
  });
}

/// Writes an executable shell script called [name] into [dir] and returns its path.
String _script(String dir, String name, String body) {
  final file = File('$dir/$name')..writeAsStringSync('#!/bin/sh\n$body\n');
  if (!Platform.isWindows) Process.runSync('chmod', ['+x', file.path]);
  return file.path;
}

/// Body of a fake uv: logs its arguments and "installs" a fake audio-separator that
/// logs its own arguments and creates the model file (argument 3) in the folder
/// given as argument 5.
String _fakeUv(String log, {bool checkEnv = false}) =>
    r'''
echo "uv $*" >> __LOG__
__CHECK__
mkdir -p "$UV_TOOL_BIN_DIR"
cat > "$UV_TOOL_BIN_DIR/audio-separator" <<'EOS'
#!/bin/sh
echo "sep $*" >> __LOG__
mkdir -p "$5"
echo model > "$5/$3"
EOS
chmod +x "$UV_TOOL_BIN_DIR/audio-separator"
'''
        .replaceAll('__LOG__', log)
        .replaceAll(
          '__CHECK__',
          checkEnv
              ? r'[ -n "$UV_TOOL_BIN_DIR" ] && [ -n "$UV_CACHE_DIR" ] || exit 1'
              : '',
        );

String _fakeSeparator(String log) => 'echo "sep \$*" >> $log';

/// A local HTTP server that serves fixed bodies, 404s the rest, and redirects
/// "/redirect/X" to "/X". [hits] counts requests per path.
class _Server {
  final HttpServer server;
  final Map<String, List<int>> routes;
  final Map<String, int> hits = {};
  _Server._(this.server, this.routes);

  static Future<_Server> start(Map<String, List<int>> routes) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final me = _Server._(s, routes);
    s.listen((req) async {
      final path = req.uri.path;
      me.hits[path] = (me.hits[path] ?? 0) + 1;
      if (path.startsWith('/redirect/')) {
        req.response.statusCode = HttpStatus.found;
        req.response.headers.set('location', '/${path.substring(10)}');
      } else if (me.routes.containsKey(path)) {
        final body = me.routes[path]!;
        req.response.contentLength = body.length;
        req.response.add(body);
      } else {
        req.response.statusCode = HttpStatus.notFound;
      }
      await req.response.close();
    });
    return me;
  }

  String url(String path) => 'http://127.0.0.1:${server.port}$path';
  Future<void> close() => server.close(force: true);
}

/// A server for the timeout tests. "/sums.txt" lists the hash of a 2000-byte body of
/// ones. Modes for "/f.bin": 'half' sends 1000 bytes and then goes silent; 'silent'
/// accepts the request and never answers; 'sums-half' stalls inside "/sums.txt"; 'slow' sends 5 chunks of 400 bytes, 150 ms
/// apart (every gap is short, the whole transfer is long).
Future<HttpServer> _timingServer(String mode) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    if (req.uri.path == '/sums.txt') {
      if (mode == 'sums-half') {
        req.response.bufferOutput = false;
        req.response.contentLength = 200;
        req.response.write('abc');
        await req.response.flush();
        return;
      }
      req.response.write('${sha256.convert(List.filled(2000, 1))}  f.bin\n');
      await req.response.close();
      return;
    }
    if (mode == 'silent') return;
    // Without this the response is buffered and the client sees nothing until the end.
    req.response.bufferOutput = false;
    req.response.contentLength = 2000;
    if (mode == 'half') {
      req.response.add(List.filled(1000, 1));
      await req.response.flush();
      return;
    }
    for (var i = 0; i < 5; i++) {
      req.response.add(List.filled(400, 1));
      await req.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    await req.response.close();
  });
  return server;
}
