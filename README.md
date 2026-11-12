# Listenook

English · [简体中文](README.zh-CN.md)

Listenook is an app for listening to podcasts and local audio or video with
synchronized transcripts. Read bilingual translations, replay sentences,
practice English dictation, and organize recordings in a searchable library.

It runs on macOS, Windows, iPhone, iPad, and Android. Cloud transcription and
AI features use your own API keys; local transcription runs on the device, on
every platform.

[Downloads](https://github.com/tacshi/Listenook/releases) ·
[Privacy](PRIVACY.md)

## Using Listenook

1. Drop audio, video, or a folder onto the window to add it to the Library, or
   find an episode in Podcasts.
2. Choose a transcription provider, use a podcast's published transcript, or
   pair local media with an existing SRT, WebVTT, or ASS/SSA file.
3. Open the transcript to listen, read, translate, edit, practice, or export.

Supported media: MP3, WAV, M4A, OGG, MP4, MKV, and AVI. Local transcription
takes files of up to 5 hours.

## Features

- **Listen and read:** synchronized audio/video playback, timestamp seeking,
  transcript search, sentence repetition, and blind listening.
- **Practice:** type what you hear and compare your answer with the transcript,
  or mimic each sentence for a chosen number of repetitions before automatically
  moving to the next. Choose an automatic pause or a fixed one of 1, 2, 3, 5,
  or 10 seconds. Automatic pauses match the sentence at the selected speed,
  plus half a second, with a 1.5-second minimum. Click a sentence to practice
  that one. With blind listening on, the text stays hidden during mimic
  practice. Word checking currently supports English.
- **Translate:** review and edit original, translated, or bilingual text.
  Translate again to fill in only the sentences still missing a translation,
  or translate a single sentence again.
- **Follow podcasts:** search public Apple Podcasts results, open RSS feeds,
  follow shows, preview episodes, and download episodes for further study.
  A transcript the publisher provides (WebVTT or SRT) is used when there is
  one.
- **Watch subtitled videos:** double-click a video (or open it with
  **⇧⌘O** / **Ctrl+Shift+O**) to play it with its own subtitles, without
  transcribing it or adding it to the Library. Built-in text tracks (MKV
  SRT/ASS/WebVTT, MP4 mov_text) and SRT, WebVTT, or ASS/SSA files next to the
  video are listed in the subtitle menu. ←/→ jump to the previous/next
  subtitle and **R** turns repeating the current one on or off. The player
  remembers each video's subtitle choice and position. Picture subtitles
  (PGS, VobSub) cannot be shown. The player opens MP4, M4V, MOV, MKV, WebM,
  and AVI: Listenook appears in **Open With** on macOS, and the Windows
  installer registers those types. Choose it as the default in Finder's
  **Get Info → Open with** or Windows **Default apps**.
- **Import subtitles:** a SRT, WebVTT, or ASS/SSA file with the same name as
  the media becomes its transcript; when several files match, you choose one.
  Imported subtitles use their parsed cue timings; they do not run speech
  recognition.
- **Transcribe recordings:** batch files with speaker labels where supported,
  language hints, context terms, progress, and cancellation. A cloud job
  that was interrupted picks up where it stopped when you start it again,
  without uploading the file twice.
- **Create AI Briefs:** generate editable overviews, chapters, key ideas,
  decisions, action items, open questions, and optional language notes.
  Timestamped evidence links back to the source recording.
- **Organize and export:** edit transcripts and speaker names, relink missing
  media, and export TXT, Markdown, SRT, or WebVTT. Briefs export as Markdown.
- **Sync between devices:** copy the Library to and from another device
  running Listenook on the same local network. The other device asks before
  anything is copied.
- **Monitor a folder:** new media in a watched folder is added to the Library,
  ready to transcribe. Listenook can stay in the macOS menu bar or the Windows
  tray to keep watching, and launch at login.

System, light, and dark themes and English/Simplified Chinese interfaces are
available. Keyboard shortcuts are listed in **Settings → Shortcuts**.

## On phones and tablets

The iPhone, iPad, and Android apps have the same features, laid out for a
narrow screen: the sidebar is a drawer, and in the reader the video sits above
the transcript.

- **Importing:** on iPhone and iPad, **Add media** opens the Files browser. On
  Android, put media in Listenook's folder on shared storage, then choose
  **Add media**. Listenook keeps its own copy; deleting the recording deletes
  that copy.
- **Exporting:** transcripts and briefs are written to `Exports` in
  Listenook's folder, which the Files app shows.

Folder monitoring, launch at login, the tray icon, and in-app updates are
desktop-only.

## Transcription and AI providers

| Provider | Availability | Notes |
| --- | --- | --- |
| Soniox | All platforms; API key required | Speaker labels, word timing, language detection, and optional translation during transcription. |
| MOSS Pro | All platforms; API key required | Speaker-labelled transcription through MOSI. |
| MOSS Local | Apple Silicon Macs, macOS 15+ | Local Core ML transcription with speaker labels. |
| Qwen3 Local | All platforms | Local multilingual transcription on the CPU with word timing, without speaker labels. |

Qwen3 Local needs the Qwen3 ForcedAligner model as well, which times each
word; the same model can add word timing to MOSS transcripts. Local speech
models are downloaded and verified separately; they are not bundled with the
app.

Text translation and AI Briefs share one configurable AI provider. Provider
presets prefill connection details, and a successful connection test lists
the provider's models to choose from.

## Data and privacy

Listenook has no application backend. Cloud transcription sends media directly
to the selected Soniox or MOSI provider when you start the job. Local
transcription and subtitle import do not upload media. Folder monitoring
discovers files without uploading them. Syncing sends the Library only to the
device you choose on your local network.

Manual or automatic LLM translation and user-requested AI Briefs send
transcript text to your configured AI endpoint.
Podcast search, feeds, streaming, and downloads contact the relevant public
services. API keys are kept in the Keychain on macOS, iPhone, and iPad and in
the Credential Manager on Windows; on Android they are kept in a file only
Listenook can read.

Transcripts, settings, local models, and downloaded podcast episodes are stored
locally. On desktop, imported source media stays in its original location; on
phones and tablets, Listenook keeps its own copy. See
[PRIVACY.md](PRIVACY.md) for provider cleanup and retention details.

## Identity and updates

| Item | Value |
| --- | --- |
| Bundle ID | `app.capyvibe.listenook` |
| macOS data directory | `~/Library/Application Support/app.capyvibe.listenook` |
| Windows data directory | `%APPDATA%\Capyvibe\Listenook` |

The library, settings and keys are the ones earlier Listenook versions wrote:
upgrading keeps them. The desktop apps update themselves from this
repository's [GitHub Releases](https://github.com/tacshi/Listenook/releases)
when you choose **Settings → About → Check for updates**.

## Development

The app is a Rust crate, built on
[Native Shell](https://github.com/longbridge/nsh). It needs a Rust toolchain
and the `nsh` CLI.

```sh
git clone git@github.com:tacshi/Listenook.git
cd Listenook
cargo run
```

A development run uses your real library. `LISTENOOK_DATA_DIR=<folder>` keeps
its data somewhere else, and `LISTENOOK_START=reader|podcasts|settings` opens
the newest transcript, Podcasts, or Settings.

`make check` verifies formatting and lints, `make test` runs the tests, and
`make pr` runs both: the gate before a pull request.

| Path | Holds |
| --- | --- |
| `src` | The app: pages, UI components ([DESIGN.md](DESIGN.md)), state, and services |
| `crates/listenook-core` | Domain logic with no UI |
| `tests` | Headless flows of what a user does |
| `vendor/qwen-asr` | The patched speech engine |
| `native/speech_worker` | The Swift helper that runs MOSS on a Mac |
| `scripts`, `packaging` | Builds, releases, and what the packages carry |
| `nsh.json`, `theme.json` | The app's name, id and version, and its theme |

## Packaging

| Platform | Command | Makes |
| --- | --- | --- |
| macOS 14+ | `scripts/build-macos.sh debug\|release [--arch arm64\|x64]` | A signed `.app`; a release adds the notarized `.dmg` and the updater's archive |
| Windows 10+ | `scripts\build-windows.ps1 debug\|release` | The app folder; a release adds the installer and the updater's archive |
| iOS, iPadOS 18+ | `scripts/build-ios.sh debug\|release`, `scripts/run-ios.sh` | An unsigned build, a signed `.ipa`, or the app on a device |
| Android 8+ | `scripts/build-android.sh debug\|release [--aab]` | An `.apk` or an App Bundle |

Artifacts are written to `build/`. Each script lists the signing settings it
reads at its top. Local speech with MOSS needs an Apple silicon Mac on
macOS 15+; `scripts/build-speech-worker.sh` builds its helper, which the macOS
build packages.

Publishing is a separate step: `scripts/publish.sh <version>`, whose options
are listed by `scripts/publish.sh --help`. Build Windows first, with
`scripts\build-windows.ps1 release -Version <version>`, and copy the
installer, its `.build.json` and the updater's `.zip` into `build/`.
Licenses of what the packages carry are in [packaging/notices](packaging/notices).
