# M1 Pro 本地 STT 模型选型

核对日期：2026-08-16。目标机器是 16 GB 统一内存的 M1 Pro；Listenook 是批量长音频、时间轴和说话人感知的 Flutter 桌面应用。

## 结论

“质量最高”需要拆成两个答案：

- **只看统一英文短音频榜单的纯文本精度，冠军是 ARK-ASR-3B。** Hugging Face Open ASR Leaderboard 当前 Mean WER 为 **4.76**；MOSS-Transcribe-preview-2B 为 4.87，MOSS-Transcribe-Diarize 0.9B 为 5.17，Qwen3-ASR-1.7B 为 5.76。这个榜单不测中文、中英混说、时间戳或说话人，因此不能直接决定 Listenook 的默认后端。[当前榜单](https://huggingface.co/datasets/hf-audio/open-asr-leaderboard)
- **最适合先集成进 Listenook 的产品方案是 MOSS-Transcribe-Diarize 0.9B 的 8-bit 本地版。** 它用一个 0.9B 模型一次生成文本、起止时间和匿名说话人，支持 50+ 语言、热词和最长约 90 分钟的离线输入；Apple 端已有原生 Swift/MLX 实现和小于 1.5 GiB 的已测峰值内存，CrispASR 也已有 MIT 许可的 C ABI、Dart binding、Metal 和 GGUF 路径。这比把高精度纯文本模型再拼接 VAD、强制对齐和说话人聚类更贴合现有产品。[官方模型卡](https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize) · [Swift/MLX 运行说明](https://github.com/soniqo/speech-swift/blob/main/docs/models/moss-transcribe-diarize.md) · [CrispASR](https://github.com/CrispStrobe/CrispASR)
- **中文纯文本“质量模式”应同时试 FireRedASR2-AED 与 Qwen3-ASR-1.7B。** FireRed 官方同表的普通话平均 CER 为 3.05、19 个方言/口音平均 11.67，优于表内 Qwen3-ASR 的 3.76/11.85，并明确面向中英 code-switch；Qwen 的语言覆盖、Apple 量化生态和上下文提示更完整。两者都没有足以代表 Listenook 真实中英句内混说的公开统一测试。[FireRedASR2S 论文](https://arxiv.org/html/2603.10420) · [Qwen3-ASR 官方仓库](https://github.com/QwenLM/Qwen3-ASR)
- **Whisper large-v3 / large-v3-turbo 仍应保留为稳定回退，不再是绝对精度首选。** whisper.cpp 的跨平台 C/C++ 接口、Apple Metal/Core ML、时间戳和长期维护记录仍是风险最低的生产基线。[whisper.cpp](https://github.com/ggml-org/whisper.cpp)

建议先发布一个可切换后端的本地实验版：默认 `MOSS-Diarize 0.9B Q8`，可选 `ARK-ASR-3B Q8（实验）`、`Qwen3-ASR-1.7B 8-bit（高质量）` 和 `Whisper large-v3-turbo（兼容）`。不要在完成同机同语料验收前把任何量化版标成“最高精度”。

## 可比较证据

下面的 Mean WER 来自同一版 Open ASR Leaderboard，可横向比较；中文数据来自各模型官方论文/模型卡，只能在同一张官方对照表内部比较。权重大小不是峰值内存。

| 候选 | 可核实的质量结论 | 中文、英文、混说 | 时间轴 / 说话人 | M1 Pro 本地路径与体积 | 许可证 | 定位 |
| --- | --- | --- | --- | --- | --- | --- |
| [**ARK-ASR-3B**](https://huggingface.co/Audio8/ARK-ASR-3B) | Open ASR Mean WER **4.76，当前第 1**；官方另报 AISHELL-1 CER 1.80、WenetSpeech meeting/net 4.97/4.58 | 19 种语言，含中英；没有公开中英 code-switch 指标 | 纯文本；需另加对齐和 diarization | [CrispASR 的 Metal GGUF](https://huggingface.co/cstr/ark-asr-3b-GGUF)：Q8 文件约 4.29 GB、Q4 约 3.52 GB；端到端 Apple port 明确标为 **experimental/WIP**，无 M1 Pro 峰值内存或长音频 RTF | Apache-2.0；CrispASR MIT | 纯文本精度冠军，暂不宜默认发布 |
| [**MOSS-Transcribe-preview-2B**](https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-preview-2B) | Mean WER **4.87，第 2**；BF16 约 2.4B 参数/4.84 GB | 官方用途是**英文 ASR**，不应因第三方标签误当多语模型 | 纯文本，无时间标记 | [CrispASR GGUF](https://huggingface.co/cstr/MOSS-Transcribe-preview-2B-GGUF) Q4 约 2.8 GB、Q8 约 3.3 GB；无 M1 Pro 实测 | Apache-2.0 | 英文纯文本备选；产品价值低于相邻两款 |
| [**MOSS-Transcribe-Diarize 0.9B**](https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize) | Mean WER **5.17，第 3**；官方多说话人表同时报告 CER/cpCER，而不是只测干净短语音 | 官方称 50+ 语言；中文、英文和 14 种比赛语言有具名证据，但没有公开中英混说分项 | **内置片段时间戳、匿名说话人、声学事件、热词**；最长约 90 分钟；离线非流式 | [MLX INT8](https://huggingface.co/aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8) 权重 1.26 GB；M5 Pro 测得英文 ASR 31.6x 实时/1,407 MiB RSS、diarization 11.8x/1,498 MiB，不能直接外推 M1。[CrispASR Q8 GGUF](https://huggingface.co/cstr/MOSS-Transcribe-Diarize-GGUF) 约 1.4 GB | Apache-2.0；speech-swift Apache-2.0；CrispASR MIT | **Listenook 首选产品模型** |
| [**Qwen3-ASR-1.7B**](https://github.com/QwenLM/Qwen3-ASR) | 当前榜单 Mean WER 5.76；官方对照中中文大幅优于 Whisper large-v3，例如 AISHELL2 2.71 vs 5.06、SpeechIO 2.88 vs 7.56 | 30 种语言 + 22 种中文方言；中英文强，但无专门 code-switch 分项 | ASR 本体输出文本；另有 0.6B ForcedAligner，支持最长 5 分钟片段的词/字时间戳；无说话人 | MLX 8-bit 约 2.46 GB，aligner 8-bit 约 1.27 GB；Swift/MLX 和 sherpa-onnx 均可嵌入，但无可引用的 M1 Pro 端到端长音频数据 | Apache-2.0 | 通用多语高质量模式 |
| [**FireRedASR2-AED**](https://github.com/FireRedTeam/FireRedASR2S) | 官方同表普通话/方言平均 CER **3.05/11.67**，优于 Qwen3-ASR 3.76/11.85；LLM 版更高但 8B+ 不适合 16 GB M1 Pro | 普通话、方言/口音、英文及 code-switch；官方未发布英文或混说单独 WER | 原模型 CTC 分支支持 token/word 时间戳与置信度；[当前 MLX Swift 示例](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/FireRedASR2/README.md)只暴露文本，不能假定已保留完整管线 | [MLX BF16 权重](https://huggingface.co/mlx-community/FireRedASR2-AED-mlx)约 4.57 GB；有 Swift 实现，无 M1 Pro 速度/峰值内存数据 | Apache-2.0 | 中文挑战者，需补产品管线 |
| [**Whisper large-v3 / turbo**](https://github.com/openai/whisper) | Qwen 官方对照显示 large-v3 在中文和多语平均上已落后；turbo 是 809M 的裁剪解码器版本，官方称只有小幅精度损失 | 99 种语言；成熟但混说仍需实测 | 原生段/词时间戳；说话人需外接 | [whisper.cpp](https://github.com/ggml-org/whisper.cpp) 原生支持 Accelerate、Metal、Core ML；large-v3 F16 约 2.9 GiB、运行内存约 3.9 GB，量化更小 | MIT | 最成熟跨平台回退 |

ARK 的榜单值 4.76 来自其模型仓库中补入 TED-LIUM 后的官方评测记录；模型卡正文仍显示旧的 5.04，不能混用。[ARK 评测记录](https://huggingface.co/Audio8/ARK-ASR-3B/blob/main/.eval_results/open_asr_leaderboard.yaml) · [ARK 模型卡](https://huggingface.co/Audio8/ARK-ASR-3B)

MOSS-Diarize 的 Apple 数字来自端口作者在 M5 Pro、固定英文 FLEURS/VoxConverse 样本上的匹配测试，而非原作者或 M1 Pro 测试；它证明本地形态可行，不证明中文、混说或 M1 性能。[MLX INT8 模型卡与测试口径](https://huggingface.co/aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8)

## 为什么产品首选不是榜单冠军

Listenook 的最终数据结构不是一段纯文本，而是可定位、可播放联动、可区分说话人的长音频 transcript。ARK 或 MOSS-preview 的 0.11 WER 差距只覆盖英文短音频文本；为它们补上时间戳和说话人会引入额外模型、内存、切片边界误差和集成状态。MOSS-Diarize 用较低的参数量直接生成 `[start][Sxx]text[end]`，产品链路更短，并且 5.17 仍是当前统一榜单第 3。

它也有明确限制：完整录音到齐后才生成，长音频把 30 秒编码块汇总进一个全局自回归上下文；时戳可能重叠或畸形，匿名 speaker ID 可能漏人，90 分钟是模型能力而不是 16 GB 主机保证。因此 Listenook 应保留分段校验、异常时间戳修复和失败后回退，不把模型输出当作无条件正确的结构化数据。[官方输出与评测](https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize) · [Apple 运行限制](https://github.com/soniqo/speech-swift/blob/main/docs/models/moss-transcribe-diarize.md)

## 集成建议

先定义与模型无关的本地接口，至少返回 `text`、`startMs`、`endMs`、`speakerId?`、`confidence?`、`language?`，并把模型下载、校验、取消、进度、峰值内存和版本写进 job metadata。模型作为安装后的可选下载项，不随 App 捆绑；保存来源 revision、SHA-256 和许可证通知，推理并发在 16 GB M1 Pro 上先限制为 1。

macOS 端有两条合理路线：

1. **优先验证 CrispASR + MOSS-Diarize Q8。** 它提供 C ABI、Dart binding、Metal、VAD、对齐、JSON/SRT/VTT 和同一运行时内的多模型回退，最接近 Flutter FFI；MOSS-Diarize、MOSS-preview 与 ARK 后端都很新，必须 pin commit/tag 并由 Listenook 自己做回归。ARK 的 GGUF 端口仅验证了少量英语/德语样例和阶段余弦相似度，仍由运行时作者标注 experimental/WIP。[CrispASR 能力和许可证](https://github.com/CrispStrobe/CrispASR) · [ARK GGUF 限制](https://huggingface.co/cstr/ark-asr-3b-GGUF) · [MOSS-Diarize GGUF](https://huggingface.co/cstr/MOSS-Transcribe-Diarize-GGUF)
2. **若只支持 macOS 15+，可比较 speech-swift 的 MOSS MLX INT8。** 它是原生 SPM/MLX、Apache-2.0，已公开精度、RSS 和长上下文策略；代价是提高系统最低版本，并把后端限制在 Apple Silicon。当前 Listenook 若要继续支持 macOS 12，不应把它作为唯一实现。[speech-swift 平台要求](https://github.com/soniqo/speech-swift/blob/main/docs/models/moss-transcribe-diarize.md)

Qwen 的备选集成可用原生 Swift/MLX，或使用已经提供 macOS arm64、C/C++、Swift 和 Dart/Flutter 的 sherpa-onnx 0.6B INT8 包；后者总权重约 941 MB，适合作为更轻的中文/多语模式，但不是 1.7B 的绝对质量配置。[sherpa-onnx Qwen3-ASR](https://k2-fsa.github.io/sherpa/onnx/qwen3-asr/index.html) · [Qwen 预训练包](https://k2-fsa.github.io/sherpa/onnx/qwen3-asr/pretrained.html) · [MLX 1.7B 8-bit](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit) · [MLX ForcedAligner 8-bit](https://huggingface.co/mlx-community/Qwen3-ForcedAligner-0.6B-8bit)

## 上线门槛

在同一台 M1 Pro 上建立 2–5 小时、人工复核的产品语料，至少覆盖普通话干净/噪声/方言、不同口音英文、句内中英切换、多人重叠、音乐和长静音、专有名词，以及 30 分钟和 2 小时文件。统一音频预处理和文本规范化后记录：中文 CER、英文 WER、混说 MER、时间边界 MAE、说话人 DER/cpCER、非语音幻觉率、冷/热启动 RTF、峰值 RSS、持续两小时的热降频与失败恢复。

发布默认模型的建议门槛是：稳态 RTF < 0.7、峰值 RSS < 8 GiB、2 小时任务不中断、时间戳单调且可修复，并且 MOSS-Diarize 在真实产品语料上的结构化总错误成本低于 `ARK + aligner + diarizer` 和 `Qwen + ForcedAligner + diarizer`。若纯文本指标优先，允许用户切到 ARK 或 Qwen；若结构化输出异常，自动回退 Whisper/whisper.cpp。

## 排除为默认的其他强候选

- NVIDIA Parakeet-TDT 0.6B v2 的 Open ASR Mean WER 是 6.05，英文速度和词时间戳很好，但仅英文；v3 的 25 种语言不含中文，适合作为英文高速模式而非 Listenook 主模型。[v2 模型卡](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) · [v3 模型卡](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- SenseVoiceSmall 只有 234M、非自回归且很快，支持中/粤/英/日/韩，但质量证据不足以超过上述新模型；其 FunASR Model License 还要求保留来源、作者和模型名，并包含非标准条款，商业分发审查成本高于 Apache/MIT。[官方模型卡](https://huggingface.co/FunAudioLLM/SenseVoiceSmall) · [模型许可证](https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE)
- VibeVoice-ASR 原生提供长音频、说话人和时间戳，但 7B/8B 原精度不适合 16 GB M1 Pro；4-bit MLX 权重约 5.71 GB，量化质量和本机峰值没有足够一手验证，暂不优先。[官方仓库](https://github.com/microsoft/VibeVoice) · [MLX 4-bit 权重](https://huggingface.co/mlx-community/VibeVoice-ASR-4bit)
