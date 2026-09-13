# Listenook privacy

Listenook has no developer-operated backend, telemetry, cloud sync, advertising,
or analytics.

Podcast discovery is optional and local-first. Search queries are sent to
Apple’s public iTunes Search API. Feed documents, episode media, and publisher
transcripts are fetched directly from the public URLs those feeds publish.
Followed shows, feed snapshots, and search cache live only on this computer.
Preview streams remote audio and does not persist it. Deep-listen downloads
are written either to `Podcasts/` inside a configured Inbox folder or to an
application-managed cache. Inbox-folder copies are user files and are not
deleted with the job; managed copies are removed when the job is deleted.
Nothing is uploaded to a transcription provider until you press **Transcribe**, except a
word-level publisher transcript that can complete without uploading media. When
MOSS Local or Qwen3 Local is selected, transcription and forced alignment run
in separate local processes and the media is never uploaded. Qwen3 Local uses
Silero VAD for segment timing and does not identify speakers. Installing an
optional speech model is the only time that model connects to Hugging Face;
inference uses verified offline Core ML or MLX files under Application Support.

When you pair an existing SRT or WebVTT file with media, Listenook stores an
immutable parsed snapshot of its timed cues and sends that snapshot directly to
the local Qwen3 ForcedAligner. It does not call a transcription provider,
upload media, or fall back to cloud transcription. Successful cues receive
locally generated word timing and tighter cue boundaries; unsuccessful cues
keep their imported timing. The original subtitle file is never modified or
silently re-read on retry. Replacing it is an explicit action. Optional LLM
translation remains separate and sends subtitle text—not media—to the configured
text endpoint when enabled.

Inbox folder monitoring is optional and entirely local. When configured,
Listenook recursively reads directory metadata for supported audio and video
files and stores the selected folder, selected extensions, pause/login
preferences, canonical source paths, byte sizes, modification times, handled
state, and optional local job IDs in an atomic JSON ledger under Application
Support. This ledger prevents an unchanged file from being repeatedly added,
including after a restart or local history deletion. Listenook never moves,
renames, changes, or deletes source media. Discovery alone never uploads or
transcribes a file; the user must still press **Transcribe**.

After an Inbox folder is configured, closing the window may leave Listenook
running in the macOS menu bar or Windows notification area so monitoring and
active jobs can continue. Optional launch at login is disabled by default.
When the window is hidden, the operating system may show a grouped local
notification for newly discovered files. Notification permission can be
denied without disabling monitoring; the tray waiting count remains available.

When you explicitly start cloud transcription, Listenook uploads the selected
media directly to the Soniox or MOSI service recorded on that job, using the
matching API key. For MOSS Pro on macOS, video, lossless audio, and high-bitrate
audio are first converted locally to a temporary 16 kHz mono AAC copy; only the
derived audio is uploaded, and the temporary copy is deleted after use. Soniox
jobs create a file and transcription resource; Listenook attempts
to delete both after retrieval, cancellation, or terminal failure. MOSS jobs
create a file and asynchronous task; Listenook deletes the uploaded file, while
the task record follows MOSI's retention policy because its public API has no
task-delete operation. Failed supported cleanup is marked locally and retried.
The app never lists or deletes unrelated account resources.

For MOSS Local, MOSS Pro, and Qwen3 Local transcripts, optional precise word
timing is generated locally with Qwen3 ForcedAligner. A failed, cancelled,
unavailable, or partially successful alignment never causes a cloud fallback
and does not discard the segment-timed transcript. Users choose between
independently downloaded INT8 and FP16 alignment variants; Listenook never
substitutes one model for another when the selected variant is unavailable.

Translation is optional. When Soniox built-in translation is enabled, the
selected target language is included in the original Soniox transcription
request and Soniox returns the transcript and translation together. No second
service receives the media for that mode. This option is ignored for MOSS jobs.

LLM translation uses the single OpenAI-compatible endpoint that you configure.
When you manually translate or enable automatic LLM translation, Listenook sends
transcript text—not the original media—to that endpoint using its text Chat
Completions API. The endpoint operator may apply its own retention and privacy
policy. Changing or removing either translation configuration does not delete
translations already stored locally.

AI Brief generation is also optional and user-invoked. Before the first brief,
Listenook explains that the selected transcript text, timestamps, and speaker
names will be sent to the same configured OpenAI-compatible endpoint. Original
audio and video are never sent to that endpoint. Generated overviews, chapters,
insights, edits, and transcript evidence references are stored locally and can
be removed with the history entry.

All transcription and AI-provider API keys are stored by the operating system's secure credential service
and are never written to settings or job manifests. Local Application Support
data contains source paths, media metadata, queue/recovery state, raw transcript
tokens, editable original and translated segments, speaker mappings,
translation progress, AI Brief drafts and generation state, and export defaults.
Original media is not copied into the library. Temporary extracted audio
is deleted after upload.

Deleting a history entry removes its local manifest and edits only. It does not
delete or modify the original media file.

## Migration from MeowSTT

The first Listenook launch copies the old local library, settings, completed
models and downloaded podcasts into the new application support directory.
It preserves the old data and does not copy media stored outside that directory.
API keys stay in operating-system secure storage; on Windows, the encrypted
storage file is copied before key migration. Migration does not upload data.
Deleting a Listenook API key prevents it from being restored from MeowSTT.
