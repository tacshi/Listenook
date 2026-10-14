import 'json.dart';

enum TranscriptSource {
  soniox,
  mossPro,
  mossLocal,
  publisher,
  qwen3Local,
  importedSubtitle,
}

enum SubtitleFormat { srt, webVtt, ass, movText }

extension SubtitleFormatX on SubtitleFormat {
  String get label => switch (this) {
    SubtitleFormat.srt => 'SRT',
    SubtitleFormat.webVtt => 'WebVTT',
    SubtitleFormat.ass => 'ASS',
    SubtitleFormat.movText => 'MP4 text',
  };
}

class MediaMetadata {
  const MediaMetadata({
    required this.sizeBytes,
    required this.durationMs,
    required this.hasAudio,
    required this.hasVideo,
    required this.formatName,
    this.audioCodec,
    this.videoCodec,
  });

  final int sizeBytes;
  final int durationMs;
  final bool hasAudio;
  final bool hasVideo;
  final String formatName;
  final String? audioCodec;
  final String? videoCodec;

  Map<String, dynamic> toJson() => {
    'size_bytes': sizeBytes,
    'duration_ms': durationMs,
    'has_audio': hasAudio,
    'has_video': hasVideo,
    'format_name': formatName,
    if (audioCodec case final value?) 'audio_codec': value,
    if (videoCodec case final value?) 'video_codec': value,
  };

  factory MediaMetadata.fromJson(Map<String, dynamic> json) => MediaMetadata(
    sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
    durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
    hasAudio: json['has_audio'] as bool? ?? false,
    hasVideo: json['has_video'] as bool? ?? false,
    formatName: json['format_name'] as String? ?? 'unknown',
    audioCodec: json['audio_codec'] as String?,
    videoCodec: json['video_codec'] as String?,
  );
}

class TranscriptToken {
  const TranscriptToken({
    required this.text,
    required this.startMs,
    required this.endMs,
    this.segmentId,
    this.speaker,
    this.language,
    this.confidence,
    this.translationStatus,
    this.sourceLanguage,
  });

  final String text;
  final int startMs;
  final int endMs;
  final String? segmentId;
  final String? speaker;
  final String? language;
  final double? confidence;
  final String? translationStatus;
  final String? sourceLanguage;

  Map<String, dynamic> toJson() => {
    'text': text,
    'start_ms': startMs,
    'end_ms': endMs,
    if (segmentId case final value?) 'segment_id': value,
    if (speaker case final value?) 'speaker': value,
    if (language case final value?) 'language': value,
    if (confidence case final value?) 'confidence': value,
    if (translationStatus case final value?) 'translation_status': value,
    if (sourceLanguage case final value?) 'source_language': value,
  };

  factory TranscriptToken.fromJson(Map<String, dynamic> json) =>
      TranscriptToken(
        text: json['text'] as String? ?? '',
        startMs: (json['start_ms'] as num?)?.toInt() ?? 0,
        endMs: (json['end_ms'] as num?)?.toInt() ?? 0,
        segmentId: json['segment_id'] as String?,
        speaker: json['speaker']?.toString(),
        language: json['language'] as String?,
        confidence: (json['confidence'] as num?)?.toDouble(),
        translationStatus: json['translation_status'] as String?,
        sourceLanguage: json['source_language'] as String?,
      );
}

class TranscriptSegment {
  const TranscriptSegment({
    required this.id,
    required this.startMs,
    required this.endMs,
    required this.text,
    this.speaker,
    this.language,
    this.translatedText,
    this.preserveBoundaryBefore = false,
  });

  final String id;
  final int startMs;
  final int endMs;
  final String text;
  final String? speaker;
  final String? language;
  final String? translatedText;
  final bool preserveBoundaryBefore;

  bool get hasTranslation => translatedText?.trim().isNotEmpty ?? false;

  TranscriptSegment copyWith({
    int? startMs,
    int? endMs,
    String? text,
    String? speaker,
    String? language,
    String? translatedText,
    bool clearTranslatedText = false,
    bool? preserveBoundaryBefore,
  }) => TranscriptSegment(
    id: id,
    startMs: startMs ?? this.startMs,
    endMs: endMs ?? this.endMs,
    text: text ?? this.text,
    speaker: speaker ?? this.speaker,
    language: language ?? this.language,
    translatedText: clearTranslatedText
        ? null
        : translatedText ?? this.translatedText,
    preserveBoundaryBefore:
        preserveBoundaryBefore ?? this.preserveBoundaryBefore,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'start_ms': startMs,
    'end_ms': endMs,
    'text': text,
    if (speaker case final value?) 'speaker': value,
    if (language case final value?) 'language': value,
    if (translatedText case final value?) 'translated_text': value,
    if (preserveBoundaryBefore) 'preserve_boundary_before': true,
  };

  factory TranscriptSegment.fromJson(Map<String, dynamic> json) =>
      TranscriptSegment(
        id: json['id'] as String? ?? '${json['start_ms'] ?? 0}',
        startMs: (json['start_ms'] as num?)?.toInt() ?? 0,
        endMs: (json['end_ms'] as num?)?.toInt() ?? 0,
        text: json['text'] as String? ?? '',
        speaker: json['speaker']?.toString(),
        language: json['language'] as String?,
        translatedText: json['translated_text'] as String?,
        preserveBoundaryBefore:
            json['preserve_boundary_before'] as bool? ?? false,
      );
}

class SpeakerProfile {
  const SpeakerProfile({required this.id, required this.name});
  final String id;
  final String name;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
  factory SpeakerProfile.fromJson(Map<String, dynamic> json) => SpeakerProfile(
    id: json['id'].toString(),
    name: json['name'] as String? ?? 'Speaker ${json['id']}',
  );
}

class TranscriptDocument {
  const TranscriptDocument({
    required this.tokens,
    required this.segments,
    required this.speakers,
    required this.updatedAt,
  });

  final List<TranscriptToken> tokens;
  final List<TranscriptSegment> segments;
  final List<SpeakerProfile> speakers;
  final DateTime updatedAt;

  String speakerName(String? id) {
    if (id == null || id.isEmpty) return '';
    return speakers
            .where((profile) => profile.id == id)
            .map((profile) => profile.name)
            .firstOrNull ??
        'Speaker $id';
  }

  TranscriptDocument copyWith({
    List<TranscriptToken>? tokens,
    List<TranscriptSegment>? segments,
    List<SpeakerProfile>? speakers,
    bool preserveUpdatedAt = false,
  }) => TranscriptDocument(
    tokens: tokens ?? this.tokens,
    segments: segments ?? this.segments,
    speakers: speakers ?? this.speakers,
    updatedAt: preserveUpdatedAt ? updatedAt : DateTime.now().toUtc(),
  );

  Map<String, dynamic> toJson() => {
    'tokens': tokens.map((item) => item.toJson()).toList(),
    'segments': segments.map((item) => item.toJson()).toList(),
    'speakers': speakers.map((item) => item.toJson()).toList(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory TranscriptDocument.fromJson(Map<String, dynamic> json) =>
      TranscriptDocument(
        tokens: mapJsonList(json['tokens'], TranscriptToken.fromJson),
        segments: mapJsonList(json['segments'], TranscriptSegment.fromJson),
        speakers: mapJsonList(json['speakers'], SpeakerProfile.fromJson),
        updatedAt: dateFromJson(json['updated_at']) ?? DateTime.now().toUtc(),
      );
}
