import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../core/contracts.dart';
import '../core/models.dart';

class SonioxApiClient implements SonioxClient {
  SonioxApiClient(this._credentials, {http.Client? httpClient, Uri? baseUri})
    : _http = httpClient ?? http.Client(),
      _base = (baseUri ?? Uri.parse('https://api.soniox.com/v1'))
          .toString()
          .replaceFirst(RegExp(r'/$'), '');

  static const model = 'stt-async-v5';
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
      throw const SonioxException(
        code: 'missing_credentials',
        message: 'A Soniox API key is required.',
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
          Uri.parse('$_base/files?limit=1'),
          headers: await _headers(apiKey: apiKey),
        )
        .timeout(const Duration(seconds: 20));
    _ensureSuccess(response.statusCode, response.body);
  }

  @override
  Future<String> uploadFile(
    String path, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    final file = File(path);
    final length = await file.length();
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
      ..files.add(
        http.MultipartFile('file', stream, length, filename: p.basename(path)),
      );
    final streamed = await _http
        .send(request)
        .timeout(const Duration(hours: 2));
    final body = await streamed.stream.bytesToString();
    _ensureSuccess(streamed.statusCode, body);
    return _requiredId(body, 'upload');
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
    final body = <String, dynamic>{
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
    };
    final response = await _http
        .post(
          Uri.parse('$_base/transcriptions'),
          headers: await _headers(json: true),
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 60));
    _ensureSuccess(response.statusCode, response.body);
    return _requiredId(response.body, 'transcription');
  }

  @override
  Future<SonioxTranscriptionState> getTranscription(String id) async {
    final response = await _http
        .get(
          Uri.parse('$_base/transcriptions/${Uri.encodeComponent(id)}'),
          headers: await _headers(),
        )
        .timeout(const Duration(seconds: 30));
    _ensureSuccess(response.statusCode, response.body);
    final json = _object(response.body);
    return SonioxTranscriptionState(
      status: json['status'] as String? ?? 'unknown',
      errorType: json['error_type'] as String?,
      errorMessage: json['error_message'] as String?,
    );
  }

  @override
  Future<Map<String, dynamic>> getTranscript(String id) async {
    final response = await _http
        .get(
          Uri.parse(
            '$_base/transcriptions/${Uri.encodeComponent(id)}/transcript',
          ),
          headers: await _headers(),
        )
        .timeout(const Duration(minutes: 2));
    _ensureSuccess(response.statusCode, response.body);
    return _object(response.body);
  }

  @override
  Future<void> deleteTranscription(String id) =>
      _delete('$_base/transcriptions/${Uri.encodeComponent(id)}');

  @override
  Future<void> deleteFile(String id) =>
      _delete('$_base/files/${Uri.encodeComponent(id)}');

  Future<void> _delete(String url) async {
    final response = await _http
        .delete(Uri.parse(url), headers: await _headers())
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 404) return;
    _ensureSuccess(response.statusCode, response.body);
  }

  String _requiredId(String body, String operation) {
    final id = _object(body)['id']?.toString();
    if (id == null || id.isEmpty) {
      throw SonioxException(
        code: 'invalid_response',
        message: 'Soniox $operation response did not contain an id.',
      );
    }
    return id;
  }

  Map<String, dynamic> _object(String body) {
    try {
      return (jsonDecode(body) as Map).cast<String, dynamic>();
    } on Object {
      throw const SonioxException(
        code: 'invalid_response',
        message: 'Soniox returned an unreadable response.',
      );
    }
  }

  void _ensureSuccess(int statusCode, String body) {
    if (statusCode >= 200 && statusCode < 300) return;
    var type = '';
    var message = 'Soniox request failed (HTTP $statusCode).';
    try {
      final json = (jsonDecode(body) as Map).cast<String, dynamic>();
      type = json['error_type']?.toString() ?? json['type']?.toString() ?? '';
      message =
          json['error_message']?.toString() ??
          json['message']?.toString() ??
          message;
    } on Object {
      // The stable HTTP status still provides a useful error category.
    }
    final code = switch (statusCode) {
      401 || 403 => 'bad_credentials',
      402 => 'exhausted_balance',
      413 => 'invalid_media',
      429 => 'rate_limit',
      >= 500 => 'server_failure',
      _ => _mapType(type),
    };
    throw SonioxException(
      code: code,
      message: message,
      statusCode: statusCode,
      errorType: type.isEmpty ? null : type,
      retryable: statusCode == 408 || statusCode == 429 || statusCode >= 500,
    );
  }

  String _mapType(String type) {
    final normalized = type.toLowerCase();
    if (normalized.contains('balance') || normalized.contains('credit')) {
      return 'exhausted_balance';
    }
    if (normalized.contains('quota') || normalized.contains('rate')) {
      return 'rate_limit';
    }
    if (normalized.contains('audio') || normalized.contains('media')) {
      return 'invalid_media';
    }
    return normalized.isEmpty ? 'request_failed' : normalized;
  }
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
