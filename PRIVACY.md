# MeowSTT privacy

MeowSTT has no developer-operated backend, telemetry, cloud sync, advertising,
or analytics.

When you explicitly start transcription, MeowSTT uploads the selected media
directly to Soniox using your API key. It creates one Soniox file and one Soniox
transcription resource per job. After transcript retrieval—or after cancellation
or a terminal error—it attempts to delete exactly those resources. Failed
cleanup remains marked locally and is retried later. The app never lists or
deletes unrelated resources in your Soniox account.

The API key is stored by the operating system's secure credential service and
is never written to settings or job manifests. Local Application Support data
contains source paths, media metadata, queue/recovery state, raw transcript
tokens, editable segments, speaker mappings, and export defaults. Original media
is not copied into the library. Temporary extracted FLAC audio is deleted after
upload.

Deleting a history entry removes its local manifest and edits only. It does not
delete or modify the original media file.
