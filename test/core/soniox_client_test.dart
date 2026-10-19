import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/data/soniox_api_client.dart';
import '../support/fakes.dart';

void main() {
  late HttpServer server;
  late SonioxApiClient client;
  late Directory directory;
  final requests = <String>[];
  final authorizations = <String?>[];
  Map<String, dynamic>? createBody;
  var rejectKey = false;

  setUp(() async {
    requests.clear();
    authorizations.clear();
    createBody = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    directory = await Directory.systemTemp.createTemp('soniox-client-');
    client = SonioxApiClient(
      MemoryCredentialStore('test-key'),
      baseUri: Uri.parse('http://${server.address.address}:${server.port}/v1'),
    );
    server.listen((request) async {
      requests.add('${request.method} ${request.uri.path}');
      authorizations.add(
        request.headers.value(HttpHeaders.authorizationHeader),
      );
      if (rejectKey) {
        request.response
          ..statusCode = 401
          ..write(
            jsonEncode({
              'error_type': 'authentication_error',
              'message': 'Bad key',
            }),
          );
        await request.response.close();
        return;
      }
      if (request.method == 'POST' && request.uri.path == '/v1/files') {
        final bytes = await request.fold<List<int>>(
          [],
          (all, chunk) => all..addAll(chunk),
        );
        expect(bytes, isNotEmpty);
        request.response.write(jsonEncode({'id': 'file-1'}));
      } else if (request.method == 'POST' &&
          request.uri.path == '/v1/transcriptions') {
        createBody =
            (jsonDecode(await utf8.decoder.bind(request).join()) as Map)
                .cast<String, dynamic>();
        request.response.write(jsonEncode({'id': 'tx-1'}));
      } else if (request.method == 'GET' &&
          request.uri.path == '/v1/transcriptions/tx-1') {
        request.response.write(jsonEncode({'status': 'completed'}));
      } else if (request.method == 'GET' &&
          request.uri.path.endsWith('/transcript')) {
        request.response.write(jsonEncode({'tokens': []}));
      } else if (request.method == 'GET' && request.uri.path == '/v1/files') {
        request.response.write(jsonEncode({'files': []}));
      } else {
        request.response.statusCode = 204;
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  test('streams upload and sends the current async-v5 request body', () async {
    final media = File('${directory.path}/large audio.wav');
    await media.writeAsBytes(List.filled(128 * 1024, 7));
    final progress = <double>[];
    final fileId = await client.uploadFile(
      media.path,
      onProgress: (fraction, _) {
        if (fraction != null) progress.add(fraction);
      },
    );
    final id = await client.createTranscription(
      fileId,
      const TranscriptionOptions(
        languageHints: ['en', 'zh'],
        contextTerms: ['Listenook'],
      ),
    );
    expect(fileId, 'file-1');
    expect(id, 'tx-1');
    expect(progress.last, 1);
    expect(createBody!['model'], 'stt-async-v5');
    expect(createBody!['enable_speaker_diarization'], isTrue);
    expect(createBody!['enable_language_identification'], isTrue);
    expect((createBody!['context'] as Map)['terms'], ['Listenook']);
    expect(createBody!.containsKey('translation'), isFalse);
    expect(authorizations, everyElement('Bearer test-key'));
  });

  test('adds one-way translation to the transcription request', () async {
    final id = await client.createTranscription(
      'file-1',
      const TranscriptionOptions(
        sonioxTranslation: SonioxTranslationOptions(
          enabled: true,
          targetLanguage: 'es',
        ),
      ),
    );

    expect(id, 'tx-1');
    expect(createBody!['translation'], {
      'type': 'one_way',
      'target_language': 'es',
    });
  });

  test('rejects unsupported Soniox translation languages locally', () async {
    await expectLater(
      client.createTranscription(
        'file-1',
        const TranscriptionOptions(
          sonioxTranslation: SonioxTranslationOptions(
            enabled: true,
            targetLanguage: 'yue',
          ),
        ),
      ),
      throwsA(
        isA<SonioxException>().having(
          (error) => error.code,
          'code',
          'soniox_translation_invalid_language',
        ),
      ),
    );
    expect(createBody, isNull);
  });

  test('validates the key currently being edited without saving it', () async {
    await client.validateKey(apiKey: 'candidate-key');

    expect(authorizations.single, 'Bearer candidate-key');
  });

  test('maps stable credential errors without exposing the key', () async {
    rejectKey = true;
    await expectLater(
      client.validateKey(),
      throwsA(
        isA<SonioxException>()
            .having((error) => error.code, 'code', 'bad_credentials')
            .having(
              (error) => error.toString(),
              'redacted',
              isNot(contains('test-key')),
            ),
      ),
    );
  });

  test('maps current Soniox balance and monthly budget error types', () {
    expect(
      canonicalSonioxErrorCode('organization_balance_exhausted'),
      'exhausted_balance',
    );
    expect(
      canonicalSonioxErrorCode('organization_monthly_budget_exhausted'),
      'budget_exhausted',
    );
    expect(
      canonicalSonioxErrorCode('project_monthly_budget_exhausted'),
      'budget_exhausted',
    );
  });
}
