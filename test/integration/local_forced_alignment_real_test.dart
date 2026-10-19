import 'package:listenook/core/app_identity.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/contracts.dart';
import 'package:listenook/core/local_speech.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/data/local_speech_process.dart';
import 'package:listenook/data/local_speech_services.dart';
import '../support/fakes.dart';

void main() {
  final manifestPath = AppIdentity.environment(
    'LISTENOOK_TEST_ALIGNMENT_MANIFEST',
  );
  final pcmPath = AppIdentity.environment('LISTENOOK_TEST_ALIGNMENT_PCM');
  final modelDirectory = AppIdentity.environment(
    'LISTENOOK_TEST_ALIGNMENT_COREML_DIRECTORY',
  );
  final alignmentModel =
      AppIdentity.environment('LISTENOOK_TEST_ALIGNMENT_MODEL') == 'fp16'
      ? LocalSpeechModels.qwen3ForcedAlignerCoreMlFp16
      : LocalSpeechModels.qwen3ForcedAlignerCoreMlInt8;
  final workerPath = AppIdentity.environment('LISTENOOK_TEST_SPEECH_WORKER');
  final requestedSegmentIds =
      AppIdentity.environment('LISTENOOK_TEST_ALIGNMENT_SEGMENT_IDS')
          ?.split(',')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toSet();
  final requireComplete =
      AppIdentity.environment('LISTENOOK_TEST_ALIGNMENT_REQUIRE_COMPLETE') ==
      '1';
  final useExactSegments =
      AppIdentity.environment('LISTENOOK_TEST_ALIGNMENT_EXACT_SEGMENTS') == '1';
  final resumeSavedTokens =
      AppIdentity.environment('LISTENOOK_TEST_ALIGNMENT_RESUME_SAVED_TOKENS') ==
      '1';
  final requestedWindowRadius =
      int.tryParse(
        AppIdentity.environment('LISTENOOK_TEST_ALIGNMENT_WINDOW_RADIUS') ?? '',
      ) ??
      0;
  final configured =
      manifestPath != null &&
      pcmPath != null &&
      modelDirectory != null &&
      workerPath != null &&
      Platform.isMacOS;

  test(
    'real alignment covers the expected transcript segments',
    () async {
      final manifest =
          (jsonDecode(await File(manifestPath!).readAsString()) as Map)
              .cast<String, dynamic>();
      final job = TranscriptionJob.fromJson(manifest);
      final savedDocument = job.document!;
      var selectedSegmentIds = requestedSegmentIds;
      if (requestedSegmentIds != null && !useExactSegments) {
        final captureWorker = _RequestCapturingWorker();
        final planningService = ProcessForcedAlignmentService(
          models: _installedAlignmentModel(modelDirectory!),
          pcm: FixedPcmPreparer(pcmPath!),
          worker: captureWorker,
          platformSupported: true,
        );
        await planningService.align(
          ForcedAlignmentRequest(
            sourcePath: job.sourcePath,
            document: savedDocument.copyWith(tokens: const []),
            model: alignmentModel,
            languageHints: job.options.languageHints,
          ),
        );
        selectedSegmentIds = captureWorker.windowSegmentIdsContaining(
          requestedSegmentIds,
          radius: requestedWindowRadius,
        );
      }
      final document = selectedSegmentIds == null
          ? savedDocument.copyWith(
              tokens: resumeSavedTokens ? savedDocument.tokens : const [],
              preserveUpdatedAt: true,
            )
          : savedDocument.copyWith(
              tokens: resumeSavedTokens
                  ? savedDocument.tokens
                        .where(
                          (token) =>
                              token.segmentId != null &&
                              selectedSegmentIds!.contains(token.segmentId),
                        )
                        .toList()
                  : const [],
              segments: savedDocument.segments
                  .where((segment) => selectedSegmentIds!.contains(segment.id))
                  .toList(),
              preserveUpdatedAt: true,
            );
      expect(document.segments, isNotEmpty);
      if (requestedSegmentIds != null) {
        expect(selectedSegmentIds, containsAll(requestedSegmentIds));
      }
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'meow-alignment-regression-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      final worker = _RecordingWorker(
        ProcessLocalSpeechWorker(
          temporaryDirectory: temporaryDirectory,
          executablePath: workerPath!,
        ),
      );
      final service = ProcessForcedAlignmentService(
        models: _installedAlignmentModel(modelDirectory!),
        pcm: FixedPcmPreparer(pcmPath!),
        worker: worker,
        platformSupported: true,
      );

      final result = await service.align(
        ForcedAlignmentRequest(
          sourcePath: job.sourcePath,
          document: document,
          model: alignmentModel,
          languageHints: job.options.languageHints,
        ),
      );
      final covered = result.tokens
          .map((token) => token.segmentId)
          .whereType<String>()
          .toSet();

      final missing = document.segments
          .map((segment) => segment.id)
          .where((id) => !covered.contains(id))
          .toList();
      if (missing.isNotEmpty) {
        // Stable reason codes contain no transcript text or hotwords.
        // ignore: avoid_print
        print(<String, Object?>{
          'missing_segment_ids': missing,
          'failed_window_reasons': worker.lastOutput?['failed_window_reasons'],
          'windows': worker.windowsFor(missing),
          'raw_tokens': worker.tokensFor(missing),
        });
      }
      if (requestedSegmentIds != null || requireComplete) {
        expect(missing, isEmpty);
      } else {
        expect(covered, contains(document.segments.first.id));
        expect(
          result.alignedSegments * 100,
          greaterThanOrEqualTo(document.segments.length * 99),
        );
      }
    },
    skip: configured
        ? false
        : 'Set LISTENOOK_TEST_ALIGNMENT_MANIFEST, LISTENOOK_TEST_ALIGNMENT_PCM, '
              'LISTENOOK_TEST_ALIGNMENT_COREML_DIRECTORY, and '
              'LISTENOOK_TEST_SPEECH_WORKER.',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

class _RecordingWorker implements LocalSpeechWorker {
  _RecordingWorker(this.delegate);

  final LocalSpeechWorker delegate;
  Map<String, dynamic>? lastOutput;
  Map<String, dynamic>? lastRequest;

  List<Map<String, Object?>> windowsFor(Iterable<String> segmentIds) {
    final requested = segmentIds.toSet();
    final windows = lastRequest?['windows'];
    if (windows is! List) return const [];
    return windows
        .whereType<Map>()
        .where((window) {
          final segments = window['segments'];
          if (segments is! List) return false;
          return segments.whereType<Map>().any(
            (segment) => requested.contains(segment['id']?.toString()),
          );
        })
        .map((window) {
          return <String, Object?>{
            'id': window['id']?.toString(),
            'start_ms': window['start_ms'],
            'end_ms': window['end_ms'],
            'segment_ids': (window['segments'] as List)
                .whereType<Map>()
                .map((segment) => segment['id']?.toString())
                .whereType<String>()
                .toList(),
          };
        })
        .toList();
  }

  List<Map<String, Object?>> tokensFor(Iterable<String> segmentIds) {
    final requested = segmentIds.toSet();
    final tokens = lastOutput?['tokens'];
    if (tokens is! List) return const [];
    return tokens
        .whereType<Map>()
        .where((token) {
          return requested.contains(token['segment_id']?.toString());
        })
        .map((token) {
          return <String, Object?>{
            'segment_id': token['segment_id']?.toString(),
            'start_ms': token['start_ms'],
            'end_ms': token['end_ms'],
          };
        })
        .toList();
  }

  @override
  Future<Map<String, dynamic>> run(
    SpeechWorkerCommand command,
    Map<String, dynamic> request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    lastRequest = request;
    final output = await delegate.run(
      command,
      request,
      onProgress: onProgress,
      shouldCancel: shouldCancel,
    );
    lastOutput = output;
    return output;
  }
}

class _RequestCapturingWorker implements LocalSpeechWorker {
  final requests = <Map<String, dynamic>>[];

  Set<String> windowSegmentIdsContaining(
    Set<String> requestedIds, {
    int radius = 0,
  }) {
    final orderedWindows = <Set<String>>[];
    for (final request in requests) {
      final windows = request['windows'];
      if (windows is! List) continue;
      for (final rawWindow in windows.whereType<Map>()) {
        final segments = rawWindow['segments'];
        if (segments is! List) continue;
        orderedWindows.add(
          segments
              .whereType<Map>()
              .map((segment) => segment['id']?.toString())
              .whereType<String>()
              .toSet(),
        );
      }
    }
    final selected = <String>{};
    for (var index = 0; index < orderedWindows.length; index++) {
      if (orderedWindows[index].intersection(requestedIds).isEmpty) continue;
      final first = (index - radius).clamp(0, orderedWindows.length - 1);
      final last = (index + radius).clamp(0, orderedWindows.length - 1);
      for (var neighbor = first; neighbor <= last; neighbor++) {
        selected.addAll(orderedWindows[neighbor]);
      }
    }
    return selected;
  }

  @override
  Future<Map<String, dynamic>> run(
    SpeechWorkerCommand command,
    Map<String, dynamic> request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    requests.add(request);
    return const <String, dynamic>{
      'tokens': <Object>[],
      'failed_window_ids': <Object>[],
    };
  }
}

/// Every model is installed in [directory].
FakeLocalModelManager _installedAlignmentModel(String directory) =>
    FakeLocalModelManager.allInstalled(pathFor: (_) => directory);
