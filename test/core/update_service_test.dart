import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:listenook/core/update_models.dart';
import 'package:listenook/data/update_installer.dart';
import 'package:listenook/data/update_service.dart';

class _FakeInstaller extends UpdateInstaller {
  final launched = <File>[];
  Object? failure;

  @override
  Future<void> launch(File file, UpdateAsset asset) async {
    if (failure case final error?) throw error;
    launched.add(file);
  }
}

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('listenook-update-test-');
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('downloads, verifies, and exposes a restart-ready update', () async {
    final bytes = <int>[1, 2, 3, 4];
    var manifestRequests = 0;
    var assetRequests = 0;
    final service = _service(
      temporary,
      MockClient((request) async {
        if (request.url.path.endsWith('latest.json')) {
          manifestRequests++;
          expect(request.url.queryParameters['_'], isNotEmpty);
          return http.Response(jsonEncode(_manifest(bytes)), 200);
        }
        assetRequests++;
        return http.Response.bytes(bytes, 200);
      }),
    );
    addTearDown(service.dispose);

    await service.checkAndDownloadNow();

    expect(service.phase, UpdatePhase.readyToRestart);
    expect(service.readyToRestart, isTrue);
    expect(service.progress, 1);
    expect(service.release?.version.name, '2.0.0');
    expect(manifestRequests, 1);
    expect(assetRequests, 1);
    expect(await File('${temporary.path}/Listenook.zip').readAsBytes(), bytes);
  });

  test('reuses a checksum-valid cached package', () async {
    final bytes = <int>[4, 3, 2, 1];
    await File('${temporary.path}/Listenook.zip').writeAsBytes(bytes);
    var assetRequests = 0;
    final service = _service(
      temporary,
      MockClient((request) async {
        if (request.url.path.endsWith('latest.json')) {
          return http.Response(jsonEncode(_manifest(bytes)), 200);
        }
        assetRequests++;
        return http.Response.bytes(bytes, 200);
      }),
    );
    addTearDown(service.dispose);

    await service.checkAndDownloadNow();

    expect(service.phase, UpdatePhase.readyToRestart);
    expect(assetRequests, 0);
  });

  test(
    'an invalid download is deleted and schedules a background retry',
    () async {
      final expected = <int>[1, 2, 3];
      final wrong = <int>[9, 9, 9];
      final service = _service(
        temporary,
        MockClient((request) async {
          if (request.url.path.endsWith('latest.json')) {
            return http.Response(jsonEncode(_manifest(expected)), 200);
          }
          return http.Response.bytes(wrong, 200);
        }),
        automaticEnabled: true,
        initialDelay: const Duration(milliseconds: 1),
        retryInterval: const Duration(hours: 1),
      );
      addTearDown(service.dispose);

      await service.start();
      final timeout = Stopwatch()..start();
      while ((service.phase != UpdatePhase.failed ||
              service.scheduledDelay != const Duration(hours: 1)) &&
          timeout.elapsed < const Duration(seconds: 2)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(service.phase, UpdatePhase.failed);
      expect(service.scheduledDelay, const Duration(hours: 1));
      expect(File('${temporary.path}/Listenook.zip').existsSync(), isFalse);
      expect(File('${temporary.path}/Listenook.zip.part').existsSync(), isFalse);
    },
  );

  test('coalesces concurrent checks and reports an up-to-date build', () async {
    var requests = 0;
    final bytes = <int>[1];
    final service = _service(
      temporary,
      MockClient((request) async {
        requests++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return http.Response(
          jsonEncode(_manifest(bytes, version: '1.0.0', build: 1)),
          200,
        );
      }),
    );
    addTearDown(service.dispose);

    await Future.wait([
      service.checkAndDownloadNow(),
      service.checkAndDownloadNow(),
    ]);

    expect(requests, 1);
    expect(service.phase, UpdatePhase.upToDate);
    expect(service.readyToRestart, isFalse);
  });

  test('cleans interrupted partials during initialization', () async {
    final partial = File('${temporary.path}/old.zip.part');
    await partial.writeAsString('partial');
    final service = _service(
      temporary,
      MockClient((_) async => http.Response('{}', 500)),
    );
    addTearDown(service.dispose);

    await service.initialize();

    expect(partial.existsSync(), isFalse);
  });

  test('shutdown cancels a scheduled automatic check', () async {
    var requests = 0;
    final service = _service(
      temporary,
      MockClient((_) async {
        requests++;
        return http.Response('{}', 500);
      }),
      automaticEnabled: true,
      initialDelay: const Duration(milliseconds: 20),
    );
    addTearDown(service.dispose);

    await service.start();
    service.shutdown();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(requests, 0);
    expect(service.scheduledDelay, isNull);
  });

  test('removes installed and superseded update packages', () async {
    final oldPackage = File('${temporary.path}/Listenook-old.zip');
    await oldPackage.writeAsBytes([1]);
    final bytes = <int>[2];
    final newer = _service(
      temporary,
      MockClient(
        (request) async => request.url.path.endsWith('latest.json')
            ? http.Response(jsonEncode(_manifest(bytes)), 200)
            : http.Response.bytes(bytes, 200),
      ),
    );
    addTearDown(newer.dispose);

    await newer.checkAndDownloadNow();
    expect(oldPackage.existsSync(), isFalse);
    expect(File('${temporary.path}/Listenook.zip').existsSync(), isTrue);

    final current = UpdateService(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode(_manifest(bytes, version: '1.0.0', build: 1)),
          200,
        ),
      ),
      installer: _FakeInstaller(),
      manifestUri: Uri.parse('https://example.com/latest.json'),
      readCurrentVersion: () async => const AppVersion(1, 0, 0, build: 1),
      updatesDirectory: () async => temporary,
      platformKey: 'macos-arm64',
      automaticEnabled: false,
    );
    addTearDown(current.dispose);
    await current.checkAndDownloadNow();
    expect(File('${temporary.path}/Listenook.zip').existsSync(), isFalse);
  });

  test('launch failure retains the verified package for retry', () async {
    final installer = _FakeInstaller();
    final bytes = <int>[8, 7, 6];
    final service = _service(
      temporary,
      MockClient(
        (request) async => request.url.path.endsWith('latest.json')
            ? http.Response(jsonEncode(_manifest(bytes)), 200)
            : http.Response.bytes(bytes, 200),
      ),
      installer: installer,
    );
    addTearDown(service.dispose);
    await service.checkAndDownloadNow();
    installer.failure = const UpdateInstallException('launch failed');

    await expectLater(
      service.installReadyUpdate(),
      throwsA(isA<UpdateInstallException>()),
    );

    expect(service.phase, UpdatePhase.readyToRestart);
    expect(service.readyToRestart, isTrue);
  });
}

UpdateService _service(
  Directory directory,
  http.Client client, {
  UpdateInstaller? installer,
  bool automaticEnabled = false,
  Duration initialDelay = Duration.zero,
  Duration retryInterval = const Duration(minutes: 15),
}) => UpdateService(
  client: client,
  installer: installer ?? _FakeInstaller(),
  manifestUri: Uri.parse('https://example.com/latest.json'),
  readCurrentVersion: () async => const AppVersion(1, 0, 0, build: 1),
  updatesDirectory: () async => directory,
  platformKey: 'macos-arm64',
  automaticEnabled: automaticEnabled,
  initialDelay: initialDelay,
  retryInterval: retryInterval,
);

Map<String, Object?> _manifest(
  List<int> bytes, {
  String version = '2.0.0',
  int build = 2,
}) => {
  'schema': 1,
  'platforms': {
    'macos-arm64': {
      'version': version,
      'build': build,
      'kind': 'appZip',
      'fileName': 'Listenook.zip',
      'size': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
      'url': 'https://example.com/Listenook.zip',
    },
  },
};
