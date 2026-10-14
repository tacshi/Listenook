import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:listenook/core/contracts.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/data/openai_llm_client.dart';

void main() {
  test(
    'completion sends prompts but never places credentials in JSON',
    () async {
      late Map<String, dynamic> body;
      final client = OpenAiCompatibleLlmClient(
        _Credentials('top-secret'),
        httpClient: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer top-secret');
          body = (jsonDecode(request.body) as Map).cast<String, dynamic>();
          expect(request.body, isNot(contains('top-secret')));
          expect(request.body, isNot(contains('media_bytes')));
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '{"overview":"ok"}'},
                },
              ],
            }),
            200,
          );
        }),
      );

      final result = await client.complete(
        settings: const LlmProviderSettings(
          baseUrl: 'https://llm.example/v1',
          model: 'brief-model',
        ),
        systemPrompt: 'System',
        userPrompt: 'Transcript text only',
      );

      expect(body['model'], 'brief-model');
      expect((body['messages'] as List), hasLength(2));
      expect(result, '{"overview":"ok"}');
    },
  );

  test('local model discovery does not send a stored cloud key', () async {
    final client = OpenAiCompatibleLlmClient(
      _Credentials('stored-cloud-key'),
      httpClient: MockClient((request) async {
        expect(request.headers, isNot(contains('authorization')));
        return http.Response(jsonEncode({'data': <Object>[]}), 200);
      }),
    );

    await client.listModels(
      const LlmProviderSettings(baseUrl: 'http://localhost:11434/v1'),
    );
  });

  test('transient failures retry with bounded exponential backoff', () async {
    var attempts = 0;
    final delays = <Duration>[];
    final client = OpenAiCompatibleLlmClient(
      _Credentials('secret'),
      delay: (duration) async => delays.add(duration),
      httpClient: MockClient((request) async {
        attempts++;
        if (attempts < 4) return http.Response('{}', 429);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'done'},
              },
            ],
          }),
          200,
        );
      }),
    );

    expect(
      await client.complete(
        settings: const LlmProviderSettings(
          baseUrl: 'https://llm.example/v1',
          model: 'model',
        ),
        systemPrompt: 'system',
        userPrompt: 'prompt',
      ),
      'done',
    );
    expect(attempts, 4);
    expect(delays, const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ]);
  });

  test('JSON mode falls back once for providers that reject it', () async {
    final formats = <Object?>[];
    final client = OpenAiCompatibleLlmClient(
      _Credentials('secret'),
      httpClient: MockClient((request) async {
        final body = (jsonDecode(request.body) as Map).cast<String, dynamic>();
        formats.add(body['response_format']);
        if (body.containsKey('response_format')) {
          return http.Response(
            jsonEncode({
              'error': {'message': 'response_format is not supported'},
            }),
            400,
          );
        }
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '{"overview":"ok"}'},
              },
            ],
          }),
          200,
        );
      }),
    );
    Future<String> complete() => client.complete(
      settings: const LlmProviderSettings(
        baseUrl: 'https://llm.example/v1',
        model: 'model',
      ),
      systemPrompt: 'Return JSON only.',
      userPrompt: 'prompt',
      jsonObject: true,
    );

    expect(await complete(), '{"overview":"ok"}');
    expect(await complete(), '{"overview":"ok"}');
    expect(formats, [
      {'type': 'json_object'},
      null,
      null,
    ]);
  });

  test('cancelling aborts the in-flight request', () async {
    var requestSent = false;
    final client = OpenAiCompatibleLlmClient(
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
      client.complete(
        settings: const LlmProviderSettings(
          baseUrl: 'https://llm.example/v1',
          model: 'model',
        ),
        systemPrompt: 'system',
        userPrompt: 'prompt',
        shouldCancel: () => requestSent,
      ),
      throwsA(isA<OperationCancelledException>()),
    );
  });
}

class _Credentials implements LlmCredentialStore {
  _Credentials(this.value);

  String? value;

  @override
  Future<void> deleteApiKey() async => value = null;

  @override
  Future<String?> readApiKey() async => value;

  @override
  Future<void> writeApiKey(String key) async => value = key;
}
