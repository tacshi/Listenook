import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/contracts.dart';
import 'package:listenook/data/moss_api_client.dart';
import 'package:listenook/data/soniox_api_client.dart';

import '../support/fakes.dart';

/// The behaviour Soniox and MOSS share through RemoteTranscriptionApi, run
/// against both so each keeps its own error codes.
void main() {
  late HttpServer server;
  late Directory directory;
  var requests = 0;
  var status = 200;
  var body = '{}';

  setUp(() async {
    requests = 0;
    status = 200;
    body = '{}';
    directory = await Directory.systemTemp.createTemp('remote-api-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      try {
        await request.drain<void>();
      } on HttpException {
        return; // The client cancelled the upload mid-body.
      }
      request.response
        ..statusCode = status
        ..write(body);
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  Uri base() => Uri.parse('http://${server.address.address}:${server.port}/v1');

  final services = <String, TranscriptionClient Function(Uri, String?)>{
    'Soniox': (uri, key) =>
        SonioxApiClient(MemoryCredentialStore(key), baseUri: uri),
    'MOSS': (uri, key) =>
        MossApiClient(MemoryCredentialStore(key), baseUri: uri),
  };
  const prefixes = {'Soniox': '', 'MOSS': 'moss_'};

  /// The code, message, status and retry flag of the service's exception.
  Matcher failure(
    String service,
    String code, {
    String? message,
    int? statusCode,
    bool? retryable,
  }) => isA<Object>().having(
    (error) {
      final dynamic remote = error;
      return (
        code: remote.code as String,
        message: remote.message as String,
        statusCode: remote.statusCode as int?,
        retryable: remote.retryable as bool,
      );
    },
    'failure',
    isA<({String code, String message, int? statusCode, bool retryable})>()
        .having((value) => value.code, 'code', '${prefixes[service]}$code')
        .having((value) => value.message, 'message', message ?? anything)
        .having(
          (value) => value.statusCode,
          'statusCode',
          statusCode ?? anything,
        )
        .having((value) => value.retryable, 'retryable', retryable ?? anything),
  );

  for (final MapEntry(key: service, value: create) in services.entries) {
    group(service, () {
      test('a missing key fails before any request', () async {
        await expectLater(
          create(base(), null).getTranscript('task'),
          throwsA(
            failure(
              service,
              'missing_credentials',
              message: 'A $service API key is required.',
            ),
          ),
        );
        expect(requests, 0);
      });

      test('server failures are retryable and keep the status', () async {
        status = 503;
        body = 'Service Unavailable';
        await expectLater(
          create(base(), 'key').getTranscript('task'),
          throwsA(
            failure(
              service,
              'server_failure',
              message: '$service request failed (HTTP 503).',
              statusCode: 503,
              retryable: true,
            ),
          ),
        );
      });

      test('rejected keys are not retryable', () async {
        status = 401;
        await expectLater(
          create(base(), 'key').getTranscript('task'),
          throwsA(failure(service, 'bad_credentials', retryable: false)),
        );
      });

      test('an unreadable success response is reported', () async {
        body = 'not json';
        await expectLater(
          create(base(), 'key').getTranscript('task'),
          throwsA(
            failure(
              service,
              'invalid_response',
              message: '$service returned an unreadable response.',
            ),
          ),
        );
      });

      test('deleting a file that is already gone succeeds', () async {
        status = 404;
        await create(base(), 'key').deleteFile('file');
        expect(requests, 1);
      });

      test('upload reports progress and Cancel stops it', () async {
        final audio = File('${directory.path}/audio.wav');
        await audio.writeAsBytes(List.filled(512 * 1024, 1));
        body = jsonEncode({'id': 'file-1'});
        final client = create(base(), 'key');
        final fractions = <double?>[];

        expect(
          await client.uploadFile(
            audio.path,
            onProgress: (fraction, _) => fractions.add(fraction),
          ),
          'file-1',
        );
        expect(fractions.last, 1);

        var chunks = 0;
        await expectLater(
          client.uploadFile(
            audio.path,
            onProgress: (_, _) => chunks++,
            shouldCancel: () => chunks > 0,
          ),
          throwsA(isA<OperationCancelledException>()),
        );
      });
    });
  }
}
