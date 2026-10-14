import 'json.dart';

enum TranslationViewMode { original, translated, bilingual }

enum TranslationOrigin { soniox, llm }

enum TranslationProviderTemplate {
  custom,
  openAi,
  openRouter,
  deepSeek,
  groq,
  nvidiaNim,
  togetherAi,
  mistralAi,
  lmStudio,
  ollama,
  fireworksAi,
  perplexity,
  volcengineArk,
}

extension TranslationProviderTemplateX on TranslationProviderTemplate {
  String get defaultBaseUrl => switch (this) {
    TranslationProviderTemplate.custom => '',
    TranslationProviderTemplate.openAi => 'https://api.openai.com/v1',
    TranslationProviderTemplate.openRouter => 'https://openrouter.ai/api/v1',
    TranslationProviderTemplate.deepSeek => 'https://api.deepseek.com/v1',
    TranslationProviderTemplate.groq => 'https://api.groq.com/openai/v1',
    TranslationProviderTemplate.nvidiaNim =>
      'https://integrate.api.nvidia.com/v1',
    TranslationProviderTemplate.togetherAi => 'https://api.together.xyz/v1',
    TranslationProviderTemplate.mistralAi => 'https://api.mistral.ai/v1',
    TranslationProviderTemplate.lmStudio => 'http://localhost:1234/v1',
    TranslationProviderTemplate.ollama => 'http://localhost:11434/v1',
    TranslationProviderTemplate.fireworksAi =>
      'https://api.fireworks.ai/inference/v1',
    TranslationProviderTemplate.perplexity => 'https://api.perplexity.ai',
    TranslationProviderTemplate.volcengineArk =>
      'https://ark.cn-beijing.volces.com/api/v3',
  };

  static TranslationProviderTemplate inferFromBaseUrl(String baseUrl) {
    final normalized = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    for (final template in TranslationProviderTemplate.values) {
      if (template == TranslationProviderTemplate.custom) continue;
      if (template.defaultBaseUrl == normalized) return template;
    }
    return TranslationProviderTemplate.custom;
  }
}

enum TranslationStatus {
  idle,
  translating,
  completed,
  partial,
  failed,
  cancelled,
  interrupted,
}

extension TranslationStatusX on TranslationStatus {
  bool get isActive => this == TranslationStatus.translating;
  bool get canRetry =>
      this == TranslationStatus.partial ||
      this == TranslationStatus.failed ||
      this == TranslationStatus.cancelled ||
      this == TranslationStatus.interrupted;
}

class SonioxTranslationOptions {
  const SonioxTranslationOptions({
    this.enabled = false,
    this.targetLanguage = '',
  });

  final bool enabled;
  final String targetLanguage;

  String? validationError() {
    if (!enabled) return null;
    if (!supportedSonioxTranslationLanguageCodes.contains(targetLanguage)) {
      return 'soniox_translation_invalid_language';
    }
    return null;
  }

  SonioxTranslationOptions copyWith({bool? enabled, String? targetLanguage}) =>
      SonioxTranslationOptions(
        enabled: enabled ?? this.enabled,
        targetLanguage: targetLanguage ?? this.targetLanguage,
      );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'target_language': targetLanguage,
  };

  factory SonioxTranslationOptions.fromJson(Map<String, dynamic>? json) =>
      SonioxTranslationOptions(
        enabled: json?['enabled'] as bool? ?? false,
        targetLanguage: json?['target_language'] as String? ?? '',
      );
}

class TranslationSettings {
  const TranslationSettings({
    this.provider = TranslationProviderTemplate.custom,
    this.baseUrl = '',
    this.model = '',
    this.targetLanguage = '',
    this.autoTranslate = false,
  });

  final TranslationProviderTemplate provider;
  final String baseUrl;
  final String model;
  final String targetLanguage;
  final bool autoTranslate;

  Uri? get uri => Uri.tryParse(baseUrl.trim());

  bool get isLoopback {
    final host = uri?.host.toLowerCase();
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  bool get requiresApiKey => !isLoopback;

  String? validationError({bool requireModel = true}) {
    final value = uri;
    if (value == null ||
        value.host.isEmpty ||
        value.userInfo.isNotEmpty ||
        value.hasQuery ||
        value.hasFragment) {
      return 'translation_invalid_url';
    }
    if (value.scheme != 'http' && value.scheme != 'https') {
      return 'translation_invalid_url';
    }
    if (!isLoopback && value.scheme != 'https') {
      return 'translation_https_required';
    }
    if (requireModel && model.trim().isEmpty) {
      return 'translation_model_required';
    }
    return null;
  }

  bool isConfigured({required bool hasApiKey}) =>
      validationError() == null && (!requiresApiKey || hasApiKey);

  TranslationSettings copyWith({
    TranslationProviderTemplate? provider,
    String? baseUrl,
    String? model,
    String? targetLanguage,
    bool? autoTranslate,
  }) => TranslationSettings(
    provider: provider ?? this.provider,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    targetLanguage: targetLanguage ?? this.targetLanguage,
    autoTranslate: autoTranslate ?? this.autoTranslate,
  );

  Map<String, dynamic> toJson() => {
    'provider': provider.name,
    'base_url': baseUrl,
    'model': model,
    'target_language': targetLanguage,
    'auto_translate': autoTranslate,
  };

  factory TranslationSettings.fromJson(Map<String, dynamic>? json) {
    final baseUrl = json?['base_url'] as String? ?? '';
    final provider =
        enumByName(TranslationProviderTemplate.values, json?['provider']) ??
        TranslationProviderTemplateX.inferFromBaseUrl(baseUrl);
    return TranslationSettings(
      provider: provider,
      baseUrl: baseUrl,
      model: json?['model'] as String? ?? '',
      targetLanguage: json?['target_language'] as String? ?? '',
      autoTranslate: json?['auto_translate'] as bool? ?? false,
    );
  }

  factory TranslationSettings.fromParts(
    LlmProviderSettings provider,
    TranslationPreferences preferences,
  ) => TranslationSettings(
    provider: provider.provider,
    baseUrl: provider.baseUrl,
    model: provider.model,
    targetLanguage: preferences.targetLanguage,
    autoTranslate: preferences.autoTranslate,
  );

  LlmProviderSettings get providerSettings =>
      LlmProviderSettings(provider: provider, baseUrl: baseUrl, model: model);

  TranslationPreferences get preferences => TranslationPreferences(
    targetLanguage: targetLanguage,
    autoTranslate: autoTranslate,
  );
}

class LlmProviderSettings {
  const LlmProviderSettings({
    this.provider = TranslationProviderTemplate.custom,
    this.baseUrl = '',
    this.model = '',
  });

  final TranslationProviderTemplate provider;
  final String baseUrl;
  final String model;

  Uri? get uri => Uri.tryParse(baseUrl.trim());

  bool get isLoopback {
    final host = uri?.host.toLowerCase();
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  bool get requiresApiKey => !isLoopback;

  String? validationError({bool requireModel = true}) {
    final value = uri;
    if (value == null ||
        value.host.isEmpty ||
        value.userInfo.isNotEmpty ||
        value.hasQuery ||
        value.hasFragment) {
      return 'translation_invalid_url';
    }
    if (value.scheme != 'http' && value.scheme != 'https') {
      return 'translation_invalid_url';
    }
    if (!isLoopback && value.scheme != 'https') {
      return 'translation_https_required';
    }
    if (requireModel && model.trim().isEmpty) {
      return 'translation_model_required';
    }
    return null;
  }

  bool isConfigured({required bool hasApiKey}) =>
      validationError() == null && (!requiresApiKey || hasApiKey);

  LlmProviderSettings copyWith({
    TranslationProviderTemplate? provider,
    String? baseUrl,
    String? model,
  }) => LlmProviderSettings(
    provider: provider ?? this.provider,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
  );

  Map<String, dynamic> toJson() => {
    'provider': provider.name,
    'base_url': baseUrl,
    'model': model,
  };

  factory LlmProviderSettings.fromJson(Map<String, dynamic>? json) {
    final baseUrl = json?['base_url'] as String? ?? '';
    return LlmProviderSettings(
      provider:
          enumByName(TranslationProviderTemplate.values, json?['provider']) ??
          TranslationProviderTemplateX.inferFromBaseUrl(baseUrl),
      baseUrl: baseUrl,
      model: json?['model'] as String? ?? '',
    );
  }
}

class TranslationPreferences {
  const TranslationPreferences({
    this.targetLanguage = '',
    this.autoTranslate = false,
  });

  final String targetLanguage;
  final bool autoTranslate;

  TranslationPreferences copyWith({
    String? targetLanguage,
    bool? autoTranslate,
  }) => TranslationPreferences(
    targetLanguage: targetLanguage ?? this.targetLanguage,
    autoTranslate: autoTranslate ?? this.autoTranslate,
  );

  Map<String, dynamic> toJson() => {
    'target_language': targetLanguage,
    'auto_translate': autoTranslate,
  };

  factory TranslationPreferences.fromJson(Map<String, dynamic>? json) =>
      TranslationPreferences(
        targetLanguage: json?['target_language'] as String? ?? '',
        autoTranslate: json?['auto_translate'] as bool? ?? false,
      );
}

class TranslationOptions {
  const TranslationOptions({
    this.enabled = false,
    this.targetLanguage = '',
    this.baseUrl = '',
    this.model = '',
  });

  factory TranslationOptions.fromSettings(TranslationSettings settings) =>
      TranslationOptions(
        enabled: settings.autoTranslate,
        targetLanguage: settings.targetLanguage,
        baseUrl: settings.baseUrl,
        model: settings.model,
      );

  final bool enabled;
  final String targetLanguage;
  final String baseUrl;
  final String model;

  TranslationOptions copyWith({
    bool? enabled,
    String? targetLanguage,
    String? baseUrl,
    String? model,
  }) => TranslationOptions(
    enabled: enabled ?? this.enabled,
    targetLanguage: targetLanguage ?? this.targetLanguage,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'target_language': targetLanguage,
    'base_url': baseUrl,
    'model': model,
  };

  factory TranslationOptions.fromJson(Map<String, dynamic>? json) =>
      TranslationOptions(
        enabled: json?['enabled'] as bool? ?? false,
        targetLanguage: json?['target_language'] as String? ?? '',
        baseUrl: json?['base_url'] as String? ?? '',
        model: json?['model'] as String? ?? '',
      );
}

class TranslationState {
  const TranslationState({
    this.status = TranslationStatus.idle,
    this.targetLanguage = '',
    this.model = '',
    this.origin,
    this.completedSegments = 0,
    this.totalSegments = 0,
    this.errorCode,
    this.errorMessage,
  });

  final TranslationStatus status;
  final String targetLanguage;
  final String model;
  final TranslationOrigin? origin;
  final int completedSegments;
  final int totalSegments;
  final String? errorCode;
  final String? errorMessage;

  double get progress =>
      totalSegments == 0 ? 0 : completedSegments / totalSegments;

  TranslationState copyWith({
    TranslationStatus? status,
    String? targetLanguage,
    String? model,
    TranslationOrigin? origin,
    int? completedSegments,
    int? totalSegments,
    String? errorCode,
    String? errorMessage,
    bool clearError = false,
    bool clearOrigin = false,
  }) => TranslationState(
    status: status ?? this.status,
    targetLanguage: targetLanguage ?? this.targetLanguage,
    model: model ?? this.model,
    origin: clearOrigin ? null : origin ?? this.origin,
    completedSegments: completedSegments ?? this.completedSegments,
    totalSegments: totalSegments ?? this.totalSegments,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );

  Map<String, dynamic> toJson() => {
    'status': status.name,
    'target_language': targetLanguage,
    'model': model,
    if (origin case final value?) 'origin': value.name,
    'completed_segments': completedSegments,
    'total_segments': totalSegments,
    if (errorCode case final value?) 'error_code': value,
    if (errorMessage case final value?) 'error_message': value,
  };

  factory TranslationState.fromJson(Map<String, dynamic>? json) =>
      TranslationState(
        status:
            enumByName(TranslationStatus.values, json?['status']) ??
            TranslationStatus.idle,
        targetLanguage: json?['target_language'] as String? ?? '',
        model: json?['model'] as String? ?? '',
        origin: enumByName(TranslationOrigin.values, json?['origin']),
        completedSegments: (json?['completed_segments'] as num?)?.toInt() ?? 0,
        totalSegments: (json?['total_segments'] as num?)?.toInt() ?? 0,
        errorCode: json?['error_code'] as String?,
        errorMessage: json?['error_message'] as String?,
      );
}

const supportedTranslationLanguageCodes = <String>[
  'en',
  'zh-Hans',
  'zh-Hant',
  'ja',
  'ko',
  'es',
  'fr',
  'de',
  'it',
  'pt',
  'ru',
  'ar',
  'hi',
  'vi',
  'th',
  'yue',
  'nl',
  'pl',
  'tr',
  'uk',
  'cs',
  'sv',
  'da',
  'fi',
  'el',
  'he',
  'id',
  'ms',
];

const supportedSonioxTranslationLanguageCodes = <String>[
  'af',
  'sq',
  'ar',
  'az',
  'eu',
  'be',
  'bn',
  'bs',
  'bg',
  'ca',
  'zh',
  'hr',
  'cs',
  'da',
  'nl',
  'en',
  'et',
  'fi',
  'fr',
  'gl',
  'de',
  'el',
  'gu',
  'he',
  'hi',
  'hu',
  'id',
  'it',
  'ja',
  'kn',
  'kk',
  'ko',
  'lv',
  'lt',
  'mk',
  'ms',
  'ml',
  'mr',
  'no',
  'fa',
  'pl',
  'pt',
  'pa',
  'ro',
  'ru',
  'sr',
  'sk',
  'sl',
  'es',
  'sw',
  'sv',
  'tl',
  'ta',
  'te',
  'th',
  'tr',
  'uk',
  'ur',
  'vi',
  'cy',
];
