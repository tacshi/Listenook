import 'dart:io';

import '../core/contracts.dart';
import '../core/models.dart';
import 'remote_transcription_api.dart';

String canonicalMossErrorCode(
  String? value, {
  String fallback = 'moss_request_failed',
}) {
  final normalized = value?.trim().toLowerCase() ?? '';
  if (normalized.isEmpty) return fallback;
  if (normalized.contains('credit') || normalized.contains('billing')) {
    return 'moss_exhausted_balance';
  }
  if (normalized.contains('rate') || normalized.contains('concurrency')) {
    return 'moss_rate_limit';
  }
  if (normalized.contains('file') ||
      normalized.contains('audio') ||
      normalized.contains('media')) {
    return 'moss_invalid_media';
  }
  return fallback;
}

class MossApiClient extends RemoteTranscriptionApi
    implements TranscriptionClient {
  MossApiClient(super.credentials, {super.httpClient, super.baseUri})
    : super(
        serviceName: 'MOSS',
        codePrefix: 'moss_',
        defaultBaseUri: Uri.parse('https://api.mosi.cn/v1'),
      );

  static const model = 'moss-transcribe-diarize';
  static const version = 'v20260410-streamparam-20260703';
  static const maxUploadBytes = 512 * 1024 * 1024;

  @override
  Future<void> validateKey({String? apiKey}) async {
    final response = await get(
      '/models',
      timeout: const Duration(seconds: 20),
      apiKey: apiKey,
    );
    final models = (object(response.body)['data'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => item['id']?.toString())
        .whereType<String>();
    if (!models.contains(model)) {
      throw const MossException(
        code: 'moss_model_unavailable',
        message: 'This MOSS API key cannot access MOSS Pro transcription.',
      );
    }
  }

  @override
  Future<String> uploadFile(
    String path, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    if (await File(path).length() > maxUploadBytes) {
      throw const MossException(
        code: 'moss_file_too_large',
        message: 'MOSS accepts files up to 512 MB.',
      );
    }
    final body = await upload(
      '/files',
      path,
      fields: const {'purpose': 'audio'},
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
    final body = await postJson('/audio/transcriptions', {
      'model': model,
      'version': version,
      'file_id': fileId,
      'diarize': true,
      'response_format': 'json',
      'async': true,
    }, timeout: const Duration(seconds: 60));
    return requiredId(
      body,
      keys: const ['task_id', 'id'],
      operation: 'transcription',
    );
  }

  @override
  Future<RemoteTranscriptionState> getTranscription(String id) async {
    final json = await _getTask(id);
    final error = (json['error'] as Map?)?.cast<String, dynamic>();
    final retrySeconds = (json['retry_after'] as num?)?.toInt();
    return RemoteTranscriptionState(
      status: json['status']?.toString() ?? 'UNKNOWN',
      errorType:
          error?['internal_error_msg']?.toString() ??
          error?['error_msg']?.toString() ??
          error?['error_code']?.toString(),
      errorMessage:
          error?['error_msg']?.toString() ??
          error?['internal_error_msg']?.toString(),
      retryAfter: retrySeconds == null
          ? null
          : Duration(seconds: retrySeconds.clamp(1, 30)),
    );
  }

  @override
  Future<Map<String, dynamic>> getTranscript(String id) => _getTask(id);

  @override
  Future<void> deleteTranscription(String id) async {}

  @override
  Future<void> deleteFile(String id) =>
      delete('/files/${Uri.encodeComponent(id)}');

  Future<Map<String, dynamic>> _getTask(String id) => getObject(
    '/audio/tasks/${Uri.encodeComponent(id)}',
    timeout: const Duration(minutes: 2),
  );

  @override
  RemoteErrorBody parseErrorBody(Map<String, dynamic> json) {
    final error = (json['error'] as Map?)?.cast<String, dynamic>();
    return (
      type:
          error?['code']?.toString() ??
          error?['type']?.toString() ??
          json['code']?.toString() ??
          '',
      message: error?['message']?.toString() ?? json['message']?.toString(),
    );
  }

  @override
  String errorCodeFor(int statusCode, String type) => switch (statusCode) {
    402 => 'moss_exhausted_balance',
    413 => 'moss_file_too_large',
    _ => canonicalMossErrorCode(type),
  };

  @override
  Exception exception({
    required String code,
    required String message,
    int? statusCode,
    String? errorType,
    bool retryable = false,
  }) => MossException(
    code: code,
    message: message,
    statusCode: statusCode,
    errorType: errorType,
    retryable: retryable,
  );
}

class MossTranscriptParser {
  const MossTranscriptParser();

  TranscriptDocument parse(Map<String, dynamic> payload) {
    final rawSegments = (payload['segments'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList();
    final segments = <TranscriptSegment>[];
    for (var index = 0; index < rawSegments.length; index++) {
      final item = rawSegments[index];
      final text = item['text']?.toString().trim() ?? '';
      if (text.isEmpty) continue;
      final startMs = _milliseconds(item['start']);
      final endMs = _milliseconds(item['end']).clamp(startMs, 1 << 31);
      final speakerValue = item['speaker']?.toString().trim();
      segments.add(
        TranscriptSegment(
          id: item['id']?.toString() ?? 'moss-$index',
          startMs: startMs,
          endMs: endMs,
          text: text,
          speaker: speakerValue == null || speakerValue.isEmpty
              ? null
              : speakerValue,
        ),
      );
    }
    if (segments.isEmpty) {
      final text = payload['text']?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        segments.add(
          TranscriptSegment(
            id: 'moss-0',
            startMs: 0,
            endMs: _milliseconds(payload['duration']),
            text: text,
          ),
        );
      }
    }
    final speakerIds = <String>[];
    for (final segment in segments) {
      final speaker = segment.speaker;
      if (speaker != null && !speakerIds.contains(speaker)) {
        speakerIds.add(speaker);
      }
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

  int _milliseconds(Object? seconds) {
    final value = seconds is num ? seconds.toDouble() : 0;
    if (!value.isFinite || value <= 0) return 0;
    return (value * 1000).round();
  }
}

class MossException implements Exception {
  const MossException({
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
  String toString() => 'MossException($code): $message';
}
