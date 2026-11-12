# Listenook on Native Shell

Listenook re-implemented in Rust on [Native Shell](https://nsh.dev) (NSH):
native views, no web view and no JavaScript VM. It replaces the Flutter app
that versions 1.x were (its source is in the repository's history).

## Run, test, package

NSH is used at the commit of the nightly CLI (`nsh --version`); `Cargo.toml`
pins the same revision.

```sh
cargo run                      # the app, on this machine
cargo test --workspace         # core logic, persistence and the UI flows (headless)
nsh package --target macos     # .nsh/out/Listenook.app and the update archive
```

`LISTENOOK_DATA_DIR=<folder>` keeps the app's data somewhere else (the tests
and a scratch run use it); `LISTENOOK_START=reader|podcasts|settings`
opens the newest transcript, Podcasts or the Settings dialog.

## Layout

| Path | Holds |
| --- | --- |
| `crates/listenook-core` | Domain logic with no UI: models and their JSON, the transcript parser, exporters, subtitle import, dictation, podcast feeds, the translation and AI Brief prompts, the two interface languages |
| `src/ui` | The app's styled components and tokens ([DESIGN.md](DESIGN.md)) |
| `src/state` | The store, what is saved to disk, API keys |
| `src/services` | Soniox and MOSS Pro, the AI provider, podcasts, the updater |
| `src/pages` | The Library (every recording, whatever its state), Podcasts, the reader that opens over either, and the Settings dialog |
| `src/shell.rs` | The sidebar, the podcast player and the window's commands |
| `tests/flows.rs` | What a user does, on the real engine without a window |

## Data

This app takes the place of the Flutter app (versions 1.x): it has the same bundle id
(`app.capyvibe.listenook`) and uses the same folder, as it is. Nothing is
copied or converted, so the Library, its media, downloaded episodes, speech
models and settings are simply there. Manifests keep the Flutter app's
format (`jobs/<id>/manifest.json`, `settings.json`, `podcast_catalog.json`),
and keys this app does not know are written back unchanged.

| | Folder |
| --- | --- |
| macOS | `~/Library/Application Support/app.capyvibe.listenook` |
| iOS, iPadOS | `Library/Application Support` in the app's container |
| Windows | `%APPDATA%\Capyvibe\Listenook` |
| Linux | `$XDG_DATA_HOME/app.capyvibe.listenook` |

API keys are read from where the Flutter app kept them on macOS and iOS
(the keychain service `app.capyvibe.listenook`). On Windows the Flutter app
kept them in its own encrypted file, which this app cannot read: they are
entered again in Settings.

Do not run both apps at once: they would write the same files.

**Development runs use the real library too.** Point a scratch run
elsewhere:

```bash
LISTENOOK_DATA_DIR=/tmp/listenook-scratch cargo run
```

## Building and releasing

The scripts in `../scripts` build every platform, and `../Makefile` has the
everyday ones (`make check`, `make test`, `make mac`, `make ios`,
`make android`):

| | Script | Makes |
| --- | --- | --- |
| macOS | `build-macos.sh debug\|release` | A signed `.app`; for a release the `.dmg`, notarized, and the updater's archive |
| Windows | `build-windows.ps1 debug\|release` | The app folder; for a release the installer and the updater's archive |
| iOS, iPadOS | `build-ios.sh debug\|release`, `run-ios.sh` | An unsigned build, a signed `.ipa`, or the app on a device |
| Android | `build-android.sh debug\|release` | An `.apk`, or with `--aab` an App Bundle |
| Stores | `publish-ios.sh`, `publish-android.sh` | The signed package, uploaded to TestFlight or Google Play's internal track |

All of them run `nsh package` with the name, id and version in `nsh.json`.
`../scripts/publish.sh <version>` publishes a release: the app updates
itself from this repository's GitHub Releases with NSH's updater (`nsh.json`
`"updater"`). `../scripts/publish.sh --help` lists its options.

Installed apps find a release from Settings → About → Check for Updates. A
development run has nothing to replace and says so.

## Transcription on the device

Qwen3 and word timing run inside the app, on the CPU, through the
[`qwen-asr`](https://crates.io/crates/qwen-asr) crate, on every platform:

- **Audio** is decoded in Rust (Symphonia: MP3, AAC/M4A/MP4, FLAC, WAV, Ogg
  Vorbis, MKV) and resampled to 16 kHz by `listenook_core::audio`. What
  Symphonia cannot read (Opus, for one) macOS's `afconvert` is asked for.
- **Qwen3** gives the text of each stretch of at most 28 seconds, cut where
  the recording is quiet. The aligner then times every word, and sentences
  take their times from their words. One language hint is the language;
  several are the languages it may be, and a stretch heard as another is
  transcribed again in the hinted language its script fits.
- **Matrix products** come from Accelerate on macOS and iOS. Elsewhere
  `src/services/blas.rs` answers the engine's one BLAS call with the
  `matrixmultiply` crate, so nothing native is built or shipped. Without
  it the engine is about eight times slower.
- **Speed**: pieces are worked on side by side, half the cores and at
  most four at a time, each with its own session on the one loaded model.
  Windows builds turn AVX2 and FMA on (`.cargo/config.toml`): the engine
  picks its vector code when it is compiled, and without them it is on its
  slowest path. Such a build does not start on a CPU without AVX2.
- **Models** are the original weights (`Qwen/Qwen3-ASR-0.6B`,
  `Qwen/Qwen3-ASR-1.7B`, `Qwen/Qwen3-ForcedAligner-0.6B`), downloaded in
  Settings → Transcription into `models/` in the data folder and checked
  against pinned SHA-256 sums.

`vendor/qwen-asr` is the crate with one change (`sdot_s32` in
`src/kernels/neon.rs`), without which it does not assemble for iOS, Android
or Windows on Arm.

MOSS (speaker labels) has no Rust runtime. It runs in the Swift helper built
from `../native/speech_worker`, on Apple-silicon Macs with macOS 15 or later
only; elsewhere it is not offered. The helper is found at
`LISTENOOK_SPEECH_WORKER`, else at `Contents/Helpers/ListenookSpeechWorker`
in the bundle, where `../scripts/build-macos.sh` puts it.

## MKV and AVI

NSH plays media with the system's player. Windows' and Android's open MKV
and AVI themselves; Apple's opens neither, so on macOS and iOS
`src/services/playable.rs` makes a playable file the first time such a
recording is opened and keeps it in `temporary/`:

- An MKV file with H.264 video and AAC-LC sound is put into an MP4 file as
  it is, nothing decoded (`listenook_core::container`). It plays with its
  picture.
- Any other MKV file plays its sound, decoded to a WAV file.
- An AVI file plays its sound track, taken out as it is (MP3 or PCM).
  AVI video is almost always a codec Apple's player has no decoder for.

AVI sound is also read for transcription on every platform. Showing other video codecs on Apple platforms would take a
bundled decoder (libmpv, as the Flutter app had).

## The video player

⇧⌘O (or Library → ⋯ → Open video…) plays a video with its own subtitles,
without transcribing it or adding it to the Library
(`src/pages/player.rs`). The subtitle menu lists the subtitle files beside
the video that carry its name and the text tracks inside it: SRT, ASS and
WebVTT in MKV, and text tracks in MP4 (`listenook_core::container`).
Picture subtitles (PGS, VobSub) cannot be shown. ← and → go to the line
before and after, R repeats the line on screen, F fills the screen, and
where a video was left, and with which subtitles, is kept in
`video_playback.json` as the Flutter app kept it.

## Phones and tablets

The layouts follow the window's width (`src/platform.rs`), so a narrow
desktop window shows the same thing as a phone:

- The sidebar is a drawer over the page, opened by the button in the top
  bar and put away when you go somewhere.
- In the reader the video is above the transcript and the other panels
  take the lower half; the position slider has a row of its own.
- Dialogs are never wider than the window, and the app keeps clear of the
  status bar and the home indicator.

NSH has no file dialog on iOS or Android, so files go through the app's
folder instead: **Files › On My iPhone › Listenook** on iOS (the app
declares file sharing in `nsh.json`), the app's folder on shared storage on
Android. "Add media" takes in what is there and moves it into the app's own
storage; removing the recording removes that copy. Exports are written to
`Exports` in the same folder. What needs a file dialog (relinking, choosing
a subtitle file, the watched folder, opening a video) is not offered.

The iOS package declares background audio, but whether NSH's player keeps
playing in the background is untested.

## The tray and the media keys

- **The tray** (the menu bar on a Mac). While a folder is watched,
  Listenook can stay in the tray (Settings → General): closing the window
  then hides it and the folder is still looked at. The icon's menu opens
  the window, pauses or resumes watching, and quits. NSH's own tray, so it
  is there on macOS, Windows and Linux.
- **Media controls.** NSH has no call for these, so `src/services/apple.rs`
  talks to macOS and iOS directly, in plain Objective-C messages. What is
  playing is told to the system (Now Playing, Control Center, the lock
  screen on iOS), and the media keys come back as play, pause, next,
  previous and seek. Whoever plays claims them (`services::media`): the
  podcast player has them until a recording is opened in the reader or a
  video in the player.

## Notifications and the key that works anywhere

- When a transcription or a download ends while Listenook is not in
  front, the system shows a notification (Settings → General turns it
  off). `services::notify` hears of it where the store changes a job, so
  every way a job can end is covered.
- Settings → Shortcuts can turn on a keystroke (⌃⌥Space) that plays or
  pauses from any app. It is off unless turned on, because a global
  shortcut takes its keystroke from every app.

## Opening files with Listenook

`nsh.json` declares the video types the player opens (`fileTypes`), so a
packaged app is offered by the system's "Open With"; a video opened that
way plays in the player, and other media is added to the Library. On
Windows and Linux the app runs once (`singleInstance`): a second launch
hands its file to the running one.

## Not ported yet

- The system's media controls on Windows (media keys, the lock screen's
  player): done for macOS and iOS with the system's own frameworks.
- On phones and tablets: the document picker, "Open in" from other
  apps, the share sheet, lock-screen controls and work that continues in
  the background. NSH has no API for any of them (see below for what
  stands in).
- MOSS on iPhone and iPad, and video codecs Apple's player cannot decode
  (see above): both need native libraries NSH packaging cannot yet carry.
- The MeowSTT migration.
