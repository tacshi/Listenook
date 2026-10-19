import 'package:listenook/core/app_identity.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/local_speech.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/data/local_speech_process.dart';
import 'package:listenook/data/local_speech_services.dart';
import '../support/fakes.dart';

void main() {
  final pcmPath = AppIdentity.environment('LISTENOOK_TEST_QWEN_PCM');
  final qwenDirectory = AppIdentity.environment(
    'LISTENOOK_TEST_QWEN_MLX_DIRECTORY',
  );
  final vadDirectory = AppIdentity.environment(
    'LISTENOOK_TEST_SILERO_COREML_DIRECTORY',
  );
  final alignmentDirectory = AppIdentity.environment(
    'LISTENOOK_TEST_ALIGNMENT_COREML_DIRECTORY',
  );
  final workerPath = AppIdentity.environment('LISTENOOK_TEST_SPEECH_WORKER');
  final configured =
      Platform.isMacOS &&
      [
        pcmPath,
        qwenDirectory,
        vadDirectory,
        workerPath,
      ].every((value) => value != null && value.isNotEmpty);

  test(
    'real Qwen and Silero run offline with bounded monotonic segments',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'meow-qwen-real-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final progress = <double>[];
      final worker = ProcessLocalSpeechWorker(
        temporaryDirectory: temporary,
        executablePath: workerPath,
      );

      final output = await worker.run(
        SpeechWorkerCommand.transcribeQwen3,
        {
          'model_directory': qwenDirectory,
          'vad_model_directory': vadDirectory,
          'audio_path': pcmPath,
          'max_segment_seconds': 10,
          'language_hints': <String>[],
          'context_terms': <String>[],
        },
        onProgress: (fraction, _) {
          if (fraction != null) progress.add(fraction);
        },
      );

      final document = const QwenStructuredTranscriptParser().parse(
        output['segments'] as List,
        durationMs: maxMediaDurationMs,
      );
      expect(document.speakers, isEmpty);
      expect(
        document.segments.every(
          (segment) =>
              segment.speaker == null &&
              segment.endMs > segment.startMs &&
              segment.endMs - segment.startMs <= 10000,
        ),
        isTrue,
      );
      for (var index = 1; index < document.segments.length; index++) {
        expect(
          document.segments[index].startMs,
          greaterThanOrEqualTo(document.segments[index - 1].endMs),
        );
      }
      expect(progress, isNotEmpty);
      expect(progress.last, 1);

      if (alignmentDirectory != null && document.segments.isNotEmpty) {
        final alignment =
            await ProcessForcedAlignmentService(
              models: _installedQwenModels(
                qwenDirectory: qwenDirectory!,
                vadDirectory: vadDirectory!,
                alignmentDirectory: alignmentDirectory,
              ),
              pcm: FixedPcmPreparer(pcmPath!),
              worker: worker,
              platformSupported: true,
            ).align(
              ForcedAlignmentRequest(
                sourcePath: pcmPath,
                document: document,
                model: LocalSpeechModels.qwen3ForcedAlignerCoreMlInt8,
              ),
            );
        expect(
          alignment.status,
          anyOf(ForcedAlignmentStatus.completed, ForcedAlignmentStatus.partial),
        );
      }
    },
    skip: configured
        ? false
        : 'Set LISTENOOK_TEST_QWEN_PCM, LISTENOOK_TEST_QWEN_MLX_DIRECTORY, '
              'LISTENOOK_TEST_SILERO_COREML_DIRECTORY, and '
              'LISTENOOK_TEST_SPEECH_WORKER.',
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

FakeLocalModelManager _installedQwenModels({
  required String qwenDirectory,
  required String vadDirectory,
  required String alignmentDirectory,
}) => FakeLocalModelManager.allInstalled(
  pathFor: (modelId) => switch (modelId) {
    'qwen3-asr-1.7b-mlx-8bit' => qwenDirectory,
    'silero-vad-v6.2.1-coreml' => vadDirectory,
    _ => alignmentDirectory,
  },
);
