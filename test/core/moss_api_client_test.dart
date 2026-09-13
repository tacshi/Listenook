import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/contracts.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/data/moss_api_client.dart';

void main() {
  test(
    'validates the candidate key and requires MOSS Pro model access',
    () async {
      late HttpServer server;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final authorizations = <String?>[];
      server.listen((request) async {
        authorizations.add(
          request.headers.value(HttpHeaders.authorizationHeader),
        );
        request.response.write(
          jsonEncode({
            'object': 'list',
            'data': [
              {'id': 'moss-transcribe-diarize'},
            ],
          }),
        );
        await request.response.close();
      });
      final client = MossApiClient(
        _Credential(),
        baseUri: Uri.parse(
          'http://${server.address.address}:${server.port}/v1',
        ),
      );

      await client.validateKey(apiKey: 'candidate-key');

      expect(authorizations, ['Bearer candidate-key']);
    },
  );

  test('rejects a valid account without MOSS Pro model access', () async {
    late HttpServer server;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.write(
        jsonEncode({
          'object': 'list',
          'data': [
            {'id': 'moss-transcribe'},
          ],
        }),
      );
      await request.response.close();
    });
    final client = MossApiClient(
      _Credential(),
      baseUri: Uri.parse('http://${server.address.address}:${server.port}/v1'),
    );

    await expectLater(
      client.validateKey(),
      throwsA(
        isA<MossException>().having(
          (error) => error.code,
          'code',
          'moss_model_unavailable',
        ),
      ),
    );
  });

  test(
    'uploads audio and returns a diarized asynchronous transcript',
    () async {
      final directory = await Directory.systemTemp.createTemp('moss-client-');
      addTearDown(() => directory.delete(recursive: true));
      final media = File('${directory.path}/meeting.wav');
      await media.writeAsBytes(List.filled(128 * 1024, 7));
      late HttpServer server;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <String>[];
      Map<String, dynamic>? createBody;
      String? uploadBody;
      server.listen((request) async {
        requests.add('${request.method} ${request.uri.path}');
        if (request.method == 'POST' && request.uri.path == '/v1/files') {
          uploadBody = await latin1.decoder.bind(request).join();
          request.response.write(jsonEncode({'id': 'file-1'}));
        } else if (request.method == 'POST' &&
            request.uri.path == '/v1/audio/transcriptions') {
          createBody =
              (jsonDecode(await utf8.decoder.bind(request).join()) as Map)
                  .cast<String, dynamic>();
          request.response.write(
            jsonEncode({
              'task_id': 'task-1',
              'status': 'PENDING',
              'retry_after': 3,
            }),
          );
        } else if (request.method == 'GET' &&
            request.uri.path == '/v1/audio/tasks/task-1') {
          request.response.write(
            jsonEncode({
              'id': 'task-1',
              'status': 'SUCCESS',
              'duration': 4.25,
              'text': '你好。欢迎。',
              'segments': [
                {
                  'id': 'segment-a',
                  'start': 0.25,
                  'end': 1.5,
                  'text': '你好。',
                  'speaker': 'S01',
                },
                {
                  'id': 'segment-b',
                  'start': 1.75,
                  'end': 4.25,
                  'text': '欢迎。',
                  'speaker': 'S02',
                },
              ],
            }),
          );
        } else if (request.method == 'DELETE' &&
            request.uri.path == '/v1/files/file-1') {
          request.response.write(jsonEncode({'id': 'file-1', 'deleted': true}));
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
      final client = MossApiClient(
        _Credential(),
        baseUri: Uri.parse(
          'http://${server.address.address}:${server.port}/v1',
        ),
      );
      final progress = <double>[];

      final fileId = await client.uploadFile(
        media.path,
        onProgress: (fraction, _) {
          if (fraction != null) progress.add(fraction);
        },
      );
      final taskId = await client.createTranscription(
        fileId,
        const TranscriptionOptions(
          languageHints: ['zh'],
          contextTerms: ['must-not-be-sent'],
        ),
      );
      final state = await client.getTranscription(taskId);
      final document = const MossTranscriptParser().parse(
        await client.getTranscript(taskId),
      );
      await client.deleteTranscription(taskId);
      await client.deleteFile(fileId);

      expect(fileId, 'file-1');
      expect(taskId, 'task-1');
      expect(progress.last, 1);
      expect(uploadBody, contains('name="purpose"'));
      expect(uploadBody, contains('audio'));
      expect(createBody, {
        'model': 'moss-transcribe-diarize',
        'version': 'v20260410-streamparam-20260703',
        'file_id': 'file-1',
        'diarize': true,
        'response_format': 'json',
        'async': true,
      });
      expect(state.isComplete, isTrue);
      expect(document.tokens, isEmpty);
      expect(document.segments.first.startMs, 250);
      expect(document.segments.last.endMs, 4250);
      expect(document.speakers.map((speaker) => speaker.id), ['S01', 'S02']);
      expect(requests, contains('DELETE /v1/files/file-1'));
      expect(requests, isNot(contains('DELETE /v1/audio/tasks/task-1')));
    },
  );

  test('preserves non-empty text when MOSS returns no segments', () {
    final document = const MossTranscriptParser().parse({
      'duration': 2.75,
      'text': 'Short message',
      'segments': const [],
    });

    expect(document.segments.single.text, 'Short message');
    expect(document.segments.single.startMs, 0);
    expect(document.segments.single.endMs, 2750);
  });

  test('exposes retry hints and asynchronous failure details', () async {
    late HttpServer server;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var calls = 0;
    server.listen((request) async {
      calls++;
      request.response.write(
        calls == 1
            ? jsonEncode({'status': 'PROCESSING', 'retry_after': 45})
            : jsonEncode({
                'status': 'FAILED',
                'error': {
                  'error_code': 16001,
                  'error_msg': 'billing error',
                  'internal_error_msg': 'insufficient credits',
                },
              }),
      );
      await request.response.close();
    });
    final client = MossApiClient(
      _Credential(),
      baseUri: Uri.parse('http://${server.address.address}:${server.port}/v1'),
    );

    final processing = await client.getTranscription('task-1');
    final failed = await client.getTranscription('task-1');

    expect(processing.retryAfter, const Duration(seconds: 30));
    expect(failed.isFailed, isTrue);
    expect(failed.errorType, 'insufficient credits');
    expect(failed.errorMessage, 'billing error');
    expect(canonicalMossErrorCode(failed.errorType), 'moss_exhausted_balance');
  });

  test('maps MOSS billing errors without exposing the API key', () async {
    late HttpServer server;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response
        ..statusCode = HttpStatus.paymentRequired
        ..write(
          jsonEncode({
            'error': {
              'message': 'insufficient credits',
              'type': 'billing_error',
              'code': 'insufficient_credits',
            },
          }),
        );
      await request.response.close();
    });
    final client = MossApiClient(
      _Credential(),
      baseUri: Uri.parse('http://${server.address.address}:${server.port}/v1'),
    );

    await expectLater(
      client.validateKey(apiKey: 'secret-candidate-key'),
      throwsA(
        isA<MossException>()
            .having((error) => error.code, 'code', 'moss_exhausted_balance')
            .having(
              (error) => error.toString(),
              'redacted',
              isNot(contains('secret-candidate-key')),
            ),
      ),
    );
  });
}

class _Credential implements CredentialStore {
  @override
  Future<void> deleteApiKey() async {}

  @override
  Future<String?> readApiKey() async => 'stored-key';

  @override
  Future<void> writeApiKey(String key) async {}
}
