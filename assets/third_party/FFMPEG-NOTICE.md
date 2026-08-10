# FFmpeg helper notice

MeowSTT distributions include the `ffmpeg` and `ffprobe` command-line helpers.
They are separate programs invoked through argument-list process APIs. The
exact pinned binaries, SHA-256 digests, and source-build provenance are recorded
in `packaging/ffmpeg/manifest.json` in the MeowSTT source tree.

- macOS helpers: `eugeneware/ffmpeg-static` release `b6.1.1`; its pinned
  Darwin executables report FFmpeg 6.0.
- Windows helpers: `BtbN/FFmpeg-Builds` release `autobuild-2025-10-31-13-40`, based on FFmpeg 8.0.
- FFmpeg source and build instructions: https://ffmpeg.org/download.html
- FFmpeg legal information: https://ffmpeg.org/legal.html

The selected helper builds are distributed under GPL-3.0-or-later. See the
adjacent `GPL-3.0.txt`. MeowSTT itself does not link against FFmpeg libraries.
