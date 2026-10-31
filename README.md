<img src="assets/branding/lockup-light.png" alt="Kantahe Maker" height="56">

# Kantahe Maker

Turns a song (an .mp3 or .mp4) and its lyrics into a `.karmp3` karaoke file: the
instrumental with the vocals removed, the lyrics timed by tapping along, and the song
info. A Flutter desktop app for macOS, Linux and Windows.

See `PLAN.md` for how it works and `CLAUDE.md` for how it is built.

## How it works

Pick an .mp3 or .mp4 with **New song**; the song then goes through six steps, one at a time:
**Song** (the audio is read), **Remove vocals** (runs in the background while you go on),
**Details** (title and artist, filled from the file's tags), **Lyrics** (found online or
pasted), **Timing** (tap along) and **Export** (the `.karmp3`). The Lyrics step sends the
song's title and artist to lrclib.net to find lyrics; nothing else leaves the computer apart
from the tool downloads you agree to.

## Building releases

The GitHub Actions workflow `.github/workflows/build.yml` builds the app on macOS,
Linux and Windows (each OS on its own runner) when a release is published on GitHub (a
draft release does not start it) and attaches `kantahe-maker-<tag>-macos.zip`,
`-linux.tar.gz` and `-windows.zip` to that release. A manual run (workflow_dispatch)
only keeps the archives as workflow artifacts. It never creates a release, pushes or
tags: you do that by hand.

- macOS builds are unsigned: the first time, right-click the app and choose Open.
- Windows shows a SmartScreen warning for an unsigned app.
- Linux needs libmpv at runtime (`libmpv2` or `libmpv1`, depending on the distro).
- The tools the app needs (ffmpeg, uv, the vocal-removal model) are not bundled: the app
  downloads them after asking for consent.
