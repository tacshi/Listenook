# Listenook / 聆页

Listenook is an app for listening to podcasts and local audio or video with
synchronized transcripts. Read bilingual translations, replay sentences,
practice English dictation, and organize recordings in a searchable library.

The interface uses **聆页** in Chinese and **Listenook** in English. It runs on
macOS, Windows, iPhone, and iPad. Cloud transcription and AI features use your
own API keys; local transcription is available on supported Apple Silicon Macs
and on iPhones and iPads with 8 GB of memory.

[Downloads](https://github.com/tacshi/Listenook/releases) ·
[Privacy](PRIVACY.md)

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

## On iPhone and iPad

The iOS app has the same features, adapted to the platform:

- **Importing:** add files and folders with the document picker, open them in
  Listenook from another app (**Open in**, **Copy to**), or drag them onto the
  app on iPad. Listenook keeps its own copy of imported media; deleting a
  transcript deletes the copy.
- **Exporting:** transcripts, briefs, and episodes go to the share sheet, which
  includes **Save to Files**.
- **Playback:** podcasts and recordings keep playing in the background and show
  lock-screen and Control Center controls.
- **Touch and keyboard:** controls that appear on hover on a Mac show for the
  current sentence on touch; with a hardware keyboard the usual shortcuts work
  (⌘. stands in for Esc), and holding ⌘ lists the app's commands.
- **Work in the background:** transcription and downloads continue for a while
  after you leave the app, with a notification when they finish.

Folder monitoring, launch at login, the menu-bar icon, and in-app updates are
desktop-only.

## Transcription and AI providers

| Provider | Availability | Notes |
| --- | --- | --- |
| Soniox | All platforms; API key required | Speaker labels, word timing, language detection, and optional translation during transcription. |
| MOSS Pro | All platforms; API key required | Speaker-labelled transcription through MOSI. |
| MOSS Local | Apple Silicon, macOS 15+; iPhone/iPad with 8 GB, iOS 18+ | Local Core ML transcription with speaker labels. |
| Qwen3 Local (Beta) | Apple Silicon, macOS 15+; iPhone/iPad with 8 GB, iOS 18+ | Local multilingual transcription with segment timing, without speaker labels. |

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
locally. On desktop, imported source media stays in its original location; on
iPhone and iPad, Listenook keeps its own copy. See
[PRIVACY.md](PRIVACY.md) for provider cleanup and retention details.

## Identity and updates

| Item | Value |
| --- | --- |
| Bundle ID | `app.capyvibe.listenook` |
| macOS data directory | `~/Library/Application Support/app.capyvibe.listenook` |
| Windows data directory | `%APPDATA%\Capyvibe\Listenook` |

The library, settings and keys are the ones earlier Listenook versions wrote:
upgrading keeps them. The desktop apps update themselves from this
repository's [GitHub Releases](https://github.com/tacshi/Listenook/releases).

## Development

The app is the Rust crate in [`nsh/`](nsh), built on
[Native Shell](https://github.com/longbridge/nsh). It needs a Rust toolchain
and the `nsh` CLI; [nsh/README.md](nsh/README.md) describes the code, how to
run it against a scratch library, and what each platform needs.

```sh
git clone git@github.com:tacshi/Listenook.git
cd Listenook/nsh
cargo run
```

`make check` verifies formatting and lints, `make test` runs the tests, and
`make pr` runs both: the gate before a pull request.

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
are listed by `scripts/publish.sh --help`.
Licenses of what the packages carry are in [packaging/notices](packaging/notices).
