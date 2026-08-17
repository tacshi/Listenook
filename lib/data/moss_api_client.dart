import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../core/contracts.dart';
import '../core/models.dart';

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

class MossApiClient implements TranscriptionClient {
  MossApiClient(this._credentials, {http.Client? httpClient, Uri? baseUri})
    : _http = httpClient ?? http.Client(),
      _base = (baseUri ?? Uri.parse('https://api.mosi.cn/v1'))
          .toString()
          .replaceFirst(RegExp(r'/$'), '');

  static const model = 'moss-transcribe-diarize';
  static const version = 'v20260410-streamparam-20260703';
  static const maxUploadBytes = 512 * 1024 * 1024;

  final CredentialStore _credentials;
  final http.Client _http;
  final String _base;

  Future<Map<String, String>> _headers({
    bool json = false,
    String? apiKey,
  }) async {
    final candidate = apiKey?.trim();
    final key = candidate == null || candidate.isEmpty
        ? await _credentials.readApiKey()
        : candidate;
    if (key == null || key.isEmpty) {
      throw const MossException(
        code: 'moss_missing_credentials',
        message: 'A MOSS API key is required.',
      );
    }
    return {
      'Authorization': 'Bearer $key',
      if (json) 'Content-Type': 'application/json',
    };
  }

  @override
  Future<void> validateKey({String? apiKey}) async {
    final response = await _http
        .get(
          Uri.parse('$_base/models'),
          headers: await _headers(apiKey: apiKey),
        )
        .timeout(const Duration(seconds: 20));
    _ensureSuccess(response.statusCode, response.body);
    final json = _object(response.body);
    final models = (json['data'] as List? ?? const [])
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
    final file = File(path);
    final length = await file.length();
    if (length > maxUploadBytes) {
      throw const MossException(
        code: 'moss_file_too_large',
        message: 'MOSS accepts files up to 512 MB.',
      );
    }
    var sent = 0;
    final stream = file.openRead().transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          if (shouldCancel?.call() ?? false) {
            sink.addError(const OperationCancelledException());
            sink.close();
            return;
          }
          sent += chunk.length;
          onProgress?.call(length == 0 ? null : sent / length, '$sent/$length');
          sink.add(chunk);
        },
      ),
    );
    final request = http.MultipartRequest('POST', Uri.parse('$_base/files'))
      ..headers.addAll(await _headers())
      ..fields['purpose'] = 'audio'
      ..files.add(
        http.MultipartFile('file', stream, length, filename: p.basename(path)),
      );
    final response = await _http
        .send(request)
        .timeout(const Duration(hours: 2));
    final body = await response.stream.bytesToString();
    _ensureSuccess(response.statusCode, body);
    return _requiredId(body, keys: const ['id'], operation: 'upload');
  }

  @override
  Future<String> createTranscription(
    String fileId,
    TranscriptionOptions options,
  ) async {
    final response = await _http
        .post(
          Uri.parse('$_base/audio/transcriptions'),
          headers: await _headers(json: true),
          body: jsonEncode({
            'model': model,
            'version': version,
            'file_id': fileId,
            'diarize': true,
            'response_format': 'json',
            'async': true,
          }),
        )
        .timeout(const Duration(seconds: 60));
    _ensureSuccess(response.statusCode, response.body);
    return _requiredId(
      response.body,
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
  Future<void> deleteFile(String id) async {
    final response = await _http
        .delete(
          Uri.parse('$_base/files/${Uri.encodeComponent(id)}'),
          headers: await _headers(),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 404) return;
    _ensureSuccess(response.statusCode, response.body);
  }

  Future<Map<String, dynamic>> _getTask(String id) async {
    final response = await _http
        .get(
          Uri.parse('$_base/audio/tasks/${Uri.encodeComponent(id)}'),
          headers: await _headers(),
        )
        .timeout(const Duration(minutes: 2));
    _ensureSuccess(response.statusCode, response.body);
    return _object(response.body);
  }

  String _requiredId(
    String body, {
    required List<String> keys,
    required String operation,
  }) {
    final json = _object(body);
    for (final key in keys) {
      final value = json[key]?.toString();
      if (value != null && value.isNotEmpty) return value;
    }
    throw MossException(
      code: 'moss_invalid_response',
      message: 'MOSS $operation response did not contain an id.',
    );
  }

  Map<String, dynamic> _object(String body) {
    try {
      return (jsonDecode(body) as Map).cast<String, dynamic>();
    } on Object {
      throw const MossException(
        code: 'moss_invalid_response',
        message: 'MOSS returned an unreadable response.',
      );
    }
  }

  void _ensureSuccess(int statusCode, String body) {
    if (statusCode >= 200 && statusCode < 300) return;
    var type = '';
    var message = 'MOSS request failed (HTTP $statusCode).';
    try {
      final json = (jsonDecode(body) as Map).cast<String, dynamic>();
      final error = (json['error'] as Map?)?.cast<String, dynamic>();
      type =
          error?['code']?.toString() ??
          error?['type']?.toString() ??
          json['code']?.toString() ??
          '';
      message =
          error?['message']?.toString() ??
          json['message']?.toString() ??
          message;
    } on Object {
      // The HTTP status still provides a stable category.
    }
    final code = switch (statusCode) {
      401 || 403 => 'moss_bad_credentials',
      402 => 'moss_exhausted_balance',
      413 => 'moss_file_too_large',
      429 => 'moss_rate_limit',
      >= 500 => 'moss_server_failure',
      _ => canonicalMossErrorCode(type),
    };
    throw MossException(
      code: code,
      message: message,
      statusCode: statusCode,
      errorType: type.isEmpty ? null : type,
      retryable: statusCode == 408 || statusCode == 429 || statusCode >= 500,
    );
  }
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
