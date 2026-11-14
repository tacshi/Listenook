import Foundation
import MossTranscribe
import Qwen3ASR
import SpeechVAD

public struct WorkerFailure: Error {
    public let code: String
    public let message: String
    public let exitCode: Int32

    public init(code: String, message: String, exitCode: Int32) {
        self.code = code
        self.message = message
        self.exitCode = exitCode
    }
}

private struct TranscriptSegmentJSON: Sendable {
    let startMs: Int
    let endMs: Int
    let speaker: String?
    let text: String
    let language: String?

    init(
        startMs: Int,
        endMs: Int,
        speaker: String?,
        text: String,
        language: String? = nil
    ) {
        self.startMs = startMs
        self.endMs = endMs
        self.speaker = speaker
        self.text = text
        self.language = language
    }

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "start_ms": startMs,
            "end_ms": endMs,
            "text": text,
        ]
        if let speaker { result["speaker"] = speaker }
        if let language { result["language"] = language }
        return result
    }
}

private struct MossChunkOutput: Sendable {
    let segments: [TranscriptSegmentJSON]
    let warnings: [String]
}

private struct WindowAlignmentAttempt {
    let tokens: [[String: Any]]
    let owners: Set<String>
    let failureReason: String?
}

private struct WindowAlignmentRecovery {
    let tokens: [[String: Any]]
    let owners: Set<String>
    let unresolvedFailures: [String: String]
}

public enum SpeechEngine {
    public static let protocolVersion = 1

    public static func run(
        command: String,
        request: [String: Any],
        onProgress: @escaping @Sendable (Double?, String) -> Void
    ) async throws -> [String: Any] {
        guard request["protocol"] as? Int == protocolVersion else {
            throw WorkerFailure(
                code: "local_worker_protocol_unsupported",
                message: "Unsupported local speech protocol.",
                exitCode: 3
            )
        }
        ProgressSink.set(onProgress)
        defer { ProgressSink.set(nil) }
        switch command {
        case "transcribe-moss":
            return try await transcribeMoss(request)
        case "transcribe-qwen3":
            return try await transcribeQwen3(request)
        case "align-qwen3":
            return try alignQwen3(request)
        default:
            throw WorkerFailure(
                code: "local_worker_arguments_invalid",
                message: "Unknown speech worker command.",
                exitCode: 2
            )
        }
    }

    public static func safeMessage(_ raw: String) -> String {
        let compact = raw.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(compact.prefix(500))
    }
}

private enum ProgressSink {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sink: (@Sendable (Double?, String) -> Void)?

    static func set(_ value: (@Sendable (Double?, String) -> Void)?) {
        lock.lock()
        sink = value
        lock.unlock()
    }

    static func send(_ fraction: Double?, _ detail: String) {
        lock.lock()
        let current = sink
        lock.unlock()
        current?(fraction.map { min(1, max(0, $0)) }, detail)
    }
}

@available(macOS 15.0, iOS 18.0, *)
private func transcribeQwen3(_ request: [String: Any]) async throws -> [String: Any] {
    let modelDirectory = try requiredString(request, "model_directory")
    let vadModelDirectory = try requiredString(request, "vad_model_directory")
    let audioPath = try requiredString(request, "audio_path")
    let wave = try openPCM16Wave(path: audioPath)
    guard wave.sampleRate == 16_000 else {
        throw WorkerFailure(
            code: "local_audio_format",
            message: "Expected 16 kHz mono signed 16-bit PCM.",
            exitCode: 5
        )
    }

    let modelURL = URL(fileURLWithPath: modelDirectory, isDirectory: true)
    let vadModelURL = URL(fileURLWithPath: vadModelDirectory, isDirectory: true)
    guard FileManager.default.fileExists(atPath: modelURL.path),
          FileManager.default.fileExists(atPath: vadModelURL.path)
    else {
        throw WorkerFailure(
            code: "local_stt_model_invalid",
            message: "The Qwen3 ASR model bundle is incomplete.",
            exitCode: 4
        )
    }

    progress(0.01, "loading-qwen3-model")
    let model: Qwen3ASRModel
    do {
        model = try await Qwen3ASRModel.fromPretrained(
            modelId: Qwen3ASRModel.largeModelId,
            cacheDir: modelURL,
            offlineMode: true
        ) { fraction, _ in
            progress(0.01 + fraction * 0.09, "loading-qwen3-model")
        }
    } catch {
        throw WorkerFailure(
            code: "local_stt_model_invalid",
            message: SpeechEngine.safeMessage(error.localizedDescription),
            exitCode: 4
        )
    }

    progress(0.10, "loading-silero-vad")
    let vad: SileroVADModel
    do {
        vad = try await SileroVADModel.fromPretrained(
            modelId: SileroVADModel.defaultCoreMLModelId,
            engine: .coreml,
            cacheDir: vadModelURL,
            offlineMode: true
        ) { fraction, _ in
            progress(0.10 + fraction * 0.04, "loading-silero-vad")
        }
    } catch {
        throw WorkerFailure(
            code: "local_stt_model_invalid",
            message: SpeechEngine.safeMessage(error.localizedDescription),
            exitCode: 4
        )
    }

    let languageHints = (request["language_hints"] as? [String] ?? [])
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    let language = languageHints.count == 1 ? languageHints[0] : nil
    let contextTerms = (request["context_terms"] as? [String] ?? [])
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    let context = contextTerms.isEmpty ? nil : contextTerms.joined(separator: ", ")
    let requestedMaximum =
        (request["max_segment_seconds"] as? NSNumber)?.doubleValue ?? 10
    let maximumSeconds = min(10, max(1, requestedMaximum))
    let maximumSamples = max(1, Int(maximumSeconds * Double(wave.sampleRate)))
    let processor = StreamingVADProcessor(model: vad, config: .sileroDefault)
    let totalSamples = max(1, wave.sampleCount)
    var activeStartSample: Int?
    var segments: [TranscriptSegmentJSON] = []
    var previousEndMs = 0

    func appendFinalSpan(start: Int, end: Int) throws {
        let clippedStart = min(max(0, start), wave.sampleCount)
        let clippedEnd = min(max(clippedStart, end), wave.sampleCount)
        guard clippedEnd > clippedStart else { return }
        let samples: [Float]
        do {
            samples = try wave.readSamples(clippedStart..<clippedEnd)
        } catch {
            throw WorkerFailure(
                code: "local_audio_format",
                message: "The prepared PCM audio could not be read.",
                exitCode: 5
            )
        }
        let text = model.transcribe(
            audio: samples,
            sampleRate: wave.sampleRate,
            language: language,
            maxTokens: 448,
            context: context
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let rawStartMs = Int(
            (Double(clippedStart) * 1000 / Double(wave.sampleRate)).rounded()
        )
        let startMs = max(previousEndMs, rawStartMs)
        let rawEndMs = Int(
            (Double(clippedEnd) * 1000 / Double(wave.sampleRate)).rounded()
        )
        let endMs = max(startMs, rawEndMs)
        guard endMs > startMs else { return }
        segments.append(
            TranscriptSegmentJSON(
                startMs: startMs,
                endMs: endMs,
                speaker: nil,
                text: text,
                language: language
            )
        )
        previousEndMs = endMs
    }

    func handle(_ events: [VADEvent]) throws {
        for event in events {
            switch event {
            case .speechStarted(let time):
                if activeStartSample == nil {
                    activeStartSample = max(0, Int(Double(time) * Double(wave.sampleRate)))
                }
            case .speechEnded(let speech):
                if let start = activeStartSample {
                    let end = min(
                        wave.sampleCount,
                        Int(Double(speech.endTime) * Double(wave.sampleRate))
                    )
                    try appendFinalSpan(start: start, end: end)
                    activeStartSample = nil
                }
            }
        }
    }

    progress(0.14, "detecting-speech")
    var offset = 0
    while offset < wave.sampleCount {
        try Task.checkCancellation()
        let end = min(offset + SileroVADModel.chunkSize, wave.sampleCount)
        let samples: [Float]
        do {
            samples = try wave.readSamples(offset..<end)
        } catch {
            throw WorkerFailure(
                code: "local_audio_format",
                message: "The prepared PCM audio could not be read.",
                exitCode: 5
            )
        }
        try handle(processor.process(samples: samples))
        if let start = activeStartSample {
            let current = min(
                wave.sampleCount,
                Int(Double(processor.currentTime) * Double(wave.sampleRate))
            )
            for span in forcedQwenSpans(
                startSample: start,
                currentSample: current,
                maximumSamples: maximumSamples
            ) {
                progress(nil, "transcribing-qwen3-span")
                try appendFinalSpan(start: span.lowerBound, end: span.upperBound)
                activeStartSample = span.upperBound
            }
        }
        offset = end
        progress(
            0.14 + Double(offset) / Double(totalSamples) * 0.86,
            "transcribing-qwen3"
        )
    }
    try handle(processor.flush())
    let text = segments.map(\.text).joined(separator: " ")
    progress(1, "transcribing-qwen3")
    return [
        "text": text,
        "segments": segments.map(\.dictionary),
        "engine": "mlx-qwen3-silero-coreml",
    ]
}

@available(macOS 15.0, iOS 18.0, *)
private func transcribeMoss(_ request: [String: Any]) async throws -> [String: Any] {
    let modelDirectory = try requiredString(request, "model_directory")
    let audioPath = try requiredString(request, "audio_path")
    let wave = try openPCM16Wave(path: audioPath)
    guard wave.sampleRate == MossTranscribeModel.inputSampleRate else {
        throw WorkerFailure(
            code: "local_audio_format",
            message: "Expected 16 kHz mono signed 16-bit PCM.",
            exitCode: 5
        )
    }
    let modelURL = URL(fileURLWithPath: modelDirectory, isDirectory: true)
    guard FileManager.default.fileExists(atPath: modelURL.path) else {
        throw WorkerFailure(
            code: "local_stt_model_invalid",
            message: "The MOSS Core ML bundle is missing.",
            exitCode: 4
        )
    }

    progress(0.02, "loading-coreml-model")
    let model: MossTranscribeModel
    do {
        model = try await MossTranscribeModel.fromDirectory(modelURL) { fraction, _ in
            progress(0.02 + fraction * 0.08, "loading-coreml-model")
        }
    } catch {
        throw WorkerFailure(
            code: "local_stt_model_invalid",
            message: SpeechEngine.safeMessage(error.localizedDescription),
            exitCode: 4
        )
    }

    let hotwords = (request["hotwords"] as? [String] ?? [])
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    var instruction = MossTranscribeModel.defaultInstruction
    if !hotwords.isEmpty {
        instruction += "\n可能出现的专有名词：" + hotwords.joined(separator: "、") + "。"
    }
    let requestedSeconds = (request["chunk_seconds"] as? NSNumber)?.doubleValue ?? 30
    let chunkSeconds = min(30, max(8, requestedSeconds))
    let maxNewTokens = min(
        640,
        max(64, (request["max_new_tokens_per_chunk"] as? NSNumber)?.intValue ?? 640)
    )
    let boundaries = try quietChunkBoundaries(
        sampleCount: wave.sampleCount,
        sampleRate: wave.sampleRate,
        maximumSeconds: chunkSeconds,
        chooseQuietPoint: { lower, upper in
            try quietestPoint(
                wave: wave,
                lower: lower,
                upper: upper
            )
        }
    )
    let totalSamples = max(1, wave.sampleCount)
    let chunkCount = boundaries.count - 1
    let requestedParallelism = min(
        2,
        max(1, (request["parallel_chunks"] as? NSNumber)?.intValue ?? 2)
    )
    let modelCount = min(chunkCount, requestedParallelism)
    var models = [model]
    if modelCount > 1 {
        progress(0.1, "loading-coreml-parallel-model")
        do {
            models.append(try await MossTranscribeModel.fromDirectory(modelURL))
        } catch {
            throw WorkerFailure(
                code: "local_stt_model_invalid",
                message: SpeechEngine.safeMessage(error.localizedDescription),
                exitCode: 4
            )
        }
    }

    var outputs = [MossChunkOutput?](repeating: nil, count: chunkCount)
    var completedSamples = 0
    progress(0.1, "transcribing-coreml")
    try await withThrowingTaskGroup(
        of: (Int, Int, MossChunkOutput).self
    ) { group in
        var nextIndex = 0

        func submit(slot: Int, index: Int) {
            let assignedModel = models[slot]
            let start = boundaries[index]
            let end = boundaries[index + 1]
            group.addTask {
                let samples = try readSamples(wave, range: start..<end)
                let output = try transcribeMossChunk(
                    model: assignedModel,
                    samples: samples,
                    sampleRate: wave.sampleRate,
                    absoluteSampleOffset: start,
                    start: 0,
                    end: samples.count,
                    maxNewTokens: maxNewTokens,
                    instruction: instruction,
                    retryDepth: 0
                )
                return (slot, index, output)
            }
        }

        for slot in models.indices where nextIndex < chunkCount {
            submit(slot: slot, index: nextIndex)
            nextIndex += 1
        }
        while let (slot, index, output) = try await group.next() {
            try Task.checkCancellation()
            outputs[index] = output
            completedSamples += boundaries[index + 1] - boundaries[index]
            progress(
                0.1 + Double(completedSamples) / Double(totalSamples) * 0.9,
                "transcribing-coreml"
            )
            if nextIndex < chunkCount {
                submit(slot: slot, index: nextIndex)
                nextIndex += 1
            }
        }
    }
    let segments = outputs.compactMap { $0 }.flatMap(\.segments)
    let warnings = outputs.compactMap { $0 }.flatMap(\.warnings)
    let text = segments.map(\.text).joined(separator: " ")
    var result: [String: Any] = [
        "text": text,
        "segments": segments.map(\.dictionary),
        "engine": "coreml",
    ]
    if !warnings.isEmpty { result["warnings"] = Array(Set(warnings)).sorted() }
    progress(1, "transcribing-coreml")
    return result
}

@available(macOS 15.0, iOS 18.0, *)
private func transcribeMossChunk(
    model: MossTranscribeModel,
    samples: [Float],
    sampleRate: Int,
    absoluteSampleOffset: Int,
    start: Int,
    end: Int,
    maxNewTokens: Int,
    instruction: String,
    retryDepth: Int
) throws -> MossChunkOutput {
    guard end > start else {
        return MossChunkOutput(segments: [], warnings: [])
    }
    let chunk = start == 0 && end == samples.count
        ? samples
        : Array(samples[start..<end])
    let result: MossTranscription
    do {
        result = try model.transcribeDetailed(
            audio: chunk,
            sampleRate: sampleRate,
            maxNewTokens: maxNewTokens,
            instruction: instruction
        )
    } catch {
        throw WorkerFailure(
            code: "local_stt_inference_failed",
            message: SpeechEngine.safeMessage(error.localizedDescription),
            exitCode: 6
        )
    }

    let generationComplete = result.metrics.stopReason == .endOfSequence
    let minimumRetrySamples = sampleRate * 8
    if !generationComplete,
       retryDepth < 2,
       end - start >= minimumRetrySamples * 2
    {
        progress(nil, "retrying-coreml-chunk")
        let boundary = quietMidpoint(
            samples: samples,
            start: start,
            end: end,
            sampleRate: sampleRate
        )
        let first = try transcribeMossChunk(
            model: model,
            samples: samples,
            sampleRate: sampleRate,
            absoluteSampleOffset: absoluteSampleOffset,
            start: start,
            end: boundary,
            maxNewTokens: maxNewTokens,
            instruction: instruction,
            retryDepth: retryDepth + 1
        )
        let second = try transcribeMossChunk(
            model: model,
            samples: samples,
            sampleRate: sampleRate,
            absoluteSampleOffset: absoluteSampleOffset,
            start: boundary,
            end: end,
            maxNewTokens: maxNewTokens,
            instruction: instruction,
            retryDepth: retryDepth + 1
        )
        return MossChunkOutput(
            segments: first.segments + second.segments,
            warnings: first.warnings + second.warnings
        )
    }
    var warnings: [String] = []
    if !generationComplete { warnings.append("moss_generation_limited") }

    let offsetMs = Int(
        (Double(absoluteSampleOffset + start) * 1000 / Double(sampleRate)).rounded()
    )
    let chunkEndMs = Int(
        (Double(absoluteSampleOffset + end) * 1000 / Double(sampleRate)).rounded()
    )
    if result.segments.isEmpty {
        let plain = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isMossControlOnlyText(plain) {
            warnings.append("moss_malformed_output")
            return MossChunkOutput(segments: [], warnings: warnings)
        }
        if !plain.isEmpty {
            return MossChunkOutput(
                segments: [TranscriptSegmentJSON(
                    startMs: offsetMs,
                    endMs: chunkEndMs,
                    speaker: nil,
                    text: plain
                )],
                warnings: warnings
            )
        }
        return MossChunkOutput(segments: [], warnings: warnings)
    }
    var segments: [TranscriptSegmentJSON] = []
    for segment in result.segments {
        let localStart = max(0, Int((segment.startTime * 1000).rounded()))
        let localEnd = max(localStart, Int((segment.endTime * 1000).rounded()))
        let absoluteStart = min(chunkEndMs, offsetMs + localStart)
        let absoluteEnd = min(chunkEndMs, max(absoluteStart, offsetMs + localEnd))
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              !isMossControlOnlyText(text),
              absoluteEnd > absoluteStart
        else {
            if isMossControlOnlyText(text) {
                warnings.append("moss_malformed_output")
            }
            continue
        }
        segments.append(
            TranscriptSegmentJSON(
                startMs: absoluteStart,
                endMs: absoluteEnd,
                speaker: segment.speaker.uppercased(),
                text: text
            )
        )
    }
    return MossChunkOutput(segments: segments, warnings: warnings)
}

@available(macOS 15.0, iOS 18.0, *)
private func alignQwen3(_ request: [String: Any]) throws -> [String: Any] {
    let modelDirectory = try requiredString(request, "model_directory")
    let audioPath = try requiredString(request, "audio_path")
    let wave = try openPCM16Wave(path: audioPath)
    guard wave.sampleRate == 16_000 else {
        throw WorkerFailure(
            code: "local_audio_format",
            message: "Expected 16 kHz mono signed 16-bit PCM.",
            exitCode: 5
        )
    }
    let modelURL = URL(fileURLWithPath: modelDirectory, isDirectory: true)
    try validateAlignerConfiguration(modelURL)
    progress(0.03, "loading-coreml-model")
    let aligner: CoreMLForcedAligner
    do {
        aligner = try CoreMLForcedAligner.fromDirectory(modelURL)
    } catch {
        throw WorkerFailure(
            code: "alignment_model_invalid",
            message: SpeechEngine.safeMessage(error.localizedDescription),
            exitCode: 4
        )
    }
    guard let windows = request["windows"] as? [[String: Any]] else {
        throw WorkerFailure(
            code: "local_worker_request_invalid",
            message: "Missing alignment windows.",
            exitCode: 3
        )
    }
    let hints = request["language_hints"] as? [String] ?? []
    let paddingMs = (request["window_padding_ms"] as? NSNumber)?.intValue ?? 250
    let audioDurationMs = Int(
        Double(wave.sampleCount) * 1000 / Double(wave.sampleRate)
    )

    func attemptAlignment(
        startMs: Int,
        endMs: Int,
        segments: [[String: Any]]
    ) -> WindowAlignmentAttempt {
        guard startMs >= 0,
              endMs > startMs,
              endMs - startMs <= 30_000
        else {
            return WindowAlignmentAttempt(
                tokens: [], owners: [], failureReason: "invalid-window")
        }
        let firstSample = min(wave.sampleCount, max(0, startMs * 16))
        let lastSample = min(wave.sampleCount, max(firstSample, endMs * 16))
        guard lastSample > firstSample else {
            return WindowAlignmentAttempt(
                tokens: [], owners: [], failureReason: "empty-audio")
        }
        var words: [String] = []
        var owners: [String] = []
        for segment in segments {
            guard let owner = segment["id"] as? String,
                  !owner.isEmpty,
                  let units = segment["units"] as? [String]
            else { continue }
            for unit in units where !unit.isEmpty {
                words.append(unit)
                owners.append(owner)
            }
        }
        guard !words.isEmpty else {
            return WindowAlignmentAttempt(
                tokens: [], owners: [], failureReason: "empty-text")
        }
        do {
            let joined = words.joined(separator: " ")
            let samples = try readSamples(
                wave,
                range: firstSample..<lastSample
            )
            let aligned = try aligner.align(
                audio: samples,
                text: joined,
                sampleRate: wave.sampleRate,
                language: resolvedLanguage(hints: hints, text: joined)
            )
            guard aligned.count == words.count else {
                return WindowAlignmentAttempt(
                    tokens: [],
                    owners: [],
                    failureReason: "unit-count-mismatch-\(aligned.count)-of-\(words.count)")
            }
            var alignedTokens: [[String: Any]] = []
            alignedTokens.reserveCapacity(words.count)
            for tokenIndex in words.indices {
                let alignedWord = aligned[tokenIndex]
                let localStart = Int((Double(alignedWord.startTime) * 1000).rounded())
                let localEnd = Int((Double(alignedWord.endTime) * 1000).rounded())
                alignedTokens.append([
                    "segment_id": owners[tokenIndex],
                    "text": words[tokenIndex],
                    "start_ms": startMs + localStart,
                    "end_ms": startMs + max(localStart, localEnd),
                ])
            }
            return WindowAlignmentAttempt(
                tokens: alignedTokens,
                owners: Set(owners),
                failureReason: nil
            )
        } catch {
            let message = error.localizedDescription.lowercased()
            let reason = message.contains("exceeds the exported fixed")
                ? "prompt-too-long"
                : "inference-failed"
            return WindowAlignmentAttempt(
                tokens: [], owners: [], failureReason: reason)
        }
    }

    func childBounds(_ segments: [[String: Any]]) -> (Int, Int)? {
        let starts = segments.compactMap {
            ($0["start_ms"] as? NSNumber)?.intValue
        }
        let ends = segments.compactMap {
            ($0["end_ms"] as? NSNumber)?.intValue
        }
        guard let first = starts.min(), let last = ends.max() else { return nil }
        return (
            max(0, first - paddingMs),
            min(audioDurationMs, last + paddingMs)
        )
    }

    func balancedSplitIndex(_ segments: [[String: Any]]) -> Int {
        let weights = segments.map {
            max(1, ($0["units"] as? [String])?.count ?? 0)
        }
        let target = max(1, weights.reduce(0, +) / 2)
        var accumulated = 0
        for index in 0..<(segments.count - 1) {
            accumulated += weights[index]
            if accumulated >= target { return index + 1 }
        }
        return max(1, segments.count / 2)
    }

    func recoverAlignment(
        id: String,
        startMs: Int,
        endMs: Int,
        segments: [[String: Any]]
    ) -> WindowAlignmentRecovery {
        let attempt = attemptAlignment(
            startMs: startMs,
            endMs: endMs,
            segments: segments
        )
        guard let failureReason = attempt.failureReason else {
            let retryOwners = alignmentOwnersNeedingBoundaryRetry(
                tokens: attempt.tokens,
                segments: segments
            )
            guard !retryOwners.isEmpty else {
                return WindowAlignmentRecovery(
                    tokens: attempt.tokens,
                    owners: attempt.owners,
                    unresolvedFailures: [:]
                )
            }

            var recoveredTokens = attempt.tokens.filter {
                guard let owner = $0["segment_id"] as? String else { return false }
                return !retryOwners.contains(owner)
            }
            var recoveredOwners = attempt.owners.subtracting(retryOwners)
            var unresolved: [String: String] = [:]
            for segment in segments {
                guard let owner = segment["id"] as? String,
                      retryOwners.contains(owner)
                else { continue }
                guard let (retryStart, retryEnd) =
                        alignmentBoundaryRetryBounds(segment: segment)
                else {
                    unresolved[owner] = "invalid-segment-bounds"
                    continue
                }
                let retry = attemptAlignment(
                    startMs: retryStart,
                    endMs: retryEnd,
                    segments: [segment]
                )
                guard retry.failureReason == nil,
                      alignmentOwnersNeedingBoundaryRetry(
                        tokens: retry.tokens,
                        segments: [segment]
                      ).isEmpty
                else {
                    unresolved[owner] =
                        retry.failureReason ?? "boundary-outside-cue"
                    continue
                }
                recoveredTokens.append(contentsOf: retry.tokens)
                recoveredOwners.formUnion(retry.owners)
            }
            return WindowAlignmentRecovery(
                tokens: recoveredTokens,
                owners: recoveredOwners,
                unresolvedFailures: unresolved
            )
        }
        let retryable = failureReason == "prompt-too-long"
            || failureReason.hasPrefix("unit-count-mismatch-")
        guard segments.count > 1, retryable else {
            let failureID = segments.count == 1
                ? (segments.first?["id"] as? String ?? id)
                : id
            return WindowAlignmentRecovery(
                tokens: [],
                owners: [],
                unresolvedFailures: [failureID: failureReason]
            )
        }

        let splitIndex = balancedSplitIndex(segments)
        let groups = [
            Array(segments[..<splitIndex]),
            Array(segments[splitIndex...]),
        ]
        let orderedBounds = orderedAlignmentSplitBounds(
            startMs: startMs,
            endMs: endMs,
            leftSegments: groups[0],
            rightSegments: groups[1],
            paddingMs: paddingMs
        )
        var recoveredTokens: [[String: Any]] = []
        var recoveredOwners: Set<String> = []
        var unresolved: [String: String] = [:]
        for (childIndex, group) in groups.enumerated() {
            let childID = "\(id)/\(childIndex)"
            let bounds = orderedBounds?[childIndex] ?? childBounds(group)
            guard let (childStart, childEnd) = bounds else {
                unresolved[childID] = "invalid-window"
                continue
            }
            let child = recoverAlignment(
                id: childID,
                startMs: childStart,
                endMs: childEnd,
                segments: group
            )
            recoveredTokens.append(contentsOf: child.tokens)
            recoveredOwners.formUnion(child.owners)
            unresolved.merge(child.unresolvedFailures) { current, _ in current }
        }
        return WindowAlignmentRecovery(
            tokens: recoveredTokens,
            owners: recoveredOwners,
            unresolvedFailures: unresolved
        )
    }

    var tokens: [[String: Any]] = []
    var failed: [String] = []
    var failureReasons: [String: String] = [:]
    for (index, window) in windows.enumerated() {
        try Task.checkCancellation()
        let windowID = window["id"] as? String ?? "window-\(index)"
        guard let startMs = (window["start_ms"] as? NSNumber)?.intValue,
              let endMs = (window["end_ms"] as? NSNumber)?.intValue,
              let segmentValues = window["segments"] as? [[String: Any]]
        else {
            failed.append(windowID)
            failureReasons[windowID] = "invalid-window"
            continue
        }
        progress(
            0.1 + 0.85 * Double(index) / Double(max(1, windows.count)),
            "aligning-coreml"
        )
        let recovered = recoverAlignment(
            id: windowID,
            startMs: startMs,
            endMs: endMs,
            segments: segmentValues
        )
        tokens.append(contentsOf: recovered.tokens)
        if recovered.owners.isEmpty {
            failed.append(windowID)
        }
        failureReasons.merge(recovered.unresolvedFailures) { current, _ in current }
    }
    progress(1, "aligning-coreml")
    var result: [String: Any] = [
        "tokens": tokens,
        "failed_window_ids": failed,
        "failed_window_reasons": failureReasons,
        "engine": "coreml",
    ]
    if !failureReasons.isEmpty { result["warning_code"] = "alignment_partial" }
    return result
}

private func validateAlignerConfiguration(_ directory: URL) throws {
    let configURL = directory.appendingPathComponent("config.json")
    guard let data = try? Data(contentsOf: configURL),
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (value["classify_num"] as? NSNumber)?.intValue == 5000
    else {
        throw WorkerFailure(
            code: "alignment_model_head_invalid",
            message: "Expected a 5000-class Core ML forced-alignment head.",
            exitCode: 4
        )
    }
}

private func resolvedLanguage(hints: [String], text: String) -> String {
    if let first = hints.first { return first }
    for scalar in text.unicodeScalars {
        switch scalar.value {
        case 0x3040...0x30ff: return "ja"
        case 0x1100...0x11ff, 0x3130...0x318f, 0xac00...0xd7af: return "ko"
        case 0x3400...0x4dbf, 0x4e00...0x9fff: return "zh"
        default: continue
        }
    }
    return "en"
}

private func quietMidpoint(
    samples: [Float],
    start: Int,
    end: Int,
    sampleRate: Int
) -> Int {
    let desired = start + (end - start) / 2
    let search = Int(2 * Double(sampleRate))
    let margin = min(Int(6 * Double(sampleRate)), (end - start) / 3)
    return quietestPoint(
        samples: samples,
        lower: max(start + margin, desired - search),
        upper: min(end - margin, desired + search),
        sampleRate: sampleRate
    )
}

private func openPCM16Wave(path: String) throws -> PCM16WaveFile {
    do {
        return try PCM16WaveFile(path: path)
    } catch PCM16WaveFileError.missing {
        throw WorkerFailure(
            code: "local_audio_missing",
            message: "Could not open prepared local audio.",
            exitCode: 5
        )
    } catch {
        throw WorkerFailure(
            code: "local_audio_format",
            message: "Expected 16 kHz mono signed 16-bit PCM WAVE audio.",
            exitCode: 5
        )
    }
}

private func readSamples(
    _ wave: PCM16WaveFile,
    range: Range<Int>
) throws -> [Float] {
    do {
        return try wave.readSamples(range)
    } catch PCM16WaveFileError.missing {
        throw WorkerFailure(
            code: "local_audio_missing",
            message: "Could not open prepared local audio.",
            exitCode: 5
        )
    } catch {
        throw WorkerFailure(
            code: "local_audio_format",
            message: "Could not read prepared local audio.",
            exitCode: 5
        )
    }
}

private func quietestPoint(
    wave: PCM16WaveFile,
    lower: Int,
    upper: Int
) throws -> Int {
    let analysis = max(1, Int(0.2 * Double(wave.sampleRate)))
    let windowStart = max(0, lower - analysis / 2)
    let windowEnd = min(wave.sampleCount, upper + analysis)
    let samples = try readSamples(wave, range: windowStart..<windowEnd)
    return windowStart + quietestPoint(
        samples: samples,
        lower: lower - windowStart,
        upper: upper - windowStart,
        sampleRate: wave.sampleRate
    )
}



private func progress(_ fraction: Double?, _ detail: String) {
    ProgressSink.send(fraction, detail)
}

private func requiredString(_ request: [String: Any], _ key: String) throws -> String {
    guard let value = request[key] as? String, !value.isEmpty else {
        throw WorkerFailure(
            code: "local_worker_request_invalid",
            message: "Missing \(key).",
            exitCode: 3
        )
    }
    return value
}


