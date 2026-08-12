# MeowSTT privacy

MeowSTT has no developer-operated backend, telemetry, cloud sync, advertising,
or analytics.

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
