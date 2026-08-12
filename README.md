# MeowSTT

MeowSTT is a batch-first Soniox transcription app for macOS and Windows. Drop
audio, video, or folders; review the queue before spending API credit; then edit
speaker-aware transcripts beside synchronized playback and export TXT,
Markdown, SRT, or WebVTT. Transcripts can optionally be translated during
Soniox transcription or afterward through one user-configured OpenAI-compatible
text endpoint.

The package name is `meow_stt`. Its permanent desktop identity is
`app.meowstt.desktop`.

## What is implemented

- Recursive folder and multi-file drag/drop with hidden-file filtering and
  canonical-path deduplication.
- libmpv validation for readability, audio streams, supported media, and the
  Soniox 300-minute limit. Inputs are limited to MP3, WAV, M4A, OGG, MP4, MKV,
  and AVI.
- A persisted semaphore-backed queue (1–4 workers, default 2) with explicit
  start, determinate local progress, cancel/retry, interrupted-upload recovery,
  remote-poll recovery, and scoped cleanup retries.
- Streaming Soniox multipart upload with `stt-async-v5`, automatic language
  identification, always-on diarization, language hints, context terms, stable
  error mapping, and transient polling backoff.
- Optional one-way Soniox translation in the original async transcription job,
  with provider-native language targets and no separate translation pass.
- A local, searchable library; source relinking; editable segments and speaker
  names; video/audio playback; timestamp seeking; transcript search; clipboard
  copy; and batch re-export.
- Manual or optional automatic LLM translation with editable bilingual review,
  partial-result recovery, retry-missing and per-segment retranslation, and
  Original/Translated/Bilingual copy and exports.
- A single editable translation configuration with VoiceTale-style provider
  templates. Custom starts blank; templates only prefill the Base URL, and
  model selection is enabled after a successful connection test.
- System/light/dark themes and English/Simplified Chinese localization.
- Secure Soniox and translation credentials in Keychain/Credential Manager.
  `SONIOX_API_KEY` is used only as a development fallback for Soniox when secure
  storage is empty.

## Privacy model

MeowSTT is BYOK and has no application backend. Starting a job uploads its
media directly to Soniox. Optional Soniox translation is performed within that
same transcription request. Optional LLM translation is a separate operation;
when requested, transcript text—not media—is sent to the single
OpenAI-compatible endpoint saved in Settings. Manifests store paths, small
metadata, raw transcript tokens, original and translated edits, translation
progress, and only the remote IDs owned by that job—never media copies or API
keys. Cleanup deletes only those owned Soniox file/transcription IDs.
See [PRIVACY.md](PRIVACY.md).

## Development

Requirements: Flutter stable with macOS and/or Windows desktop enabled. The
existing `media_kit_libs_video` dependency supplies libmpv. Windows packaging
fetches the pinned FLAC 1.5.0 encoder described in
`packaging/flac/manifest.json`; macOS uses its built-in `afconvert` encoder.

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d macos
```

Before `flutter run -d windows`, prepare the small native encoder once with
`scripts\fetch-flac.ps1 -Arch x64` (or `arm64` on a native ARM64 development
host). Packaging scripts do this automatically.

Set `SONIOX_API_KEY` only to opt into live development calls. Normal tests use
fake local services and never consume Soniox credit.

Keyboard shortcuts: `Cmd/Ctrl+O` opens media and `Cmd/Ctrl+Enter` starts the
reviewed queue. All primary actions remain reachable without a mouse.

## Packaging

macOS (macOS 12+, arm64 or Intel):

```sh
scripts/build-debug.sh --arch arm64
scripts/build-release.sh --arch all
```

Set `DEVELOPER_ID_APPLICATION` (or `MEOWSTT_MAC_SIGN_IDENTITY`) to the full
Developer ID Application identity for production. The release script uses the
`notarytool` keychain profile named `MeowSTT` by default; override it with
`MEOWSTT_NOTARY_PROFILE`. Signed releases fail before building if that profile
cannot be used, then notarize and staple both the app and DMG before packaging
the final DMG. The app stores the Soniox API key in the encrypted macOS login
Keychain without opting into the entitlement-only Data Protection Keychain, so
direct distributions do not require a provisioning profile or the restricted
Keychain Sharing entitlement. macOS builds run a real Keychain round-trip
integration test before packaging.

Debug packages prefer the same Developer ID Application identity as releases:
`MEOWSTT_MAC_DEBUG_SIGN_IDENTITY`, then `MEOWSTT_MAC_SIGN_IDENTITY`, then
`DEVELOPER_ID_APPLICATION`. Without an explicit value, the script matches an
available Developer ID identity to the Team ID of an existing release app, or
uses the only available Developer ID identity. It warns and falls back to
ad-hoc signing when no usable release identity exists or debug signing fails.
Set `MEOWSTT_MAC_DEBUG_SIGN_IDENTITY=-` to force that fallback.

Windows (Windows 10 22H2+, matching native host):

```powershell
scripts\build-debug.ps1 -Arch x64
scripts\build-release.ps1 -Arch arm64
```

The `.cmd` wrappers accept the same arguments. Debug builds produce an
uncompressed portable directory. Release builds produce a portable ZIP and an
Inno Setup installer. Install Inno
Setup 6 or 7, or set `MEOWSTT_ISCC` to `ISCC.exe`. For production code signing,
set `MEOWSTT_WINDOWS_PFX`, optionally `MEOWSTT_WINDOWS_PFX_PASSWORD`,
`MEOWSTT_WINDOWS_PUBLISHER`, `MEOWSTT_WINDOWS_TIMESTAMP_URL`, and
`MEOWSTT_SIGNTOOL`.

Set `MEOWSTT_FLAC_DIR` to a pre-provisioned native Windows FLAC encoder
directory to bypass the binary download. The matching FLAC source archive is
still fetched and included for license compliance. Every script validates
executable architecture and writes artifacts directly under `dist/`. Filenames
include the platform, architecture, and build mode. Windows release builds and
macOS builds also emit a matching `.sha256` manifest. For example:

```text
dist/MeowSTT-1.0.0-macos-arm64-release.dmg
dist/MeowSTT-1.0.0-macos-arm64-release.sha256
```

macOS release output contains only a DMG and its checksum manifest. Windows
debug output remains an uncompressed portable directory under `dist/`; Windows
release output contains a portable ZIP and an Inno Setup `-setup.exe` installer.

macOS debug output remains an uncompressed `.app` bundle under `dist/`.

The macOS build scripts are non-interactive and do not launch the built app.
Signed release builds access the Developer ID certificate and `notarytool`
profile in Keychain. Run the app credential round-trip and launch checks
explicitly when needed:

```bash
flutter test integration_test/secure_credential_store_test.dart -d macos
scripts/verify-macos-app.sh build/macos/Build/Products/Debug/MeowSTT.app
```

## Architecture

UI widgets depend on one Provider/ChangeNotifier controller. The controller
orchestrates injected contracts for credentials, settings, manifests, media,
Soniox, OpenAI-compatible text translation, playback, and exports. Networking,
subprocesses, persistence, and formatting live outside the UI. Every job
transition is atomically persisted in an Application Support job directory,
which is the restart-recovery boundary.

## Third-party software

Distribution artifacts retain the libmpv already supplied by
`media_kit_libs_video`; there are no standalone FFmpeg or FFprobe programs.
Windows adds the compact FLAC encoder and its corresponding source archive.
Provenance, SHA-256 checksums, and license texts live in `packaging/flac/` and
`assets/third_party/`. Soniox is a separate third-party transcription service
and requires a user-owned account and API key.
