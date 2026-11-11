# Cloud STT provider comparison for Listenook

**Research date:** 2026-08-21  
**Scope:** Current public pay-as-you-go cloud speech-to-text APIs, using official provider documentation and one open primary benchmark project. Prices are USD, exclude taxes/storage/egress, and are normalized to one audio hour where possible.

## Conclusion

**No provider is currently demonstrably both better than Soniox and cheaper as a drop-in replacement for Listenook.**

There are cheaper *raw ASR* endpoints—Cloudflare Workers AI Whisper (about **$0.031/hour**), Groq Whisper Large v3 Turbo (**$0.04/hour**, or about **$0.02/hour** through Groq Batch), and Fireworks Whisper v3 Turbo (**$0.054/hour**). They are worth testing for a deliberately reduced “cheap transcript” mode, but their low sticker prices do not establish better accuracy and do not reproduce Soniox's complete output contract in one proven call: reliable speaker attribution, token-level mixed-language labels, word timing/confidence, contextual vocabulary, and a five-hour managed async job lifecycle. [Cloudflare model/pricing](https://developers.cloudflare.com/workers-ai/models/whisper-large-v3-turbo/), [Groq STT](https://console.groq.com/docs/speech-to-text), [Groq Batch](https://console.groq.com/docs/batch), [Fireworks model library](https://fireworks.ai/models?featured=true&modelTypes=Audio%2CReranker%2CEmbedding)

The closest full-feature challengers are not cheaper:

- **Mistral Voxtral Mini Transcribe 2** has diarization, automatic language detection, word timestamps, and context biasing, but costs **$0.18/hour**, supports 13 languages, and accepts at most three hours per file. [Pricing](https://mistral.ai/pricing/api/), [audio overview](https://docs.mistral.ai/studio/audio/overview), [offline transcription](https://docs.mistral.ai/studio/audio/speech_to_text/offline_transcription)
- **Speechmatics Melia 1 Batch** costs **$0.129/hour**. Its advertised 33% model-training opt-in discount reduces this to about **$0.086/hour**, but explicitly permits Speechmatics to store and use the submitted audio and transcripts for training. That is a different privacy product, and no comparable current evidence establishes it as more accurate than Soniox on Listenook's workload. [Speechmatics pricing](https://www.speechmatics.com/pricing)

Recommendation: keep Soniox as the cloud default. If lower cost is important, benchmark Fireworks, Groq, and Cloudflare on a Listenook corpus as an explicitly reduced-feature option; benchmark Mistral or Speechmatics only as quality challengers, not assumed savings.

## What “better” means in this repository

Listenook is batch-first, accepts audio/video/folders, exports token-timed subtitle formats, and permits media up to 300 minutes. Its current Soniox path uploads a file, creates an async `stt-async-v6` job, polls it, retrieves tokens, and deletes both the transcription and remote file. It always enables speaker diarization and language identification and optionally sends language hints, context terms, and translation configuration. [README](../../README.md), [Soniox client](../../lib/data/soniox_api_client.dart), [duration and transcript model](../../lib/core/models.dart)

A credible replacement therefore needs more than low word error rate:

1. managed batch transcription for files up to five hours, or safe chunking with speaker/timestamp continuity;
2. speaker labels, word-level timing, and preferably confidence;
3. automatic language detection for code-switching, ideally language metadata on each token/word;
4. language hints and contextual vocabulary;
5. a simple BYOK API with direct upload, polling/recovery, deletion, and acceptable retention/privacy;
6. measurably better accuracy on Listenook's actual multilingual, noisy, long-form corpus.

Streaming latency is secondary for the current product, but is included below because it may matter to a future live mode.

## Soniox baseline

Soniox changed to token pricing in June 2026. Async audio input is **$1.50/M tokens**, input/output text is **$3.50/M tokens**, and Soniox's reference hour contains about 30,000 audio tokens plus 15,000 output text tokens. That works out to **$0.0975 for a typical async hour** before unusual context or extra output, matching Soniox's advertised “about $0.10/hour.” Diarization, language identification, and formatting do not carry separate add-on charges. [Soniox pricing](https://soniox.com/pricing)

`stt-async-v5` supports 60+ languages; language identification is token-level and handles multiple languages in one recording; diarization supports up to 15 speakers and attaches the speaker to each token; timestamps and confidence are returned per token; structured context supports domain text and terms. The async file limit is exactly **300 minutes**, matching Listenook, and files/transcriptions can be deleted through the managed resource API. [Models](https://soniox.com/docs/stt/models), [languages](https://soniox.com/docs/stt/concepts/supported-languages), [language identification](https://soniox.com/docs/stt/concepts/language-identification), [diarization](https://soniox.com/docs/stt/concepts/speaker-diarization), [timestamps](https://soniox.com/docs/stt/concepts/timestamps), [confidence](https://soniox.com/docs/stt/concepts/confidence-scores), [context](https://soniox.com/docs/stt/concepts/context), [async limits](https://soniox.com/docs/stt/async/limits-and-quotas), [async API](https://soniox.com/docs/stt/async/async-transcription)

Soniox says customer content is not used for model training and offers US, EU, and Japan content-processing endpoints. Its realtime path is transient; async data persists as required by the requested storage/job flow and should be explicitly deleted, as Listenook already does. [Security and privacy](https://soniox.com/docs/security-and-privacy), [data residency](https://soniox.com/docs/data-residency)

## Price and fit comparison

The “comparable price” column adds required public feature charges where the provider lists them. “Cheaper?” means cheaper than the typical Soniox async hour, not merely cheaper than Soniox's historical pricing.

| Provider / model | Public async price | Comparable Listenook fit | Cheaper than Soniox? | Assessment |
|---|---:|---|---|---|
| **Soniox `stt-async-v5`** | **~$0.10/h typical** | Native five-hour jobs; token language, speaker, time and confidence; context; translation | Baseline | Best current price/feature bundle. [Pricing](https://soniox.com/pricing) |
| **Cloudflare Whisper Large v3 Turbo** | **$0.0306/h** | Schema exposes full text, segment output and VTT, but not native speaker or per-word language metadata; large inputs require an application chunking pipeline | **Yes** | Cheapest raw transcript, not a feature-equivalent replacement. [Model schema](https://developers.cloudflare.com/workers-ai/models/whisper-large-v3-turbo/), [chunking guide](https://developers.cloudflare.com/workers-ai/guides/tutorials/build-a-workers-ai-whisper-with-chunking/) |
| **Groq Whisper Large v3 Turbo** | **$0.04/h sync; ~$0.02/h Batch** | Word/segment timestamps and prompt; no documented speaker diarization; direct upload limit is 25 MB on free and 100 MB on developer tier; larger files need chunking | **Yes** | Excellent cheap draft mode; not the same transcript structure or long-file lifecycle. [STT docs](https://console.groq.com/docs/speech-to-text), [Batch discount](https://console.groq.com/docs/batch) |
| **Fireworks Whisper v3 Turbo / Large** | **$0.054/h / $0.09/h** | Word/sentence alignment, translation, VAD and preprocessing; Fireworks added diarization and batch audio support, but current public materials do not demonstrate Soniox-equivalent token language IDs, context behavior, five-hour limits, or superior accuracy | **Yes** | **Best cheap challenger to benchmark**, but not proven better or drop-in. [Model prices](https://fireworks.ai/models?featured=true&modelTypes=Audio%2CReranker%2CEmbedding), [audio API](https://fireworks.ai/blog/audio-transcription-launch), [diarization changelog](https://docs.fireworks.ai/updates/changelog) |
| **Speechmatics Melia 1 Batch** | **$0.129/h**, or **~$0.086/h** with training opt-in | Diarization, word timings and custom dictionary are core; 56+ languages are advertised | Only with training opt-in | Privacy tradeoff and no comparable proof of better accuracy. [Pricing](https://www.speechmatics.com/pricing), [STT docs](https://docs.speechmatics.com/) |
| **AssemblyAI Universal-2** | **$0.17/h** with diarization | 99 languages, word timestamps, auto language detection, keyterms, code-switching and diarization | No | Strong feature match, but about 70% more expensive. [Pricing](https://www.assemblyai.com/pricing), [model matrix](https://www.assemblyai.com/docs/getting-started/models) |
| **Mistral Voxtral Mini Transcribe 2** | **$0.18/h** | Diarization, detection, word timestamps and context; 13 languages; three-hour maximum | No | Closest modern quality challenger; must chunk Listenook's longest files. [Pricing](https://mistral.ai/pricing/api/), [audio overview](https://docs.mistral.ai/studio/audio/overview) |
| **Google Chirp 3 Dynamic Batch** | **$0.18/h** | Diarization, auto language detection, adaptation and word timestamps have method/language limits; word timestamps cap batch inputs at 20 minutes for Chirp 3 | No | Cheap deferred enterprise batch, but extensive chunking and GCP resource integration. [Pricing](https://cloud.google.com/speech-to-text/pricing), [Chirp 3](https://docs.cloud.google.com/speech-to-text/v2/docs/chirp-model), [batch recognition](https://cloud.google.com/speech-to-text/docs/batch-recognize) |
| **Azure Speech Batch** | **Region-dependent; generally above $0.10/h** | Batch/fast APIs support word timing, language identification and diarization, but diarized batch files are capped at 240 minutes; phrase lists are not supported by asynchronous batch transcription | No | Mature enterprise option, but misses the five-hour/context bar without workflow changes. [Pricing](https://azure.microsoft.com/en-us/pricing/details/speech/), [limits](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speech-services-quotas-and-limits), [phrase lists](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/improve-accuracy-phrase-list) |
| **Deepgram Nova-3 Multilingual** | **$0.39/h** prerecorded with keyterms; diarization included | Multilingual/LID, per-word speaker/timing and up to 100 keyterms | No | Good API and streaming latency, but roughly four times Soniox's typical async price. [Pricing](https://deepgram.com/pricing), [keyterms](https://developers.deepgram.com/docs/keyterm), [diarization](https://developers.deepgram.com/docs/diarization), [language](https://developers.deepgram.com/docs/language) |
| **Gladia** | **$0.61/h starter; from $0.20/h committed** | 100+ languages, code-switching, word-level language, timestamps, diarization and custom vocabulary | No | Feature-rich, but not cheaper even with advertised commitment pricing. [Pricing](https://www.gladia.io/pricing), [language detection](https://docs.gladia.io/chapters/language/language-detection), [code-switching](https://docs.gladia.io/chapters/language/code-switching), [custom vocabulary](https://docs.gladia.io/chapters/audio-intelligence/custom-vocabulary) |
| **AWS Transcribe** | **Region/tier-dependent; current US East batch example $0.006/min ($0.36/h)** | Up to eight-hour inputs, diarization, word timing/confidence, language ID and custom vocabulary; batch media normally lives in S3 | No | Broad and mature, but more expensive and more infrastructure-heavy. [Pricing](https://aws.amazon.com/transcribe/pricing/), [limits](https://docs.aws.amazon.com/general/latest/gr/transcribe.html), [diarization](https://docs.aws.amazon.com/transcribe/latest/dg/diarization.html), [language ID](https://docs.aws.amazon.com/transcribe/latest/dg/lang-id-batch.html) |

AssemblyAI's newer Universal-3.5 Pro starts at $0.21/hour before diarization/prompting add-ons, and Gladia, ElevenLabs, Google standard batch, Azure, AWS, and Deepgram are all plainly above the current Soniox baseline in comparable public configurations. [AssemblyAI pricing](https://www.assemblyai.com/pricing), [ElevenLabs pricing](https://elevenlabs.io/pricing/api?price.section=speech_to_text), [Google pricing](https://cloud.google.com/speech-to-text/pricing)

## Accuracy and latency evidence

There is no current independent, apples-to-apples public benchmark covering the latest **async** models with Listenook's combination of multilingual/code-switched long-form audio, diarization, context terms, and token timing. Provider-run accuracy charts use different datasets/configurations and often omit Soniox v5, so they cannot prove that a candidate is “better.” Mistral, for example, reports about 4% FLEURS WER for Voxtral Mini Transcribe 2 and favorable results against several providers, but its published comparison does not include Soniox v5. [Mistral launch and benchmark methodology](https://mistral.ai/news/voxtral-transcribe-2/)

The open Pipecat benchmark is useful only for a future **streaming English voice-agent** mode. On 1,000 short samples, Soniox v5 recorded 1.34% mean semantic WER with 260 ms median time-to-final-segment. Azure had slightly lower mean WER at 1.21% but 1,016 ms median latency; Speechmatics recorded 1.40%/495 ms, AssemblyAI Universal-3.5 Pro 1.44%/282 ms, and Deepgram Nova-3 1.71%/247 ms. Thus the benchmark does not identify another provider that is simultaneously more accurate, lower-latency, and cheaper than Soniox. It says nothing conclusive about Listenook's batch workload, and its ground truth is Gemini-generated then human-reviewed. [Pipecat benchmark/results and methodology](https://github.com/pipecat-ai/stt-benchmark)

## Privacy and API caveats

- **Speechmatics' sub-Soniox price is conditional.** The 33% discount requires model-training opt-in and permission to retain/use recordings and transcripts; without it Melia 1 costs $0.129/hour. [Speechmatics pricing](https://www.speechmatics.com/pricing)
- **Groq Batch is not immediate async transcription.** It discounts requests by 50%, offers completion windows from 24 hours to seven days, and retains batch state for up to 30 days unless deleted sooner. Default inference is not used for training; Groq documents retention/ZDR separately. [Batch](https://console.groq.com/docs/batch), [data controls](https://console.groq.com/docs/your-data)
- **Cloudflare's cheap endpoint is a model invocation, not a Soniox-style durable transcription resource.** Its official large-file tutorial chunks inputs; its model response schema does not expose speaker IDs or per-word language/confidence. Cloudflare says Workers AI customer content is not used to train models. [Model schema](https://developers.cloudflare.com/workers-ai/models/whisper-large-v3-turbo/), [chunking](https://developers.cloudflare.com/workers-ai/guides/tutorials/build-a-workers-ai-whisper-with-chunking/), [data usage](https://developers.cloudflare.com/workers-ai/platform/data-usage/)
- **Fireworks deserves a real bake-off rather than dismissal.** Its serverless Whisper rate is below Soniox and it has announced diarization and batch support. However, the current official public evidence does not establish equivalent mixed-language metadata/context/long-file semantics or better quality, so it is a promising candidate—not an answered replacement. [Fireworks audio launch](https://fireworks.ai/blog/audio-transcription-launch), [changelog](https://docs.fireworks.ai/updates/changelog)

## Recommended validation gate

Before changing the cloud default, build a private evaluation set representative of Listenook rather than relying on generic WER:

- clean dictation, noisy meetings, interviews, podcasts, and video audio;
- English plus Listenook's actual high-use languages and code-switched clips;
- names, product terms, acronyms, numbers, and punctuation;
- overlapping speakers and 2/5/10+ speaker recordings;
- short clips plus one-, three-, and five-hour files;
- deletion/retention checks and failure recovery.

Measure word error rate, named-entity/number accuracy, speaker-attributed WER or diarization error rate, language-label accuracy, timestamp error, end-to-end job latency, upload/chunk failure rate, and **fully loaded cost** including alignment/diarization/chunking/storage. A candidate should replace Soniox only if it wins on the weighted Listenook score and remains below the measured Soniox token bill—not merely below $0.10/hour on its base model line item.
