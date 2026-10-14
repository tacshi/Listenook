# Listenook / 聆页

Listenook is a desktop app for listening to podcasts and local audio or video
with synchronized transcripts. Read bilingual translations, replay sentences,
practice English dictation, and organize recordings in a searchable library.

The interface uses **聆页** in Chinese and **Listenook** in English. It runs on
macOS and Windows. Cloud transcription and AI features use your own API keys;
local transcription is available on supported Apple Silicon Macs.

[Downloads](https://github.com/tacshi/Listenook-Release/releases) ·
[Privacy](PRIVACY.md) · [Release instructions](Release_Steps.md)

## Using Listenook

1. Drop audio, video, or a folder into Inbox, or find an episode in Podcast.
2. Choose a transcription provider, use available word-level publisher
   transcripts, or pair local media with an existing SRT, WebVTT, or ASS file.
3. Open the transcript to listen, read, translate, edit, practice, or export.

Supported media: MP3, WAV, M4A, OGG, MP4, MKV, and AVI, up to 300 minutes per file.

## Features

- **Listen and read:** synchronized audio/video playback, timestamp seeking,
  transcript search, sentence repetition, and blind listening.
- **Practice:** type what you hear and compare your answer with the transcript,
  or mimic each sentence for a chosen number of repetitions before automatically
  moving to the next. Choose an automatic pause or a fixed interval of 1–10
  seconds. Automatic pauses match the sentence at the selected speed, plus half
  a second, with a 1.5-second minimum. Click a sentence to start practicing it.
  Blind listening can optionally hide the original text during mimic practice.
  Word checking currently supports English.
- **Translate:** review and edit original, translated, or bilingual text.
  Retry missing translations or translate individual segments again.
- **Follow podcasts:** search public Apple Podcasts results, open RSS feeds,
  follow shows, preview episodes, and download episodes for further study.
  Word-level publisher transcripts can be imported when available.
- **Watch subtitled videos:** double-click a video (or open it with
  **⇧⌘O** / **Ctrl+Shift+O**) to play it with its own subtitles, without
  transcribing it or adding it to the Library. Built-in text tracks (MKV
  SRT/ASS/WebVTT, MP4 mov_text) and SRT, WebVTT, or ASS/SSA files next to the
  video are listed in the subtitle menu. ←/→ jump to the previous/next
  subtitle and holding **R** repeats the current one. The player remembers
  each video's subtitle choice and position. Picture subtitles (PGS, VobSub)
  cannot be shown. On macOS Listenook appears in **Open With** for every video
  type; the Windows installer registers MP4, M4V, MOV, MKV, WebM, and AVI.
  Choose it as the default in Finder's **Get Info → Open with** or Windows
  **Default apps**.
- **Import subtitles:** pair SRT, WebVTT, or ASS/SSA files with local media and review
  matches before import. Imported subtitles use their parsed cue timings;
  they do not run speech recognition or forced alignment.
- **Transcribe recordings:** batch files with speaker labels where supported,
  language hints, context terms, progress, cancellation, and recovery after
  interruption.
- **Create AI Briefs:** generate editable overviews, chapters, key ideas,
  decisions, action items, open questions, and optional language notes.
  Timestamped evidence links back to the source recording.
- **Organize and export:** edit transcripts and speaker names, relink missing
  media, and export TXT, Markdown, SRT, or WebVTT. Briefs export as Markdown.
- **Monitor a folder:** discover new media for review, with an optional macOS
  menu-bar or Windows tray companion and launch at login.

System, light, and dark themes and English/Simplified Chinese interfaces are
available. Keyboard shortcuts are listed in **Settings → Shortcuts**.

## Transcription and AI providers

| Provider | Availability | Notes |
| --- | --- | --- |
| Soniox | macOS and Windows; API key required | Speaker labels, word timing, language detection, and optional translation during transcription. |
| MOSS Pro | macOS and Windows; API key required | Speaker-labelled transcription through MOSI. |
| MOSS Local | Apple Silicon, macOS 15+ | Local Core ML transcription with speaker labels. |
| Qwen3 Local (Beta) | Apple Silicon, macOS 15+ | Local multilingual transcription with segment timing, without speaker labels. |

On supported Macs, a separately downloaded Qwen3 ForcedAligner can add word
timing to eligible transcriptions. Local speech models are downloaded and
verified separately; they are not bundled with the app.

Text translation and AI Briefs share one configurable AI provider. Provider
presets prefill connection details; model selection becomes available after a
successful connection test.

## Data and privacy

Listenook has no application backend. Cloud transcription sends media directly
to the selected Soniox or MOSI provider when you start the job. Local
transcription and subtitle import do not upload media. Folder monitoring
discovers files without uploading them.

Manual or automatic LLM translation and user-requested AI Briefs send
transcript text to your configured AI endpoint.
Podcast search, feeds, streaming, and downloads contact the relevant public
services. API keys use operating-system secure storage.

Transcripts, settings, local models, and downloaded podcast episodes are stored
locally. Imported source media stays in its original location. See
[PRIVACY.md](PRIVACY.md) for provider cleanup and retention details.

## Moving from MeowSTT

Install Listenook manually for the first upgrade. Quit MeowSTT, including its
menu-bar or tray process, before opening Listenook. First launch copies the old
library, settings, completed local models, and downloaded podcasts into the new
data directory, preserving the old data for recovery. Existing Listenook data
takes priority.

If copying fails, check disk space and folder access, then retry. API key
migration can be retried, or you can enter the keys again. Keys you clear in
Listenook are not restored from the old app. On macOS, disable the old MeowSTT
login item if prompted.

| Item | Value |
| --- | --- |
| Dart package | `listenook` |
| Main bundle ID | `app.capyvibe.listenook` |
| Login helper bundle ID | `app.capyvibe.listenook.Launcher` |
| macOS data directory | `~/Library/Application Support/app.capyvibe.listenook` |
| Windows data directory | `%APPDATA%\Capyvibe\Listenook` |

Executable and installer filenames use Listenook in every language. The Windows
installer retains its upgrade identity and may reuse the old installation
folder. Existing `MEOWSTT_*` environment variables remain compatibility
fallbacks; `LISTENOOK_*` variables take priority.

Later Listenook releases use `listenook-latest.json` in
[tacshi/Listenook-Release](https://github.com/tacshi/Listenook-Release). The old
`latest.json` remains the MeowSTT update feed. See
[Release_Steps.md](Release_Steps.md) for publishing and feed separation.

## Development

Desktop builds need the Flutter **master** SDK pinned in `.fvmrc`: the main and
video player windows are created through Flutter's multi-window API
(`lib/core/windowing/`), which stable does not have. Install
[FVM](https://fvm.app), then use `fvm flutter …` (or `scripts/flutter.sh …`);
the build scripts resolve the pinned SDK themselves. A bare `flutter` from PATH
fails to compile and rewrites `pubspec.lock`. The Apple Silicon speech worker
also requires Xcode and its Metal toolchain.

```sh
git clone git@github.com:tacshi/Listenook.git
cd Listenook
fvm install
fvm flutter pub get
fvm flutter run -d macos
```

For local speech during development on Apple Silicon, build the helper and
point the app to it:

```sh
scripts/build-speech-worker.sh
LISTENOOK_SPEECH_WORKER="$PWD/build/native/speech_worker/ListenookSpeechWorker" fvm flutter run -d macos
```

Before `fvm flutter run -d windows`, prepare the native FLAC encoder once:

```powershell
scripts\fetch-flac.ps1 -Arch x64
```

Use `arm64` on a native ARM64 Windows host. Packaging scripts prepare the encoder
automatically. macOS uses its built-in `afconvert` encoder.

Run static analysis and tests relevant to the change. For example, to check
application identity and startup:

```sh
fvm flutter analyze
fvm flutter test test/core/app_identity_test.dart test/ui/bootstrap_test.dart
```

Native bundle identity, localized-name channel, and isolated Keychain migration
checks run separately from packaging:

```sh
fvm flutter test integration_test/secure_credential_store_test.dart -d macos
```

Cloud smoke tests are opt-in and may consume provider credit when
`SONIOX_API_KEY` or `MOSS_API_KEY` is set. Normal tests use fake services.

Real Qwen/Silero tests use `LISTENOOK_TEST_QWEN_PCM`,
`LISTENOOK_TEST_QWEN_MLX_DIRECTORY`, `LISTENOOK_TEST_SILERO_COREML_DIRECTORY`, and
`LISTENOOK_TEST_SPEECH_WORKER`; optionally set
`LISTENOOK_TEST_ALIGNMENT_COREML_DIRECTORY`. The long-audio benchmark is
`dart run scripts/benchmark_local_qwen.dart`, with `--worker`,
`--model-directory`, `--vad-directory`, and `--audio`. Its two-hour M1 Pro gate
requires RTF below 0.7, worker RSS below 8 GiB, and valid monotonic timestamps.
Qwen remains beta pending comparison with MOSS on the same evaluation corpus.

## Packaging

macOS supports macOS 12+ on Apple Silicon and Intel. Local speech requires
Apple Silicon and macOS 15+.

```sh
scripts/build-debug.sh --arch arm64
scripts/build-release.sh --arch all
```

For production signing, set `LISTENOOK_MAC_SIGN_IDENTITY` or
`DEVELOPER_ID_APPLICATION` to the Developer ID Application identity. Notarization
prefers the `Listenook` profile, with `MeowSTT` as a compatibility fallback when
no profile is explicitly configured. `LISTENOOK_NOTARY_PROFILE` overrides the
profile. Signed releases are notarized and stapled before distribution.

Debug signing uses `LISTENOOK_MAC_DEBUG_SIGN_IDENTITY`, then
`LISTENOOK_MAC_SIGN_IDENTITY`, then `DEVELOPER_ID_APPLICATION`. Otherwise it
matches an existing release's Team ID or uses the only available Developer ID.
It falls back to ad-hoc signing when needed; set
`LISTENOOK_MAC_DEBUG_SIGN_IDENTITY=-` to request that explicitly.

Windows requires Windows 10 22H2+ and a host matching the target architecture:

```powershell
scripts\win-debug.ps1 -Arch x64
scripts\win-release.ps1 1.2.3 -Arch x64
```

Release builds require Inno Setup 6 or 7; use `LISTENOOK_ISCC` if it is not on
PATH. Windows signing uses `LISTENOOK_WINDOWS_PFX`, with optional
`LISTENOOK_WINDOWS_PFX_PASSWORD`, `LISTENOOK_WINDOWS_PUBLISHER`,
`LISTENOOK_WINDOWS_TIMESTAMP_URL`, and `LISTENOOK_SIGNTOOL`.
`LISTENOOK_FLAC_DIR` can select a pre-provisioned native encoder directory.

Artifacts are written to `dist/`, with platform, architecture, mode, and version
in their filenames. macOS debug builds produce an app bundle; release builds
produce a DMG and updater ZIP. Windows debug builds produce a portable folder;
release builds produce a portable ZIP and Inno Setup installer.

Build scripts do not launch the macOS app. Run a launch check explicitly when
needed:

```sh
scripts/verify-macos-app.sh build/macos/Build/Products/Debug/Listenook.app
```

Publishing is a separate step described in [Release_Steps.md](Release_Steps.md).

## Code structure and dependencies

Flutter controllers coordinate credentials, persisted jobs, transcription,
translation, playback, and exports through injected interfaces. Networking,
subprocesses, storage, and formatting live outside UI widgets. Persisted job
transitions support recovery after restart.

Playback uses libmpv from `media_kit_libs_video`; there are no standalone FFmpeg
or FFprobe executables. Windows packages the native FLAC encoder and its source
archive. The Apple Silicon speech worker uses pinned speech-swift, Core ML, and
MLX dependencies. Provenance and licenses are in [packaging/flac](packaging/flac)
and [assets/third_party](assets/third_party).
