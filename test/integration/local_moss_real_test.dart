import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/contracts.dart';
import 'package:meow_stt/core/local_speech.dart';
import 'package:meow_stt/core/models.dart';
import 'package:meow_stt/data/local_speech_process.dart';
import 'package:meow_stt/data/local_speech_services.dart';

void main() {
  final pcmPath = Platform.environment['MEOWSTT_TEST_MOSS_PCM'];
  final modelDirectory =
      Platform.environment['MEOWSTT_TEST_MOSS_COREML_DIRECTORY'];
  final alignmentModelDirectory =
      Platform.environment['MEOWSTT_TEST_ALIGNMENT_COREML_DIRECTORY'];
  final sourcePath =
      Platform.environment['MEOWSTT_TEST_SOURCE_PATH'] ?? pcmPath ?? '';
  final workerPath = Platform.environment['MEOWSTT_TEST_SPEECH_WORKER'];
  final expectRecovery =
      Platform.environment['MEOWSTT_EXPECT_MOSS_RECOVERY'] == '1';
  final configured =
      Platform.isMacOS &&
      [
        pcmPath,
        modelDirectory,
        workerPath,
      ].every((value) => value != null && value.isNotEmpty);

  test(
    'real MOSS worker emits progress after model loading',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'meow-moss-progress-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final progress = <double>[];
      final progressDetails = <String>[];
      final worker = ProcessLocalSpeechWorker(
        temporaryDirectory: temporary,
        executablePath: workerPath,
      );

      final output = await worker.run(
        SpeechWorkerCommand.transcribeMoss,
        {
          'model_directory': modelDirectory,
          'audio_path': pcmPath,
          'chunk_seconds': 30,
          'parallel_chunks': 2,
          'max_new_tokens_per_chunk': 640,
          'hotwords': <String>[],
        },
        onProgress: (fraction, detail) {
          if (detail == 'transcribing-coreml' && fraction != null) {
            progress.add(fraction);
          }
          if (detail != null) progressDetails.add(detail);
        },
      );

      expect(output['segments'], isA<List>());
      final document = const MossTaggedTranscriptParser().parseStructured(
        output['segments'] as List,
        durationMs: maxMediaDurationMs,
        plainText: output['text'] as String?,
      );
      expect(document.segments, isNotEmpty);
      expect(progress, isNotEmpty);
      expect(progress.any((fraction) => fraction > 0.12), isTrue);
      expect(progress.last, 1);
      if (expectRecovery) {
        expect(progressDetails, contains('retrying-coreml-chunk'));
      }
      if (alignmentModelDirectory != null) {
        final alignment =
            await ProcessForcedAlignmentService(
              models: _InstalledModels(
                mossDirectory: modelDirectory!,
                alignmentDirectory: alignmentModelDirectory,
              ),
              pcm: _ExistingPcm(pcmPath!),
              worker: worker,
              platformSupported: true,
            ).align(
              ForcedAlignmentRequest(
                sourcePath: sourcePath,
                document: document,
              ),
            );
        expect(alignment.alignedSegments, document.segments.length);
        expect(alignment.status, ForcedAlignmentStatus.completed);
      }
    },
    skip: configured
        ? false
        : 'Set MEOWSTT_TEST_MOSS_PCM, '
              'MEOWSTT_TEST_MOSS_COREML_DIRECTORY, and '
              'MEOWSTT_TEST_SPEECH_WORKER.',
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

class _InstalledModels implements LocalModelManager {
  const _InstalledModels({
    required this.mossDirectory,
    required this.alignmentDirectory,
  });

  final String mossDirectory;
  final String alignmentDirectory;

  @override
  List<LocalModelDescriptor> get models => LocalSpeechModels.all;

  @override
  String pathFor(String modelId) =>
      modelId == LocalSpeechModels.mossDiarizeCoreMlInt8.id
      ? mossDirectory
      : alignmentDirectory;

  @override
  Future<LocalModelStatus> status(
    String modelId, {
    bool verifyIntegrity = false,
  }) async {
    final descriptor = modelId == LocalSpeechModels.mossDiarizeCoreMlInt8.id
        ? LocalSpeechModels.mossDiarizeCoreMlInt8
        : LocalSpeechModels.qwen3ForcedAlignerCoreMlInt8;
    return LocalModelStatus(
      descriptor: descriptor,
      availability: LocalModelAvailability.ready,
      downloadedBytes: descriptor.sizeBytes,
    );
  }

  @override
  Future<void> delete(String modelId) async {}

  @override
  Future<void> download(
    String modelId, {
    ModelDownloadProgress? onProgress,
    CancelCheck? shouldCancel,
  }) async {}
}

class _ExistingPcm implements LocalPcmPreparer {
  const _ExistingPcm(this.path);

  final String path;

  @override
  Future<PreparedLocalPcm> prepare(
    String sourcePath, {
    required int durationMs,
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async => PreparedLocalPcm(path);

  @override
  Future<void> release(PreparedLocalPcm pcm) async {}
}
