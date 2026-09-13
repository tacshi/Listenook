import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:listenook/core/local_speech.dart';
import 'package:listenook/data/local_model_manager.dart';
import 'package:path/path.dart' as p;

void main() {
  test('Core ML local speech requires macOS 15 and Apple Silicon', () {
    expect(
      CoreMlSpeechRuntimeSupport.isSupported(
        isMacOS: true,
        isArm64: true,
        operatingSystemVersion: 'Version 15.6.1 (Build 24G90)',
      ),
      isTrue,
    );
    expect(
      CoreMlSpeechRuntimeSupport.isSupported(
        isMacOS: true,
        isArm64: true,
        operatingSystemVersion: 'Version 14.7 (Build 23H124)',
      ),
      isFalse,
    );
    expect(
      CoreMlSpeechRuntimeSupport.isSupported(
        isMacOS: true,
        isArm64: false,
        operatingSystemVersion: 'macOS 15.0',
      ),
      isFalse,
    );
  });

  test('production Core ML speech bundles stay pinned to immutable files', () {
    final moss = LocalSpeechModels.mossDiarizeCoreMlInt8;
    final qwen = LocalSpeechModels.qwen3AsrMlx8Bit;
    final vad = LocalSpeechModels.sileroVadCoreMl;
    final aligner = LocalSpeechModels.qwen3ForcedAlignerCoreMlInt8;
    final fp16Aligner = LocalSpeechModels.qwen3ForcedAlignerCoreMlFp16;

    expect(moss.revision, '1cd68cfc84a26f0df95ba0868982d2c185839b62');
    expect(moss.sizeBytes, 1271160422);
    expect(moss.repository, contains('CoreML-INT8'));
    expect(moss.files, hasLength(15));
    expect(qwen.revision, 'e5450a26d1fd417c45fc9c405651ddc3180a27a6');
    expect(qwen.sizeBytes, 2467854870);
    expect(qwen.files, hasLength(6));
    expect(vad.revision, '523876545a57961474fee9df913e833e130560b8');
    expect(vad.sizeBytes, 641874);
    expect(vad.files, hasLength(6));
    expect(LocalSpeechModels.qwen3AsrBundle.artifacts, [qwen, vad]);
    expect(LocalSpeechModels.qwen3AsrBundle.sizeBytes, 2468496744);
    expect(aligner.revision, 'ac27c13a9dae935e7d478b996d89d94ff617e3ca');
    expect(aligner.sizeBytes, 1081578155);
    expect(aligner.repository, contains('CoreML-INT8'));
    expect(aligner.files, hasLength(13));
    expect(fp16Aligner.revision, '04ca8c28f641b9e32a0ac8d1edd3cdec83f22159');
    expect(fp16Aligner.sizeBytes, 1844072687);
    expect(fp16Aligner.repository, contains('CoreML-FP16'));
    expect(fp16Aligner.files, hasLength(13));
    expect(
      aligner.downloadUriFor(aligner.files.first).path,
      contains(aligner.revision),
    );
    expect(
      fp16Aligner.downloadUriFor(fp16Aligner.files.first).path,
      contains(fp16Aligner.revision),
    );
    expect(
      LocalSpeechModels.forcedAlignerById(fp16Aligner.id),
      same(fp16Aligner),
    );
    expect(
      LocalSpeechModels.all
          .expand((model) => [model.id, model.displayName, model.repository])
          .join(' ')
          .toLowerCase(),
      isNot(contains('gguf')),
    );
  });

  test(
    'ordinary status avoids hashing an installed bundle on startup',
    () async {
      final root = await Directory.systemTemp.createTemp('meow-model-fast-');
      addTearDown(() => root.delete(recursive: true));
      final descriptor = _descriptor(const {
        'config.json': [1, 2, 3],
        'model.mlmodelc/weights/weight.bin': [4, 5],
      });
      var digestCalls = 0;
      final manager = HttpLocalModelManager(
        modelsDirectory: root,
        descriptors: [descriptor],
        digestFile: (file) async {
          digestCalls++;
          return sha256.convert(await file.readAsBytes()).toString();
        },
      );
      await _writeBundle(manager.pathFor(descriptor.id), const {
        'config.json': [1, 2, 3],
        'model.mlmodelc/weights/weight.bin': [4, 5],
      });

      final status = await manager.status(descriptor.id);
      expect(status.availability, LocalModelAvailability.ready);
      expect(digestCalls, 0);

      final verified = await manager.status(
        descriptor.id,
        verifyIntegrity: true,
      );
      final verifiedAgain = await manager.status(
        descriptor.id,
        verifyIntegrity: true,
      );
      expect(verified.availability, LocalModelAvailability.ready);
      expect(verifiedAgain.availability, LocalModelAvailability.ready);
      expect(digestCalls, 2);

      final changed = File(
        p.join(manager.pathFor(descriptor.id), 'config.json'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await changed.writeAsBytes(const [3, 2, 1], flush: true);
      final corrupt = await manager.status(
        descriptor.id,
        verifyIntegrity: true,
      );
      expect(corrupt.availability, LocalModelAvailability.corrupt);
      expect(digestCalls, 3);
    },
  );

  test(
    'download resumes bundle files and installs the directory atomically',
    () async {
      final root = await Directory.systemTemp.createTemp('meow-model-test-');
      addTearDown(() => root.delete(recursive: true));
      final descriptor = _descriptor(const {
        'config.json': [1, 2, 3],
        'model.mlmodelc/weights/weight.bin': [4, 5, 6, 7],
      });
      final partial = File(
        p.join(
          root.path,
          '.fixture.part',
          'model.mlmodelc',
          'weights',
          'weight.bin.part',
        ),
      );
      await partial.parent.create(recursive: true);
      await partial.writeAsBytes(const [4, 5]);
      final ranges = <String, String?>{};
      final manager = HttpLocalModelManager(
        modelsDirectory: root,
        descriptors: [descriptor],
        client: MockClient((request) async {
          final path = request.url.path.split('/').last;
          ranges[path] = request.headers['range'];
          return switch (path) {
            'config.json' => http.Response.bytes(const [1, 2, 3], 200),
            'weight.bin' => http.Response.bytes(
              const [6, 7],
              206,
              headers: {'content-range': 'bytes 2-3/4'},
            ),
            _ => http.Response('', 404),
          };
        }),
      );

      final progress = <int>[];
      await manager.download(
        descriptor.id,
        onProgress: (downloaded, total) => progress.add(downloaded),
      );

      expect(ranges['weight.bin'], 'bytes=2-');
      expect(progress.last, descriptor.sizeBytes);
      expect(await Directory('${root.path}/.fixture.part').exists(), isFalse);
      expect(await Directory(manager.pathFor(descriptor.id)).exists(), isTrue);
      expect(
        await File(
          p.join(
            manager.pathFor(descriptor.id),
            'model.mlmodelc/weights/weight.bin',
          ),
        ).readAsBytes(),
        orderedEquals(const [4, 5, 6, 7]),
      );
    },
  );

  test('a failed checksum never installs the staged Core ML bundle', () async {
    final root = await Directory.systemTemp.createTemp('meow-model-bad-');
    addTearDown(() => root.delete(recursive: true));
    final descriptor = _descriptor(const {
      'config.json': [1, 2, 3],
    });
    final manager = HttpLocalModelManager(
      modelsDirectory: root,
      descriptors: [descriptor],
      client: MockClient(
        (_) async => http.Response.bytes(const [4, 5, 6], 200),
      ),
    );

    await expectLater(
      manager.download(descriptor.id),
      throwsA(
        isA<LocalModelException>().having(
          (error) => error.code,
          'code',
          'model_checksum_mismatch',
        ),
      ),
    );

    expect(await Directory(manager.pathFor(descriptor.id)).exists(), isFalse);
    expect(
      (await manager.status(descriptor.id, verifyIntegrity: true)).availability,
      LocalModelAvailability.corrupt,
    );
  });

  test('a complete corrupt part restarts without an invalid range', () async {
    final root = await Directory.systemTemp.createTemp('meow-model-retry-');
    addTearDown(() => root.delete(recursive: true));
    final descriptor = _descriptor(const {
      'config.json': [1, 2, 3],
    });
    final partial = File(
      p.join(root.path, '.fixture.part', 'config.json.part'),
    );
    await partial.parent.create(recursive: true);
    await partial.writeAsBytes(const [4, 5, 6]);
    String? range;
    final manager = HttpLocalModelManager(
      modelsDirectory: root,
      descriptors: [descriptor],
      client: MockClient((request) async {
        range = request.headers['range'];
        return http.Response.bytes(const [1, 2, 3], 200);
      }),
    );

    await manager.download(descriptor.id);

    expect(range, isNull);
    expect(
      await File(
        p.join(manager.pathFor(descriptor.id), 'config.json'),
      ).readAsBytes(),
      orderedEquals(const [1, 2, 3]),
    );
  });

  test(
    'legacy GGUF files and directories are removed during Core ML migration',
    () async {
      final root = await Directory.systemTemp.createTemp('meow-model-legacy-');
      addTearDown(() => root.delete(recursive: true));
      for (final id in HttpLocalModelManager.legacyGGUFModelIds) {
        final file = File(p.join(root.path, id, '$id.gguf'));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(const [1]);
      }
      for (final name in HttpLocalModelManager.legacyGGUFFileNames) {
        await File(p.join(root.path, name)).writeAsBytes(const [1]);
        await File(p.join(root.path, '$name.part')).writeAsBytes(const [1]);
      }
      final manager = HttpLocalModelManager(modelsDirectory: root);

      await manager.removeLegacyGGUFModels();

      for (final id in HttpLocalModelManager.legacyGGUFModelIds) {
        expect(await Directory(p.join(root.path, id)).exists(), isFalse);
      }
      for (final name in HttpLocalModelManager.legacyGGUFFileNames) {
        expect(await File(p.join(root.path, name)).exists(), isFalse);
        expect(await File(p.join(root.path, '$name.part')).exists(), isFalse);
      }
    },
  );
}

LocalModelDescriptor _descriptor(Map<String, List<int>> files) =>
    LocalModelDescriptor(
      id: 'fixture',
      displayName: 'Fixture Core ML',
      repository: 'example/fixture-coreml',
      revision: 'fixed',
      files: [
        for (final entry in files.entries)
          LocalModelFile(
            path: entry.key,
            sizeBytes: entry.value.length,
            sha256: sha256.convert(entry.value).toString(),
          ),
      ],
    );

Future<void> _writeBundle(String root, Map<String, List<int>> files) async {
  for (final entry in files.entries) {
    final file = File(p.join(root, entry.key));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(entry.value);
  }
}
