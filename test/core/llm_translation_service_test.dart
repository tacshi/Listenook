import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:listenook/core/contracts.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/data/llm_translation_service.dart';
import 'package:listenook/data/openai_llm_client.dart';

void main() {
  test('translation settings require HTTPS except on loopback hosts', () {
    expect(
      const TranslationSettings(
        baseUrl: 'http://example.com/v1',
        model: 'model',
      ).validationError(),
      'translation_https_required',
    );
    expect(
      const TranslationSettings(
        baseUrl: 'http://localhost:11434/v1',
        model: 'model',
      ).isConfigured(hasApiKey: false),
      isTrue,
    );
    expect(
      const TranslationSettings(
        baseUrl: 'http://[::1]:8080/v1',
        model: 'model',
      ).isConfigured(hasApiKey: false),
      isTrue,
    );
    expect(
      const TranslationSettings(
        baseUrl: 'https://secret@example.com/v1',
        model: 'model',
      ).validationError(),
      'translation_invalid_url',
    );
  });

  test(
    'model discovery tests candidate values without saving the key',
    () async {
      final credentials = _Credentials('stored-key');
      final service = _service(
        credentials,
        httpClient: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.toString(), 'https://llm.example/v1/models');
          expect(request.headers['authorization'], 'Bearer candidate-key');
          return http.Response(
            jsonEncode({
              'object': 'list',
              'data': [
                {'id': 'z-model'},
                {'id': 'a-model'},
              ],
            }),
            200,
          );
        }),
      );

      final models = await service.listModels(
        const TranslationSettings(baseUrl: 'https://llm.example/v1'),
        candidateApiKey: 'candidate-key',
      );

      expect(models, ['a-model', 'z-model']);
      expect(credentials.value, 'stored-key');
    },
  );

  test('loopback discovery does not send a stored cloud key', () async {
    final service = _service(
      _Credentials('stored-cloud-key'),
      httpClient: MockClient((request) async {
        expect(request.url.toString(), 'http://localhost:11434/v1/models');
        expect(request.headers, isNot(contains('authorization')));
        return http.Response(jsonEncode({'data': <Object>[]}), 200);
      }),
    );

    final models = await service.listModels(
      const TranslationSettings(baseUrl: 'http://localhost:11434/v1'),
    );

    expect(models, isEmpty);
  });

  test(
    'chat completions use official shape and align numbered output',
    () async {
      final credentials = _Credentials('secret');
      late Map<String, dynamic> requestBody;
      final service = _service(
        credentials,
        httpClient: MockClient((request) async {
          expect(request.method, 'POST');
          expect(
            request.url.toString(),
            'https://llm.example/v1/chat/completions',
          );
          expect(request.headers['authorization'], 'Bearer secret');
          requestBody = (jsonDecode(request.body) as Map)
              .cast<String, dynamic>();
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'id': 'chatcmpl-test',
                'choices': [
                  {
                    'index': 0,
                    'message': {'role': 'assistant', 'content': '1. 你好\n2. 世界'},
                    'finish_reason': 'stop',
                  },
                ],
              }),
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final updates = <String, String>{};

      await service.translate(
        settings: const TranslationSettings(
          baseUrl: 'https://llm.example/v1',
          model: 'translate-model',
        ),
        targetLanguage: 'zh-Hans',
        segments: const [
          TranscriptSegment(id: '1', startMs: 0, endMs: 1, text: 'Hello'),
          TranscriptSegment(id: '2', startMs: 1, endMs: 2, text: 'Hello'),
          TranscriptSegment(id: '3', startMs: 2, endMs: 3, text: 'World'),
        ],
        onBatch: (batch, _, _) async => updates.addAll(batch),
      );

      expect(requestBody['model'], 'translate-model');
      final messages = requestBody['messages'] as List;
      expect(messages, hasLength(2));
      expect((messages.first as Map)['role'], 'system');
      expect((messages.last as Map)['role'], 'user');
      expect(updates, {'1': '你好', '2': '你好', '3': '世界'});
    },
  );

  test(
    'credential failures map to a stable error without exposing keys',
    () async {
      final service = _service(
        _Credentials('top-secret'),
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {'message': 'invalid credential'},
            }),
            401,
          ),
        ),
      );

      await expectLater(
        service.listModels(
          const TranslationSettings(baseUrl: 'https://llm.example/v1'),
        ),
        throwsA(
          isA<TranslationException>()
              .having(
                (error) => error.code,
                'code',
                'translation_bad_credentials',
              )
              .having(
                (error) => error.toString(),
                'safe string',
                isNot(contains('top-secret')),
              ),
        ),
      );
    },
  );

  test('transient failures are retried up to three times', () async {
    var attempts = 0;
    final delays = <Duration>[];
    final service = _service(
      _Credentials('secret'),
      delay: (duration) async => delays.add(duration),
      httpClient: MockClient((_) async {
        attempts++;
        if (attempts < 4) return http.Response('{}', 429);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': '1. Translated'},
              },
            ],
          }),
          200,
        );
      }),
    );
    final updates = <String, String>{};

    await service.translate(
      settings: const TranslationSettings(
        baseUrl: 'https://llm.example/v1',
        model: 'model',
      ),
      targetLanguage: 'en',
      segments: const [
        TranscriptSegment(id: 'one', startMs: 0, endMs: 1, text: 'Source'),
      ],
      onBatch: (batch, _, _) async => updates.addAll(batch),
    );

    expect(attempts, 4);
    expect(delays, const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ]);
    expect(updates['one'], 'Translated');
  });

  test(
    'requests contain at most 20 segments or 8000 source characters',
    () async {
      var calls = 0;
      final service = _service(
        _Credentials('secret'),
        httpClient: MockClient((request) async {
          calls++;
          final body = (jsonDecode(request.body) as Map)
              .cast<String, dynamic>();
          final messages = body['messages'] as List;
          final prompt = (messages.last as Map)['content'] as String;
          final input = prompt.split('Input:\n').last.split('\n\nOutput').first;
          final lines = const LineSplitter().convert(input);
          expect(lines.length, lessThanOrEqualTo(20));
          final sourceCharacters = lines.fold<int>(
            0,
            (total, line) =>
                total + line.replaceFirst(RegExp(r'^\d+\. '), '').length,
          );
          expect(sourceCharacters, lessThanOrEqualTo(8000));
          final content = [
            for (var index = 0; index < lines.length; index++)
              '${index + 1}. translated-${index + 1}',
          ].join('\n');
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': content},
                },
              ],
            }),
            200,
          );
        }),
      );
      final updates = <String, String>{};

      await service.translate(
        settings: const TranslationSettings(
          baseUrl: 'https://llm.example/v1',
          model: 'model',
        ),
        targetLanguage: 'en',
        segments: [
          for (var index = 0; index < 21; index++)
            TranscriptSegment(
              id: '$index',
              startMs: index,
              endMs: index + 1,
              text: 'source-$index',
            ),
        ],
        onBatch: (batch, _, _) async => updates.addAll(batch),
      );
      expect(calls, 2);
      expect(updates, hasLength(21));

      calls = 0;
      updates.clear();
      await service.translate(
        settings: const TranslationSettings(
          baseUrl: 'https://llm.example/v1',
          model: 'model',
        ),
        targetLanguage: 'en',
        segments: [
          TranscriptSegment(
            id: 'long',
            startMs: 0,
            endMs: 1,
            text: List.filled(8001, 'a').join(),
          ),
        ],
        onBatch: (batch, _, _) async => updates.addAll(batch),
      );
      expect(calls, 2);
      expect(updates['long'], 'translated-1 translated-1');
    },
  );

  test('cancelling aborts the in-flight request', () async {
    var requestSent = false;
    final service = _service(
      _Credentials('secret'),
      // MockClient leaves aborting to the handler: wait for the trigger.
      httpClient: MockClient.streaming((request, _) async {
        requestSent = true;
        if (request case http.Abortable(:final abortTrigger?)) {
          await abortTrigger;
          throw http.RequestAbortedException(request.url);
        }
        fail('The request has no abort trigger.');
      }),
    );

    await expectLater(
      service.translate(
        settings: const TranslationSettings(
          baseUrl: 'https://llm.example/v1',
          model: 'model',
        ),
        targetLanguage: 'en',
        segments: const [
          TranscriptSegment(id: 'one', startMs: 0, endMs: 1, text: 'Source'),
        ],
        onBatch: (_, _, _) async {},
        shouldCancel: () => requestSent,
      ),
      throwsA(isA<OperationCancelledException>()),
    );
  });
}

LlmTranslationService _service(
  TranslationCredentialStore credentials, {
  required http.Client httpClient,
  Future<void> Function(Duration duration)? delay,
}) => LlmTranslationService(
  OpenAiCompatibleLlmClient(credentials, httpClient: httpClient, delay: delay),
);

class _Credentials implements TranslationCredentialStore {
  _Credentials(this.value);

  String? value;

  @override
  Future<void> deleteApiKey() async => value = null;

  @override
  Future<String?> readApiKey() async => value;

  @override
  Future<void> writeApiKey(String key) async => value = key;
}
