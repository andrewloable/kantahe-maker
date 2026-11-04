# Kantahe Maker: plan

Kantahe Maker is a Flutter desktop app for macOS, Linux and Windows. It turns a song
(`.mp3` or `.mp4`) and its lyrics into a `.karmp3` karaoke file. The app's domain is
kantahe.party. The format is specified below, and this file is its source of truth.

The work itself is tracked in beads (`bd ready`, `bd list`). This file explains how the
pieces fit together.

## The output: `.karmp3`

The `.karmp3` format is specified in `README.md`, section "The .karmp3 format", and that
section is the source of truth: the entries and their order, how `NAME` is built, the `.lrc`
and `.nfo` layouts, the fixed 1980 entry times, the `.part` then rename rule, and how a
reader and a writer should behave. A test (`test/readme_format_test.dart`) keeps its
examples and its list of `.nfo` rows in step with the code. Change the format there first.

## User flow

**New song** on Home picks an `.mp3` or `.mp4` (the file picker also offers .m4a, .mkv, .webm, .wav and .flac). The song
then opens as a wizard that shows one step at a time: a step header (tap a step to go there),
Back, and Next. Next and the header only open a step once every step before it is done;
Split vocals does not hold up the later steps while it runs. A reopened song opens on its
first unfinished step.

**Open .karmp3** on Home makes a song from a karaoke file to edit it. lib/karmp3_read.dart reads
the ZIP, the `.lrc` and the `.nfo`; lib/karmp3_open.dart copies the instrumental (and the vocals)
out as they are, so nothing is split again, and fills the project from the file: details from the
`.nfo`, lyrics and line and word times from the `.lrc` (offset 0, because those times already
include the offset), the model name of the `Vocals removed` row, and the path of the file. The
song screen treats such a song as already split: it needs `source.mp3` for the Timing step and
nothing else (a file with vocals gets one by mixing the two stems with ffmpeg when it opens; one
without vocals gets a copy of the instrumental). Opened and exported again without edits, the
file comes out the same. "Replace the audio..." on the Song step of such a song asks for another audio or video
file, deletes the stems and source from the song folder, clears audioFromKarmp3 and the model name
and runs the normal read and split; the details, lyrics, times and the path of the opened file stay.
On the Export step such a song gets **Save over <file>** (after a confirmation it writes the edited
song to the same path through the usual `.part` file and rename, so a failure leaves the old file as
it was) and **Export as...** (the Save dialog, for a copy elsewhere).

A **robot icon** next to **New song** starts a song from a Spotify link instead: a dialog asks for
the link (prefilled from the clipboard when it holds one) and shows a notice that the audio is
converted by spotsaver.net. lib/spotify_link.dart reads the title, artist and length;
lib/spotsaver.dart (on lib/cdp.dart) drives spotsaver.net in a Chrome or Edge window that opens minimized for a few seconds and
saves the MP3 in a temporary folder, while lib/autofill.dart looks up composer, lyricist and
lyrics at the same time. Only when the audio exists is the song folder made (so a failure or a
cancel leaves nothing behind); the song then opens and vocal splitting starts as for any other
song. When the download fails the user may choose an MP3 file instead and keeps the details and
lyrics.

1. **Song**: shows the chosen file. ffmpeg writes `source.mp3` (a plain copy when the input is
   already MP3) and `source.wav` (44.1 kHz stereo, used for separation).
2. **Split vocals**: runs in the background, so the user may go on to the next steps; a status
   line on them says how it is going. `audio-separator` (UVR models) turns `source.wav` into an
   instrumental WAV and a vocals WAV in one run. ffmpeg encodes the vocals as `vocals.mp3`
   (libmp3lame, 48 kbps constant, 44.1 kHz, mono) and then the instrumental as
   `instrumental.mp3` (libmp3lame, 96 kbps constant, 44.1 kHz stereo). Both get an Info header
   (ffmpeg's default: frame count and seek table). Each stem is first measured and then brought to
   about -16 LUFS (two passes of ffmpeg `loudnorm`; a silent stem is left as it is), so the
   vocals end up as loud as the instrumental. Only Export waits for it.
3. **Details**: title, artist, and optionally songbook number, composer and lyricist. A blank
   title or artist is filled from the file's tags (ffprobe) once the audio is read; typed
   values are never replaced. The step also searches musicbrainz.org by itself when it opens
   (the typed title and artist, or what the file name suggests, as in "Title - Artist.mp3")
   and lists matches with album, year and length (when nothing is found and both are filled in,
   it searches once more with title and artist swapped, since the file name may be "Artist - Title"). Picking one sets the title and artist and
   fills composer and lyricist where they are blank (a work's "writer" counts as both). Only
   the title and artist (or the file name) are sent, and the step says so. A pasted Spotify
   song link (a box at the top of the step; lib/spotify_link.dart reads the track's title, artist
   and length from open.spotify.com's embed page) starts lib/autofill.dart: it replaces the title
   and artist, and fills composer, lyricist and the lyrics where those are blank, with the lyrics'
   times only when the lrclib.net entry is within 2 s of the audio's own length. The audio always
   comes from the user's file.
4. **Lyrics**: searched on lrclib.net automatically when the step opens with an empty lyrics box
   (once per title and artist). When lrclib.net finds nothing, lyrics.ovh is asked (plain
   lyrics only); when both found nothing, the same two are tried once more with title and artist
   swapped. Only the title and artist are sent, and the step says so. Pick a result or
   paste the lyrics, one line per lyric line. Blank lines are dropped. A result marked
   "timed" has line times: picking it pre-times the lines.
5. **Timing**: `source.mp3` plays with the vocals in, which makes the lines easier to hear.
   Space stamps the next line, Backspace undoes the last stamp, ←/→ seek 2 s, and playback
   speed can be 0.5×, 0.75× or 1×. A tap offset setting (−0.50 to +0.50 s, default 0)
   corrects for reaction time. A preview mode plays the instrumental with the current line
   highlighted. A status line says how many lines are tapped. Times that came with the
   lyrics from lrclib.net are marked as such until the user corrects them by tapping, and the
   `.nfo` says where the timing came from. With **Word timing** on, Space times the next word of
   the selected line, the first word too (one press per word, so the next line starts at its
   first word); the rows show it (`wordMarks` in lib/tap_session.dart, colour only so a
   line never reflows): the timed words are lit and, on the selected line, the word being sung (the last
   timed, the first word before any is) is underlined. Outside word timing the words of the line being sung light up as they play, by
   their times plus the offset. Backspace takes back one word at a time (after a line gets its
   last word the selection moves on by itself, and the first Backspace goes back to that line;
   after a click it acts on the clicked line); "Reset the words of this line" (`resetWords`)
   clears all the word times of the selected line, keeps its tap and seeks to its start.
6. **Export**: shows the file name and any unfinished step with a button to go there. The
   "Include the vocals" box (off by default, saved per song) adds `NAME.vocals.mp3`, so a
   player can turn the vocals on and off. A song whose vocals were removed by version 1.0.x
   has no `vocals.mp3`; with the box ticked, the step says so and offers "Run vocal splitting
   again" first. **Preview** (enabled when the export is ready) opens a dialog that plays the
   song as the export would make it: lib/screens/preview_dialog.dart plays the song folder's own
   `instrumental.mp3` (and `vocals.mp3` when the box is ticked) with the player of the Timing step,
   and shows the lines the export writes (lib/preview.dart: `TapSession.exportLines()`, offset and
   word times included), the line being sung highlighted, a word at a time where every word is
   timed; a tap on a line or on the bar seeks both players. With vocals there is a switch and a
   level; the two players start, seek and pause together and the vocals are moved to the
   instrumental's position when more than 150 ms away (checked every 500 ms, at most once a
   second), the rule of the Kantahe web player. The Kantahe Flutter app is not copied: it shows the
   web player in a WebView, which needs a Kantahe server and has no desktop support. The preview
   writes nothing and needs no ffmpeg. Then a save dialog, and the `.karmp3` is written.
   Afterwards: Show in folder, or Back to songs.

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
| Vocal splitting | **`audio-separator`** (python-audio-separator; packages the UVR models as a CLI), started through **`uv`** (external) | `uv` is one binary; it fetches its own Python and the package, so the user installs nothing by hand |
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
  export.dart            exportBlockers, timingBlockers, exportKarMp3
  wizard.dart            the song wizard's steps: done, can enter, opening step (pure Dart)
  lyrics_lookup.dart     lrclib.net search (synced lyrics too) and the lyrics.ovh fallback
  song_info.dart         musicbrainz.org search: title, artist, album, year, composer, lyricist
  web_get.dart           one HTTP GET with timeout, size limit and the app's User-Agent
  screens/               home, song (the wizard), tap, lyrics_search_panel, song_info_panel,
                         settings, tools_dialog
test/                    one *_test.dart per lib file; pure logic first, widget tests with injected seams
```

## Decisions, and when to revisit

- **Separation runs through uv + audio-separator, not a Dart/ONNX port of UVR.** Writing our
  own STFT and inference code would be much more code. Revisit if the size of the Python
  setup (several hundred MB to about 1 GB because of torch) gets complaints. The replacement
  would be the `onnxruntime` FFI package plus a Dart STFT for MDX-Net.
- **Separation runs on the CPU unless the user turns on the graphics card (Windows only).**
  The Settings switch "Use the graphics card" (`settings.json`, off by default) installs
  `audio-separator[dml]` (DirectML, about 650 MB more, `uv tool install --force`) and starts the
  separator with `--use_directml`. If that run fails, the same song is split again on the
  processor. `audio-separator` ignores `--use_directml` without the DirectML packages and runs on the
  CPU. CUDA (`[gpu]`) was not tried: it needs CUDA builds of torch (about 2.5 GB) and DirectML
  already runs on NVIDIA cards. CoreML on Apple Silicon is not switched on by the app.
- **Timing is per line in the MVP.** Word-level tapping is a separate later task. The player
  already handles line-only LRC.
- **The macOS App Sandbox is turned off.** The app runs binaries it downloaded, and the
  sandbox would block them. This is acceptable because the app is not headed for the Mac
  App Store.
- **MP3 bitrates are fixed and constant**: the instrumental is 96 kbps and the vocals 48 kbps (128 and
  64 kbps in 1.1.x, the instrumental 192 kbps up to 1.0.x); the `.nfo` Audio and Vocals audio rows
  say what a file really has. Version 1.2.0 tried variable bitrate at about 96 and 48 kbps (LAME
  ABR) and 1.2.1 went back to constant bitrate: Chromium seeks in a variable-bitrate MP3 0.3 to
  1.4 s away from the asked time (the seek goes through the approximate Xing seek table) while
  `currentTime` still says the asked time, so the Kantahe web player's guide vocals came in late
  after a toggle. Constant bitrate seeks exactly (measured in Chromium at 96 and 48 kbps). A
  setting can be added if someone asks for one.

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
