<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/branding/lockup-dark.png">
  <img src="assets/branding/lockup-light.png" alt="Kantahe Maker" height="56">
</picture>

# Kantahe Maker

**Make your own karaoke files.** Pick a song and Kantahe Maker takes the vocals out, finds the lyrics, lets you time them by tapping along, and saves it all in one `.karmp3` file. Everything happens on your own computer.

The app's domain is kantahe.party.

<img src="docs/screenshots/05-timing.png" alt="Tapping along to the lyrics of a song in Kantahe Maker" width="880">

*The screenshots show a demo song in the public domain; the lists of matches and lyrics are examples.*

## Why Kantahe Maker

- **Free and open source** (MIT license).
- **Vocals split on your computer** by AI models. Your music is never uploaded.
- **Lyrics and song details found for you**, or type and paste your own.
- **Tap along to time the lyrics**, at half speed if you like, even word by word.
- **Vocals on or off:** tick one box to add the singer's track as a separate, smaller MP3, so a player can switch it on and off.
- **macOS, Windows and Linux.**

## Download

Get the latest version from the [releases page](https://github.com/andrewloable/kantahe-maker/releases/latest):

- **macOS** (12 or newer, Apple silicon and Intel): `kantahe-maker-<version>-macos.zip`. The app is not signed: the first time, right-click it and choose **Open**.
- **Windows**: `kantahe-maker-<version>-windows.zip`. SmartScreen warns about unsigned apps: choose **More info**, then **Run anyway**.
- **Linux**: `kantahe-maker-<version>-linux.tar.gz`. It needs libmpv (`libmpv2` or `libmpv1`).

The first time, the app asks before it downloads the tools it needs (ffmpeg, Python with the vocal-splitting software, and the model): about 1.4 GB, once.

## How it works

Click **New song** and pick an audio or video file (an .mp3 or .mp4, for example). Six steps follow, one screen each. To change a karaoke file you made before, click **Open .karmp3** instead: it opens as a song that is already split, so you can edit its details, lyrics and timing and save it again.

**1. Song.** The app reads your file.

<img src="docs/screenshots/01-home.png" alt="The list of songs, with the New song button" width="600">

**2. Split vocals.** The singer is split from the music, in the background: carry on meanwhile.

<img src="docs/screenshots/02-remove-vocals.png" alt="Vocal splitting running" width="600">

**3. Details.** Title and artist come from the file (a name like "Title - Artist.mp3" is expected); pick a match for composer and lyricist. If nothing is found, the search is tried again with title and artist swapped, in case the file is named "Artist - Title". The Lyrics step also tries the swapped order when it finds nothing. Or paste a Spotify song link in the box at the top of Details: the title, artist, composer, lyricist and lyrics are filled in by themselves (lyrics only into an empty box; their times only when they fit the length of your audio). The audio still comes from your file.

<img src="docs/screenshots/03-details.png" alt="Song details with a list of matches" width="600">

**4. Lyrics.** Pick a result, or paste your own. "Timed" results come with line times. As in Details, a search that finds nothing is tried again with title and artist swapped.

<img src="docs/screenshots/04-lyrics.png" alt="Lyrics results and the lyrics box" width="600">

**5. Timing.** Play the song and press Space as each line starts. For word-by-word timing switch on **Word timing**: Space then times the next word of the selected line, first word included (one press per word); the words you have timed light up and the word being sung (the one you timed last) is underlined. After the last word the selection moves to the first word of the next line. Backspace takes back one word at a time, and **Reset the words of this line** clears the whole line so you can time it again. While the song plays, the words of the current line light up as they are sung. **Auto-time with AI** (optional, needs a free Cloudflare account: see below) listens to the vocals and times every word for you.

<img src="docs/screenshots/05-timing.png" alt="Timing the lyrics line by line" width="600">

**6. Export.** Choose whether to include the vocals and save the `.karmp3`. Click **Preview** first to hear the song with the lyrics moving as they will in the file (with the vocals on or off, and at a level you choose, if you included them).

<img src="docs/screenshots/06-export.png" alt="The export step after saving a file" width="600">

## Automatic timing with Cloudflare AI (optional)

The **Auto-time with AI** button in the Timing step sends the song's vocals to [Cloudflare Workers AI](https://developers.cloudflare.com/workers-ai/) (the Deepgram Nova-3 speech model), which says when each word starts. The app lines the words up with your lyrics, gives every word a time, and offers to add words that are sung but missing from your lyrics. Every time is put 200 ms earlier than heard, so singers have time to react to the next word. Check the result by playing the song; it is a good first draft, not a perfect one.

To use it you need a Cloudflare account and two values from it. The Cloudflare dashboard changes now and then, so a button may be named a little differently; Cloudflare's own guide is [Workers AI: REST API](https://developers.cloudflare.com/workers-ai/get-started/rest-api/).

1. **Make a free account** at [cloudflare.com](https://www.cloudflare.com/). Check Cloudflare's Workers AI pricing (linked from the guide above) for the free allowance and what happens beyond it: use of the AI is billed to your account, not by this app.
2. **Find your Account ID.** In the dashboard open **AI > Workers AI** and choose **Use REST API**: the panel shows your Account ID. (It is also on your account's home page, in the menu next to the account name: **Copy account ID**.)
3. **Make an API token.** In the same panel choose **Create a Workers AI API Token** (or go to **My Profile > API Tokens > Create Token** and pick the **Workers AI** template). The token needs the permissions **Workers AI: Read** and **Workers AI: Edit**. Copy the token when it is shown: Cloudflare shows it only once.
4. **Put them in Kantahe Maker.** Click the settings icon (top right of the home screen), find **Cloudflare AI (automatic timing)**, paste the Account ID and the API token, and click **Save and test**. The app saves them and checks them with Cloudflare (a free request that does not use the AI). The message under the button says whether the test passed; if it did, the **Auto-time with AI** button appears in the Timing step, and if not it stays hidden until a test passes. Changing either value tests it again.
5. **Use it.** Open a song's Timing step and click **Auto-time with AI**. The app asks before it sends anything, then shows how many lyric words it found and any missing words it proposes (tick the ones to add), and **Apply** replaces the times of all lines. You can correct any line or word by hand afterwards, as usual.

Good to know:

- Only the vocals are sent (the whole song if the song has no separate vocals), and only after you click **Send and time**, each time.
- The token is kept in the app's settings file on your computer, readable only by your user account on macOS and Linux. Treat it like a password: do not share it, and do not put it in a bug report. To stop using the feature, clear both fields and click **Save and test**, and delete the token in the Cloudflare dashboard.
- If the test says Cloudflare refused the request, the Account ID is wrong or the token lacks the Workers AI permissions (Read and Edit). Fix it and click **Save and test** again.
- The result is only as good as the AI's hearing: songs with loud backing vocals, rap, or a language it knows poorly give weaker times.

## Your privacy

Your songs stay on your computer, unless you use the optional AI timing below. The app otherwise sends only a few words, only to these services, and each step shows what it sends:

- **Details:** the title and artist (or the file name) go to musicbrainz.org.
- **Lyrics:** the title and artist go to lrclib.net, and to lyrics.ovh when lrclib.net finds nothing. If lrclib.net has a server problem, the app tries again up to 5 times; then a link offers a Google search for the lyrics in your browser. The title and artist go to Google only when you click that link.
- **Spotify link (optional):** the link you paste goes to open.spotify.com, to read the title, artist and length; those then go to musicbrainz.org and lrclib.net as above.
- **New song from a Spotify link (robot icon):** the same, and spotsaver.net is opened in a Chrome or Edge window that opens minimized for a few seconds with your link, as if you used the site yourself; it sends back the MP3.
- **Tools:** with your consent, about 1.4 GB once (see Download).
- **Auto-time with AI (optional):** if you set it up and click it, the song's vocals go to Cloudflare Workers AI (api.cloudflare.com), after you confirm each time. Nothing is sent unless you do.

Nothing else leaves your computer. There is no account (Cloudflare is needed only for the optional AI timing).

## FAQ

**Which files can I use?** Audio or video files: .mp3, .mp4, .m4a, .mkv, .webm, .wav and .flac.

**How long does vocal splitting take?** It depends on your computer and the song. It runs in the background, so you can fill in the details and lyrics meanwhile. On Windows, Settings has a switch, **Use the graphics card** (off by default), that runs it on the graphics card (NVIDIA, AMD or Intel, through DirectML). The first time it downloads about 650 MB more. On one test song (4:12, RTX 3080) the whole step went from about 104 s to 47 s. If the graphics card cannot be used, the processor is used instead.

**Where does the audio of a Spotify link come from?** The robot icon next to "New song" asks for a Spotify song link and does the rest: spotsaver.net converts a YouTube video of the song to MP3 in a Chrome or Edge window that opens minimized for a few seconds, the details and lyrics come from the link, and the song opens ready for vocal splitting. It is not Spotify's audio, so quality and version can differ. It needs Google Chrome or Microsoft Edge installed. Use it only for songs you have the right to use.

**The download from a Spotify link failed. What now?** Choose your own MP3 in the same window ("Choose an MP3 instead"): the details and lyrics from the link are kept. Or try again.

**Can I edit a .karmp3 I made before?** Yes: click **Open .karmp3** on the home screen. The song opens with its details, lyrics and times as they are in the file, and the audio in the file is used as it is, so nothing is split again. Change what you like, then go to Export: **Save over** replaces the file you opened (after asking you), and **Export as...** saves a copy somewhere else. The file you opened is not touched until you save over it. To use another recording, click **Replace the audio...** on the Song step: the new file is read and split like a new song, and your details, lyrics and times stay (re-tap in Timing if the new audio starts or ends differently). Files made by older versions open too.

**Where are my songs saved?** In the app's folder for your user (on macOS: `~/Library/Application Support/party.kantahe.maker/projects`), saved as you go. The `.karmp3` goes where you choose. Delete a song from the list on the home screen.

**What is a .karmp3?** A karaoke file: a ZIP with the song without its vocals, the lyrics with times, the song details and, if you chose it, the vocals. The format is open and described [below](#the-karmp3-format).

**Light and dark?** The app follows your computer's setting.

**Does it work with a screen reader?** No. The Flutter engine the app is built on can crash on macOS when a screen reader (or another tool that reads the screen) is running, so the app does not offer its contents to them.

<img src="docs/screenshots/07-timing-dark.png" alt="The timing step in the dark theme" width="600">

## For developers

Kantahe Maker is a Flutter desktop app. See `PLAN.md` for how it works and `CLAUDE.md` for how it is built. The `.karmp3` format is specified [below](#the-karmp3-format). License: MIT (see `LICENSE`).

```bash
flutter pub get
flutter analyze             # must be clean
flutter test                # unit tests
flutter run -d macos        # or -d linux / -d windows on those hosts
flutter build macos         # release build (linux/windows on their own hosts)
```

### Building releases

The GitHub Actions workflow `.github/workflows/build.yml` builds the app on macOS,
Linux and Windows (each OS on its own runner) when a release is published on GitHub (a
draft release does not start it) and attaches `kantahe-maker-<tag>-macos.zip`,
`-linux.tar.gz` and `-windows.zip` to that release. A manual run (workflow_dispatch)
only keeps the archives as workflow artifacts. It never creates a release, pushes or
tags: you do that by hand.

- macOS builds are unsigned: the first time, right-click the app and choose Open.
- Windows shows a SmartScreen warning for an unsigned app.
- Linux needs libmpv at runtime (`libmpv2` or `libmpv1`, depending on the distro).
- The tools the app needs (ffmpeg, uv, the vocal-splitting model) are not bundled: the app
  downloads them after asking for consent.

## The .karmp3 format

This section is the specification of the `.karmp3` file, for developers and AI agents who
want to build other programs that read or write it (players, converters, editors). It is the
source of truth: the code that writes the format is checked against the examples below by a
test (`test/readme_format_test.dart`).

A `.karmp3` is a **ZIP archive** with an instrumental MP3 (the song without its vocals), the
lyrics timed line by line (and, optionally, word by word), and the song's details. Since
version 1.1.0 it can also hold the vocals as a separate MP3, so a player can switch them on
and off.

| Version that wrote the file | What is in it |
|---|---|
| 1.0.x | `NAME.mp3`, `NAME.lrc`, `NAME.nfo`. The `.nfo` has no `Instrumental` row. The instrumental is 192 kbps and not normalized |
| 1.1 and later | The same, and the `.nfo` always has an `Instrumental` row. `NAME.vocals.mp3` is added when the user chose to include the vocals. The instrumental is 128 kbps for songs processed by 1.1 (192 kbps for songs processed earlier); both MP3s are normalized to about -16 LUFS |
| 1.2.0 only | The same, but both MP3s are variable bitrate (the instrumental averages about 96 kbps, the vocals about 48 kbps) with a Xing header. The `Audio` and `Vocals audio` rows say "average (VBR)". Players that use a browser's audio element play the vocals late after a seek (see "Constant bitrate") |
| 1.2.1 and later | The same, with constant-bitrate MP3s: the instrumental 96 kbps and the vocals 48 kbps, both with an Info header (frame count and seek table). The `Audio` and `Vocals audio` rows say the plain bitrate |
| 1.2.6 and later | The same, and the `.nfo` always has a `Timing by` row (`line` or `word`). Songs timed with the AI have the two new `Lyric timing` values below |

### Files in the archive

| Entry | Content |
|---|---|
| `NAME.mp3` | the **instrumental**: the song with its vocals removed (MP3, 44.1 kHz, stereo) |
| `NAME.lrc` | the lyrics with times: tag lines, then one timed line per lyric line (see "The .lrc file") |
| `NAME.nfo` | the song's details as aligned `Key : value` lines (see "The .nfo file") |
| `NAME.vocals.mp3` | optional, only when the user included the vocals: the vocals alone (MP3, 44.1 kHz, 48 kbps, mono), with the same length and start as `NAME.mp3`, so a player can play the two together in step |

- **`NAME`** is `NNNNN - Artist - Title` when the song has a songbook number (padded to 5
  digits), and `Artist - Title` when it has not. Artist and title are cleaned the same way:
  the characters `\ / : * ? " < > |` and control characters become spaces, runs of white
  space become one space, spaces and dots are trimmed from both ends, the result is cut to
  80 characters, and an empty result becomes `Unknown`. The file on disk is `NAME.karmp3`.
- **Order of the entries**: `NAME.mp3`, `NAME.lrc`, `NAME.nfo`, then `NAME.vocals.mp3` when
  present. The vocals come last, so a reader that simply takes the first `.mp3` gets the
  instrumental.
- **ZIP details**: deflate compression; every entry's modified time is 1980-01-01 00:00 and
  the `.nfo` holds no date, so the same input always gives the same bytes; text files are
  UTF-8 with `\n` line ends; names are UTF-8.
- **Loudness**: since 1.1.0 both MP3s are normalized to about -16 LUFS each, so the vocals
  are as loud as the instrumental, not at their original level. A player that mixes them may
  want to lower the vocals. Older files are not normalized.
- **Constant bitrate**: since 1.2.1 the instrumental is 96 kbps and the vocals 48 kbps (128 and
  64 kbps in 1.1; 1.2.0 was the exception, see below), all constant bitrate (the `.nfo` rows
  say so). Each starts with an Info tag in its first frame
  that holds the number of frames and bytes and a 100-entry seek table; take the exact length
  from the frame count (1152 samples per frame at 44.1 kHz). A writer must not use variable
  bitrate: a browser's audio element seeks in a variable-bitrate MP3 up to about 1.4 s away
  from the asked time while `currentTime` still reports the asked time (measured in Chromium),
  so the vocals and the lyrics fall out of step after every seek. Constant-bitrate files seek
  exactly. Version 1.2.0 did write variable-bitrate files (a Xing tag instead of Info, the
  average from its counts); a reader may meet them, and a song is made again by running its
  vocal splitting again.
- **Nothing else** goes in the archive (no video, no original audio). A reader should ignore
  entries it does not know.
- **Times** in the `.lrc` count from the start of `NAME.mp3` (and of `NAME.vocals.mp3`, which
  starts at the same moment). They already include the tap offset the user chose in the
  maker; a player applies no offset of its own.

### The .lrc file

```
[ti:TITLE]
[ar:ARTIST]
[au:COMPOSER]            (only when a composer is given)
[mm:ss.xx]lyric line     (one per lyric line)
```

- Tag lines match `^\[([A-Za-z]+):(.*)\]$`. `ti` and `ar` are always there, `au` (the
  composer) only when one is given. The title, artist and composer are on one line each.
- A **timestamp** is `mm:ss.xx`: minutes padded to at least 2 digits, then seconds with two
  decimals padded to 5 characters (`07.31`). The time is rounded to whole hundredths of a
  second first, so 59.996 s is written `01:00.00`. Negative times are written as `00:00.00`.
- A lyric line with **line timing** is `[mm:ss.xx]text`. Match it with
  `^\[(\d{2,}):(\d{2}\.\d{2})\](.*)$`.
- A lyric line with **word timing** is `[mm:ss.xx]` followed by the words, each preceded by
  its own `<mm:ss.xx>` mark; the first mark equals the line's time. A word keeps the space
  that follows it. Match a mark with `<(\d{2,}):(\d{2}\.\d{2})>`. A line without marks counts
  as one word at the line's time, so a reader can treat both kinds alike.
- Blank lyric lines are not written. Lines are in playing order and their times do not go
  backwards.

### The .nfo file

Each line is `Key`, spaces, ` : `, and the value; keys are padded with spaces to the length of
the longest key (`Vocals removed`, 14 characters), so the colons line up. Match a line with
`^(.+?)\s+:\s(.*)$`. Rows with an empty value are left out. The rows come in this order
(a reader should look rows up by key, ignore keys it does not know, and not rely on the
order or on a row being there unless the table says "always"):

| Key | Present | Value |
|---|---|---|
| `Title` | always | the title, on one line |
| `Artist` | always | the artist, on one line |
| `Song number` | when the song has a songbook number | the number, without padding (`101`) |
| `Composer` | when given | the composer |
| `Lyricist` | when given | the lyricist |
| `Duration` | always | `m:ss`, rounded to whole seconds (`3:47`) |
| `Audio` | when the instrumental could be read | what the instrumental really is: `MP3, 44.1 kHz, 96 kbps` (`128 kbps` in files made by 1.1, `192 kbps` from songs processed by 1.0.x; `MP3, 44.1 kHz, 95 kbps average (VBR)` in files made by 1.2.0, the average from the Xing tag) |
| `Vocals removed` | always | the name of the model that removed the vocals (`UVR-MDX-NET-Inst_HQ_3`) |
| `Instrumental` | always in files made by 1.1 and later | the name of the instrumental's entry in the archive (`NAME.mp3`) |
| `Vocals` | only when the vocals are included | the name of the vocals' entry (`NAME.vocals.mp3`) |
| `Vocals audio` | only when the vocals are included and could be read | what the vocals really are, in the same words as `Audio` and then the channels: `MP3, 44.1 kHz, 48 kbps, mono` (`64 kbps` in files made by 1.1, `46 kbps average (VBR)` and the like in files made by 1.2.0) |
| `Lyrics` | always | `timed (.lrc, N lines)` |
| `Lyric timing` | always | where the times come from: `tapped by hand in Kantahe Maker`, or `from lrclib.net synced lyrics` (times that came with the lyrics and were not changed), or `from lrclib.net synced lyrics, corrected by hand in Kantahe Maker`, or (1.2.6 and later) `automatic: words timed by Deepgram Nova-3 on Cloudflare Workers AI` (with `, corrected by hand in Kantahe Maker` added when the user changed the times afterwards). A reader should show any value it does not know as it is, not treat it as an error |
| `Timing by` | always in files made by 1.2.6 and later | `word` when at least one lyric line in the `.lrc` has word marks, otherwise `line`; a player can use it to flag the song without reading the `.lrc`. A file without this row is timed by line, unless its `.lrc` has word marks |

### Reading a .karmp3

1. Open the file as a ZIP archive.
2. Find the `.lrc` and the `.nfo` entries by their extension.
3. Parse the `.nfo` into key/value pairs with `^(.+?)\s+:\s(.*)$`.
   `Timing by` says `word` when the `.lrc` has word marks (show a flag for the song); a file
   without the row is timed by line.
4. The **instrumental** is the entry whose name is the value of `Instrumental`. If there is
   no such row (a file made by 1.0.x), it is the only `.mp3` entry.
5. The **vocals** are the entry whose name is the value of `Vocals`. If there is no such row
   there are no vocals: do not offer a vocals switch.
6. Parse the `.lrc`: the tags, then the timed lines (with their word marks, if any).
7. Play the instrumental and show the lyrics at their times. When the user turns the vocals
   on, start `NAME.vocals.mp3` at the same moment and keep the two in step (seek and pause
   both together); the vocals are at the same loudness as the instrumental, so offer a
   volume control for them.

### Writing a .karmp3

1. Build `NAME` as described above and write `NAME.mp3` (44.1 kHz stereo MP3, no tags,
   96 kbps constant bitrate with an Info tag, normalized to about -16 LUFS). With vocals,
   write `NAME.vocals.mp3` the same length (mono, 44.1 kHz, 48 kbps constant bitrate with an
   Info tag, same loudness). With ffmpeg: `-c:a libmp3lame -b:a 96k` (`48k` for the vocals;
   ffmpeg writes the Info tag by itself); no `-abr` or `-q:a`.
2. Write `NAME.lrc` with the tag lines and the timed lines, using the timestamp rules above.
3. Write `NAME.nfo` with the rows above in that order. Always write `Instrumental`; write
   `Vocals` and `Vocals audio` only when the vocals entry is in the archive. Describe the
   instrumental in `Audio` as it is.
4. Add the entries in the order `.mp3`, `.lrc`, `.nfo`, `.vocals.mp3`, deflated, with the
   modified time 1980-01-01 00:00.
5. Write the archive to `NAME.karmp3.part` first and rename it when it is complete, so a
   file with the final name is never half written.

### Example

A song with a songbook number and the vocals included (the sizes are only an example):

```text
Archive:  00101 - Traditional - Amazing Grace.karmp3
  Length      Date    Time    Name
---------  ---------- -----   ----
  3643024  01-01-1980 00:00   00101 - Traditional - Amazing Grace.mp3
      280  01-01-1980 00:00   00101 - Traditional - Amazing Grace.lrc
      610  01-01-1980 00:00   00101 - Traditional - Amazing Grace.nfo
  1821512  01-01-1980 00:00   00101 - Traditional - Amazing Grace.vocals.mp3
```

`00101 - Traditional - Amazing Grace.nfo`:

```nfo
Title          : Amazing Grace
Artist         : Traditional
Song number    : 101
Composer       : John Newton
Lyricist       : John Newton
Duration       : 3:47
Audio          : MP3, 44.1 kHz, 96 kbps
Vocals removed : UVR-MDX-NET-Inst_HQ_3
Instrumental   : 00101 - Traditional - Amazing Grace.mp3
Vocals         : 00101 - Traditional - Amazing Grace.vocals.mp3
Vocals audio   : MP3, 44.1 kHz, 48 kbps, mono
Lyrics         : timed (.lrc, 4 lines)
Lyric timing   : tapped by hand in Kantahe Maker
Timing by      : word
```

`00101 - Traditional - Amazing Grace.lrc` (the third line has word timing):

```lrc
[ti:Amazing Grace]
[ar:Traditional]
[au:John Newton]
[00:12.50]Amazing grace, how sweet the sound
[00:17.80]That saved a wretch like me
[00:23.10]<00:23.10>I <00:23.40>once <00:23.80>was <00:24.10>lost,
[00:28.00]But now am found
```
