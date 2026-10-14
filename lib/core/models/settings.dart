import 'job.dart';
import 'json.dart';
import 'translation.dart';

enum ExportFormat { txt, markdown, srt, webVtt }

enum ExportContentMode { original, translated, bilingual }

enum AppThemeMode { system, light, dark }

enum AppLocaleMode { system, english, simplifiedChinese }

enum AppContentDestination { podcast, workspace, library }

class ExportOptions {
  const ExportOptions({
    this.format = ExportFormat.txt,
    this.showSpeakers = true,
    this.showTimestamps = false,
    this.localeCode = 'en',
    this.contentMode = ExportContentMode.original,
  });

  final ExportFormat format;
  final bool showSpeakers;
  final bool showTimestamps;
  final String localeCode;
  final ExportContentMode contentMode;

  ExportOptions copyWith({
    ExportFormat? format,
    bool? showSpeakers,
    bool? showTimestamps,
    String? localeCode,
    ExportContentMode? contentMode,
  }) => ExportOptions(
    format: format ?? this.format,
    showSpeakers: showSpeakers ?? this.showSpeakers,
    showTimestamps: showTimestamps ?? this.showTimestamps,
    localeCode: localeCode ?? this.localeCode,
    contentMode: contentMode ?? this.contentMode,
  );

  Map<String, dynamic> toJson() => {
    'format': format.name,
    'show_speakers': showSpeakers,
    'show_timestamps': showTimestamps,
    'locale_code': localeCode,
    'content_mode': contentMode.name,
  };

  factory ExportOptions.fromJson(Map<String, dynamic>? json) => ExportOptions(
    format:
        enumByName(ExportFormat.values, json?['format']) ?? ExportFormat.txt,
    showSpeakers: json?['show_speakers'] as bool? ?? true,
    showTimestamps: json?['show_timestamps'] as bool? ?? false,
    localeCode: json?['locale_code'] as String? ?? 'en',
    contentMode:
        enumByName(ExportContentMode.values, json?['content_mode']) ??
        ExportContentMode.original,
  );
}

class AppSettings {
  const AppSettings({
    this.themeMode = AppThemeMode.system,
    this.localeMode = AppLocaleMode.system,
    this.showSpeakers = true,
    this.showTimestamps = false,
    this.blindListeningEnabled = false,
    this.mimicRepGoal = 3,
    this.mimicPauseSeconds = 0,
    this.exportOptions = const ExportOptions(),
    this.onboardingComplete = false,
    LlmProviderSettings llmProviderSettings = const LlmProviderSettings(),
    TranslationPreferences translationPreferences =
        const TranslationPreferences(),
    TranslationSettings? translationSettings,
    this.sonioxTranslation = const SonioxTranslationOptions(),
    this.defaultTranscriptionProvider = TranscriptionProvider.soniox,
    this.defaultForcedAlignmentModel,
    this.automaticWordTiming = true,
    this.autoTranscribeLocal = false,
    this.lastContentDestination = AppContentDestination.podcast,
    this.lastWorkspaceJobId,
    this.playbackPositionsMs = const {},
  }) : _llmProviderSettings = llmProviderSettings,
       _translationPreferences = translationPreferences,
       _legacyTranslationSettings = translationSettings;

  final AppThemeMode themeMode;
  final AppLocaleMode localeMode;
  final bool showSpeakers;
  final bool showTimestamps;
  final bool blindListeningEnabled;
  final int mimicRepGoal;

  /// Zero selects a pause based on the sentence's playback duration.
  final int mimicPauseSeconds;
  final ExportOptions exportOptions;
  final bool onboardingComplete;
  final LlmProviderSettings _llmProviderSettings;
  final TranslationPreferences _translationPreferences;
  final TranslationSettings? _legacyTranslationSettings;
  final SonioxTranslationOptions sonioxTranslation;
  final TranscriptionProvider defaultTranscriptionProvider;
  final ForcedAlignmentModel? defaultForcedAlignmentModel;
  final bool automaticWordTiming;
  final bool autoTranscribeLocal;
  final AppContentDestination lastContentDestination;
  final String? lastWorkspaceJobId;
  final Map<String, int> playbackPositionsMs;

  LlmProviderSettings get llmProviderSettings =>
      _legacyTranslationSettings?.providerSettings ?? _llmProviderSettings;

  TranslationPreferences get translationPreferences =>
      _legacyTranslationSettings?.preferences ?? _translationPreferences;

  TranslationSettings get translationSettings => TranslationSettings.fromParts(
    llmProviderSettings,
    translationPreferences,
  );

  AppSettings copyWith({
    AppThemeMode? themeMode,
    AppLocaleMode? localeMode,
    bool? showSpeakers,
    bool? showTimestamps,
    bool? blindListeningEnabled,
    int? mimicRepGoal,
    int? mimicPauseSeconds,
    ExportOptions? exportOptions,
    bool? onboardingComplete,
    LlmProviderSettings? llmProviderSettings,
    TranslationPreferences? translationPreferences,
    TranslationSettings? translationSettings,
    SonioxTranslationOptions? sonioxTranslation,
    TranscriptionProvider? defaultTranscriptionProvider,
    ForcedAlignmentModel? defaultForcedAlignmentModel,
    bool? automaticWordTiming,
    bool? autoTranscribeLocal,
    AppContentDestination? lastContentDestination,
    String? lastWorkspaceJobId,
    bool clearLastWorkspaceJobId = false,
    Map<String, int>? playbackPositionsMs,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    localeMode: localeMode ?? this.localeMode,
    showSpeakers: showSpeakers ?? this.showSpeakers,
    showTimestamps: showTimestamps ?? this.showTimestamps,
    blindListeningEnabled: blindListeningEnabled ?? this.blindListeningEnabled,
    mimicRepGoal: mimicRepGoal ?? this.mimicRepGoal,
    mimicPauseSeconds: mimicPauseSeconds ?? this.mimicPauseSeconds,
    exportOptions: exportOptions ?? this.exportOptions,
    onboardingComplete: onboardingComplete ?? this.onboardingComplete,
    llmProviderSettings:
        translationSettings?.providerSettings ??
        llmProviderSettings ??
        this.llmProviderSettings,
    translationPreferences:
        translationSettings?.preferences ??
        translationPreferences ??
        this.translationPreferences,
    sonioxTranslation: sonioxTranslation ?? this.sonioxTranslation,
    defaultTranscriptionProvider:
        defaultTranscriptionProvider ?? this.defaultTranscriptionProvider,
    defaultForcedAlignmentModel:
        defaultForcedAlignmentModel ?? this.defaultForcedAlignmentModel,
    automaticWordTiming: automaticWordTiming ?? this.automaticWordTiming,
    autoTranscribeLocal: autoTranscribeLocal ?? this.autoTranscribeLocal,
    lastContentDestination:
        lastContentDestination ?? this.lastContentDestination,
    lastWorkspaceJobId: clearLastWorkspaceJobId
        ? null
        : lastWorkspaceJobId ?? this.lastWorkspaceJobId,
    playbackPositionsMs: playbackPositionsMs ?? this.playbackPositionsMs,
  );

  Map<String, dynamic> toJson() => {
    'manifest_version': manifestVersion,
    'theme_mode': themeMode.name,
    'locale_mode': localeMode.name,
    'show_speakers': showSpeakers,
    'show_timestamps': showTimestamps,
    'blind_listening_enabled': blindListeningEnabled,
    'mimic_rep_goal': mimicRepGoal,
    'mimic_pause_seconds': mimicPauseSeconds,
    'export_options': exportOptions.toJson(),
    'onboarding_complete': onboardingComplete,
    'llm_provider_settings': llmProviderSettings.toJson(),
    'translation_preferences': translationPreferences.toJson(),
    'soniox_translation': sonioxTranslation.toJson(),
    'default_transcription_provider': defaultTranscriptionProvider.name,
    if (defaultForcedAlignmentModel case final value?)
      'default_forced_alignment_model': value.name,
    'auto_align_transcripts': automaticWordTiming,
    'auto_transcribe_local': autoTranscribeLocal,
    'last_content_destination': lastContentDestination.name,
    if (lastWorkspaceJobId case final value?) 'last_workspace_job_id': value,
    if (playbackPositionsMs.isNotEmpty)
      'playback_positions_ms': playbackPositionsMs,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final legacy = TranslationSettings.fromJson(
      (json['translation_settings'] as Map?)?.cast<String, dynamic>(),
    );
    final hasSplitSettings = json['llm_provider_settings'] is Map;
    return AppSettings(
      themeMode:
          enumByName(AppThemeMode.values, json['theme_mode']) ??
          AppThemeMode.system,
      localeMode:
          enumByName(AppLocaleMode.values, json['locale_mode']) ??
          AppLocaleMode.system,
      showSpeakers: json['show_speakers'] as bool? ?? true,
      showTimestamps: json['show_timestamps'] as bool? ?? false,
      blindListeningEnabled: json['blind_listening_enabled'] as bool? ?? false,
      mimicRepGoal: switch (json['mimic_rep_goal']) {
        int value when value > 0 => value,
        _ => const AppSettings().mimicRepGoal,
      },
      mimicPauseSeconds: switch (json['mimic_pause_seconds']) {
        int value when value >= 0 && value <= 10 => value,
        _ => const AppSettings().mimicPauseSeconds,
      },
      exportOptions: ExportOptions.fromJson(
        (json['export_options'] as Map?)?.cast<String, dynamic>(),
      ),
      onboardingComplete: json['onboarding_complete'] as bool? ?? false,
      llmProviderSettings: hasSplitSettings
          ? LlmProviderSettings.fromJson(
              (json['llm_provider_settings'] as Map).cast<String, dynamic>(),
            )
          : legacy.providerSettings,
      translationPreferences: hasSplitSettings
          ? TranslationPreferences.fromJson(
              (json['translation_preferences'] as Map?)
                  ?.cast<String, dynamic>(),
            )
          : legacy.preferences,
      sonioxTranslation: SonioxTranslationOptions.fromJson(
        (json['soniox_translation'] as Map?)?.cast<String, dynamic>(),
      ),
      defaultTranscriptionProvider:
          enumByName(
            TranscriptionProvider.values,
            json['default_transcription_provider'],
          ) ??
          TranscriptionProvider.soniox,
      defaultForcedAlignmentModel: enumByName(
        ForcedAlignmentModel.values,
        json['default_forced_alignment_model'],
      ),
      automaticWordTiming:
          json['auto_align_transcripts'] as bool? ??
          json['auto_align_moss'] as bool? ??
          true,
      autoTranscribeLocal: json['auto_transcribe_local'] as bool? ?? false,
      lastContentDestination:
          enumByName(
            AppContentDestination.values,
            json['last_content_destination'],
          ) ??
          AppContentDestination.podcast,
      lastWorkspaceJobId: json['last_workspace_job_id'] as String?,
      playbackPositionsMs: _playbackPositionsFromJson(
        json['playback_positions_ms'],
      ),
    );
  }
}

Map<String, int> _playbackPositionsFromJson(Object? value) {
  if (value is! Map) return const {};
  final maximum = const Duration(days: 365).inMilliseconds;
  return {
    for (final entry in value.entries)
      if (entry.key is String && entry.value is num)
        if ((entry.value as num).toInt() case final milliseconds
            when milliseconds > 0 && milliseconds <= maximum)
          entry.key as String: milliseconds,
  };
}
