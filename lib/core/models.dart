import 'dart:convert';

const int manifestVersion = 1;
const int maxMediaDurationMs = 300 * 60 * 1000;

enum JobStatus {
  pending,
  probing,
  ready,
  converting,
  uploading,
  queuedRemote,
  processing,
  fetching,
  completed,
  empty,
  failed,
  cancelled,
  missingSource,
  paused,
}

extension JobStatusX on JobStatus {
  bool get isActive => switch (this) {
    JobStatus.probing ||
    JobStatus.converting ||
    JobStatus.uploading ||
    JobStatus.queuedRemote ||
    JobStatus.processing ||
    JobStatus.fetching => true,
    _ => false,
  };

  bool get isTerminal => switch (this) {
    JobStatus.completed ||
    JobStatus.empty ||
    JobStatus.failed ||
    JobStatus.cancelled ||
    JobStatus.missingSource => true,
    _ => false,
  };

  bool get canTranscribe => this == JobStatus.ready || this == JobStatus.paused;
  bool get canRetry =>
      this == JobStatus.failed ||
      this == JobStatus.cancelled ||
      this == JobStatus.missingSource ||
      this == JobStatus.empty;
}

enum ExportFormat { txt, markdown, srt, webVtt }

enum AppThemeMode { system, light, dark }

enum AppLocaleMode { system, english, simplifiedChinese }

enum CleanupState { none, pending, complete }

class JobProgress {
  const JobProgress({required this.stage, this.fraction, this.detail});

  const JobProgress.idle() : this(stage: 'pending');

  final String stage;
  final double? fraction;
  final String? detail;

  Map<String, dynamic> toJson() => {
    'stage': stage,
    if (fraction case final value?) 'fraction': value,
    if (detail case final value?) 'detail': value,
  };

  factory JobProgress.fromJson(Map<String, dynamic>? json) => JobProgress(
    stage: json?['stage'] as String? ?? 'pending',
    fraction: (json?['fraction'] as num?)?.toDouble(),
    detail: json?['detail'] as String?,
  );
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
    this.speaker,
    this.language,
    this.confidence,
  });

  final String text;
  final int startMs;
  final int endMs;
  final String? speaker;
  final String? language;
  final double? confidence;

  Map<String, dynamic> toJson() => {
    'text': text,
    'start_ms': startMs,
    'end_ms': endMs,
    if (speaker case final value?) 'speaker': value,
    if (language case final value?) 'language': value,
    if (confidence case final value?) 'confidence': value,
  };

  factory TranscriptToken.fromJson(Map<String, dynamic> json) =>
      TranscriptToken(
        text: json['text'] as String? ?? '',
        startMs: (json['start_ms'] as num?)?.toInt() ?? 0,
        endMs: (json['end_ms'] as num?)?.toInt() ?? 0,
        speaker: json['speaker']?.toString(),
        language: json['language'] as String?,
        confidence: (json['confidence'] as num?)?.toDouble(),
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
  });

  final String id;
  final int startMs;
  final int endMs;
  final String text;
  final String? speaker;
  final String? language;

  TranscriptSegment copyWith({
    String? text,
    String? speaker,
    String? language,
  }) => TranscriptSegment(
    id: id,
    startMs: startMs,
    endMs: endMs,
    text: text ?? this.text,
    speaker: speaker ?? this.speaker,
    language: language ?? this.language,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'start_ms': startMs,
    'end_ms': endMs,
    'text': text,
    if (speaker case final value?) 'speaker': value,
    if (language case final value?) 'language': value,
  };

  factory TranscriptSegment.fromJson(Map<String, dynamic> json) =>
      TranscriptSegment(
        id: json['id'] as String? ?? '${json['start_ms'] ?? 0}',
        startMs: (json['start_ms'] as num?)?.toInt() ?? 0,
        endMs: (json['end_ms'] as num?)?.toInt() ?? 0,
        text: json['text'] as String? ?? '',
        speaker: json['speaker']?.toString(),
        language: json['language'] as String?,
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
    List<TranscriptSegment>? segments,
    List<SpeakerProfile>? speakers,
  }) => TranscriptDocument(
    tokens: tokens,
    segments: segments ?? this.segments,
    speakers: speakers ?? this.speakers,
    updatedAt: DateTime.now().toUtc(),
  );

  Map<String, dynamic> toJson() => {
    'tokens': tokens.map((item) => item.toJson()).toList(),
    'segments': segments.map((item) => item.toJson()).toList(),
    'speakers': speakers.map((item) => item.toJson()).toList(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory TranscriptDocument.fromJson(Map<String, dynamic> json) =>
      TranscriptDocument(
        tokens: _mapList(json['tokens'], TranscriptToken.fromJson),
        segments: _mapList(json['segments'], TranscriptSegment.fromJson),
        speakers: _mapList(json['speakers'], SpeakerProfile.fromJson),
        updatedAt: _date(json['updated_at']) ?? DateTime.now().toUtc(),
      );
}

class TranscriptionOptions {
  const TranscriptionOptions({
    this.languageHints = const [],
    this.contextTerms = const [],
  });

  final List<String> languageHints;
  final List<String> contextTerms;

  TranscriptionOptions copyWith({
    List<String>? languageHints,
    List<String>? contextTerms,
  }) => TranscriptionOptions(
    languageHints: languageHints ?? this.languageHints,
    contextTerms: contextTerms ?? this.contextTerms,
  );

  Map<String, dynamic> toJson() => {
    'language_hints': languageHints,
    'context_terms': contextTerms,
    'enable_speaker_diarization': true,
    'enable_language_identification': true,
  };

  factory TranscriptionOptions.fromJson(Map<String, dynamic>? json) =>
      TranscriptionOptions(
        languageHints: _strings(json?['language_hints']),
        contextTerms: _strings(json?['context_terms']),
      );
}

class ExportOptions {
  const ExportOptions({
    this.format = ExportFormat.txt,
    this.showSpeakers = true,
    this.showTimestamps = false,
    this.localeCode = 'en',
  });

  final ExportFormat format;
  final bool showSpeakers;
  final bool showTimestamps;
  final String localeCode;

  ExportOptions copyWith({
    ExportFormat? format,
    bool? showSpeakers,
    bool? showTimestamps,
    String? localeCode,
  }) => ExportOptions(
    format: format ?? this.format,
    showSpeakers: showSpeakers ?? this.showSpeakers,
    showTimestamps: showTimestamps ?? this.showTimestamps,
    localeCode: localeCode ?? this.localeCode,
  );

  Map<String, dynamic> toJson() => {
    'format': format.name,
    'show_speakers': showSpeakers,
    'show_timestamps': showTimestamps,
    'locale_code': localeCode,
  };

  factory ExportOptions.fromJson(Map<String, dynamic>? json) => ExportOptions(
    format:
        _enumByName(ExportFormat.values, json?['format']) ?? ExportFormat.txt,
    showSpeakers: json?['show_speakers'] as bool? ?? true,
    showTimestamps: json?['show_timestamps'] as bool? ?? false,
    localeCode: json?['locale_code'] as String? ?? 'en',
  );
}

class AppSettings {
  const AppSettings({
    this.themeMode = AppThemeMode.system,
    this.localeMode = AppLocaleMode.system,
    this.concurrency = 2,
    this.showSpeakers = true,
    this.showTimestamps = false,
    this.exportOptions = const ExportOptions(),
    this.onboardingComplete = false,
    this.ffmpegOverride,
  });

  final AppThemeMode themeMode;
  final AppLocaleMode localeMode;
  final int concurrency;
  final bool showSpeakers;
  final bool showTimestamps;
  final ExportOptions exportOptions;
  final bool onboardingComplete;
  final String? ffmpegOverride;

  AppSettings copyWith({
    AppThemeMode? themeMode,
    AppLocaleMode? localeMode,
    int? concurrency,
    bool? showSpeakers,
    bool? showTimestamps,
    ExportOptions? exportOptions,
    bool? onboardingComplete,
    String? ffmpegOverride,
    bool clearFfmpegOverride = false,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    localeMode: localeMode ?? this.localeMode,
    concurrency: (concurrency ?? this.concurrency).clamp(1, 4),
    showSpeakers: showSpeakers ?? this.showSpeakers,
    showTimestamps: showTimestamps ?? this.showTimestamps,
    exportOptions: exportOptions ?? this.exportOptions,
    onboardingComplete: onboardingComplete ?? this.onboardingComplete,
    ffmpegOverride: clearFfmpegOverride
        ? null
        : ffmpegOverride ?? this.ffmpegOverride,
  );

  Map<String, dynamic> toJson() => {
    'manifest_version': manifestVersion,
    'theme_mode': themeMode.name,
    'locale_mode': localeMode.name,
    'concurrency': concurrency,
    'show_speakers': showSpeakers,
    'show_timestamps': showTimestamps,
    'export_options': exportOptions.toJson(),
    'onboarding_complete': onboardingComplete,
    if (ffmpegOverride case final value?) 'ffmpeg_override': value,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
    themeMode:
        _enumByName(AppThemeMode.values, json['theme_mode']) ??
        AppThemeMode.system,
    localeMode:
        _enumByName(AppLocaleMode.values, json['locale_mode']) ??
        AppLocaleMode.system,
    concurrency: ((json['concurrency'] as num?)?.toInt() ?? 2).clamp(1, 4),
    showSpeakers: json['show_speakers'] as bool? ?? true,
    showTimestamps: json['show_timestamps'] as bool? ?? false,
    exportOptions: ExportOptions.fromJson(
      (json['export_options'] as Map?)?.cast<String, dynamic>(),
    ),
    onboardingComplete: json['onboarding_complete'] as bool? ?? false,
    ffmpegOverride: json['ffmpeg_override'] as String?,
  );
}

class TranscriptionJob {
  const TranscriptionJob({
    required this.id,
    required this.batchId,
    required this.sourcePath,
    required this.createdAt,
    required this.updatedAt,
    required this.status,
    this.queueIndex = 0,
    this.progress = const JobProgress.idle(),
    this.metadata,
    this.options = const TranscriptionOptions(),
    this.document,
    this.errorCode,
    this.errorMessage,
    this.remoteFileId,
    this.remoteTranscriptionId,
    this.cleanupState = CleanupState.none,
  });

  final String id;
  final String batchId;
  final String sourcePath;
  final DateTime createdAt;
  final DateTime updatedAt;
  final JobStatus status;
  final int queueIndex;
  final JobProgress progress;
  final MediaMetadata? metadata;
  final TranscriptionOptions options;
  final TranscriptDocument? document;
  final String? errorCode;
  final String? errorMessage;
  final String? remoteFileId;
  final String? remoteTranscriptionId;
  final CleanupState cleanupState;

  String get fileName => sourcePath.replaceAll('\\', '/').split('/').last;

  TranscriptionJob copyWith({
    String? sourcePath,
    JobStatus? status,
    int? queueIndex,
    JobProgress? progress,
    MediaMetadata? metadata,
    TranscriptionOptions? options,
    TranscriptDocument? document,
    String? errorCode,
    String? errorMessage,
    String? remoteFileId,
    String? remoteTranscriptionId,
    CleanupState? cleanupState,
    bool clearError = false,
    bool clearRemoteFileId = false,
    bool clearRemoteTranscriptionId = false,
  }) => TranscriptionJob(
    id: id,
    batchId: batchId,
    sourcePath: sourcePath ?? this.sourcePath,
    createdAt: createdAt,
    updatedAt: DateTime.now().toUtc(),
    status: status ?? this.status,
    queueIndex: queueIndex ?? this.queueIndex,
    progress: progress ?? this.progress,
    metadata: metadata ?? this.metadata,
    options: options ?? this.options,
    document: document ?? this.document,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    remoteFileId: clearRemoteFileId ? null : remoteFileId ?? this.remoteFileId,
    remoteTranscriptionId: clearRemoteTranscriptionId
        ? null
        : remoteTranscriptionId ?? this.remoteTranscriptionId,
    cleanupState: cleanupState ?? this.cleanupState,
  );

  Map<String, dynamic> toJson() => {
    'manifest_version': manifestVersion,
    'id': id,
    'batch_id': batchId,
    'source_path': sourcePath,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'status': status.name,
    'queue_index': queueIndex,
    'progress': progress.toJson(),
    if (metadata case final value?) 'metadata': value.toJson(),
    'options': options.toJson(),
    if (document case final value?) 'document': value.toJson(),
    if (errorCode case final value?) 'error_code': value,
    if (errorMessage case final value?) 'error_message': value,
    if (remoteFileId case final value?) 'remote_file_id': value,
    if (remoteTranscriptionId case final value?)
      'remote_transcription_id': value,
    'cleanup_state': cleanupState.name,
  };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory TranscriptionJob.fromJson(Map<String, dynamic> json) {
    final status =
        _enumByName(JobStatus.values, json['status']) ?? JobStatus.pending;
    return TranscriptionJob(
      id: json['id'] as String,
      batchId: json['batch_id'] as String? ?? 'recovered',
      sourcePath: json['source_path'] as String,
      createdAt: _date(json['created_at']) ?? DateTime.now().toUtc(),
      updatedAt: _date(json['updated_at']) ?? DateTime.now().toUtc(),
      status: status,
      queueIndex: (json['queue_index'] as num?)?.toInt() ?? 0,
      progress: JobProgress.fromJson(
        (json['progress'] as Map?)?.cast<String, dynamic>(),
      ),
      metadata: json['metadata'] is Map
          ? MediaMetadata.fromJson(
              (json['metadata'] as Map).cast<String, dynamic>(),
            )
          : null,
      options: TranscriptionOptions.fromJson(
        (json['options'] as Map?)?.cast<String, dynamic>(),
      ),
      document: json['document'] is Map
          ? TranscriptDocument.fromJson(
              (json['document'] as Map).cast<String, dynamic>(),
            )
          : null,
      errorCode: json['error_code'] as String?,
      errorMessage: json['error_message'] as String?,
      remoteFileId: json['remote_file_id'] as String?,
      remoteTranscriptionId: json['remote_transcription_id'] as String?,
      cleanupState:
          _enumByName(CleanupState.values, json['cleanup_state']) ??
          CleanupState.none,
    );
  }
}

class BatchSession {
  const BatchSession({
    required this.id,
    required this.jobIds,
    required this.createdAt,
  });

  final String id;
  final List<String> jobIds;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'job_ids': jobIds,
    'created_at': createdAt.toIso8601String(),
  };
}

List<T> _mapList<T>(dynamic value, T Function(Map<String, dynamic>) parser) =>
    value is List
    ? value
          .whereType<Map>()
          .map((item) => parser(item.cast<String, dynamic>()))
          .toList()
    : <T>[];

List<String> _strings(dynamic value) =>
    value is List ? value.whereType<String>().toList() : const [];

DateTime? _date(dynamic value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

T? _enumByName<T extends Enum>(List<T> values, dynamic name) {
  if (name is! String) return null;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
