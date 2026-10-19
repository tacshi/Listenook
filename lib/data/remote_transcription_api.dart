import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../core/contracts.dart';

/// The error type and message a service put in a failed response's body.
typedef RemoteErrorBody = ({String type, String? message});

/// Plumbing shared by the Soniox and MOSS clients: bearer-key headers, file
/// uploads that report progress and can be cancelled, JSON responses, and
/// turning a failed response into the service's exception with a stable
/// error code.
///
/// Error codes are [codePrefix] plus a name, such as `bad_credentials`, so
/// each service keeps its own codes and messages.
abstract class RemoteTranscriptionApi {
  RemoteTranscriptionApi(
    this._credentials, {
    required this.serviceName,
    required this.codePrefix,
    required Uri defaultBaseUri,
    http.Client? httpClient,
    Uri? baseUri,
  }) : client = httpClient ?? http.Client(),
       _base = (baseUri ?? defaultBaseUri).toString().replaceFirst(
         RegExp(r'/$'),
         '',
       );

  final CredentialStore _credentials;
  final String serviceName;
  final String codePrefix;
  final http.Client client;
  final String _base;

  /// Builds the service's exception.
  Exception exception({
    required String code,
    required String message,
    int? statusCode,
    String? errorType,
    bool retryable = false,
  });

  /// Reads the service's own error type and message from a failed response.
  RemoteErrorBody parseErrorBody(Map<String, dynamic> json);

  /// The error code for a failed response the shared mapping does not cover
  /// (anything but 401, 403, 429 and 5xx). [type] is empty when the service
  /// gave none.
  String errorCodeFor(int statusCode, String type);

  Uri uri(String path) => Uri.parse('$_base$path');

  Future<Map<String, String>> headers({
    bool json = false,
    String? apiKey,
  }) async {
    final candidate = apiKey?.trim();
    final key = candidate == null || candidate.isEmpty
        ? await _credentials.readApiKey()
        : candidate;
    if (key == null || key.isEmpty) {
      throw exception(
        code: '${codePrefix}missing_credentials',
        message: 'A $serviceName API key is required.',
      );
    }
    return {
      'Authorization': 'Bearer $key',
      if (json) 'Content-Type': 'application/json',
    };
  }

  /// GETs [path], throwing the service's exception unless it succeeded.
  Future<http.Response> get(
    String path, {
    required Duration timeout,
    String? apiKey,
  }) async {
    final response = await client
        .get(uri(path), headers: await headers(apiKey: apiKey))
        .timeout(timeout);
    ensureSuccess(response.statusCode, response.body);
    return response;
  }

  Future<Map<String, dynamic>> getObject(
    String path, {
    required Duration timeout,
  }) async => object((await get(path, timeout: timeout)).body);

  /// POSTs [body] as JSON and returns the response body.
  Future<String> postJson(
    String path,
    Object body, {
    required Duration timeout,
  }) async {
    final response = await client
        .post(
          uri(path),
          headers: await headers(json: true),
          body: jsonEncode(body),
        )
        .timeout(timeout);
    ensureSuccess(response.statusCode, response.body);
    return response.body;
  }

  /// DELETEs [path]; a resource that is already gone counts as deleted.
  Future<void> delete(String path) async {
    final response = await client
        .delete(uri(path), headers: await headers())
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 404) return;
    ensureSuccess(response.statusCode, response.body);
  }

  /// Uploads [filePath] as the multipart `file` field and returns the
  /// response body. Progress is reported per chunk sent, and [shouldCancel]
  /// is checked before each one.
  Future<String> upload(
    String path,
    String filePath, {
    Map<String, String> fields = const {},
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    final file = File(filePath);
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
    final request = http.MultipartRequest('POST', uri(path))
      ..headers.addAll(await headers())
      ..fields.addAll(fields)
      ..files.add(
        http.MultipartFile(
          'file',
          stream,
          length,
          filename: p.basename(filePath),
        ),
      );
    final response = await client
        .send(request)
        .timeout(const Duration(hours: 2));
    final body = await response.stream.bytesToString();
    ensureSuccess(response.statusCode, body);
    return body;
  }

  Map<String, dynamic> object(String body) {
    try {
      return (jsonDecode(body) as Map).cast<String, dynamic>();
    } on Object {
      throw exception(
        code: '${codePrefix}invalid_response',
        message: '$serviceName returned an unreadable response.',
      );
    }
  }

  /// The first non-empty value among [keys] in a JSON object [body].
  String requiredId(
    String body, {
    List<String> keys = const ['id'],
    required String operation,
  }) {
    final json = object(body);
    for (final key in keys) {
      final value = json[key]?.toString();
      if (value != null && value.isNotEmpty) return value;
    }
    throw exception(
      code: '${codePrefix}invalid_response',
      message: '$serviceName $operation response did not contain an id.',
    );
  }

  void ensureSuccess(int statusCode, String body) {
    if (statusCode >= 200 && statusCode < 300) return;
    var type = '';
    String? message;
    try {
      (:type, :message) = parseErrorBody(
        (jsonDecode(body) as Map).cast<String, dynamic>(),
      );
    } on Object {
      // The HTTP status still gives a stable category.
    }
    throw exception(
      code: switch (statusCode) {
        401 || 403 => '${codePrefix}bad_credentials',
        429 => '${codePrefix}rate_limit',
        >= 500 => '${codePrefix}server_failure',
        _ => errorCodeFor(statusCode, type),
      },
      message: message ?? '$serviceName request failed (HTTP $statusCode).',
      statusCode: statusCode,
      errorType: type.isEmpty ? null : type,
      retryable: statusCode == 408 || statusCode == 429 || statusCode >= 500,
    );
  }
}
