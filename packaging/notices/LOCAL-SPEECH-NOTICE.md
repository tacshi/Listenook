# Local speech notices

Listenook's optional Apple Silicon speech worker links speech-swift at commit
`13643ab4361da8f33c8002026c9d357ded0b6896` and Apple's Core ML framework.
speech-swift is licensed under Apache License 2.0.

Optional model weights are downloaded by the user and are not bundled:

- OpenMOSS-Team/MOSS-Transcribe-Diarize-0.9B, converted to Core ML INT8 by
  aufklarer, licensed under Apache License 2.0.
- Qwen/Qwen3-ForcedAligner-0.6B, converted to selectable Core ML INT8 and
  FP16 variants by aufklarer, licensed under Apache License 2.0.
- Qwen/Qwen3-ASR-1.7B, converted to MLX 8-bit weights by aufklarer, licensed
  under Apache License 2.0.
- Silero VAD v6.2.1, converted to Core ML by aufklarer, licensed under the MIT
  License. Copyright (c) 2020-present Silero Team.

See `APACHE-2.0.txt` and `SILERO-MIT.txt` for the license texts. Model
revisions, expected sizes, and SHA-256 hashes are pinned in the application
source and verified before use.
