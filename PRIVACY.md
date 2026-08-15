# MeowSTT privacy

MeowSTT has no developer-operated backend, telemetry, cloud sync, advertising,
or analytics.

Podcast discovery is optional and local-first. Search queries are sent to
Apple’s public iTunes Search API. Feed documents, episode media, and publisher
transcripts are fetched directly from the public URLs those feeds publish.
Followed shows, feed snapshots, and search cache live only on this computer.
Preview streams remote audio and does not persist it. Deep-listen downloads
are written either to `Podcasts/` inside a configured Inbox folder or to an
application-managed cache. Inbox-folder copies are user files and are not
deleted with the job; managed copies are removed when the job is deleted.
Nothing is uploaded to Soniox until you press **Transcribe**, except a
word-level publisher transcript that can complete without uploading media.

Inbox folder monitoring is optional and entirely local. When configured,
MeowSTT recursively reads directory metadata for supported audio and video
files and stores the selected folder, selected extensions, pause/login
preferences, canonical source paths, byte sizes, modification times, handled
state, and optional local job IDs in an atomic JSON ledger under Application
Support. This ledger prevents an unchanged file from being repeatedly added,
including after a restart or local history deletion. MeowSTT never moves,
renames, changes, or deletes source media. Discovery alone never uploads or
transcribes a file; the user must still press **Transcribe**.

After an Inbox folder is configured, closing the window may leave MeowSTT
running in the macOS menu bar or Windows notification area so monitoring and
active jobs can continue. Optional launch at login is disabled by default.
When the window is hidden, the operating system may show a grouped local
notification for newly discovered files. Notification permission can be
denied without disabling monitoring; the tray waiting count remains available.

When you explicitly start transcription, MeowSTT uploads the selected media
directly to Soniox using your API key. It creates one Soniox file and one Soniox
transcription resource per job. After transcript retrieval—or after cancellation
or a terminal error—it attempts to delete exactly those resources. Failed
cleanup remains marked locally and is retried later. The app never lists or
deletes unrelated resources in your Soniox account.

Translation is optional. When Soniox built-in translation is enabled, the
selected target language is included in the original Soniox transcription
request and Soniox returns the transcript and translation together. No second
service receives the media for that mode.

LLM translation uses the single OpenAI-compatible endpoint that you configure.
When you manually translate or enable automatic LLM translation, MeowSTT sends
transcript text—not the original media—to that endpoint using its text Chat
Completions API. The endpoint operator may apply its own retention and privacy
policy. Changing or removing either translation configuration does not delete
translations already stored locally.

AI Brief generation is also optional and user-invoked. Before the first brief,
MeowSTT explains that the selected transcript text, timestamps, and speaker
names will be sent to the same configured OpenAI-compatible endpoint. Original
audio and video are never sent to that endpoint. Generated overviews, chapters,
insights, edits, and transcript evidence references are stored locally and can
be removed with the history entry.

Both API keys are stored by the operating system's secure credential service
and are never written to settings or job manifests. Local Application Support
data contains source paths, media metadata, queue/recovery state, raw transcript
tokens, editable original and translated segments, speaker mappings,
translation progress, AI Brief drafts and generation state, and export defaults.
Original media is not copied into the library. Temporary extracted FLAC audio
is deleted after upload.

Deleting a history entry removes its local manifest and edits only. It does not
delete or modify the original media file.
