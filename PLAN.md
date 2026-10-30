# Kantahe Maker: plan

Kantahe Maker is a Flutter desktop app for macOS, Linux and Windows. It turns a song
(`.mp3` or `.mp4`) and its lyrics into a `.karmp3` karaoke file. The format is specified
below, and this file is its source of truth.

The work itself is tracked in beads (`bd ready`, `bd list`). This file explains how the
pieces fit together.

## The output: `.karmp3`

A `.karmp3` is a plain ZIP archive (deflate) holding three entries that share one base name:

| Entry | Content |
|---|---|
| `NAME.mp3` | the **instrumental**: the song with its vocals removed |
| `NAME.lrc` | timed lyrics: `[ti:]`, `[ar:]` and optional `[au:]` tags, then one `[mm:ss.xx]` line per lyric line (`<mm:ss.xx>` before each word when word timing exists) |
| `NAME.nfo` | metadata as aligned `Key : value` lines. Empty values are left out |

- `NAME` is `NNNNN - Artist - Title` when a songbook number is given, and `Artist - Title`
  when it is not. Each part is cleaned the same way: the characters
  `\ / : * ? " < > |` and control characters become spaces, whitespace runs are collapsed,
  spaces and dots are trimmed from the ends, the result is cut to 80 characters, and an
  empty result becomes `Unknown`.
- Timestamps are `mm:ss.xx`: minutes padded to 2 digits, then seconds with two decimals
  padded to 5 characters. The time is rounded to whole centiseconds first, so 59.996 s
  becomes `01:00.00`. Negative times are clamped to 0.
- LRC: `[ti:TITLE]` and `[ar:ARTIST]`, then `[au:COMPOSER]` if a composer is given. Then
  one line per lyric line, either `[t]text` (line timing) or `[t]<t1>word<t2>word…` (word
  timing, where `[t]` equals the first word's time).
- NFO rows appear in this order: `Title`, `Artist`, `Song number`, `Composer`, `Lyricist`,
  `Duration` (m:ss), `Audio`, `Vocals removed` (the model name), `Lyrics` ("timed (.lrc,
  N lines)"), `Lyric timing` ("tapped by hand in Kantahe Maker"). Keys are padded to the
  longest key among all rows (`Vocals removed`, 14 characters) and written as
  `Key : value`. Rows with an empty value are left out.
- Every ZIP entry's modified time is fixed at 1980-01-01 00:00 and the `.nfo` holds no date,
  so the same input always produces the same archive contents.
- The archive is written to `PATH.part` first and renamed into place at the end, so a file
  with the final name is always complete.
- No other entries go in the archive (no video, no original audio).

Rules a reader relies on:

- LRC tag lines match `^\[([A-Za-z]+):(.*)\]$`.
- Each lyric line starts with `[mm:ss.xx]`. With word timing, each word follows its own
  `<mm:ss.xx>` mark. Without word timing, the whole line counts as one word at the line's
  time.
- `.nfo` lines match `^(.+?)\s+:\s(.*)$`.
- A reader finds the entries by extension (`.mp3`, `.lrc`, `.nfo`), not by name.

Example `.lrc` (line timing):

```
[ti:Song Title]
[ar:Artist]
[00:07.31]First lyric line
[00:11.34]Second lyric line
```

## User flow

1. **New song**: pick an `.mp3` or `.mp4` (anything ffmpeg can read also works).
2. **Import**: ffmpeg writes `source.mp3` (a plain copy when the input is already MP3) and
   `source.wav` (44.1 kHz stereo, used for separation).
3. **Remove vocals**: runs in the background. `audio-separator` (UVR models) turns
   `source.wav` into an instrumental WAV, and ffmpeg encodes that as `instrumental.mp3`
   (libmp3lame, 192 kbps, 44.1 kHz).
4. **Lyrics**: paste the lyrics, one line per lyric line. Blank lines are dropped.
5. **Tap timing**: `source.mp3` plays with the vocals in, which makes the lines easier to hear.
   Space stamps the next line, Backspace undoes the last stamp, ←/→ seek 2 s, and playback
   speed can be 0.5×, 0.75× or 1×. A tap offset setting (−0.50 to +0.50 s, default 0)
   corrects for reaction time. A preview mode plays the instrumental with the current line
   highlighted. Tapping can happen while step 3 is still running.
6. **Details**: title, artist, and optionally songbook number, composer and lyricist.
7. **Export**: a save dialog, then the `.karmp3` is written.

Each song's work lives in a project folder that is saved as you go, so closing the app does
not lose the tapping.

## Architecture

All of the app's own code is Dart. Every outside tool is a separate executable that the
app runs with `dart:io` `Process`. Nothing outside the app is bundled with it.

| Piece | Choice | Why |
|---|---|---|
| UI | Flutter desktop (macOS, Linux, Windows) | the stated requirement |
| Playback for tapping | `media_kit` + `media_kit_libs_audio` (libmpv) | plays the same way on all three OSes, gives an accurate position and supports playback speed |
| Open and save dialogs | `file_selector` (flutter.dev) | first-party, works on all three desktops |
| ZIP writing | `archive` | ZIP with deflate, plus the tar/xz/zip extraction that tool downloads need |
| Paths | `path_provider`, `path` | app support directory for tools and projects |
| HTTP downloads | `dart:io` `HttpClient` | standard library; no dependency needed |
| Checksums | `crypto` (sha256) | verifies downloaded tools |
| State | plain `StatefulWidget` / `ChangeNotifier` | the app is small enough that it needs no state-management library |
| Audio conversion | **ffmpeg + ffprobe** (external) | extraction, encoding and reading the duration |
| Vocal removal | **`audio-separator`** (python-audio-separator; packages the UVR models as a CLI), started through **`uv`** (external) | `uv` is one binary; it fetches its own Python and the package, so the user installs nothing by hand |
| Separation model | `UVR-MDX-NET-Inst_HQ_3.onnx` (the `audio-separator` default for karaoke instrumentals) | fast on CPU; `audio-separator` downloads it on first use |

### Dependency manager (download only after the user agrees)

- **ffmpeg/ffprobe**: the app first looks for the tools on `PATH` and in `/opt/homebrew/bin`
  and `/usr/local/bin`. Apps started from Finder do not inherit the shell's `PATH`, which is
  why those two folders are checked by name. If the tools are not found, it downloads static
  builds: BtbN FFmpeg-Builds for Windows and Linux, and Martin Riedl's builds for macOS. The
  implementing task verifies the exact URLs and checksum files.
- **uv**: downloaded from astral-sh/uv GitHub releases, using the archive that matches the OS
  and CPU, and checked against the `.sha256` file published next to it.
- **Python, audio-separator and the model**: fetched by uv and audio-separator on first
  separation. `UV_CACHE_DIR`, `UV_PYTHON_INSTALL_DIR` and `UV_TOOL_DIR` point inside the
  app's tools folder, and so does `--model_file_dir`. Everything therefore stays in one
  folder that the user can delete.
- A single consent dialog lists each item with its source URL, approximate size and
  license. Nothing is downloaded until the user clicks Download. Clicking it is the consent,
  so no consent file is kept: the dialog appears again whenever tools are missing. A
  Settings page shows tool status, can re-run the download, open the tools folder and
  delete it.

Tools folder: `<app support>/tools/`. Song projects: `<app support>/projects/<id>/`.

### Code layout (target)

```
lib/
  main.dart              app, routes, safe quit (AppLifecycleListener)
  karmp3.dart            safeName, karMp3Name, stamp, buildLrc, Nfo, writeKarMp3 (pure Dart)
  tool_pins.dart         pinned versions, download URLs, checksum URLs, licenses, sizes
  tools.dart             host detection, findExecutable, verified download, extract, install, resolve
  pipeline.dart          ffmpeg/ffprobe/audio-separator args; importSong; SeparationJob
  tap_session.dart       line-timing logic (stamp, undo, select, offset, export)
  project.dart           SongProject + project.json persistence
  export.dart            exportBlockers, exportKarMp3
  screens/               home, song, tap, settings, tools_dialog
test/                    one *_test.dart per lib file; pure logic first, widget tests with injected seams
```

## Decisions, and when to revisit

- **Separation runs through uv + audio-separator, not a Dart/ONNX port of UVR.** Writing our
  own STFT and inference code would be much more code. Revisit if the size of the Python
  setup (several hundred MB to about 1 GB because of torch) gets complaints. The replacement
  would be the `onnxruntime` FFI package plus a Dart STFT for MDX-Net.
- **Separation runs on the CPU in the MVP.** GPU support (the `[gpu]` extra on NVIDIA,
  CoreML on Apple Silicon) waits until speed becomes a problem.
- **Timing is per line in the MVP.** Word-level tapping is a separate later task. The player
  already handles line-only LRC.
- **The macOS App Sandbox is turned off.** The app runs binaries it downloaded, and the
  sandbox would block them. This is acceptable because the app is not headed for the Mac
  App Store.
- **Instrumental bitrate is fixed at 192 kbps.** A setting can be added if someone asks for one.

## How the work is run

The work is split into beads epics (A Foundation, B Format, C Tools, D Pipeline,
E Timing, F App, G Post-MVP), and every task is written so that an agent with no other
context can carry it out. Each implementation task is test-first: write the listed tests,
watch them fail (RED, recorded in bd notes), implement until they pass (GREEN), then check
that each named mutation makes its regression test fail. Each implementation task is
followed by a review task that re-runs the gate and the mutations, and checks the spec,
the constraints and over-engineering. Dependent work waits for the review, not just the
implementation. `bd ready` shows what can start.

## Git policy

Commits and pushes are manual only. The person working on the project runs them. No tool,
hook or agent commits or pushes on its own (see `CLAUDE.md`). Beads `dolt.auto-push` is set
to `false`.
