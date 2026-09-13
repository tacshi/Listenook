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
    final alignmentDocument = request.document;
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

    final eligible = <TranscriptSegment, List<String>>{};
    var skippedTooLong = 0;
    var skippedUnsupportedLanguage = 0;
    for (final segment in alignmentDocument.segments) {
      final units = _unitizer.units(segment.text);
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

    AlignmentResult mergeRetained(AlignmentResult pending) =>
        _mergeRetainedAlignment(
          alignmentDocument,
          pending,
          languageAutomaticallyDetermined,
        );

    if (eligible.isEmpty) {
      if (skippedUnsupportedLanguage > 0) {
        return mergeRetained(
          _unavailable(
            total,
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
            totalSegments: total,
            languageAutomaticallyDetermined: languageAutomaticallyDetermined,
            warningCode: 'alignment_segment_too_long',
          ),
        );
      }
      return mergeRetained(
        _unavailable(total, 'alignment_no_eligible_segments'),
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
      final windows = _buildWindows(eligible.entries.toList());
      final windowBounds = _windowBounds(windows);
      final unresolvedDocument = alignmentDocument.copyWith(
        tokens: const [],
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
                _segmentRequest(entry),
            ],
          },
      ];

      AlignmentResult mergedOutput(Map<String, dynamic> output) {
        return _mergeRetainedAlignment(
          alignmentDocument,
          _parseOutput(
            output,
            unresolvedDocument,
            windows,
            skippedTooLong: skippedTooLong,
            languageAutomaticallyDetermined: languageAutomaticallyDetermined,
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
            : (output) => request.onCheckpoint!(mergedOutput(output)),
      );
      return mergedOutput(output);
    } finally {
      await _pcm.release(prepared);
    }
  }

  AlignmentResult _mergeRetainedAlignment(
    TranscriptDocument document,
    AlignmentResult pending,
    bool languageAutomaticallyDetermined,
  ) {
    final bySegment = <String, List<TranscriptToken>>{};
    for (final token in pending.tokens) {
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

  Map<String, dynamic> _segmentRequest(
    MapEntry<TranscriptSegment, List<String>> entry,
  ) => {
    'id': entry.key.id,
    'start_ms': entry.key.startMs,
    'end_ms': entry.key.endMs,
    'units': entry.value,
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
    required int skippedTooLong,
    required bool languageAutomaticallyDetermined,
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
    List<MapEntry<TranscriptSegment, List<String>>> entries,
  ) {
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
      if (overlappingIds.contains(entry.key.id)) {
        flush();
        windows.add([entry]);
        continue;
      }
      if (current.isEmpty) {
        current.add(entry);
        continue;
      }
      final previous = current.last.key;
      if (entry.key.startMs < previous.endMs) {
        flush();
        windows.add([entry]);
        continue;
      }
      final continuous =
          entry.key.startMs - previous.endMs <= _coreMlWindowPaddingMs;
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
    List<List<MapEntry<TranscriptSegment, List<String>>>> windows,
  ) => [
    for (final window in windows)
      (
        startMs: max(0, window.first.key.startMs - _coreMlWindowPaddingMs),
        endMs: window.last.key.endMs + _coreMlWindowPaddingMs,
      ),
  ];

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
