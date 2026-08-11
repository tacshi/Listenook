# libmpv extraction prototype

Tested on Windows x64 with the `libmpv-2.dll` already bundled by
`media_kit_libs_video`.

## Result

The bundled libmpv can replace both standalone helpers for probing and PCM
audio extraction:

- `NativePlayer.getProperty` plus `Player.state.tracks` provides container,
  duration, audio/video track, and codec metadata.
- libmpv's `pcm` audio output can disable video, downmix to mono, resample to
  16 kHz, and write a 16-bit WAVE file.
- `untimed=yes` makes extraction run offline instead of at playback speed.

The prototype is [`tool/libmpv_extract_prototype.dart`](../tool/libmpv_extract_prototype.dart).

## Format matrix

Each fixture contained 30 seconds of generated audio. MP4, MKV, and AVI also
contained video.

| Source | Output | Sample rate | Channels | Output duration | libmpv extraction time |
|---|---|---:|---:|---:|---:|
| MP3 | PCM s16le WAVE | 16 kHz | 1 | 30.02 s | 61 ms |
| WAV | PCM s16le WAVE | 16 kHz | 1 | 30.02 s | 34 ms |
| M4A | PCM s16le WAVE | 16 kHz | 1 | 30.02 s | 46 ms |
| OGG/Vorbis | PCM s16le WAVE | 16 kHz | 1 | 30.02 s | 39 ms |
| MP4/H.264+AAC | PCM s16le WAVE | 16 kHz | 1 | 30.02 s | 37 ms |
| MKV/H.264+AAC | PCM s16le WAVE | 16 kHz | 1 | 30.04 s | 40 ms |
| AVI/MPEG-4+MP3 | PCM s16le WAVE | 16 kHz | 1 | 30.05 s | 46 ms |

The timings are measured inside the process and include player disposal. A
standalone compiled Dart test process takes about five additional seconds to
shut down after `main` returns; the long-lived Flutter application does not
start a new process per extraction.

Probing the MP4 fixture took 23 ms and returned its 30.021-second duration,
MP4 container identifier, AAC audio track, and H.264 video track.

## FLAC limitation

The bundled libmpv has mpv encoding mode disabled. Setting mpv's `o` option
before `mpv_initialize` returns `MPV_ERROR_INVALID_PARAMETER` during
initialization. Setting it later through `NativePlayer.setProperty` creates no
output and playback remains clocked.

Therefore libmpv can produce PCM/WAVE directly, but it cannot produce the
current FLAC intermediate. Keeping compact uploads requires a separate small
FLAC encoder; it does not require the full standalone FFmpeg program.

At 16 kHz, mono, 16-bit PCM, WAVE data is about 109.9 MiB per hour, or about
549.3 MiB for the 300-minute limit.

## Measured artifact reduction

The existing Windows release contains:

| Artifact | Size |
|---|---:|
| `ffmpeg.exe` | 181.35 MiB |
| `ffprobe.exe` | 181.16 MiB |
| Combined removable helpers | 362.50 MiB |
| Existing `libmpv-2.dll` retained | 28.39 MiB |

A release staging copy with only the `ffmpeg` helper directory excluded
measured:

| Artifact | Current | Without standalone helpers |
|---|---:|---:|
| Uncompressed portable build | 441.28 MiB | 78.77 MiB |
| Portable ZIP | 166.59 MiB | 33.65 MiB |
| Inno Setup installer | 107.96 MiB | 25.47 MiB |

The completed production Windows x64 release, including the FLAC runtime,
license files, and compressed corresponding source, measures:

| Artifact | Previous release | Production compact release | Reduction |
|---|---:|---:|---:|
| Uncompressed portable build | 441.28 MiB | 81.27 MiB | 81.6% |
| Portable ZIP | 166.59 MiB | 35.35 MiB | 78.8% |
| Inno Setup installer | 107.96 MiB | 26.97 MiB | 75.0% |

On the validation host, the final release build spent 43.6 seconds in Flutter
compilation and 72.3 seconds end to end. The remaining packaging time creates
both the portable ZIP and the independently compressed Inno Setup installer.
An incremental debug build completed in 15.8 seconds (12.0 seconds in Flutter)
and performed neither compression nor hashing. Previously, the two 181 MiB
helpers made every copy, compression, installer, and checksum pass much more
expensive.

The slim ZIP and installer were built from the initial pruned staging copy.
Production code now follows the validated path: libmpv probes and writes PCM,
the waveform renderer reads PCM directly, Windows encodes FLAC with the
official compact FLAC 1.5.0 tools, and macOS encodes Apple Lossless with its
built-in `afconvert`.

## Production implementation

The implemented pipeline is:

1. Accept only MP3, WAV, M4A, OGG, MP4, MKV, and AVI inputs.
2. Upload the four audio formats directly when no real video track is present.
3. Never upload a video container as a fallback; extract 16 kHz mono PCM with
   libmpv and encode a lossless audio-only file first.
4. Encode FLAC on Windows with `flac.exe` plus `libFLAC.dll` (861,696 bytes
   combined on x64). Encode ALAC/M4A on macOS with `/usr/bin/afconvert` and no
   additional bundled executable.
5. Extract 8 kHz mono PCM for waveform calculation, retain only 1,200 peak
   values in memory, and render the transparent PNG in Dart.
6. Remove stale standalone `ffmpeg` directories and manifests during every
   incremental Windows and macOS package build.

Windows ARM64 packaging is configured to compile a native, statically linked
`flac.exe` from the pinned official source archive; the validation host did not
have the Visual Studio ARM64 C++ component installed, so that path still needs
a native ARM64 build. The x64 build uses the official prebuilt binary. A macOS
build is also required on each target architecture to validate the
platform-specific `afconvert` and signing paths.

An end-to-end Windows Flutter smoke run used the production service against the
MP4/H.264+AAC fixture. It detected the video track, rendered a 1,204-byte PNG,
created a 195,788-byte FLAC file, and reported both bundled libmpv v0.36.0 and
FLAC 1.5.0 available. This also verified libmpv's extensible PCM WAVE header in
the streaming waveform parser.
