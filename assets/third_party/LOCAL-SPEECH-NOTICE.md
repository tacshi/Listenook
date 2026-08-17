# Local speech notices

MeowSTT's optional Apple Silicon speech worker links speech-swift at commit
`13643ab4361da8f33c8002026c9d357ded0b6896` and Apple's Core ML framework.
speech-swift is licensed under Apache License 2.0.

Optional model weights are downloaded by the user and are not bundled:

- OpenMOSS-Team/MOSS-Transcribe-Diarize-0.9B, converted to Core ML INT8 by
  aufklarer, licensed under Apache License 2.0.
- Qwen/Qwen3-ForcedAligner-0.6B, converted to Core ML INT8 by aufklarer,
  licensed under Apache License 2.0.

See `APACHE-2.0.txt` for the license text. Model revisions, expected sizes, and
SHA-256 hashes are pinned in the application source and verified before use.
