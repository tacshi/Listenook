import 'dart:convert';

import '../core/contracts.dart';
import '../core/models.dart';

class DefaultAiBriefService implements AiBriefService {
  const DefaultAiBriefService(this._llm);

  static const maxCharactersPerChunk = 8000;
  static const _systemPrompt =
      'You turn timestamped transcripts into concise, trustworthy work '
      'products. Use only facts explicitly supported by the supplied '
      'segments. Every chapter and insight must cite one or more exact '
      'segment IDs. Never invent decisions, owners, deadlines, or questions. '
      'Language-learning explanations may use established linguistic '
      'knowledge, but every selected term and source excerpt must come from '
      'the cited transcript segments. '
      'Omit unsupported items. Return JSON only, with no Markdown fences.';

  final LlmClient _llm;

  @override
  int estimateRequestCount(
    TranscriptDocument document,
    Set<AiBriefSection> sections,
  ) {
    if (sections.isEmpty) return 0;
    final count = _chunks(document).length;
    return count == 0 ? 0 : count + (count > 1 ? 1 : 0);
  }

  @override
  Future<AiBrief> generate({
    required LlmProviderSettings settings,
    required TranscriptDocument document,
    required Set<AiBriefSection> sections,
    required String outputLanguage,
    String? learningLanguage,
    AiLearningLevel learningLevel = AiLearningLevel.intermediate,
    AiBriefProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    if (sections.isEmpty) {
      throw const AiBriefException('ai_brief_no_sections');
    }
    if (document.segments
        .where((item) => item.text.trim().isNotEmpty)
        .isEmpty) {
      throw const AiBriefException('ai_brief_empty_transcript');
    }
    final validation = settings.validationError();
    if (validation != null) throw AiBriefException(validation);
    final chunks = _chunks(document);
    final resolvedLearningLanguage = _resolvedLearningLanguage(
      document,
      learningLanguage,
    );
    final totalRequests = chunks.length + (chunks.length > 1 ? 1 : 0);
    final candidates = <Map<String, dynamic>>[];
    try {
      for (var index = 0; index < chunks.length; index++) {
        _checkCancelled(shouldCancel);
        final prompt = _chunkPrompt(
          chunks[index],
          document: document,
          sections: sections,
          outputLanguage: outputLanguage,
          learningLanguage: resolvedLearningLanguage,
          learningLevel: learningLevel,
          chunkIndex: index,
          chunkCount: chunks.length,
        );
        candidates.add(
          await _completeJson(
            settings: settings,
            prompt: prompt,
            shouldCancel: shouldCancel,
          ),
        );
        await onProgress?.call('analyzing', index + 1, totalRequests);
      }

      Map<String, dynamic> result;
      if (candidates.length == 1) {
        result = candidates.single;
      } else {
        _checkCancelled(shouldCancel);
        result = await _completeJson(
          settings: settings,
          prompt: _synthesisPrompt(
            candidates,
            sections: sections,
            outputLanguage: outputLanguage,
            learningLanguage: resolvedLearningLanguage,
            learningLevel: learningLevel,
          ),
          shouldCancel: shouldCancel,
        );
        await onProgress?.call('synthesizing', totalRequests, totalRequests);
      }
      return _validatedBrief(
        result,
        settings: settings,
        document: document,
        sections: sections,
        outputLanguage: outputLanguage,
        learningLanguage: learningLanguage,
        learningLevel: learningLevel,
      );
    } on OperationCancelledException {
      rethrow;
    } on AiBriefException {
      rethrow;
    } on LlmException catch (error) {
      final suffix = error.code.startsWith('llm_')
          ? error.code.substring('llm_'.length)
          : error.code;
      throw AiBriefException('ai_brief_$suffix', message: error.message);
    }
  }

  List<List<TranscriptSegment>> _chunks(TranscriptDocument document) {
    final chunks = <List<TranscriptSegment>>[];
    var current = <TranscriptSegment>[];
    var characters = 0;
    for (final segment in document.segments) {
      if (segment.text.trim().isEmpty) continue;
      final renderedLength = _renderSegment(document, segment).length + 1;
      if (current.isNotEmpty &&
          characters + renderedLength > maxCharactersPerChunk) {
        chunks.add(current);
        current = <TranscriptSegment>[];
        characters = 0;
      }
      current.add(segment);
      characters += renderedLength;
    }
    if (current.isNotEmpty) chunks.add(current);
    return chunks;
  }

  String _chunkPrompt(
    List<TranscriptSegment> chunk, {
    required TranscriptDocument document,
    required Set<AiBriefSection> sections,
    required String outputLanguage,
    required String? learningLanguage,
    required AiLearningLevel learningLevel,
    required int chunkIndex,
    required int chunkCount,
  }) {
    final requested = sections.map((item) => item.name).join(', ');
    final learningInstructions = _learningInstructions(
      sections: sections,
      learningLanguage: learningLanguage,
      learningLevel: learningLevel,
      synthesis: chunkCount == 1,
    );
    final lines = chunk
        .map((segment) => _renderSegment(document, segment))
        .join('\n');
    return '''
Analyze transcript chunk ${chunkIndex + 1} of $chunkCount.
Write all user-facing text in language code "$outputLanguage".
Requested sections: $requested.
$learningInstructions

Return exactly this JSON shape:
{"overview":"concise overview or empty string","overview_evidence":["segment-id"],"chapters":[{"title":"...","summary":"...","evidence":["segment-id"]}],"insights":[{"type":"keyIdea|notableMoment|decision|actionItem|openQuestion","text":"...","owner":null,"deadline":null,"evidence":["segment-id"]}],"language_notes":[{"kind":"vocabulary|expression|grammar","term":"...","explanation":"...","source_excerpt":"...","evidence":["segment-id"]}]}

For owner and deadline, use null unless the cited transcript states them explicitly. Keep overview_evidence to the smallest useful set of supporting segments.

Transcript:
$lines
''';
  }

  String _synthesisPrompt(
    List<Map<String, dynamic>> candidates, {
    required Set<AiBriefSection> sections,
    required String outputLanguage,
    required String? learningLanguage,
    required AiLearningLevel learningLevel,
  }) {
    final requested = sections.map((item) => item.name).join(', ');
    final learningInstructions = _learningInstructions(
      sections: sections,
      learningLanguage: learningLanguage,
      learningLevel: learningLevel,
      synthesis: true,
    );
    return '''
Synthesize the candidate analyses below into one non-repetitive brief.
Write all user-facing text in language code "$outputLanguage".
Requested sections: $requested.
Preserve only supplied evidence segment IDs. Do not introduce facts.
$learningInstructions

Return exactly this JSON shape:
{"overview":"concise overview or empty string","overview_evidence":["segment-id"],"chapters":[{"title":"...","summary":"...","evidence":["segment-id"]}],"insights":[{"type":"keyIdea|notableMoment|decision|actionItem|openQuestion","text":"...","owner":null,"deadline":null,"evidence":["segment-id"]}],"language_notes":[{"kind":"vocabulary|expression|grammar","term":"...","explanation":"...","source_excerpt":"...","evidence":["segment-id"]}]}

Candidates:
${jsonEncode(candidates)}
''';
  }

  String _renderSegment(
    TranscriptDocument document,
    TranscriptSegment segment,
  ) => _renderSegmentFromName(
    segment,
    speakerName: document.speakerName(segment.speaker),
  );

  String _renderSegmentFromName(
    TranscriptSegment segment, {
    String? speakerName,
  }) {
    final speaker = speakerName?.trim().isNotEmpty == true
        ? '[speaker=${speakerName!.trim()}]'
        : '';
    final language = segment.language?.trim().isNotEmpty == true
        ? '[language=${segment.language!.trim()}]'
        : '';
    return '[id=${segment.id}][${_clock(segment.startMs)}]$speaker$language '
        '${segment.text.trim()}';
  }

  String _learningInstructions({
    required Set<AiBriefSection> sections,
    required String? learningLanguage,
    required AiLearningLevel learningLevel,
    required bool synthesis,
  }) {
    if (!sections.contains(AiBriefSection.languageNotes)) {
      return 'Return language_notes as an empty array.';
    }
    final language = learningLanguage == null
        ? 'the dominant natural language in the transcript'
        : 'language code "$learningLanguage"';
    final count = synthesis
        ? 'Select 6–12 high-value notes overall, or fewer when the transcript '
              'does not support that many.'
        : 'Select only high-value candidates from this chunk; do not pad the '
              'result.';
    return '''
Language notes are requested for $language at ${learningLevel.name} level.
$count Balance vocabulary, reusable expressions, and grammar or usage when the evidence supports them.
Keep term and source_excerpt in the learned language. Write explanation in the requested output language using clear, professional, level-appropriate wording.
source_excerpt must be a short verbatim substring of a cited transcript segment. Do not assess pronunciation, fluency, or speaker correctness, and do not create quizzes, corrections, or invented examples.
''';
  }

  String? _resolvedLearningLanguage(
    TranscriptDocument document,
    String? override,
  ) {
    final selected = override?.trim();
    if (selected != null && selected.isNotEmpty) return selected;
    final weights = <String, int>{};
    for (final segment in document.segments) {
      final language = segment.language?.trim();
      if (language == null || language.isEmpty) continue;
      weights.update(
        language,
        (value) => value + segment.text.trim().length,
        ifAbsent: () => segment.text.trim().length,
      );
    }
    if (weights.isEmpty) return null;
    return weights.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  Future<Map<String, dynamic>> _completeJson({
    required LlmProviderSettings settings,
    required String prompt,
    CancelCheck? shouldCancel,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final response = await _llm.complete(
        settings: settings,
        systemPrompt: _systemPrompt,
        userPrompt: attempt == 0
            ? prompt
            : '$prompt\nYour previous response was not valid JSON. Return only '
                  'one valid JSON object matching the requested shape.',
        shouldCancel: shouldCancel,
      );
      try {
        return _decodeJsonObject(response);
      } on FormatException {
        if (attempt == 1) {
          throw const AiBriefException('ai_brief_invalid_response');
        }
      }
    }
    throw const AiBriefException('ai_brief_invalid_response');
  }

  Map<String, dynamic> _decodeJsonObject(String value) {
    var candidate = value.trim();
    if (candidate.startsWith('```')) {
      candidate = candidate
          .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
          .replaceFirst(RegExp(r'\s*```$'), '');
    }
    final start = candidate.indexOf('{');
    final end = candidate.lastIndexOf('}');
    if (start < 0 || end <= start) throw const FormatException();
    final decoded = jsonDecode(candidate.substring(start, end + 1));
    if (decoded is! Map) throw const FormatException();
    return decoded.cast<String, dynamic>();
  }

  AiBrief _validatedBrief(
    Map<String, dynamic> json, {
    required LlmProviderSettings settings,
    required TranscriptDocument document,
    required Set<AiBriefSection> sections,
    required String outputLanguage,
    required String? learningLanguage,
    required AiLearningLevel learningLevel,
  }) {
    final validIds = document.segments.map((item) => item.id).toSet();
    final overviewEvidence = _evidence(json['overview_evidence'], validIds);
    final overview =
        sections.contains(AiBriefSection.overview) &&
            overviewEvidence.isNotEmpty
        ? json['overview']?.toString().trim() ?? ''
        : '';
    final chapters = <AiChapter>[];
    if (sections.contains(AiBriefSection.chapters) &&
        json['chapters'] is List) {
      for (final item in (json['chapters'] as List).whereType<Map>()) {
        final evidence = _evidence(item['evidence'], validIds);
        final title = item['title']?.toString().trim() ?? '';
        if (evidence.isEmpty || title.isEmpty) continue;
        chapters.add(
          AiChapter(
            id: _generatedId('chapter', title, chapters.length),
            title: title,
            summary: item['summary']?.toString().trim() ?? '',
            evidenceSegmentIds: evidence,
          ),
        );
      }
    }
    final insights = <AiInsight>[];
    final seen = <String>{};
    if (json['insights'] is List) {
      for (final item in (json['insights'] as List).whereType<Map>()) {
        final type = _insightType(item['type']);
        if (type == null || !_sectionAllows(type, sections)) continue;
        final evidence = _evidence(item['evidence'], validIds);
        final content = item['text']?.toString().trim() ?? '';
        if (evidence.isEmpty || content.isEmpty) continue;
        final deduplicationKey = '${type.name}:${_normalize(content)}';
        if (!seen.add(deduplicationKey)) continue;
        insights.add(
          AiInsight(
            id: _generatedId(type.name, content, insights.length),
            type: type,
            text: content,
            owner: _supportedDetail(
              item['owner'],
              evidence,
              document,
              allowSpeakerName: true,
            ),
            deadline: _supportedDetail(item['deadline'], evidence, document),
            evidenceSegmentIds: evidence,
          ),
        );
      }
    }
    final languageNotes = <AiLanguageNote>[];
    final seenLanguageNotes = <String>{};
    if (sections.contains(AiBriefSection.languageNotes) &&
        json['language_notes'] is List) {
      for (final item in (json['language_notes'] as List).whereType<Map>()) {
        final kind = _languageNoteKind(item['kind']);
        if (kind == null) continue;
        final evidence = _evidence(item['evidence'], validIds);
        final term = item['term']?.toString().trim() ?? '';
        final explanation = item['explanation']?.toString().trim() ?? '';
        final sourceExcerpt = item['source_excerpt']?.toString().trim() ?? '';
        if (evidence.isEmpty ||
            term.isEmpty ||
            explanation.isEmpty ||
            sourceExcerpt.isEmpty ||
            !_excerptIsSupported(sourceExcerpt, evidence, document)) {
          continue;
        }
        final deduplicationKey = '${kind.name}:${_normalize(term)}';
        if (!seenLanguageNotes.add(deduplicationKey)) continue;
        languageNotes.add(
          AiLanguageNote(
            id: _generatedId(
              'language-${kind.name}',
              term,
              languageNotes.length,
            ),
            kind: kind,
            term: term,
            explanation: explanation,
            sourceExcerpt: sourceExcerpt,
            evidenceSegmentIds: evidence,
          ),
        );
        if (languageNotes.length == 12) break;
      }
    }
    if (overview.isEmpty &&
        chapters.isEmpty &&
        insights.isEmpty &&
        languageNotes.isEmpty) {
      throw const AiBriefException('ai_brief_no_supported_content');
    }
    return AiBrief(
      overview: overview,
      overviewEvidenceSegmentIds: overviewEvidence,
      chapters: chapters,
      insights: insights,
      languageNotes: languageNotes,
      learningLanguage: learningLanguage,
      learningLevel: learningLevel,
      outputLanguage: outputLanguage,
      model: settings.model.trim(),
      selectedSections: Set<AiBriefSection>.of(sections),
      generatedAt: DateTime.now().toUtc(),
      sourceTranscriptUpdatedAt: document.updatedAt,
    );
  }

  List<String> _evidence(dynamic value, Set<String> validIds) => value is List
      ? value
            .map((item) => item.toString())
            .where(validIds.contains)
            .toSet()
            .toList(growable: false)
      : const [];

  AiInsightType? _insightType(dynamic value) => switch (value?.toString()) {
    'keyIdea' => AiInsightType.keyIdea,
    'notableMoment' => AiInsightType.notableMoment,
    'decision' => AiInsightType.decision,
    'actionItem' => AiInsightType.actionItem,
    'openQuestion' => AiInsightType.openQuestion,
    _ => null,
  };

  AiLanguageNoteKind? _languageNoteKind(dynamic value) =>
      switch (value?.toString()) {
        'vocabulary' => AiLanguageNoteKind.vocabulary,
        'expression' => AiLanguageNoteKind.expression,
        'grammar' => AiLanguageNoteKind.grammar,
        _ => null,
      };

  bool _excerptIsSupported(
    String excerpt,
    List<String> evidence,
    TranscriptDocument document,
  ) {
    final byId = {for (final segment in document.segments) segment.id: segment};
    return evidence.any((id) => byId[id]?.text.contains(excerpt) ?? false);
  }

  bool _sectionAllows(AiInsightType type, Set<AiBriefSection> sections) =>
      switch (type) {
        AiInsightType.keyIdea || AiInsightType.notableMoment =>
          sections.contains(AiBriefSection.keyIdeas),
        AiInsightType.decision => sections.contains(AiBriefSection.decisions),
        AiInsightType.actionItem => sections.contains(
          AiBriefSection.actionItems,
        ),
        AiInsightType.openQuestion => sections.contains(
          AiBriefSection.openQuestions,
        ),
      };

  String? _optionalText(dynamic value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty || text.toLowerCase() == 'null'
        ? null
        : text;
  }

  String? _supportedDetail(
    dynamic value,
    List<String> evidence,
    TranscriptDocument document, {
    bool allowSpeakerName = false,
  }) {
    final detail = _optionalText(value);
    if (detail == null) return null;
    final normalized = _normalize(detail);
    final byId = {for (final segment in document.segments) segment.id: segment};
    for (final id in evidence) {
      final segment = byId[id];
      if (segment == null) continue;
      if (_normalize(segment.text).contains(normalized)) return detail;
      if (allowSpeakerName &&
          _normalize(document.speakerName(segment.speaker)) == normalized) {
        return detail;
      }
    }
    return null;
  }

  String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  String _generatedId(String prefix, String value, int index) {
    final hash = _normalize(value).hashCode.toUnsigned(32).toRadixString(16);
    return '$prefix-$hash-$index';
  }

  String _clock(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    return hours > 0
        ? '${hours.toString().padLeft(2, '0')}:'
              '${minutes.toString().padLeft(2, '0')}:'
              '${seconds.toString().padLeft(2, '0')}'
        : '${minutes.toString().padLeft(2, '0')}:'
              '${seconds.toString().padLeft(2, '0')}';
  }

  void _checkCancelled(CancelCheck? shouldCancel) {
    if (shouldCancel?.call() ?? false) {
      throw const OperationCancelledException();
    }
  }
}
