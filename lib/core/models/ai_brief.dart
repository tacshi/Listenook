import 'json.dart';
import 'transcript.dart';

enum AiBriefSection {
  overview,
  chapters,
  keyIdeas,
  decisions,
  actionItems,
  openQuestions,
  languageNotes,
}

const defaultAiBriefSections = <AiBriefSection>{
  AiBriefSection.overview,
  AiBriefSection.chapters,
  AiBriefSection.keyIdeas,
  AiBriefSection.decisions,
  AiBriefSection.actionItems,
  AiBriefSection.openQuestions,
};

enum AiInsightType {
  keyIdea,
  notableMoment,
  decision,
  actionItem,
  openQuestion,
}

enum AiLearningLevel { beginner, intermediate, advanced }

enum AiLanguageNoteKind { vocabulary, expression, grammar }

enum AiGenerationStatus {
  idle,
  generating,
  completed,
  failed,
  cancelled,
  interrupted,
}

extension AiGenerationStatusX on AiGenerationStatus {
  bool get isActive => this == AiGenerationStatus.generating;
  bool get canRetry =>
      this == AiGenerationStatus.failed ||
      this == AiGenerationStatus.cancelled ||
      this == AiGenerationStatus.interrupted;
}

class AiChapter {
  const AiChapter({
    required this.id,
    required this.title,
    required this.summary,
    required this.evidenceSegmentIds,
    this.edited = false,
  });

  final String id;
  final String title;
  final String summary;
  final List<String> evidenceSegmentIds;
  final bool edited;

  AiChapter copyWith({
    String? title,
    String? summary,
    List<String>? evidenceSegmentIds,
    bool? edited,
  }) => AiChapter(
    id: id,
    title: title ?? this.title,
    summary: summary ?? this.summary,
    evidenceSegmentIds: evidenceSegmentIds ?? this.evidenceSegmentIds,
    edited: edited ?? this.edited,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'summary': summary,
    'evidence_segment_ids': evidenceSegmentIds,
    'edited': edited,
  };

  factory AiChapter.fromJson(Map<String, dynamic> json) => AiChapter(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    summary: json['summary'] as String? ?? '',
    evidenceSegmentIds: jsonStrings(json['evidence_segment_ids']),
    edited: json['edited'] as bool? ?? false,
  );
}

class AiInsight {
  const AiInsight({
    required this.id,
    required this.type,
    required this.text,
    required this.evidenceSegmentIds,
    this.owner,
    this.deadline,
    this.edited = false,
  });

  final String id;
  final AiInsightType type;
  final String text;
  final String? owner;
  final String? deadline;
  final List<String> evidenceSegmentIds;
  final bool edited;

  AiInsight copyWith({
    String? text,
    String? owner,
    String? deadline,
    List<String>? evidenceSegmentIds,
    bool? edited,
    bool clearOwner = false,
    bool clearDeadline = false,
  }) => AiInsight(
    id: id,
    type: type,
    text: text ?? this.text,
    owner: clearOwner ? null : owner ?? this.owner,
    deadline: clearDeadline ? null : deadline ?? this.deadline,
    evidenceSegmentIds: evidenceSegmentIds ?? this.evidenceSegmentIds,
    edited: edited ?? this.edited,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'text': text,
    if (owner case final value?) 'owner': value,
    if (deadline case final value?) 'deadline': value,
    'evidence_segment_ids': evidenceSegmentIds,
    'edited': edited,
  };

  factory AiInsight.fromJson(Map<String, dynamic> json) => AiInsight(
    id: json['id'] as String? ?? '',
    type:
        enumByName(AiInsightType.values, json['type']) ?? AiInsightType.keyIdea,
    text: json['text'] as String? ?? '',
    owner: json['owner'] as String?,
    deadline: json['deadline'] as String?,
    evidenceSegmentIds: jsonStrings(json['evidence_segment_ids']),
    edited: json['edited'] as bool? ?? false,
  );
}

class AiLanguageNote {
  const AiLanguageNote({
    required this.id,
    required this.kind,
    required this.term,
    required this.explanation,
    required this.sourceExcerpt,
    required this.evidenceSegmentIds,
    this.edited = false,
  });

  final String id;
  final AiLanguageNoteKind kind;
  final String term;
  final String explanation;
  final String sourceExcerpt;
  final List<String> evidenceSegmentIds;
  final bool edited;

  AiLanguageNote copyWith({
    String? term,
    String? explanation,
    String? sourceExcerpt,
    List<String>? evidenceSegmentIds,
    bool? edited,
  }) => AiLanguageNote(
    id: id,
    kind: kind,
    term: term ?? this.term,
    explanation: explanation ?? this.explanation,
    sourceExcerpt: sourceExcerpt ?? this.sourceExcerpt,
    evidenceSegmentIds: evidenceSegmentIds ?? this.evidenceSegmentIds,
    edited: edited ?? this.edited,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'term': term,
    'explanation': explanation,
    'source_excerpt': sourceExcerpt,
    'evidence_segment_ids': evidenceSegmentIds,
    'edited': edited,
  };

  factory AiLanguageNote.fromJson(Map<String, dynamic> json) => AiLanguageNote(
    id: json['id'] as String? ?? '',
    kind:
        enumByName(AiLanguageNoteKind.values, json['kind']) ??
        AiLanguageNoteKind.vocabulary,
    term: json['term'] as String? ?? '',
    explanation: json['explanation'] as String? ?? '',
    sourceExcerpt: json['source_excerpt'] as String? ?? '',
    evidenceSegmentIds: jsonStrings(json['evidence_segment_ids']),
    edited: json['edited'] as bool? ?? false,
  );
}

class AiBrief {
  const AiBrief({
    required this.overview,
    this.overviewEvidenceSegmentIds = const [],
    required this.chapters,
    required this.insights,
    this.languageNotes = const [],
    this.learningLanguage,
    this.learningLevel = AiLearningLevel.intermediate,
    required this.outputLanguage,
    required this.model,
    required this.selectedSections,
    required this.generatedAt,
    required this.sourceTranscriptUpdatedAt,
    this.edited = false,
  });

  final String overview;
  final List<String> overviewEvidenceSegmentIds;
  final List<AiChapter> chapters;
  final List<AiInsight> insights;
  final List<AiLanguageNote> languageNotes;
  final String? learningLanguage;
  final AiLearningLevel learningLevel;
  final String outputLanguage;
  final String model;
  final Set<AiBriefSection> selectedSections;
  final DateTime generatedAt;
  final DateTime sourceTranscriptUpdatedAt;
  final bool edited;

  bool isStaleFor(TranscriptDocument document) =>
      document.updatedAt.isAfter(sourceTranscriptUpdatedAt);

  AiBrief copyWith({
    String? overview,
    List<String>? overviewEvidenceSegmentIds,
    List<AiChapter>? chapters,
    List<AiInsight>? insights,
    List<AiLanguageNote>? languageNotes,
    String? learningLanguage,
    AiLearningLevel? learningLevel,
    bool? edited,
    bool clearLearningLanguage = false,
  }) => AiBrief(
    overview: overview ?? this.overview,
    overviewEvidenceSegmentIds:
        overviewEvidenceSegmentIds ?? this.overviewEvidenceSegmentIds,
    chapters: chapters ?? this.chapters,
    insights: insights ?? this.insights,
    languageNotes: languageNotes ?? this.languageNotes,
    learningLanguage: clearLearningLanguage
        ? null
        : learningLanguage ?? this.learningLanguage,
    learningLevel: learningLevel ?? this.learningLevel,
    outputLanguage: outputLanguage,
    model: model,
    selectedSections: selectedSections,
    generatedAt: generatedAt,
    sourceTranscriptUpdatedAt: sourceTranscriptUpdatedAt,
    edited: edited ?? this.edited,
  );

  Map<String, dynamic> toJson() => {
    'overview': overview,
    'overview_evidence_segment_ids': overviewEvidenceSegmentIds,
    'chapters': chapters.map((item) => item.toJson()).toList(),
    'insights': insights.map((item) => item.toJson()).toList(),
    'language_notes': languageNotes.map((item) => item.toJson()).toList(),
    if (learningLanguage case final value?) 'learning_language': value,
    'learning_level': learningLevel.name,
    'output_language': outputLanguage,
    'model': model,
    'selected_sections': selectedSections.map((item) => item.name).toList(),
    'generated_at': generatedAt.toIso8601String(),
    'source_transcript_updated_at': sourceTranscriptUpdatedAt.toIso8601String(),
    'edited': edited,
  };

  factory AiBrief.fromJson(Map<String, dynamic> json) => AiBrief(
    overview: json['overview'] as String? ?? '',
    overviewEvidenceSegmentIds: jsonStrings(
      json['overview_evidence_segment_ids'],
    ),
    chapters: mapJsonList(json['chapters'], AiChapter.fromJson),
    insights: mapJsonList(json['insights'], AiInsight.fromJson),
    languageNotes: mapJsonList(json['language_notes'], AiLanguageNote.fromJson),
    learningLanguage: json['learning_language'] as String?,
    learningLevel:
        enumByName(AiLearningLevel.values, json['learning_level']) ??
        AiLearningLevel.intermediate,
    outputLanguage: json['output_language'] as String? ?? 'en',
    model: json['model'] as String? ?? '',
    selectedSections: enumSetFromJson(
      AiBriefSection.values,
      json['selected_sections'],
      fallback: defaultAiBriefSections,
    ),
    generatedAt: dateFromJson(json['generated_at']) ?? DateTime.now().toUtc(),
    sourceTranscriptUpdatedAt:
        dateFromJson(json['source_transcript_updated_at']) ??
        DateTime.now().toUtc(),
    edited: json['edited'] as bool? ?? false,
  );
}

class AiGenerationState {
  const AiGenerationState({
    this.status = AiGenerationStatus.idle,
    this.stage = '',
    this.completedChunks = 0,
    this.totalChunks = 0,
    this.outputLanguage = '',
    this.learningLanguage,
    this.learningLevel = AiLearningLevel.intermediate,
    this.model = '',
    this.selectedSections = const {},
    this.mergeSections = false,
    this.errorCode,
    this.errorMessage,
  });

  final AiGenerationStatus status;
  final String stage;
  final int completedChunks;
  final int totalChunks;
  final String outputLanguage;
  final String? learningLanguage;
  final AiLearningLevel learningLevel;
  final String model;
  final Set<AiBriefSection> selectedSections;
  final bool mergeSections;
  final String? errorCode;
  final String? errorMessage;

  double get progress => totalChunks == 0 ? 0 : completedChunks / totalChunks;

  AiGenerationState copyWith({
    AiGenerationStatus? status,
    String? stage,
    int? completedChunks,
    int? totalChunks,
    String? outputLanguage,
    String? learningLanguage,
    AiLearningLevel? learningLevel,
    String? model,
    Set<AiBriefSection>? selectedSections,
    bool? mergeSections,
    String? errorCode,
    String? errorMessage,
    bool clearError = false,
    bool clearLearningLanguage = false,
  }) => AiGenerationState(
    status: status ?? this.status,
    stage: stage ?? this.stage,
    completedChunks: completedChunks ?? this.completedChunks,
    totalChunks: totalChunks ?? this.totalChunks,
    outputLanguage: outputLanguage ?? this.outputLanguage,
    learningLanguage: clearLearningLanguage
        ? null
        : learningLanguage ?? this.learningLanguage,
    learningLevel: learningLevel ?? this.learningLevel,
    model: model ?? this.model,
    selectedSections: selectedSections ?? this.selectedSections,
    mergeSections: mergeSections ?? this.mergeSections,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );

  Map<String, dynamic> toJson() => {
    'status': status.name,
    'stage': stage,
    'completed_chunks': completedChunks,
    'total_chunks': totalChunks,
    'output_language': outputLanguage,
    if (learningLanguage case final value?) 'learning_language': value,
    'learning_level': learningLevel.name,
    'model': model,
    'selected_sections': selectedSections.map((item) => item.name).toList(),
    'merge_sections': mergeSections,
    if (errorCode case final value?) 'error_code': value,
    if (errorMessage case final value?) 'error_message': value,
  };

  factory AiGenerationState.fromJson(Map<String, dynamic>? json) =>
      AiGenerationState(
        status:
            enumByName(AiGenerationStatus.values, json?['status']) ??
            AiGenerationStatus.idle,
        stage: json?['stage'] as String? ?? '',
        completedChunks: (json?['completed_chunks'] as num?)?.toInt() ?? 0,
        totalChunks: (json?['total_chunks'] as num?)?.toInt() ?? 0,
        outputLanguage: json?['output_language'] as String? ?? '',
        learningLanguage: json?['learning_language'] as String?,
        learningLevel:
            enumByName(AiLearningLevel.values, json?['learning_level']) ??
            AiLearningLevel.intermediate,
        model: json?['model'] as String? ?? '',
        selectedSections: enumSetFromJson(
          AiBriefSection.values,
          json?['selected_sections'],
          fallback: const {},
        ),
        mergeSections: json?['merge_sections'] as bool? ?? false,
        errorCode: json?['error_code'] as String?,
        errorMessage: json?['error_message'] as String?,
      );
}
