import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/contracts.dart';
import '../core/models.dart';

class OpenAiCompatibleLlmClient implements LlmClient {
  OpenAiCompatibleLlmClient(
    this._credentials, {
    http.Client? httpClient,
    Future<void> Function(Duration duration)? delay,
  }) : _http = httpClient ?? http.Client(),
       _delay = delay ?? ((duration) => Future<void>.delayed(duration));

  final LlmCredentialStore _credentials;
  final http.Client _http;
  final Future<void> Function(Duration duration) _delay;

  @override
  Future<List<String>> listModels(
    LlmProviderSettings settings, {
    String? candidateApiKey,
  }) async {
    final validation = settings.validationError(requireModel: false);
    if (validation != null) throw LlmException(validation);
    final key = await _apiKey(settings, candidate: candidateApiKey);
    final response = await _http
        .get(_endpoint(settings, 'models'), headers: _headers(key))
        .timeout(const Duration(seconds: 20));
    _ensureSuccess(response.statusCode, response.body);
    try {
      final json = (jsonDecode(response.body) as Map).cast<String, dynamic>();
      final data = json['data'];
      if (data is! List) throw const FormatException();
      return data
          .whereType<Map>()
          .map((item) => item['id']?.toString().trim() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
    } on Object {
      throw const LlmException('llm_invalid_response');
    }
  }

  @override
  Future<String> complete({
    required LlmProviderSettings settings,
    required String systemPrompt,
    required String userPrompt,
    CancelCheck? shouldCancel,
  }) async {
    final validation = settings.validationError();
    if (validation != null) throw LlmException(validation);
    final key = await _apiKey(settings);
    LlmException? lastError;
    for (var attempt = 1; attempt <= 4; attempt++) {
      _checkCancelled(shouldCancel);
      try {
        return await _send(
          settings: settings,
          key: key,
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
          shouldCancel: shouldCancel,
        );
      } on LlmException catch (error) {
        lastError = error;
        if (!error.retryable || attempt == 4) rethrow;
      } on TimeoutException {
        lastError = const LlmException('llm_timeout', retryable: true);
        if (attempt == 4) throw lastError;
      } on SocketException {
        lastError = const LlmException('llm_network_error', retryable: true);
        if (attempt == 4) throw lastError;
      } on http.ClientException {
        lastError = const LlmException('llm_network_error', retryable: true);
        if (attempt == 4) throw lastError;
      }
      _checkCancelled(shouldCancel);
      await _delay(Duration(seconds: 1 << (attempt - 1)));
    }
    throw lastError ?? const LlmException('llm_request_failed');
  }

  Future<String> _send({
    required LlmProviderSettings settings,
    required String? key,
    required String systemPrompt,
    required String userPrompt,
    CancelCheck? shouldCancel,
  }) async {
    final abort = Completer<void>();
    final timer = shouldCancel == null
        ? null
        : Timer.periodic(const Duration(milliseconds: 150), (_) {
            if (shouldCancel() && !abort.isCompleted) abort.complete();
          });
    final request =
        http.AbortableRequest('POST', _endpoint(settings, 'chat/completions'))
          ..headers.addAll(_headers(key, json: true))
          ..body = jsonEncode({
            'model': settings.model.trim(),
            'messages': [
              {'role': 'system', 'content': systemPrompt},
              {'role': 'user', 'content': userPrompt},
            ],
          });
    late http.Response response;
    try {
      final streamed = await _http
          .send(request)
          .timeout(const Duration(minutes: 2));
      response = await http.Response.fromStream(
        streamed,
      ).timeout(const Duration(minutes: 2));
    } on http.RequestAbortedException {
      throw const OperationCancelledException();
    } finally {
      timer?.cancel();
    }
    _ensureSuccess(response.statusCode, response.body);
    try {
      final json = (jsonDecode(response.body) as Map).cast<String, dynamic>();
      final choices = json['choices'];
      if (choices is! List || choices.isEmpty || choices.first is! Map) {
        throw const FormatException();
      }
      final message = (choices.first as Map)['message'];
      final content = message is Map ? message['content'] : null;
      if (content is! String || content.trim().isEmpty) {
        throw const FormatException();
      }
      return content.trim();
    } on Object {
      throw const LlmException('llm_invalid_response');
    }
  }

  Future<String?> _apiKey(
    LlmProviderSettings settings, {
    String? candidate,
  }) async {
    final candidateValue = candidate?.trim();
    if (!settings.requiresApiKey &&
        (candidateValue == null || candidateValue.isEmpty)) {
      return null;
    }
    final key = candidateValue != null && candidateValue.isNotEmpty
        ? candidateValue
        : await _credentials.readApiKey();
    if (settings.requiresApiKey && (key == null || key.isEmpty)) {
      throw const LlmException('llm_missing_credentials');
    }
    return key;
  }

  Uri _endpoint(LlmProviderSettings settings, String path) {
    final base = settings.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    return Uri.parse('$base/$path');
  }

  Map<String, String> _headers(String? key, {bool json = false}) => {
    if (key != null && key.isNotEmpty) 'Authorization': 'Bearer $key',
    if (json) 'Content-Type': 'application/json',
  };

  void _ensureSuccess(int statusCode, String body) {
    if (statusCode >= 200 && statusCode < 300) return;
    final missingEndpointOrModel = _looksLikeMissingEndpointOrModel(body);
    final code = switch (statusCode) {
      401 || 403 => 'llm_bad_credentials',
      404 => 'llm_endpoint_or_model_not_found',
      400 when missingEndpointOrModel => 'llm_endpoint_or_model_not_found',
      408 => 'llm_timeout',
      429 => 'llm_rate_limit',
      >= 500 => 'llm_server_failure',
      _ => 'llm_request_failed',
    };
    throw LlmException(
      code,
      retryable: statusCode == 408 || statusCode == 429 || statusCode >= 500,
    );
  }

  bool _looksLikeMissingEndpointOrModel(String body) {
    final value = body.toLowerCase();
    final missing =
        value.contains('not found') ||
        value.contains('does not exist') ||
        value.contains('unknown');
    return missing && (value.contains('model') || value.contains('endpoint'));
  }

  void _checkCancelled(CancelCheck? shouldCancel) {
    if (shouldCancel?.call() ?? false) {
      throw const OperationCancelledException();
    }
  }
}
