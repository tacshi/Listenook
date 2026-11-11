import '../core/contracts.dart';
import '../core/models.dart';
import 'remote_transcription_api.dart';

String canonicalSonioxErrorCode(
  String? errorType, {
  String fallback = 'request_failed',
}) {
  final normalized = errorType?.trim().toLowerCase() ?? '';
  if (normalized.isEmpty) return fallback;
  if (normalized == 'organization_balance_exhausted' ||
      normalized == 'insufficient_funds' ||
      normalized == 'insufficient_balance' ||
      normalized.contains('balance') ||
      normalized.contains('credit')) {
    return 'exhausted_balance';
  }
  if (normalized == 'organization_monthly_budget_exhausted' ||
      normalized == 'project_monthly_budget_exhausted' ||
      normalized.contains('budget')) {
    return 'budget_exhausted';
  }
  if (normalized.contains('quota') || normalized.contains('rate')) {
    return 'rate_limit';
  }
  if (normalized.contains('audio') || normalized.contains('media')) {
    return 'invalid_media';
  }
  return normalized;
}

class SonioxApiClient extends RemoteTranscriptionApi implements SonioxClient {
  SonioxApiClient(super.credentials, {super.httpClient, super.baseUri})
    : super(
        serviceName: 'Soniox',
        codePrefix: '',
        defaultBaseUri: Uri.parse('https://api.soniox.com/v1'),
      );

  static const model = 'stt-async-v6';

  @override
  Future<void> validateKey({String? apiKey}) => get(
    '/files?limit=1',
    timeout: const Duration(seconds: 20),
    apiKey: apiKey,
  );

  @override
  Future<String> uploadFile(
    String path, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    final body = await upload(
      '/files',
      path,
      onProgress: onProgress,
      shouldCancel: shouldCancel,
    );
    return requiredId(body, operation: 'upload');
  }

  @override
  Future<String> createTranscription(
    String fileId,
    TranscriptionOptions options,
  ) async {
    final translationError = options.sonioxTranslation.validationError();
    if (translationError != null) {
      throw const SonioxException(
        code: 'soniox_translation_invalid_language',
        message: 'The selected Soniox translation language is not supported.',
      );
    }
    final context = <String, dynamic>{
      if (options.contextTerms.isNotEmpty) 'terms': options.contextTerms,
    };
    final body = await postJson('/transcriptions', {
      'model': model,
      'file_id': fileId,
      'enable_language_identification': true,
      'enable_speaker_diarization': true,
      if (options.languageHints.isNotEmpty)
        'language_hints': options.languageHints,
      if (options.sonioxTranslation.enabled)
        'translation': {
          'type': 'one_way',
          'target_language': options.sonioxTranslation.targetLanguage,
        },
      if (context.isNotEmpty) 'context': context,
    }, timeout: const Duration(seconds: 60));
    return requiredId(body, operation: 'transcription');
  }

  @override
  Future<SonioxTranscriptionState> getTranscription(String id) async {
    final json = await getObject(
      '/transcriptions/${Uri.encodeComponent(id)}',
      timeout: const Duration(seconds: 30),
    );
    return SonioxTranscriptionState(
      status: json['status'] as String? ?? 'unknown',
      errorType: json['error_type'] as String?,
      errorMessage: json['error_message'] as String?,
    );
  }

  @override
  Future<Map<String, dynamic>> getTranscript(String id) => getObject(
    '/transcriptions/${Uri.encodeComponent(id)}/transcript',
    timeout: const Duration(minutes: 2),
  );

  @override
  Future<void> deleteTranscription(String id) =>
      delete('/transcriptions/${Uri.encodeComponent(id)}');

  @override
  Future<void> deleteFile(String id) =>
      delete('/files/${Uri.encodeComponent(id)}');

  @override
  RemoteErrorBody parseErrorBody(Map<String, dynamic> json) => (
    type: json['error_type']?.toString() ?? json['type']?.toString() ?? '',
    message: json['error_message']?.toString() ?? json['message']?.toString(),
  );

  @override
  String errorCodeFor(int statusCode, String type) => switch (statusCode) {
    402 => canonicalSonioxErrorCode(type, fallback: 'exhausted_balance'),
    413 => 'invalid_media',
    _ => canonicalSonioxErrorCode(type),
  };

  @override
  Exception exception({
    required String code,
    required String message,
    int? statusCode,
    String? errorType,
    bool retryable = false,
  }) => SonioxException(
    code: code,
    message: message,
    statusCode: statusCode,
    errorType: errorType,
    retryable: retryable,
  );
}

class SonioxException implements Exception {
  const SonioxException({
    required this.code,
    required this.message,
    this.statusCode,
    this.errorType,
    this.retryable = false,
  });

  final String code;
  final String message;
  final int? statusCode;
  final String? errorType;
  final bool retryable;

  @override
  String toString() => 'SonioxException($code): $message';
}
