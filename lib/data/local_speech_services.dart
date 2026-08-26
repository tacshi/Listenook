import 'dart:math';

import '../core/aligned_token_timing.dart';
import '../core/contracts.dart';
import '../core/local_speech.dart';
import '../core/models.dart';
import '../core/transcript_parser.dart';

class MossTaggedTranscriptParser {
  const MossTaggedTranscriptParser();

  static final _startTag = RegExp(r'\[[^\]]+\]\[S\d+\]', caseSensitive: false);
  static final _segment = RegExp(
    r'\[([^\]]+)\]\[(S\d+)\]([\s\S]*?)\[([^\]]+)\](?=\s*\[|\s*$)',
    caseSensitive: false,
  );

  TranscriptDocument parse(String raw, {required int durationMs}) {
    final value = raw.trim().replaceAllMapped(
      RegExp(r'\[([^\]\r\n]+)\]\s+\[(S\d+)\]', caseSensitive: false),
      (match) => '[${match.group(1)}][${match.group(2)}]',
    );
    if (value.isEmpty) {
      return TranscriptDocument(
        tokens: const [],
        segments: const [],
        speakers: const [],
        updatedAt: DateTime.now().toUtc(),
      );
    }
    final hasTags = _startTag.hasMatch(value);
    if (!hasTags) {
      return TranscriptDocument(
        tokens: const [],
        segments: [
          TranscriptSegment(
            id: 'moss-0',
            startMs: 0,
            endMs: max(0, durationMs),
            text: value,
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.now().toUtc(),
      );
    }

    final matches = _segment.allMatches(value).toList(growable: false);
    if (matches.isEmpty ||
        value.substring(0, matches.first.start).trim().isNotEmpty ||
        value.substring(matches.last.end).trim().isNotEmpty) {
      throw const LocalSpeechException('moss_truncated_output');
    }
    for (var index = 1; index < matches.length; index++) {
      if (value
          .substring(matches[index - 1].end, matches[index].start)
          .trim()
          .isNotEmpty) {
        throw const LocalSpeechException('moss_truncated_output');
      }
    }

    final segments = <TranscriptSegment>[];
    final speakerIds = <String>[];
    for (var index = 0; index < matches.length; index++) {
      final match = matches[index];
      final text = match.group(3)?.trim() ?? '';
      if (text.isEmpty) continue;
      final startMs = _timestampMs(match.group(1));
      final parsedEnd = _timestampMs(match.group(4));
      final endMs = max(startMs, parsedEnd);
      final speaker = (match.group(2) ?? 'S01').toUpperCase();
      if (!speakerIds.contains(speaker)) speakerIds.add(speaker);
      segments.add(
        TranscriptSegment(
          id: 'moss-$index',
          startMs: startMs,
          endMs: endMs,
          text: text,
          speaker: speaker,
        ),
      );
    }
    return TranscriptDocument(
      tokens: const [],
      segments: segments,
      speakers: [
        for (var index = 0; index < speakerIds.length; index++)
          SpeakerProfile(id: speakerIds[index], name: 'Speaker ${index + 1}'),
      ],
      updatedAt: DateTime.now().toUtc(),
    );
  }

  TranscriptDocument parseStructured(
    List<dynamic> rawSegments, {
    required int durationMs,
    String? plainText,
  }) {
    final segments = <TranscriptSegment>[];
    final speakerIds = <String>[];
    for (final value in rawSegments) {
      if (value is! Map) continue;
      final raw = value.cast<Object?, Object?>();
      final text = raw['text']?.toString().trim() ?? '';
      final rawStart = (raw['start_ms'] as num?)?.toInt();
      final rawEnd = (raw['end_ms'] as num?)?.toInt();
      if (text.isEmpty ||
          isMossControlOnlyTranscriptText(text) ||
          rawStart == null ||
          rawEnd == null) {
        continue;
      }
      final startMs = rawStart.clamp(0, max(0, durationMs)).toInt();
      final endMs = rawEnd.clamp(startMs, max(startMs, durationMs)).toInt();
      if (endMs <= startMs) continue;
      final speakerValue = raw['speaker']?.toString().trim().toUpperCase();
      final speaker = speakerValue == null || speakerValue.isEmpty
          ? null
          : speakerValue;
      if (speaker != null && !speakerIds.contains(speaker)) {
        speakerIds.add(speaker);
      }
      segments.add(
        TranscriptSegment(
          id: 'moss-${segments.length}',
          startMs: startMs,
          endMs: endMs,
          text: text,
          speaker: speaker,
        ),
      );
    }
    final fallback = plainText?.trim() ?? '';
    if (segments.isEmpty &&
        fallback.isNotEmpty &&
        !isMossControlOnlyTranscriptText(fallback)) {
      segments.add(
        TranscriptSegment(
          id: 'moss-0',
          startMs: 0,
          endMs: max(0, durationMs),
          text: fallback,
        ),
      );
    }
    return TranscriptDocument(
      tokens: const [],
      segments: List.unmodifiable(segments),
      speakers: [
        for (var index = 0; index < speakerIds.length; index++)
          SpeakerProfile(id: speakerIds[index], name: 'Speaker ${index + 1}'),
      ],
      updatedAt: DateTime.now().toUtc(),
    );
  }

  int _timestampMs(String? raw) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty) {
      throw const LocalSpeechException('moss_invalid_timestamp');
    }
    final parts = value.split(':');
    double seconds;
    if (parts.length == 1) {
      seconds = double.tryParse(parts.single) ?? double.nan;
    } else if (parts.length == 3) {
      final hours = int.tryParse(parts[0]);
      final minutes = int.tryParse(parts[1]);
      final tail = double.tryParse(parts[2]);
      if (hours == null || minutes == null || tail == null) {
        seconds = double.nan;
      } else {
        seconds = hours * 3600 + minutes * 60 + tail;
      }
    } else {
      seconds = double.nan;
    }
    if (!seconds.isFinite || seconds < 0) {
      throw const LocalSpeechException('moss_invalid_timestamp');
    }
    return (seconds * 1000).round();
  }
}

class QwenStructuredTranscriptParser {
  const QwenStructuredTranscriptParser();

  TranscriptDocument parse(
    List<dynamic> rawSegments, {
    required int durationMs,
  }) {
    final segments = <TranscriptSegment>[];
    var previousEndMs = 0;
    for (final value in rawSegments) {
      if (value is! Map) continue;
      final raw = value.cast<Object?, Object?>();
      final text = raw['text']?.toString().trim() ?? '';
      final rawStart = (raw['start_ms'] as num?)?.toInt();
      final rawEnd = (raw['end_ms'] as num?)?.toInt();
      if (text.isEmpty || rawStart == null || rawEnd == null) continue;
      final startMs = rawStart
          .clamp(previousEndMs, max(previousEndMs, durationMs))
          .toInt();
      final endMs = rawEnd.clamp(startMs, max(startMs, durationMs)).toInt();
      if (endMs <= startMs) continue;
      final languageValue = raw['language']?.toString().trim();
      segments.add(
        TranscriptSegment(
          id: 'qwen3-${segments.length}',
          startMs: startMs,
          endMs: endMs,
          text: text,
          language: languageValue == null || languageValue.isEmpty
              ? null
              : languageValue,
        ),
      );
      previousEndMs = endMs;
    }
    return TranscriptDocument(
      tokens: const [],
      segments: List.unmodifiable(segments),
      speakers: const [],
      updatedAt: DateTime.now().toUtc(),
    );
  }
}

class QwenAlignmentUnitizer {
  const QwenAlignmentUnitizer();

  List<String> units(String text) {
    final result = <String>[];
    final buffer = StringBuffer();
    int? bufferedClass;
    void flush() {
      if (buffer.isEmpty) return;
      result.add(buffer.toString());
      buffer.clear();
      bufferedClass = null;
    }

    for (final rune in text.runes) {
      if (_isHan(rune) || _isKana(rune) || _isHangul(rune)) {
        flush();
        result.add(String.fromCharCode(rune));
      } else if (_isWordRune(rune)) {
        final runeClass = _isAsciiDigit(rune) ? 1 : 2;
        if (buffer.isNotEmpty && bufferedClass != runeClass) flush();
        bufferedClass = runeClass;
        buffer.writeCharCode(rune);
      } else {
        flush();
      }
    }
    flush();
    return result;
  }

  bool canAutoAlign(String text) {
    for (final rune in text.runes) {
      if (_isWordRune(rune) ||
          _isHan(rune) ||
          _isKana(rune) ||
          _isHangul(rune)) {
        continue;
      }
      if (_isWhitespaceOrPunctuation(rune)) continue;
      if (_isReadableSymbol(rune)) continue;
      return false;
    }
    return true;
  }

  bool _isWordRune(int rune) =>
      (rune >= 0x30 && rune <= 0x39) ||
      (rune >= 0x41 && rune <= 0x5a) ||
      (rune >= 0x61 && rune <= 0x7a) ||
      (rune >= 0x00c0 && rune <= 0x024f) ||
      (rune >= 0x0300 && rune <= 0x036f) ||
      (rune >= 0x0400 && rune <= 0x052f) ||
      rune == 0x27 ||
      rune == 0x2019;

  bool _isAsciiDigit(int rune) => rune >= 0x30 && rune <= 0x39;

  bool _isReadableSymbol(int rune) =>
      (rune >= 0x00a2 && rune <= 0x00a5) ||
      rune == 0x00b0 ||
      (rune >= 0x20a0 && rune <= 0x20cf);

  bool _isHan(int rune) =>
      (rune >= 0x3400 && rune <= 0x4dbf) ||
      (rune >= 0x4e00 && rune <= 0x9fff) ||
      (rune >= 0x20000 && rune <= 0x2ceaf);

  bool _isKana(int rune) =>
      (rune >= 0x3040 && rune <= 0x30ff) || (rune >= 0x31f0 && rune <= 0x31ff);

  bool _isHangul(int rune) =>
      (rune >= 0x1100 && rune <= 0x11ff) ||
      (rune >= 0x3130 && rune <= 0x318f) ||
      (rune >= 0xac00 && rune <= 0xd7af);

  bool _isWhitespaceOrPunctuation(int rune) =>
      String.fromCharCode(rune).trim().isEmpty ||
      (rune >= 0x21 && rune <= 0x2f) ||
      (rune >= 0x3a && rune <= 0x40) ||
      (rune >= 0x5b && rune <= 0x60) ||
      (rune >= 0x7b && rune <= 0x7e) ||
      (rune >= 0x2000 && rune <= 0x206f) ||
      (rune >= 0x2e00 && rune <= 0x2e7f) ||
      (rune >= 0x3000 && rune <= 0x303f) ||
      (rune >= 0xfe10 && rune <= 0xfe6f) ||
      (rune >= 0xff00 && rune <= 0xff65);
}

class ProcessLocalSttService implements LocalSttService {
  ProcessLocalSttService({
    required LocalModelManager models,
    required LocalPcmPreparer pcm,
    required LocalSpeechWorker worker,
    required bool platformSupported,
    MossTaggedTranscriptParser parser = const MossTaggedTranscriptParser(),
    QwenStructuredTranscriptParser qwenParser =
        const QwenStructuredTranscriptParser(),
  }) : _models = models,
       _pcm = pcm,
       _worker = worker,
       _platformSupported = platformSupported,
       _parser = parser,
       _qwenParser = qwenParser;

  final LocalModelManager _models;
  final LocalPcmPreparer _pcm;
  final LocalSpeechWorker _worker;
  final bool _platformSupported;
  final MossTaggedTranscriptParser _parser;
  final QwenStructuredTranscriptParser _qwenParser;

  @override
  bool get isSupported => _platformSupported;

  @override
  Future<LocalSttResult> transcribe(
    LocalSttRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    if (!isSupported) throw const LocalSpeechException('local_stt_unsupported');
    if (request.durationMs > maxMediaDurationMs) {
      throw const LocalSpeechException('duration_limit');
    }
    final (model, requiredModels, command) = switch (request.engine) {
      LocalSttEngine.mossDiarize => (
        LocalSpeechModels.mossDiarizeCoreMlInt8,
        [LocalSpeechModels.mossDiarizeCoreMlInt8],
        SpeechWorkerCommand.transcribeMoss,
      ),
      LocalSttEngine.qwen3Asr => (
        LocalSpeechModels.qwen3AsrMlx8Bit,
        LocalSpeechModels.qwen3AsrBundle.artifacts,
        SpeechWorkerCommand.transcribeQwen3,
      ),
    };
    for (final requiredModel in requiredModels) {
      final modelStatus = await _models.status(
        requiredModel.id,
        verifyIntegrity: true,
      );
      if (modelStatus.availability != LocalModelAvailability.ready) {
        throw const LocalSpeechException('local_stt_model_missing');
      }
    }
    final prepared = await _pcm.prepare(
      request.sourcePath,
      durationMs: request.durationMs,
      onProgress: (fraction, _) => onProgress?.call(fraction, 'converting'),
      shouldCancel: shouldCancel,
    );
    try {
      onProgress?.call(0, 'transcribing');
      final output = await _worker.run(
        command,
        {
          'protocol': 1,
          'model_directory': _models.pathFor(model.id),
          'audio_path': prepared.path,
          if (request.engine == LocalSttEngine.mossDiarize) ...{
            'chunk_seconds': 30,
            'parallel_chunks': 2,
            'max_new_tokens_per_chunk': 640,
            'hotwords': request.options.contextTerms,
          } else ...{
            'vad_model_directory': _models.pathFor(
              LocalSpeechModels.sileroVadCoreMl.id,
            ),
            'max_segment_seconds': 10,
            'language_hints': request.options.languageHints,
            'context_terms': request.options.contextTerms,
          },
        },
        onProgress: (fraction, detail) =>
            onProgress?.call(fraction, detail ?? 'transcribing'),
        shouldCancel: shouldCancel,
      );
      final rawSegments = output['segments'];
      TranscriptDocument document;
      if (rawSegments is List) {
        document = request.engine == LocalSttEngine.qwen3Asr
            ? _qwenParser.parse(rawSegments, durationMs: request.durationMs)
            : _parser.parseStructured(
                rawSegments,
                durationMs: request.durationMs,
                plainText: output['text']?.toString(),
              );
      } else {
        final raw = output['raw_transcript'] as String?;
        if (raw == null || request.engine == LocalSttEngine.qwen3Asr) {
          throw const LocalSpeechException('local_stt_invalid_output');
        }
        document = _parser.parse(raw, durationMs: request.durationMs);
      }
      return LocalSttResult(
        document: document,
        model: TranscriptionModelReference(
          id: model.id,
          revision: model.revision,
        ),
      );
    } finally {
      await _pcm.release(prepared);
    }
  }
}

class ProcessForcedAlignmentService implements ForcedAlignmentService {
  ProcessForcedAlignmentService({
    required LocalModelManager models,
    required LocalPcmPreparer pcm,
    required LocalSpeechWorker worker,
    required bool platformSupported,
    QwenAlignmentUnitizer unitizer = const QwenAlignmentUnitizer(),
  }) : _models = models,
       _pcm = pcm,
       _worker = worker,
       _platformSupported = platformSupported,
       _unitizer = unitizer;

  static const supportedLanguages = {
    'zh',
    'yue',
    'en',
    'de',
    'es',
    'fr',
    'it',
    'pt',
    'ru',
    'ko',
    'ja',
  };
  static const maximumCoreMlWindowMs = 29000;
  static const maximumWorkerWindowsPerRun = 48;
  static const _coreMlWindowPaddingMs = 250;
  static const _coreMlFixedPromptTokens = 768;
  static const _coreMlPromptSafetyTokens = 48;
  static const _coreMlStructuralTokens = 15;
  static const _coreMlAudioTokensPerSecond = 13;

  final LocalModelManager _models;
  final LocalPcmPreparer _pcm;
  final LocalSpeechWorker _worker;
  final bool _platformSupported;
  final QwenAlignmentUnitizer _unitizer;

  @override
  bool get isSupported => _platformSupported;

  @override
  Future<AlignmentResult> align(
    ForcedAlignmentRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    final total = request.document.segments.length;
    final orderedText =
        request.timelineMode == ForcedAlignmentTimelineMode.orderedText;
    final alignmentDocument = request.document.copyWith(
      segments: [
        for (final segment in request.document.segments)
          _alignmentWindowSegment(segment),
      ],
      preserveUpdatedAt: true,
    );
    if (!isSupported) return _unavailable(total, 'alignment_unsupported');
    final normalizedHints = request.languageHints
        .map((value) => value.toLowerCase().split(RegExp('[-_]')).first)
        .where((value) => value.isNotEmpty)
        .toSet();
    final languageAutomaticallyDetermined = normalizedHints.isEmpty;
    if (normalizedHints.any((value) => !supportedLanguages.contains(value))) {
      return _unavailable(total, 'alignment_language_unsupported');
    }
    final model = LocalSpeechModels.forcedAlignerById(request.model.id);
    if (model == null || model.revision != request.model.revision) {
      return _unavailable(total, 'alignment_model_missing');
    }
    final modelStatus = await _models.status(model.id, verifyIntegrity: true);
    if (modelStatus.availability != LocalModelAvailability.ready) {
      return _unavailable(total, 'alignment_model_missing');
    }
    if (alignmentDocument.segments.isEmpty) {
      return const AlignmentResult(
        tokens: [],
        status: ForcedAlignmentStatus.completed,
        alignedSegments: 0,
        totalSegments: 0,
      );
    }

    final tokensBySegment = <String, List<TranscriptToken>>{};
    for (final token in alignmentDocument.tokens) {
      final owner = token.segmentId;
      if (owner == null) continue;
      tokensBySegment.putIfAbsent(owner, () => []).add(token);
    }
    final retainedTokens = <TranscriptToken>[];
    final unresolvedSegments = <TranscriptSegment>[];
    final eligible = <TranscriptSegment, List<String>>{};
    var skippedTooLong = 0;
    var skippedUnsupportedLanguage = 0;
    for (final segment in alignmentDocument.segments) {
      final units = _unitizer.units(segment.text);
      final reusable = _reusableAlignedTokens(
        segment,
        units,
        tokensBySegment[segment.id] ?? const [],
        orderedText: orderedText,
      );
      if (reusable != null) {
        retainedTokens.addAll(reusable);
        continue;
      }
      unresolvedSegments.add(segment);
      if (languageAutomaticallyDetermined &&
          !_unitizer.canAutoAlign(segment.text)) {
        skippedUnsupportedLanguage++;
        continue;
      }
      if (segment.endMs - segment.startMs > maximumCoreMlWindowMs) {
        skippedTooLong++;
        continue;
      }
      if (units.isEmpty) continue;
      eligible[segment] = units;
    }

    AlignmentResult mergeRetained(AlignmentResult pending) {
      final merged = _mergeRetainedAlignment(
        alignmentDocument,
        retainedTokens,
        pending,
        languageAutomaticallyDetermined,
      );
      return orderedText
          ? _stabilizeOrderedTimeline(alignmentDocument, merged)
          : merged;
    }

    if (eligible.isEmpty) {
      if (skippedUnsupportedLanguage > 0) {
        return mergeRetained(
          _unavailable(
            unresolvedSegments.length,
            'alignment_language_unsupported',
          ),
        );
      }
      if (skippedTooLong > 0) {
        return mergeRetained(
          AlignmentResult(
            tokens: const [],
            status: ForcedAlignmentStatus.partial,
            alignedSegments: 0,
            totalSegments: unresolvedSegments.length,
            languageAutomaticallyDetermined: languageAutomaticallyDetermined,
            warningCode: 'alignment_segment_too_long',
          ),
        );
      }
      if (unresolvedSegments.isEmpty) {
        return mergeRetained(
          const AlignmentResult(
            tokens: [],
            status: ForcedAlignmentStatus.completed,
            alignedSegments: 0,
            totalSegments: 0,
          ),
        );
      }
      return mergeRetained(
        _unavailable(
          unresolvedSegments.length,
          'alignment_no_eligible_segments',
        ),
      );
    }

    final durationMs = eligible.keys
        .map((segment) => segment.endMs)
        .fold<int>(0, max);
    final prepared = await _pcm.prepare(
      request.sourcePath,
      durationMs: durationMs,
      onProgress: (fraction, detail) => onProgress?.call(
        fraction == null ? null : fraction * 0.2,
        detail ?? 'converting',
      ),
      shouldCancel: shouldCancel,
    );
    try {
      final windows = _buildWindows(
        eligible.entries.toList(),
        orderedText: orderedText,
      );
      final windowBounds = _windowBounds(windows, orderedText: orderedText);
      final unresolvedDocument = alignmentDocument.copyWith(
        tokens: const [],
        segments: unresolvedSegments,
        preserveUpdatedAt: true,
      );
      final windowRequests = [
        for (var index = 0; index < windows.length; index++)
          {
            'id': 'window-$index',
            'start_ms': windowBounds[index].startMs,
            'end_ms': windowBounds[index].endMs,
            'segments': [
              for (final entry in windows[index])
                _segmentRequest(entry, orderedText: orderedText),
            ],
          },
      ];

      AlignmentResult mergedOutput(Map<String, dynamic> output) {
        return _mergeRetainedAlignment(
          alignmentDocument,
          retainedTokens,
          _parseOutput(
            output,
            unresolvedDocument,
            windows,
            windowBounds: windowBounds,
            skippedTooLong: skippedTooLong,
            languageAutomaticallyDetermined: languageAutomaticallyDetermined,
            orderedText: orderedText,
          ),
          languageAutomaticallyDetermined,
        );
      }

      final output = await _runWorkerBatches(
        model: model,
        audioPath: prepared.path,
        languageHints: normalizedHints.toList()..sort(),
        windows: windowRequests,
        onProgress: onProgress,
        shouldCancel: shouldCancel,
        onCheckpoint: request.onCheckpoint == null
            ? null
            : (output) {
                final checkpoint = mergedOutput(output);
                request.onCheckpoint!(
                  orderedText
                      ? _stabilizeOrderedTimeline(alignmentDocument, checkpoint)
                      : checkpoint,
                );
              },
      );
      var result = mergedOutput(output);
      if (orderedText) {
        result = await _realignOrderedSeams(
          model: model,
          audioPath: prepared.path,
          languageHints: normalizedHints.toList()..sort(),
          document: alignmentDocument,
          initial: result,
          onProgress: onProgress,
          shouldCancel: shouldCancel,
        );
        result = _stabilizeOrderedTimeline(alignmentDocument, result);
      }
      return result;
    } finally {
      await _pcm.release(prepared);
    }
  }

  TranscriptSegment _alignmentWindowSegment(TranscriptSegment segment) =>
      segment.copyWith(
        startMs: segment.alignmentWindowStartMs ?? segment.startMs,
        endMs: segment.alignmentWindowEndMs ?? segment.endMs,
      );

  List<TranscriptToken>? _reusableAlignedTokens(
    TranscriptSegment segment,
    List<String> units,
    List<TranscriptToken> tokens, {
    required bool orderedText,
  }) {
    if (segment.alignmentWindowStartMs == null ||
        segment.alignmentWindowEndMs == null ||
        units.isEmpty ||
        tokens.length != units.length) {
      return null;
    }
    final start = segment.alignmentWindowStartMs!;
    final end = segment.alignmentWindowEndMs!;
    final reusable = <TranscriptToken>[];
    for (var index = 0; index < units.length; index++) {
      final token = tokens[index];
      if (token.text != units[index] ||
          (!orderedText && token.startMs < start) ||
          (!orderedText && token.endMs > end) ||
          (orderedText
              ? token.endMs <= token.startMs
              : token.endMs < token.startMs) ||
          (reusable.isNotEmpty &&
              (token.startMs < reusable.last.startMs ||
                  token.endMs < reusable.last.endMs))) {
        return null;
      }
      reusable.add(
        TranscriptToken(
          text: token.text,
          startMs: token.startMs,
          endMs: token.endMs,
          segmentId: segment.id,
          speaker: segment.speaker,
          language: segment.language,
        ),
      );
    }
    return reusable;
  }

  AlignmentResult _mergeRetainedAlignment(
    TranscriptDocument document,
    List<TranscriptToken> retained,
    AlignmentResult pending,
    bool languageAutomaticallyDetermined,
  ) {
    final bySegment = <String, List<TranscriptToken>>{};
    for (final token in [...retained, ...pending.tokens]) {
      final owner = token.segmentId;
      if (owner == null) continue;
      bySegment.putIfAbsent(owner, () => []).add(token);
    }
    final tokens = <TranscriptToken>[
      for (final segment in document.segments)
        ...bySegment[segment.id] ?? const [],
    ];
    final segmentIds = document.segments.map((segment) => segment.id).toSet();
    final aligned = bySegment.keys.where(segmentIds.contains).length;
    final status = aligned == document.segments.length
        ? ForcedAlignmentStatus.completed
        : tokens.isEmpty
        ? pending.status
        : ForcedAlignmentStatus.partial;
    return AlignmentResult(
      tokens: List.unmodifiable(tokens),
      status: status,
      alignedSegments: aligned,
      totalSegments: document.segments.length,
      languageAutomaticallyDetermined:
          languageAutomaticallyDetermined ||
          pending.languageAutomaticallyDetermined,
      warningCode: status == ForcedAlignmentStatus.completed
          ? null
          : pending.warningCode ?? 'alignment_partial',
      warningMessage: status == ForcedAlignmentStatus.completed
          ? null
          : pending.warningMessage,
    );
  }

  Future<AlignmentResult> _realignOrderedSeams({
    required LocalModelDescriptor model,
    required String audioPath,
    required List<String> languageHints,
    required TranscriptDocument document,
    required AlignmentResult initial,
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    final tokensBySegment = _tokensBySegment(initial.tokens);
    final conflictBoundaries = <int>[];
    for (var index = 0; index + 1 < document.segments.length; index++) {
      final left = document.segments[index];
      final right = document.segments[index + 1];
      final leftTokens = tokensBySegment[left.id];
      final rightTokens = tokensBySegment[right.id];
      if (leftTokens == null ||
          leftTokens.isEmpty ||
          rightTokens == null ||
          rightTokens.isEmpty ||
          leftTokens.last.endMs <= rightTokens.first.startMs) {
        continue;
      }
      conflictBoundaries.add(index);
    }
    if (conflictBoundaries.isEmpty) return initial;

    final ranges = <({int start, int end, Set<String> targetSegmentIds})>[];
    for (final boundary in conflictBoundaries) {
      final start = max(0, boundary - 1);
      final end = min(document.segments.length - 1, boundary + 2);
      final targets = {
        document.segments[boundary].id,
        document.segments[boundary + 1].id,
      };
      if (ranges.isNotEmpty && ranges.last.end >= start) {
        final previous = ranges.removeLast();
        ranges.add((
          start: previous.start,
          end: max(previous.end, end),
          targetSegmentIds: {...previous.targetSegmentIds, ...targets},
        ));
      } else {
        ranges.add((start: start, end: end, targetSegmentIds: targets));
      }
    }

    final repairWindows = <List<MapEntry<TranscriptSegment, List<String>>>>[];
    final repairTargetIds = <Set<String>>[];
    for (final range in ranges) {
      final entries = [
        for (var index = range.start; index <= range.end; index++)
          MapEntry(
            document.segments[index],
            _unitizer.units(document.segments[index].text),
          ),
      ];
      final startMs = max(
        0,
        entries.first.key.startMs - _coreMlWindowPaddingMs,
      );
      final endMs = entries.last.key.endMs + _coreMlWindowPaddingMs;
      if (entries.any((entry) => entry.value.isEmpty) ||
          endMs - startMs > maximumCoreMlWindowMs ||
          _estimatedPromptTokens(entries) >
              _coreMlFixedPromptTokens - _coreMlPromptSafetyTokens) {
        continue;
      }
      repairWindows.add(entries);
      repairTargetIds.add(range.targetSegmentIds);
    }
    if (repairWindows.isEmpty) return initial;

    final bounds = _windowBounds(repairWindows, orderedText: true);
    final requests = [
      for (var index = 0; index < repairWindows.length; index++)
        <String, Object>{
          'id': 'window-$index',
          'start_ms': bounds[index].startMs,
          'end_ms': bounds[index].endMs,
          'segments': [
            for (final entry in repairWindows[index])
              _segmentRequest(entry, orderedText: true),
          ],
        },
    ];
    Map<String, dynamic> output;
    try {
      output = await _runWorkerBatches(
        model: model,
        audioPath: audioPath,
        languageHints: languageHints,
        windows: requests,
        onProgress: (fraction, detail) => onProgress?.call(
          fraction == null ? null : 0.9 + fraction * 0.1,
          detail ?? 'aligning-seams',
        ),
        shouldCancel: shouldCancel,
      );
    } on LocalSpeechException {
      return initial;
    }

    final repairSegments = [
      for (final window in repairWindows)
        for (final entry in window) entry.key,
    ];
    final repairDocument = document.copyWith(
      tokens: const [],
      segments: repairSegments,
      preserveUpdatedAt: true,
    );
    final repaired = _parseOutput(
      output,
      repairDocument,
      repairWindows,
      windowBounds: bounds,
      skippedTooLong: 0,
      languageAutomaticallyDetermined: initial.languageAutomaticallyDetermined,
      orderedText: true,
    );
    final repairedBySegment = _tokensBySegment(repaired.tokens);
    final acceptedRepairIds = <String>{};
    for (
      var windowIndex = 0;
      windowIndex < repairWindows.length;
      windowIndex++
    ) {
      final window = repairWindows[windowIndex];
      final candidate = <TranscriptToken>[];
      var complete = true;
      for (final entry in window) {
        final owned = repairedBySegment[entry.key.id];
        if (owned == null || owned.length != entry.value.length) {
          complete = false;
          break;
        }
        candidate.addAll(owned);
      }
      if (!complete || _hasOrderedTokenConflict(candidate)) continue;
      acceptedRepairIds.addAll(repairTargetIds[windowIndex]);
    }
    if (acceptedRepairIds.isEmpty) return initial;

    final mergedBySegment = _tokensBySegment(initial.tokens);
    for (final id in acceptedRepairIds) {
      mergedBySegment[id] = repairedBySegment[id]!;
    }
    final tokens = <TranscriptToken>[
      for (final segment in document.segments)
        ...mergedBySegment[segment.id] ?? const [],
    ];
    return _alignmentResultWithTokens(document, initial, tokens);
  }

  AlignmentResult _stabilizeOrderedTimeline(
    TranscriptDocument document,
    AlignmentResult source,
  ) {
    final tokensBySegment = _tokensBySegment(source.tokens);
    String? previousCoveredId;
    for (final segment in document.segments) {
      final current = tokensBySegment[segment.id];
      if (current == null || current.isEmpty) continue;
      if (previousCoveredId case final previousId?) {
        final previous = tokensBySegment[previousId];
        if (previous != null &&
            previous.isNotEmpty &&
            previous.last.endMs > current.first.startMs) {
          final separated = _separateOrderedSegments(previous, current);
          if (separated == null) {
            tokensBySegment.remove(segment.id);
            continue;
          }
          tokensBySegment[previousId] = separated.left;
          tokensBySegment[segment.id] = separated.right;
        }
      }
      previousCoveredId = segment.id;
    }
    _retimeOrderedConflictGroups(document, tokensBySegment);
    final tokens = <TranscriptToken>[
      for (final segment in document.segments)
        ...tokensBySegment[segment.id] ?? const [],
    ];
    final clipped = _pushOrderedTokenTransitions(tokens);
    if (_sameTokenTimings(source.tokens, clipped)) return source;
    return _alignmentResultWithTokens(document, source, clipped);
  }

  void _retimeOrderedConflictGroups(
    TranscriptDocument document,
    Map<String, List<TranscriptToken>> tokensBySegment,
  ) {
    final covered = [
      for (final segment in document.segments)
        if (tokensBySegment[segment.id]?.isNotEmpty ?? false) segment,
    ];
    var groupStart = 0;
    while (groupStart + 1 < covered.length) {
      var groupEnd = groupStart;
      while (groupEnd + 1 < covered.length) {
        final left = tokensBySegment[covered[groupEnd].id]!;
        final right = tokensBySegment[covered[groupEnd + 1].id]!;
        if (left.last.endMs <= right.first.startMs) break;
        groupEnd++;
      }
      if (groupEnd == groupStart) {
        groupStart++;
        continue;
      }
      final groupSegments = covered.sublist(groupStart, groupEnd + 1);
      final groupTokens = <TranscriptToken>[
        for (final segment in groupSegments) ...tokensBySegment[segment.id]!,
      ];
      var intervalStart = groupTokens.map((token) => token.startMs).reduce(min);
      var intervalEnd = groupTokens.map((token) => token.endMs).reduce(max);
      if (intervalEnd - intervalStart < groupTokens.length) {
        intervalStart = min(
          intervalStart,
          groupSegments.map((segment) => segment.startMs).reduce(min),
        );
        intervalEnd = max(
          intervalEnd,
          groupSegments.map((segment) => segment.endMs).reduce(max),
        );
      }
      if (intervalEnd - intervalStart < groupTokens.length) {
        for (var index = groupStart + 1; index <= groupEnd; index++) {
          tokensBySegment.remove(covered[index].id);
        }
        groupStart = groupEnd + 1;
        continue;
      }
      final retimed = _retimeTokenRange(
        groupTokens,
        startIndex: 0,
        endIndex: groupTokens.length,
        startMs: intervalStart,
        endMs: intervalEnd,
      );
      var tokenOffset = 0;
      for (final segment in groupSegments) {
        final count = tokensBySegment[segment.id]!.length;
        tokensBySegment[segment.id] = List.unmodifiable(
          retimed.sublist(tokenOffset, tokenOffset + count),
        );
        tokenOffset += count;
      }
      groupStart = groupEnd + 1;
    }
  }

  List<TranscriptToken> _pushOrderedTokenTransitions(
    List<TranscriptToken> source,
  ) {
    final result = source.toList(growable: true);
    for (var index = 0; index + 1 < result.length; index++) {
      final left = result[index];
      final right = result[index + 1];
      if (left.endMs <= right.startMs) continue;
      final duration = max(1, right.endMs - right.startMs);
      result[index + 1] = _tokenWithTiming(
        right,
        startMs: left.endMs,
        endMs: left.endMs + duration,
      );
    }
    return List.unmodifiable(result);
  }

  ({List<TranscriptToken> left, List<TranscriptToken> right})?
  _separateOrderedSegments(
    List<TranscriptToken> left,
    List<TranscriptToken> right,
  ) {
    if (left.isEmpty ||
        right.isEmpty ||
        left.last.endMs <= right.first.startMs) {
      return (left: left, right: right);
    }
    final intervalStart = min(left.first.startMs, right.first.startMs);
    final intervalEnd = max(left.last.endMs, right.last.endMs);
    final tokenCount = left.length + right.length;
    if (intervalEnd - intervalStart < tokenCount) return null;
    final preferredMinimum =
        intervalEnd - intervalStart >=
            tokenCount * minimumAlignedTokenDurationMs
        ? minimumAlignedTokenDurationMs
        : 1;
    final minimumBoundary = intervalStart + left.length * preferredMinimum;
    final maximumBoundary = intervalEnd - right.length * preferredMinimum;
    if (maximumBoundary < minimumBoundary) return null;
    final targetBoundary = (left.last.endMs + right.first.startMs) ~/ 2;
    final boundary = targetBoundary.clamp(minimumBoundary, maximumBoundary);

    var leftStartIndex = 0;
    while (leftStartIndex < left.length &&
        left[leftStartIndex].endMs <= boundary) {
      leftStartIndex++;
    }
    if (leftStartIndex == left.length) {
      leftStartIndex = left.length - 1;
    }
    while (leftStartIndex > 0 &&
        boundary - left[leftStartIndex - 1].endMs <
            (left.length - leftStartIndex) * preferredMinimum) {
      leftStartIndex--;
    }
    final leftRepairStart = leftStartIndex == 0
        ? intervalStart
        : left[leftStartIndex - 1].endMs;
    if (boundary - leftRepairStart <
        (left.length - leftStartIndex) * preferredMinimum) {
      return null;
    }

    var rightEndExclusive = 0;
    while (rightEndExclusive < right.length &&
        right[rightEndExclusive].startMs < boundary) {
      rightEndExclusive++;
    }
    if (rightEndExclusive == 0) rightEndExclusive = 1;
    var rightRepairEnd = rightEndExclusive < right.length
        ? right[rightEndExclusive].startMs
        : intervalEnd;
    while (rightEndExclusive < right.length &&
        rightRepairEnd - boundary < rightEndExclusive * preferredMinimum) {
      rightEndExclusive++;
      rightRepairEnd = rightEndExclusive < right.length
          ? right[rightEndExclusive].startMs
          : intervalEnd;
    }
    if (rightRepairEnd - boundary < rightEndExclusive * preferredMinimum) {
      return null;
    }

    return (
      left: _retimeTokenRange(
        left,
        startIndex: leftStartIndex,
        endIndex: left.length,
        startMs: leftRepairStart,
        endMs: boundary,
      ),
      right: _retimeTokenRange(
        right,
        startIndex: 0,
        endIndex: rightEndExclusive,
        startMs: boundary,
        endMs: rightRepairEnd,
      ),
    );
  }

  List<TranscriptToken> _retimeTokenRange(
    List<TranscriptToken> source, {
    required int startIndex,
    required int endIndex,
    required int startMs,
    required int endMs,
  }) {
    final result = source.toList(growable: true);
    final count = endIndex - startIndex;
    for (var offset = 0; offset < count; offset++) {
      result[startIndex + offset] = _tokenWithTiming(
        result[startIndex + offset],
        startMs: startMs + (endMs - startMs) * offset ~/ count,
        endMs: startMs + (endMs - startMs) * (offset + 1) ~/ count,
      );
    }
    return List.unmodifiable(result);
  }

  Map<String, List<TranscriptToken>> _tokensBySegment(
    Iterable<TranscriptToken> tokens,
  ) {
    final result = <String, List<TranscriptToken>>{};
    for (final token in tokens) {
      final owner = token.segmentId;
      if (owner == null) continue;
      result.putIfAbsent(owner, () => []).add(token);
    }
    return result;
  }

  bool _hasOrderedTokenConflict(List<TranscriptToken> tokens) {
    for (var index = 0; index + 1 < tokens.length; index++) {
      if (tokens[index].endMs > tokens[index + 1].startMs) return true;
    }
    return false;
  }

  bool _sameTokenTimings(
    List<TranscriptToken> left,
    List<TranscriptToken> right,
  ) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index].segmentId != right[index].segmentId ||
          left[index].text != right[index].text ||
          left[index].startMs != right[index].startMs ||
          left[index].endMs != right[index].endMs) {
        return false;
      }
    }
    return true;
  }

  TranscriptToken _tokenWithTiming(
    TranscriptToken token, {
    required int startMs,
    required int endMs,
  }) => TranscriptToken(
    text: token.text,
    startMs: startMs,
    endMs: endMs,
    segmentId: token.segmentId,
    speaker: token.speaker,
    language: token.language,
    confidence: token.confidence,
    translationStatus: token.translationStatus,
    sourceLanguage: token.sourceLanguage,
  );

  AlignmentResult _alignmentResultWithTokens(
    TranscriptDocument document,
    AlignmentResult source,
    List<TranscriptToken> tokens,
  ) {
    final segmentIds = document.segments.map((segment) => segment.id).toSet();
    final aligned = tokens
        .map((token) => token.segmentId)
        .whereType<String>()
        .where(segmentIds.contains)
        .toSet()
        .length;
    final status = aligned == document.segments.length
        ? ForcedAlignmentStatus.completed
        : tokens.isEmpty
        ? ForcedAlignmentStatus.failed
        : ForcedAlignmentStatus.partial;
    return AlignmentResult(
      tokens: List.unmodifiable(tokens),
      status: status,
      alignedSegments: aligned,
      totalSegments: document.segments.length,
      languageAutomaticallyDetermined: source.languageAutomaticallyDetermined,
      warningCode: status == ForcedAlignmentStatus.completed
          ? null
          : source.warningCode ?? 'alignment_partial',
      warningMessage: status == ForcedAlignmentStatus.completed
          ? null
          : source.warningMessage,
    );
  }

  Map<String, dynamic> _segmentRequest(
    MapEntry<TranscriptSegment, List<String>> entry, {
    required bool orderedText,
  }) => {
    'id': entry.key.id,
    'start_ms': entry.key.startMs,
    'end_ms': entry.key.endMs,
    'units': entry.value,
    if (orderedText) 'allow_outside_segment_bounds': true,
  };

  Future<Map<String, dynamic>> _runWorkerBatches({
    required LocalModelDescriptor model,
    required String audioPath,
    required List<String> languageHints,
    required List<Map<String, Object>> windows,
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
    void Function(Map<String, dynamic> output)? onCheckpoint,
  }) async {
    final tokens = <Object?>[];
    final failedWindowIds = <String>{};
    String? warningCode;
    String? warningMessage;
    var lastProgress = 0.0;

    Map<String, dynamic> snapshot() => {
      'tokens': List<Object?>.of(tokens),
      'failed_window_ids': failedWindowIds.toList(growable: false),
      if (warningCode != null) 'warning_code': warningCode,
      if (warningMessage != null) 'warning_message': warningMessage,
    };

    void reportProgress(double fraction, String? detail) {
      lastProgress = max(lastProgress, fraction.clamp(0, 1));
      onProgress?.call(0.2 + lastProgress * 0.8, detail ?? 'aligning');
    }

    late Future<void> Function(
      List<Map<String, Object>> batch,
      int offset,
      bool isRetry,
    )
    runBatch;
    runBatch = (batch, offset, isRetry) async {
      if (shouldCancel?.call() ?? false) {
        throw const OperationCancelledException();
      }
      try {
        final output = await _worker.run(
          SpeechWorkerCommand.alignQwen3,
          {
            'protocol': 1,
            'model_directory': _models.pathFor(model.id),
            'audio_path': audioPath,
            'window_max_ms': maximumCoreMlWindowMs,
            'window_padding_ms': _coreMlWindowPaddingMs,
            'language_hints': languageHints,
            'segments': [
              for (final window in batch)
                for (final segment in (window['segments'] as List)) segment,
            ],
            'windows': batch,
          },
          onProgress: (fraction, detail) {
            if (fraction == null) {
              onProgress?.call(null, detail ?? 'aligning');
              return;
            }
            reportProgress(
              (offset + fraction * batch.length) / windows.length,
              detail,
            );
          },
          shouldCancel: shouldCancel,
        );
        if (output['tokens'] case final List values) tokens.addAll(values);
        if (output['failed_window_ids'] case final List values) {
          failedWindowIds.addAll(values.map((value) => value.toString()));
        }
        warningCode ??= output['warning_code']?.toString();
        warningMessage ??= output['warning_message']?.toString();
        reportProgress((offset + batch.length) / windows.length, 'aligning');
      } on LocalSpeechException catch (error) {
        final recoverable =
            error.code == 'local_worker_failed' ||
            error.code == 'local_worker_invalid_output';
        if (!recoverable) rethrow;
        if (batch.length > 1) {
          final midpoint = batch.length ~/ 2;
          await runBatch(batch.sublist(0, midpoint), offset, false);
          await runBatch(batch.sublist(midpoint), offset + midpoint, false);
          return;
        }
        if (!isRetry) {
          await runBatch(batch, offset, true);
          return;
        }
        failedWindowIds.add(batch.single['id'].toString());
        warningCode = error.code;
        warningMessage = error.message ?? warningMessage;
        reportProgress((offset + 1) / windows.length, 'aligning');
      }
    };

    for (
      var offset = 0;
      offset < windows.length;
      offset += maximumWorkerWindowsPerRun
    ) {
      final end = min(offset + maximumWorkerWindowsPerRun, windows.length);
      await runBatch(windows.sublist(offset, end), offset, false);
      onCheckpoint?.call(snapshot());
    }
    return snapshot();
  }

  AlignmentResult _parseOutput(
    Map<String, dynamic> output,
    TranscriptDocument document,
    List<List<MapEntry<TranscriptSegment, List<String>>>> windows, {
    required List<({int startMs, int endMs})> windowBounds,
    required int skippedTooLong,
    required bool languageAutomaticallyDetermined,
    required bool orderedText,
  }) {
    final segmentsById = {
      for (final segment in document.segments) segment.id: segment,
    };
    final rawBySegment = <String, List<Map<String, dynamic>>>{};
    final rawTokens = output['tokens'];
    if (rawTokens is List) {
      for (final item in rawTokens.whereType<Map>()) {
        final json = item.cast<String, dynamic>();
        final segmentId = json['segment_id']?.toString();
        if (segmentId == null || !segmentsById.containsKey(segmentId)) continue;
        rawBySegment.putIfAbsent(segmentId, () => []).add(json);
      }
    }

    final failedWindowIds = switch (output['failed_window_ids']) {
      final List values => values.map((value) => value.toString()).toSet(),
      _ => const <String>{},
    };
    final tokens = <TranscriptToken>[];
    for (var windowIndex = 0; windowIndex < windows.length; windowIndex++) {
      if (failedWindowIds.contains('window-$windowIndex')) continue;
      final windowStart = windowBounds[windowIndex].startMs;
      final windowEnd = windowBounds[windowIndex].endMs;
      if (orderedText) {
        tokens.addAll(
          _parseOrderedWindow(
            windows[windowIndex],
            rawBySegment,
            windowStart: windowStart,
            windowEnd: windowEnd,
          ),
        );
        continue;
      }
      for (final entry in windows[windowIndex]) {
        final segment = entry.key;
        final raw = rawBySegment[segment.id] ?? const [];
        var valid = true;
        if (raw.length != entry.value.length) {
          continue;
        }
        final owned = <TranscriptToken>[];
        var hasClampedBoundaryPoint = false;
        for (var tokenIndex = 0; tokenIndex < raw.length; tokenIndex++) {
          final json = raw[tokenIndex];
          final text = json['text']?.toString() ?? '';
          final rawStart = (json['start_ms'] as num?)?.toInt();
          final rawEnd = (json['end_ms'] as num?)?.toInt();
          if (text != entry.value[tokenIndex] ||
              rawStart == null ||
              rawEnd == null) {
            valid = false;
            break;
          }
          if (rawEnd < rawStart) {
            valid = false;
            break;
          }
          final lowerBound = segment.startMs;
          final upperBound = segment.endMs;
          final start = rawStart.clamp(lowerBound, upperBound);
          final end = rawEnd.clamp(start, upperBound);
          final tiedTimestampClass =
              rawStart == rawEnd &&
              rawStart >= lowerBound &&
              rawStart < upperBound;
          if (end == start && !tiedTimestampClass) {
            hasClampedBoundaryPoint = true;
          }
          if (owned.isNotEmpty &&
              (start < owned.last.startMs || end < owned.last.endMs)) {
            valid = false;
            break;
          }
          owned.add(
            TranscriptToken(
              text: text,
              startMs: start,
              endMs: end,
              segmentId: segment.id,
              speaker: segment.speaker,
              language: segment.language,
            ),
          );
        }
        if (!valid) continue;
        if (owned.length == 1 && hasClampedBoundaryPoint) continue;
        final allCollapsed =
            owned.length > 1 &&
            owned.every(
              (token) =>
                  token.startMs == owned.first.startMs &&
                  token.endMs == owned.first.endMs,
            );
        if (allCollapsed && segment.endMs - segment.startMs >= owned.length) {
          _redistributeTokens(
            owned,
            startIndex: 0,
            startMs: segment.startMs,
            endMs: segment.endMs,
          );
        }
        var collapsedTailStart = owned.length;
        while (collapsedTailStart > 0 &&
            owned[collapsedTailStart - 1].startMs == segment.endMs &&
            owned[collapsedTailStart - 1].endMs == segment.endMs) {
          collapsedTailStart--;
        }
        if (collapsedTailStart > 0 && collapsedTailStart < owned.length) {
          var repairStart = collapsedTailStart;
          var intervalStart = owned[repairStart - 1].endMs;
          var repairCount = owned.length - repairStart;
          var availableMs = segment.endMs - intervalStart;
          while (repairStart > 0 &&
              availableMs < repairCount * minimumAlignedTokenDurationMs) {
            repairStart--;
            intervalStart = repairStart == 0
                ? segment.startMs
                : owned[repairStart - 1].endMs;
            repairCount = owned.length - repairStart;
            availableMs = segment.endMs - intervalStart;
          }
          if (availableMs >= repairCount) {
            _redistributeTokens(
              owned,
              startIndex: repairStart,
              startMs: intervalStart,
              endMs: segment.endMs,
            );
          }
        }
        final stabilized = stabilizeAlignedTokenTransitions(
          tokens: owned,
          segment: segment,
        );
        if (stabilized.length > 1 &&
            stabilized.every(
              (token) =>
                  token.startMs == stabilized.first.startMs &&
                  token.endMs == stabilized.first.endMs,
            )) {
          continue;
        }
        tokens.addAll(stabilized);
      }
    }

    final covered = tokens
        .map((token) => token.segmentId)
        .whereType<String>()
        .toSet();
    final total = document.segments.length;
    final status = tokens.isEmpty
        ? ForcedAlignmentStatus.failed
        : covered.length == total
        ? ForcedAlignmentStatus.completed
        : ForcedAlignmentStatus.partial;
    return AlignmentResult(
      tokens: List.unmodifiable(tokens),
      status: status,
      alignedSegments: covered.length,
      totalSegments: total,
      languageAutomaticallyDetermined: languageAutomaticallyDetermined,
      warningCode: status == ForcedAlignmentStatus.partial
          ? (skippedTooLong > 0
                ? 'alignment_segment_too_long'
                : output['warning_code']?.toString() ?? 'alignment_partial')
          : status == ForcedAlignmentStatus.failed
          ? (output['warning_code']?.toString() ?? 'alignment_failed')
          : null,
      warningMessage: output['warning_message']?.toString(),
    );
  }

  List<TranscriptToken> _parseOrderedWindow(
    List<MapEntry<TranscriptSegment, List<String>>> entries,
    Map<String, List<Map<String, dynamic>>> rawBySegment, {
    required int windowStart,
    required int windowEnd,
  }) {
    final ordered = <TranscriptToken>[];
    for (final entry in entries) {
      final segment = entry.key;
      final raw = rawBySegment[segment.id] ?? const [];
      if (raw.length != entry.value.length) continue;
      final candidate = <TranscriptToken>[];
      var valid = true;
      for (var tokenIndex = 0; tokenIndex < raw.length; tokenIndex++) {
        final json = raw[tokenIndex];
        final text = json['text']?.toString() ?? '';
        final rawStart = (json['start_ms'] as num?)?.toInt();
        final rawEnd = (json['end_ms'] as num?)?.toInt();
        if (text != entry.value[tokenIndex] ||
            rawStart == null ||
            rawEnd == null ||
            rawEnd < rawStart) {
          valid = false;
          break;
        }
        final start = rawStart.clamp(windowStart, windowEnd);
        final end = rawEnd.clamp(start, windowEnd);
        final previous = candidate.lastOrNull ?? ordered.lastOrNull;
        if (previous != null &&
            (start < previous.startMs || end < previous.endMs)) {
          valid = false;
          break;
        }
        candidate.add(
          TranscriptToken(
            text: text,
            startMs: start,
            endMs: end,
            segmentId: segment.id,
            speaker: segment.speaker,
            language: segment.language,
          ),
        );
      }
      if (valid) ordered.addAll(candidate);
    }
    if (ordered.isEmpty) return const [];
    return _repairOrderedTiedTokens(
          ordered,
          windowStart: windowStart,
          windowEnd: windowEnd,
        ) ??
        const [];
  }

  List<TranscriptToken>? _repairOrderedTiedTokens(
    List<TranscriptToken> tokens, {
    required int windowStart,
    required int windowEnd,
  }) {
    final repaired = tokens.toList(growable: true);

    TranscriptToken withTiming(
      TranscriptToken token, {
      required int startMs,
      required int endMs,
    }) => TranscriptToken(
      text: token.text,
      startMs: startMs,
      endMs: endMs,
      segmentId: token.segmentId,
      speaker: token.speaker,
      language: token.language,
      confidence: token.confidence,
      translationStatus: token.translationStatus,
      sourceLanguage: token.sourceLanguage,
    );

    var index = 0;
    while (index < repaired.length) {
      if (repaired[index].endMs > repaired[index].startMs) {
        index++;
        continue;
      }
      final runStart = index;
      final anchor = repaired[index].startMs;
      while (index < repaired.length &&
          repaired[index].startMs == anchor &&
          repaired[index].endMs == anchor) {
        index++;
      }
      final runEnd = index;
      final count = runEnd - runStart;
      var left = runStart == 0 ? windowStart : repaired[runStart - 1].endMs;
      var right = runEnd == repaired.length
          ? windowEnd
          : repaired[runEnd].startMs;
      if (right - left < count) {
        final deficit = count - (right - left);
        if (runStart > 0 &&
            repaired[runStart - 1].endMs - repaired[runStart - 1].startMs >
                deficit) {
          final previous = repaired[runStart - 1];
          repaired[runStart - 1] = withTiming(
            previous,
            startMs: previous.startMs,
            endMs: previous.endMs - deficit,
          );
          left -= deficit;
        } else if (runEnd < repaired.length &&
            repaired[runEnd].endMs - repaired[runEnd].startMs > deficit) {
          final next = repaired[runEnd];
          repaired[runEnd] = withTiming(
            next,
            startMs: next.startMs + deficit,
            endMs: next.endMs,
          );
          right += deficit;
        } else {
          return null;
        }
      }
      final available = right - left;
      if (available < count) return null;
      final preferred = count * minimumAlignedTokenDurationMs;
      late final int blockStart;
      late final int blockEnd;
      if (available <= preferred) {
        blockStart = left;
        blockEnd = right;
      } else if (anchor <= left) {
        blockStart = left;
        blockEnd = left + preferred;
      } else if (anchor >= right) {
        blockStart = right - preferred;
        blockEnd = right;
      } else {
        blockStart = (anchor - preferred ~/ 2).clamp(left, right - preferred);
        blockEnd = blockStart + preferred;
      }
      final duration = blockEnd - blockStart;
      for (var offset = 0; offset < count; offset++) {
        final token = repaired[runStart + offset];
        repaired[runStart + offset] = withTiming(
          token,
          startMs: blockStart + duration * offset ~/ count,
          endMs: blockStart + duration * (offset + 1) ~/ count,
        );
      }
    }
    for (var tokenIndex = 0; tokenIndex < repaired.length; tokenIndex++) {
      final token = repaired[tokenIndex];
      if (token.startMs < windowStart ||
          token.endMs > windowEnd ||
          token.endMs <= token.startMs ||
          (tokenIndex > 0 && token.startMs < repaired[tokenIndex - 1].endMs)) {
        return null;
      }
    }
    return List.unmodifiable(repaired);
  }

  void _redistributeTokens(
    List<TranscriptToken> tokens, {
    required int startIndex,
    required int startMs,
    required int endMs,
  }) {
    final count = tokens.length - startIndex;
    final durationMs = endMs - startMs;
    for (var index = 0; index < count; index++) {
      final tokenIndex = startIndex + index;
      final token = tokens[tokenIndex];
      tokens[tokenIndex] = TranscriptToken(
        text: token.text,
        startMs: startMs + durationMs * index ~/ count,
        endMs: startMs + durationMs * (index + 1) ~/ count,
        segmentId: token.segmentId,
        speaker: token.speaker,
        language: token.language,
      );
    }
  }

  List<List<MapEntry<TranscriptSegment, List<String>>>> _buildWindows(
    List<MapEntry<TranscriptSegment, List<String>>> entries, {
    required bool orderedText,
  }) {
    entries.sort((a, b) {
      final start = a.key.startMs.compareTo(b.key.startMs);
      return start == 0 ? a.key.endMs.compareTo(b.key.endMs) : start;
    });
    final overlappingIds = <String>{};
    for (var left = 0; left < entries.length; left++) {
      for (var right = left + 1; right < entries.length; right++) {
        if (entries[right].key.startMs >= entries[left].key.endMs) break;
        overlappingIds
          ..add(entries[left].key.id)
          ..add(entries[right].key.id);
      }
    }
    final windows = <List<MapEntry<TranscriptSegment, List<String>>>>[];
    var current = <MapEntry<TranscriptSegment, List<String>>>[];
    void flush() {
      if (current.isNotEmpty) windows.add(current);
      current = [];
    }

    for (final entry in entries) {
      if (!orderedText && overlappingIds.contains(entry.key.id)) {
        flush();
        windows.add([entry]);
        continue;
      }
      if (current.isEmpty) {
        current.add(entry);
        continue;
      }
      final previous = current.last.key;
      if (!orderedText && entry.key.startMs < previous.endMs) {
        flush();
        windows.add([entry]);
        continue;
      }
      final continuous = orderedText
          ? entry.key.startMs <= previous.endMs + _coreMlWindowPaddingMs
          : entry.key.startMs - previous.endMs <= _coreMlWindowPaddingMs;
      final withinLimit =
          entry.key.endMs - current.first.key.startMs <= maximumCoreMlWindowMs;
      final candidate = [...current, entry];
      final withinPromptBudget =
          _estimatedPromptTokens(candidate) <=
          _coreMlFixedPromptTokens - _coreMlPromptSafetyTokens;
      if (continuous && withinLimit && withinPromptBudget) {
        current.add(entry);
      } else {
        flush();
        current.add(entry);
      }
    }
    flush();
    return windows;
  }

  List<({int startMs, int endMs})> _windowBounds(
    List<List<MapEntry<TranscriptSegment, List<String>>>> windows, {
    required bool orderedText,
  }) {
    final bounds = [
      for (final window in windows)
        (
          startMs: max(0, window.first.key.startMs - _coreMlWindowPaddingMs),
          endMs: window.last.key.endMs + _coreMlWindowPaddingMs,
        ),
    ];
    return bounds;
  }

  int _estimatedPromptTokens(
    List<MapEntry<TranscriptSegment, List<String>>> entries,
  ) {
    final startMs = max(0, entries.first.key.startMs - _coreMlWindowPaddingMs);
    final endMs = entries.last.key.endMs + _coreMlWindowPaddingMs;
    final audioTokens = ((endMs - startMs) * _coreMlAudioTokensPerSecond / 1000)
        .ceil();
    final textTokens = entries
        .expand((entry) => entry.value)
        .fold<int>(0, (total, unit) => total + _estimatedUnitTokens(unit));
    return _coreMlStructuralTokens + audioTokens + textTokens;
  }

  int _estimatedUnitTokens(String unit) {
    final runes = unit.runes.length;
    // Every alignment unit adds two timestamp slots. A single CJK unit is
    // normally one tokenizer token; longer Latin/Cyrillic units are budgeted
    // conservatively because BPE can split names and uncommon words.
    final contentTokens = runes <= 1 ? 1 : max(1, (runes + 2) ~/ 3);
    return 2 + contentTokens;
  }

  AlignmentResult _unavailable(int total, String code) => AlignmentResult(
    tokens: const [],
    status: ForcedAlignmentStatus.unavailable,
    alignedSegments: 0,
    totalSegments: total,
    warningCode: code,
  );
}
