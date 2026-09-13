import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/contracts.dart';
import 'package:listenook/core/local_speech.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/core/podcast_models.dart';
import 'package:listenook/data/inbox_folder_monitor.dart';
import 'package:listenook/data/local_media_source_resolver.dart';
import 'package:listenook/data/local_repositories.dart';
import 'package:listenook/data/podcast/http_podcast_gateway.dart';
import 'package:listenook/data/timed_subtitle_import.dart';
import 'package:listenook/data/transcript_exporter.dart';
import 'package:listenook/state/app_controller.dart';

void main() {
  test(
    'imported subtitles align directly from their persisted snapshot',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final subtitle = File('${fixture.root.path}/meeting.srt');
      await subtitle.writeAsString('''
1
00:00:00,000 --> 00:00:02,000
Hello imported
''');
      final localStt = _CountingLocalStt();
      final alignment = _ImportedAlignment();
      final controller = await fixture.controller(
        settings: const AppSettings(
          defaultTranscriptionProvider: TranscriptionProvider.soniox,
          defaultForcedAlignmentModel: ForcedAlignmentModel.qwen3CoreMlInt8,
          automaticWordTiming: false,
        ),
        localStt: localStt,
        alignment: alignment,
      );

      final review = await controller.previewSourceImports([
        fixture.audio.path,
        subtitle.path,
      ]);
      final match = review!.media.single;
      await controller.enqueueReviewedImports([
        SubtitleImportSelection(
          media: match.media,
          subtitle: match.automaticCandidate,
          languageCode: 'en',
        ),
      ]);
      await subtitle.writeAsString('changed after import');

      var job = controller.inboxJobs.single;
      expect(job.status, JobStatus.ready);
      expect(
        job.transcriptAcquisitionMode,
        TranscriptAcquisitionMode.importedSubtitles,
      );
      expect(job.transcriptSource, TranscriptSource.importedSubtitle);
      expect(job.document!.segments.single.text, 'Hello imported');
      expect(job.importedSubtitleProvenance!.displayName, 'meeting.srt');

      await controller.startReady();

      job = controller.inboxJobs.single;
      expect(localStt.calls, 0);
      expect(alignment.requests, hasLength(1));
      expect(
        alignment.requests.single.document.segments.single.text,
        'Hello imported',
      );
      expect(job.status, JobStatus.completed);
      expect(job.forcedAlignment.status, ForcedAlignmentStatus.completed);
      expect(job.document!.segments.single.text, 'Hello imported');
      expect(job.document!.segments.single.startMs, 250);
      expect(job.document!.segments.single.endMs, 1750);
      expect(job.document!.segments.single.alignmentWindowStartMs, 0);
      expect(job.document!.segments.single.alignmentWindowEndMs, 2000);

      await subtitle.writeAsString('''
1
00:00:00,300 --> 00:00:01,600
Replacement text
''');
      expect(
        await controller.replaceImportedSubtitle(job.id, subtitle.path),
        isNull,
      );
      job = controller.inboxJobs.single;
      expect(job.status, JobStatus.ready);
      expect(job.document!.tokens, isEmpty);
      expect(job.document!.segments.single.text, 'Replacement text');
      expect(job.document!.segments.single.startMs, 300);
      expect(job.document!.segments.single.endMs, 1600);
      expect(job.forcedAlignment.status, ForcedAlignmentStatus.notRequested);
    },
  );

  test(
    'imported alignment persists a checkpoint before interruption',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final subtitle = File('${fixture.root.path}/meeting.srt');
      await subtitle.writeAsString('''
1
00:00:00,000 --> 00:00:01,000
First.

2
00:00:01,000 --> 00:00:02,000
Second
''');
      final controller = await fixture.controller(
        settings: const AppSettings(
          defaultForcedAlignmentModel: ForcedAlignmentModel.qwen3CoreMlInt8,
        ),
        localStt: _CountingLocalStt(),
        alignment: _CheckpointThenCancelAlignment(),
      );
      final review = await controller.previewSourceImports([
        fixture.audio.path,
        subtitle.path,
      ]);
      await controller.enqueueReviewedImports([
        SubtitleImportSelection(
          media: review!.media.single.media,
          subtitle: review.media.single.automaticCandidate,
          languageCode: 'en',
        ),
      ]);

      await controller.startReady();

      final job = controller.inboxJobs.single;
      expect(job.forcedAlignment.status, ForcedAlignmentStatus.cancelled);
      expect(job.forcedAlignment.alignedSegments, 1);
      expect(
        job.document!.tokens.single.segmentId,
        job.document!.segments.first.id,
      );
      expect(job.document!.segments.first.startMs, 100);
      expect(job.document!.segments.first.endMs, 800);
      final persisted = (await LocalJobRepository(
        fixture.paths,
      ).loadAll()).single;
      expect(
        persisted.document!.tokens.single.segmentId,
        persisted.document!.segments.first.id,
      );
    },
  );

  test(
    'conflicting imported alignment keeps only affected cues at original timing',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final subtitle = File('${fixture.root.path}/meeting.srt');
      await subtitle.writeAsString('''
1
00:00:00,000 --> 00:00:02,500
First sentence.

2
00:00:01,500 --> 00:00:04,000
Second sentence.

3
00:00:04,000 --> 00:00:06,000
Third sentence.
''');
      final controller = await fixture.controller(
        settings: const AppSettings(
          defaultForcedAlignmentModel: ForcedAlignmentModel.qwen3CoreMlInt8,
        ),
        localStt: _CountingLocalStt(),
        alignment: _ConflictingImportedAlignment(),
        media: _FixedMetadataMedia(
          const MediaMetadata(
            sizeBytes: 64,
            durationMs: 6000,
            hasAudio: true,
            hasVideo: false,
            formatName: 'wav',
          ),
        ),
      );
      final review = await controller.previewSourceImports([
        fixture.audio.path,
        subtitle.path,
      ]);
      await controller.enqueueReviewedImports([
        SubtitleImportSelection(
          media: review!.media.single.media,
          subtitle: review.media.single.automaticCandidate,
          languageCode: 'en',
        ),
      ]);
      await _waitFor(
        () => controller.inboxJobs.single.status == JobStatus.ready,
      );

      await controller.startReady();

      final job = controller.inboxJobs.single;
      expect(
        (job.errorCode, job.errorMessage),
        (null, null),
        reason: 'alignment should complete without a job-level failure',
      );
      expect(job.status, JobStatus.completed);
      expect(job.document!.tokens.map((token) => token.text), [
        'Third ',
        'sentence.',
      ]);
      expect(job.document!.segments, hasLength(3));
      expect(
        job.document!.segments.map(
          (segment) => (segment.startMs, segment.endMs),
        ),
        [(0, 2500), (1500, 4000), (4300, 5700)],
      );
      expect(
        job.document!.segments.map((segment) => segment.alignmentIncomplete),
        [true, true, false],
      );
      expect(job.forcedAlignment.status, ForcedAlignmentStatus.partial);
      expect(job.forcedAlignment.alignedSegments, 1);
      expect(job.forcedAlignment.totalSegments, 3);
      expect(job.forcedAlignment.warningCode, 'alignment_timeline_conflict');
    },
  );

  test(
    'rolling subtitles align normalized sentence text without mass fallback',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final subtitle = File('${fixture.root.path}/meeting.srt');
      await subtitle.writeAsString('''
1
00:00:00,000 --> 00:00:05,000
Sentence zero.

2
00:00:01,000 --> 00:00:06,000
Sentence one.

3
00:00:02,000 --> 00:00:07,000
Sentence two.

4
00:00:03,000 --> 00:00:08,000
Sentence three.

5
00:00:04,000 --> 00:00:09,000
Sentence four.

6
00:00:05,000 --> 00:00:10,000
Sentence five.

7
00:00:06,000 --> 00:00:11,000
Sentence six.

8
00:00:07,000 --> 00:00:12,000
Sentence seven.
''');
      final alignment = _RollingImportedAlignment();
      final controller = await fixture.controller(
        settings: const AppSettings(
          defaultForcedAlignmentModel: ForcedAlignmentModel.qwen3CoreMlInt8,
        ),
        localStt: _CountingLocalStt(),
        alignment: alignment,
        media: _FixedMetadataMedia(
          const MediaMetadata(
            sizeBytes: 64,
            durationMs: 12000,
            hasAudio: true,
            hasVideo: false,
            formatName: 'wav',
          ),
        ),
      );
      final review = await controller.previewSourceImports([
        fixture.audio.path,
        subtitle.path,
      ]);
      await controller.enqueueReviewedImports([
        SubtitleImportSelection(
          media: review!.media.single.media,
          subtitle: review.media.single.automaticCandidate,
          languageCode: 'en',
        ),
      ]);
      await _waitFor(
        () => controller.inboxJobs.single.status == JobStatus.ready,
      );

      await controller.startReady();

      final request = alignment.requests.single;
      expect(request.timelineMode, ForcedAlignmentTimelineMode.orderedText);
      expect(
        request.document.segments.every(
          (segment) => segment.id.startsWith('imported-sentence-'),
        ),
        isTrue,
      );
      final job = controller.inboxJobs.single;
      expect(job.forcedAlignment.status, ForcedAlignmentStatus.completed);
      expect(job.forcedAlignment.alignedSegments, 8);
      expect(job.document!.segments, hasLength(8));
      expect(
        job.document!.segments.any((segment) => segment.alignmentIncomplete),
        isFalse,
      );
      expect(
        job.document!.segments.map((segment) => segment.text),
        request.document.segments.map((segment) => segment.text),
      );
    },
  );

  test(
    'retry realigns persisted cross-cue conflicts instead of reusing them',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final subtitle = File('${fixture.root.path}/meeting.srt');
      await subtitle.writeAsString('''
1
00:00:00,000 --> 00:00:02,500
First sentence.

2
00:00:01,500 --> 00:00:04,000
Second sentence.
''');
      const settings = AppSettings(
        defaultForcedAlignmentModel: ForcedAlignmentModel.qwen3CoreMlInt8,
      );
      const metadata = MediaMetadata(
        sizeBytes: 64,
        durationMs: 4000,
        hasAudio: true,
        hasVideo: false,
        formatName: 'wav',
      );
      final controller = await fixture.controller(
        settings: settings,
        localStt: _CountingLocalStt(),
        alignment: _ImportedAlignment(),
        media: _FixedMetadataMedia(metadata),
      );
      final review = await controller.previewSourceImports([
        fixture.audio.path,
        subtitle.path,
      ]);
      await controller.enqueueReviewedImports([
        SubtitleImportSelection(
          media: review!.media.single.media,
          subtitle: review.media.single.automaticCandidate,
          languageCode: 'en',
        ),
      ]);
      await _waitFor(
        () => controller.inboxJobs.single.status == JobStatus.ready,
      );
      final imported = controller.inboxJobs.single;
      final first = imported.document!.segments.first;
      final second = imported.document!.segments.last;
      final persistedConflict = imported.copyWith(
        status: JobStatus.completed,
        document: imported.document!.copyWith(
          segments: [
            first.copyWith(startMs: 400, endMs: 2100),
            second.copyWith(startMs: 1800, endMs: 3600),
          ],
          tokens: [
            TranscriptToken(
              text: 'First sentence.',
              startMs: 400,
              endMs: 2100,
              segmentId: first.id,
            ),
            TranscriptToken(
              text: 'Second sentence.',
              startMs: 1800,
              endMs: 3600,
              segmentId: second.id,
            ),
          ],
        ),
        importedSubtitleProvenance: imported.importedSubtitleProvenance!
            .copyWith(sentenceBreaksNormalized: true),
        forcedAlignment: ForcedAlignmentState(
          status: ForcedAlignmentStatus.partial,
          modelId: LocalSpeechModels.qwen3ForcedAlignerCoreMlInt8.id,
          modelRevision:
              LocalSpeechModels.qwen3ForcedAlignerCoreMlInt8.revision,
          alignedSegments: 2,
          totalSegments: 2,
          warningCode: 'alignment_partial',
        ),
      );
      await LocalJobRepository(fixture.paths).save(persistedConflict);

      final repair = _RepairingImportedAlignment();
      final reloaded = await fixture.controller(
        settings: settings,
        localStt: _CountingLocalStt(),
        alignment: repair,
        media: _FixedMetadataMedia(metadata),
      );
      await reloaded.retryForcedAlignment(imported.id);

      expect(repair.requests.single.document.tokens, isEmpty);
      final repaired = reloaded.jobById(imported.id)!;
      expect(repaired.forcedAlignment.status, ForcedAlignmentStatus.completed);
      expect(
        repaired.document!.segments.map(
          (segment) => (segment.startMs, segment.endMs),
        ),
        [(400, 1400), (1600, 3600)],
      );
    },
  );

  test('startup does not wait for full local-model verification', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final models = _BlockingVerificationModels();

    final controller = await fixture
        .controller(
          settings: const AppSettings(),
          localStt: _LocalStt(),
          alignment: _Alignment(),
          localModelManager: models,
        )
        .timeout(const Duration(seconds: 1));

    expect(controller.initializing, isFalse);
    await models.verificationStarted.future.timeout(const Duration(seconds: 1));
    models.releaseVerification.complete();
  });

  test('startup selects and persists the sole installed aligner', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final models = _AlignmentModels({
      LocalSpeechModels.qwen3ForcedAlignerCoreMlInt8.id,
    });

    final controller = await fixture.controller(
      settings: const AppSettings(),
      localStt: _LocalStt(),
      alignment: _Alignment(),
      localModelManager: models,
      preserveUnselectedAlignmentModel: true,
    );

    expect(
      controller.settings.defaultForcedAlignmentModel,
      ForcedAlignmentModel.qwen3CoreMlInt8,
    );
    expect(
      (await JsonSettingsRepository(
        fixture.paths,
      ).load()).defaultForcedAlignmentModel,
      ForcedAlignmentModel.qwen3CoreMlInt8,
    );
  });

  test(
    'startup leaves the choice unset when both aligners are installed',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final models = _AlignmentModels({
        for (final descriptor in LocalSpeechModels.forcedAligners.values)
          descriptor.id,
      });

      final controller = await fixture.controller(
        settings: const AppSettings(),
        localStt: _LocalStt(),
        alignment: _Alignment(),
        localModelManager: models,
        preserveUnselectedAlignmentModel: true,
      );

      expect(controller.settings.defaultForcedAlignmentModel, isNull);
    },
  );

  test('the first downloaded aligner becomes the default', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final models = _AlignmentModels({});
    final controller = await fixture.controller(
      settings: const AppSettings(),
      localStt: _LocalStt(),
      alignment: _Alignment(),
      localModelManager: models,
      preserveUnselectedAlignmentModel: true,
    );

    await controller.downloadLocalModel(
      LocalSpeechModels.qwen3ForcedAlignerCoreMlFp16.id,
    );

    expect(
      controller.settings.defaultForcedAlignmentModel,
      ForcedAlignmentModel.qwen3CoreMlFp16,
    );
  });

  test('MOSS alignment stays unavailable until a model is selected', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final alignment = _CountingAlignment();
    final controller = await fixture.controller(
      settings: const AppSettings(
        defaultTranscriptionProvider: TranscriptionProvider.mossLocal,
      ),
      localStt: _LocalStt(),
      alignment: alignment,
      preserveUnselectedAlignmentModel: true,
    );

    await controller.enqueueSources([fixture.audio.path]);
    await _waitFor(() => controller.inboxJobs.single.status == JobStatus.ready);
    await controller.startReady();

    final job = controller.inboxJobs.single;
    expect(alignment.calls, 0);
    expect(job.forcedAlignment.status, ForcedAlignmentStatus.unavailable);
    expect(job.forcedAlignment.warningCode, 'alignment_model_not_selected');
    expect(job.forcedAlignment.modelId, isNull);
    expect(job.document!.segments.single.text, 'Hello world');
  });

  test(
    'queued alignment keeps its model while retries use the new default',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final alignment = _SwitchingAlignment();
      final controller = await fixture.controller(
        settings: const AppSettings(
          defaultTranscriptionProvider: TranscriptionProvider.mossLocal,
          defaultForcedAlignmentModel: ForcedAlignmentModel.qwen3CoreMlInt8,
        ),
        localStt: _LocalStt(),
        alignment: alignment,
      );

      await controller.enqueueSources([fixture.audio.path]);
      await _waitFor(
        () => controller.inboxJobs.single.status == JobStatus.ready,
      );
      final firstRun = controller.startReady();
      await alignment.firstEntered.future;
      await controller.updateSettings(
        controller.settings.copyWith(
          defaultForcedAlignmentModel: ForcedAlignmentModel.qwen3CoreMlFp16,
        ),
      );
      alignment.releaseFirst.complete();
      await firstRun;

      var job = controller.inboxJobs.single;
      expect(
        alignment.models.first,
        same(LocalSpeechModels.qwen3ForcedAlignerCoreMlInt8),
      );
      expect(
        job.forcedAlignment.modelId,
        LocalSpeechModels.qwen3ForcedAlignerCoreMlInt8.id,
      );

      await controller.retryForcedAlignment(job.id);
      job = controller.inboxJobs.single;
      expect(
        alignment.models.last,
        same(LocalSpeechModels.qwen3ForcedAlignerCoreMlFp16),
      );
      expect(
        job.forcedAlignment.modelId,
        LocalSpeechModels.qwen3ForcedAlignerCoreMlFp16.id,
      );
    },
  );

  test(
    'local MOSS persists segments then adds segment-owned word timing',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final controller = await fixture.controller(
        settings: const AppSettings(
          defaultTranscriptionProvider: TranscriptionProvider.mossLocal,
        ),
        localStt: _LocalStt(),
        alignment: _Alignment(),
      );

      await controller.enqueueSources([fixture.audio.path]);
      await _waitFor(
        () => controller.inboxJobs.single.status == JobStatus.ready,
      );
      expect(
        controller.inboxJobs.single.transcriptionModel?.id,
        LocalSpeechModels.mossDiarizeCoreMlInt8.id,
      );
      await controller.startReady();

      final job = controller.inboxJobs.single;
      expect(job.status, JobStatus.completed);
      expect(job.transcriptSource, TranscriptSource.mossLocal);
      expect(
        job.transcriptionModel?.id,
        LocalSpeechModels.mossDiarizeCoreMlInt8.id,
      );
      expect(job.document!.segments.single.text, 'Hello world');
      expect(job.document!.tokens.single.segmentId, 'moss-0');
      expect(job.forcedAlignment.status, ForcedAlignmentStatus.completed);
      expect(job.progress.stage, 'complete');
    },
  );

  test(
    'local transcription keeps the last numeric progress during retries',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final localStt = _IntermittentProgressLocalStt();
      addTearDown(() {
        if (!localStt.release.isCompleted) localStt.release.complete();
      });
      final controller = await fixture.controller(
        settings: const AppSettings(
          defaultTranscriptionProvider: TranscriptionProvider.mossLocal,
          automaticWordTiming: false,
        ),
        localStt: localStt,
        alignment: _Alignment(),
      );

      await controller.enqueueSources([fixture.audio.path]);
      await _waitFor(
        () => controller.inboxJobs.single.status == JobStatus.ready,
      );

      final running = controller.startReady();
      await localStt.numericProgressEmitted.future;
      await _waitFor(
        () => controller.inboxJobs.single.progress.fraction == 0.44,
      );

      localStt.emitProgressWithoutFraction.complete();
      await localStt.progressWithoutFractionEmitted.future;
      await _waitFor(
        () =>
            controller.inboxJobs.single.progress.detail ==
            'retrying-coreml-chunk',
      );

      expect(controller.inboxJobs.single.progress.fraction, 0.44);

      localStt.release.complete();
      await running;
    },
  );

  test(
    'Qwen Local persists model provenance and coarse no-speaker timing',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final localStt = _QwenLocalStt();
      final alignment = _CountingAlignment();
      final controller = await fixture.controller(
        settings: const AppSettings(
          defaultTranscriptionProvider: TranscriptionProvider.qwen3Local,
          automaticWordTiming: false,
        ),
        localStt: localStt,
        alignment: alignment,
      );

      await controller.enqueueSources([fixture.audio.path]);
      await _waitFor(
        () => controller.inboxJobs.single.status == JobStatus.ready,
      );
      expect(
        controller.inboxJobs.single.transcriptionModel?.id,
        LocalSpeechModels.qwen3AsrMlx8Bit.id,
      );
      await controller.setTranscriptAcquisitionMode(
        controller.inboxJobs.single.id,
        TranscriptAcquisitionMode.soniox,
      );
      expect(controller.inboxJobs.single.transcriptionModel, isNull);
      await controller.setTranscriptAcquisitionMode(
        controller.inboxJobs.single.id,
        TranscriptAcquisitionMode.qwen3Local,
      );
      expect(
        controller.inboxJobs.single.transcriptionModel?.revision,
        LocalSpeechModels.qwen3AsrMlx8Bit.revision,
      );
      await controller.startReady();

      final job = controller.inboxJobs.single;
      expect(localStt.engines, [LocalSttEngine.qwen3Asr]);
      expect(job.status, JobStatus.completed);
      expect(job.transcriptSource, TranscriptSource.qwen3Local);
      expect(
        job.transcriptAcquisitionMode,
        TranscriptAcquisitionMode.qwen3Local,
      );
      expect(job.transcriptionModel?.id, LocalSpeechModels.qwen3AsrMlx8Bit.id);
      expect(
        job.transcriptionModel?.revision,
        LocalSpeechModels.qwen3AsrMlx8Bit.revision,
      );
      expect(job.document!.speakers, isEmpty);
      expect(job.document!.segments.single.speaker, isNull);
      expect(job.document!.tokens, isEmpty);
      expect(alignment.calls, 0);
    },
  );

  test(
    'Qwen coarse timing completes with actionable unavailable alignment',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final alignment = _CountingAlignment();
      final controller = await fixture.controller(
        settings: const AppSettings(
          defaultTranscriptionProvider: TranscriptionProvider.qwen3Local,
        ),
        localStt: _QwenLocalStt(),
        alignment: alignment,
        preserveUnselectedAlignmentModel: true,
      );

      await controller.enqueueSources([fixture.audio.path]);
      await _waitFor(
        () => controller.inboxJobs.single.status == JobStatus.ready,
      );
      await controller.startReady();

      final job = controller.inboxJobs.single;
      expect(job.status, JobStatus.completed);
      expect(job.forcedAlignment.status, ForcedAlignmentStatus.unavailable);
      expect(job.forcedAlignment.warningCode, 'alignment_model_not_selected');
      expect(job.document!.segments.single.text, 'Higher quality text');
      expect(alignment.calls, 0);
    },
  );

  test('Qwen Local participates in local auto-start', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final localStt = _QwenLocalStt();
    final controller = await fixture.controller(
      settings: const AppSettings(
        defaultTranscriptionProvider: TranscriptionProvider.qwen3Local,
        automaticWordTiming: false,
        autoTranscribeLocal: true,
      ),
      localStt: localStt,
      alignment: _Alignment(),
    );

    await controller.enqueueSources([fixture.audio.path]);
    await _waitFor(
      () => controller.inboxJobs.single.status == JobStatus.completed,
    );

    expect(localStt.engines, [LocalSttEngine.qwen3Asr]);
  });

  test(
    'Qwen bundle readiness is atomic and a partial install resumes',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final models = _QwenModels(failId: LocalSpeechModels.sileroVadCoreMl.id);
      final controller = await fixture.controller(
        settings: const AppSettings(),
        localStt: _QwenLocalStt(),
        alignment: _Alignment(),
        localModelManager: models,
      );
      final aggregateProgress = <double>[];
      controller.addListener(() {
        final progress = controller.localModelDownloadProgress(
          LocalSpeechModels.qwen3AsrBundle.id,
        );
        if (progress != null) aggregateProgress.add(progress);
      });

      expect(
        controller.isTranscriptionProviderConfigured(
          TranscriptionProvider.qwen3Local,
        ),
        isFalse,
      );
      await expectLater(
        controller.downloadLocalModelBundle(LocalSpeechModels.qwen3AsrBundle),
        throwsA(isA<LocalModelException>()),
      );
      expect(
        controller.localModelBundleAvailability(
          LocalSpeechModels.qwen3AsrBundle,
        ),
        LocalModelAvailability.partial,
      );
      expect(models.downloads, [
        LocalSpeechModels.qwen3AsrMlx8Bit.id,
        LocalSpeechModels.sileroVadCoreMl.id,
      ]);

      models.failId = null;
      await controller.downloadLocalModelBundle(
        LocalSpeechModels.qwen3AsrBundle,
      );
      expect(models.downloads.last, LocalSpeechModels.sileroVadCoreMl.id);
      expect(
        controller.isTranscriptionProviderConfigured(
          TranscriptionProvider.qwen3Local,
        ),
        isTrue,
      );
      expect(
        aggregateProgress,
        contains(
          closeTo(
            LocalSpeechModels.qwen3AsrMlx8Bit.sizeBytes /
                LocalSpeechModels.qwen3AsrBundle.sizeBytes,
            0.000001,
          ),
        ),
      );
      expect(aggregateProgress.last, 1);
      await controller.deleteLocalModelBundle(LocalSpeechModels.qwen3AsrBundle);
      expect(models.installed, isEmpty);
    },
  );

  test('restart returns an interrupted Qwen transcription to ready', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final now = DateTime.now().toUtc();
    await LocalJobRepository(fixture.paths).save(
      TranscriptionJob(
        id: 'interrupted-qwen',
        batchId: 'batch',
        sourcePath: fixture.audio.path,
        createdAt: now,
        updatedAt: now,
        status: JobStatus.processing,
        metadata: _metadata,
        transcriptionProvider: TranscriptionProvider.qwen3Local,
        transcriptAcquisitionMode: TranscriptAcquisitionMode.qwen3Local,
      ),
    );

    final controller = await fixture.controller(
      settings: const AppSettings(
        defaultTranscriptionProvider: TranscriptionProvider.qwen3Local,
      ),
      localStt: _QwenLocalStt(),
      alignment: _Alignment(),
    );
    await _waitFor(
      () => controller.jobById('interrupted-qwen')?.status == JobStatus.ready,
    );
    final persisted = Stopwatch()..start();
    while (true) {
      final jobs = await LocalJobRepository(fixture.paths).loadAll();
      if (jobs.single.status == JobStatus.ready) break;
      if (persisted.elapsed > const Duration(seconds: 3)) {
        fail('Timed out waiting for recovered Qwen state to persist.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    final recovered = controller.jobById('interrupted-qwen')!;
    expect(recovered.progress.stage, 'ready');
    expect(recovered.document, isNull);
    expect(recovered.remoteFileId, isNull);
    expect(recovered.remoteTranscriptionId, isNull);
  });

  test('MOSS Local auto-transcription is opt-in', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final localStt = _CountingLocalStt();
    final controller = await fixture.controller(
      settings: const AppSettings(
        defaultTranscriptionProvider: TranscriptionProvider.mossLocal,
      ),
      localStt: localStt,
      alignment: _Alignment(),
    );

    await controller.enqueueSources([fixture.audio.path]);
    await _waitFor(() => controller.inboxJobs.single.status == JobStatus.ready);

    expect(localStt.calls, 0);
    expect(controller.processing, isFalse);
  });

  test('new MOSS Local imports auto-transcribe when enabled', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final localStt = _CountingLocalStt();
    final controller = await fixture.controller(
      settings: const AppSettings(
        defaultTranscriptionProvider: TranscriptionProvider.mossLocal,
        autoTranscribeLocal: true,
      ),
      localStt: localStt,
      alignment: _Alignment(),
    );

    await controller.enqueueSources([fixture.audio.path]);
    await _waitFor(
      () => controller.inboxJobs.single.status == JobStatus.completed,
    );

    expect(localStt.calls, 1);
    expect(
      controller.inboxJobs.single.transcriptSource,
      TranscriptSource.mossLocal,
    );
  });

  test(
    'five-hour MOSS Local imports remain eligible for auto-transcription',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final localStt = _CountingLocalStt();
      final controller = await fixture.controller(
        settings: const AppSettings(
          defaultTranscriptionProvider: TranscriptionProvider.mossLocal,
          autoTranscribeLocal: true,
        ),
        localStt: localStt,
        alignment: _Alignment(),
        media: _FixedMetadataMedia(
          const MediaMetadata(
            sizeBytes: 576000044,
            durationMs: maxMediaDurationMs,
            hasAudio: true,
            hasVideo: true,
            formatName: 'mp4',
          ),
        ),
      );

      await controller.enqueueSources([fixture.audio.path]);
      await _waitFor(
        () => controller.inboxJobs.single.status == JobStatus.completed,
      );

      expect(localStt.calls, 1);
    },
  );

  test(
    'dropped MOSS Local files remain manual when automation is enabled',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final localStt = _CountingLocalStt();
      final controller = await fixture.controller(
        settings: const AppSettings(
          defaultTranscriptionProvider: TranscriptionProvider.mossLocal,
          autoTranscribeLocal: true,
        ),
        localStt: localStt,
        alignment: _Alignment(),
      );

      await controller.enqueueSources([
        fixture.audio.path,
      ], allowLocalAutoStart: false);
      await _waitFor(
        () => controller.inboxJobs.single.status == JobStatus.ready,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(localStt.calls, 0);
      expect(controller.processing, isFalse);
      expect(controller.canStartReady, isTrue);

      await controller.startReady();
      expect(localStt.calls, 1);
      expect(controller.inboxJobs.single.status, JobStatus.completed);
    },
  );

  test(
    'remote jobs stay manual until a new job switches to MOSS Local',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final localStt = _CountingLocalStt();
      final controller = await fixture.controller(
        settings: const AppSettings(autoTranscribeLocal: true),
        localStt: localStt,
        alignment: _Alignment(),
      );

      await controller.enqueueSources([fixture.audio.path]);
      await _waitFor(
        () => controller.inboxJobs.single.status == JobStatus.ready,
      );
      expect(localStt.calls, 0);

      await controller.updateSessionTranscriptionProvider(
        TranscriptionProvider.mossLocal,
      );
      await _waitFor(
        () => controller.inboxJobs.single.status == JobStatus.completed,
      );

      expect(localStt.calls, 1);
    },
  );

  test('disabling local automation drops pending auto-start work', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final media = _BlockingMedia();
    final localStt = _CountingLocalStt();
    final controller = await fixture.controller(
      settings: const AppSettings(
        defaultTranscriptionProvider: TranscriptionProvider.mossLocal,
        autoTranscribeLocal: true,
      ),
      localStt: localStt,
      alignment: _Alignment(),
      media: media,
    );

    await controller.enqueueSources([fixture.audio.path]);
    await media.inspectStarted.future;
    await controller.updateSettings(
      controller.settings.copyWith(autoTranscribeLocal: false),
    );
    media.releaseInspect.complete();
    await _waitFor(() => controller.inboxJobs.single.status == JobStatus.ready);

    expect(localStt.calls, 0);
  });

  test('disabling local automation lets only the running job finish', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final second = File('${fixture.root.path}/second.wav');
    await second.writeAsBytes(List<int>.filled(64, 0));
    final localStt = _GatedLocalStt();
    final controller = await fixture.controller(
      settings: const AppSettings(
        defaultTranscriptionProvider: TranscriptionProvider.mossLocal,
        autoTranscribeLocal: true,
      ),
      localStt: localStt,
      alignment: _Alignment(),
    );

    await controller.enqueueSources([fixture.audio.path, second.path]);
    await localStt.entered.future;
    await controller.updateSettings(
      controller.settings.copyWith(autoTranscribeLocal: false),
    );
    localStt.release.complete();
    await _waitFor(() => controller.completedCount == 1);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(localStt.calls, 1);
    expect(
      controller.inboxJobs.where((job) => job.status.canTranscribe),
      hasLength(1),
    );
  });

  test('installing a missing local model resumes eligible new work', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final models = _InstallableModels();
    final localStt = _CountingLocalStt();
    final controller = await fixture.controller(
      settings: const AppSettings(
        defaultTranscriptionProvider: TranscriptionProvider.mossLocal,
        autoTranscribeLocal: true,
      ),
      localStt: localStt,
      alignment: _Alignment(),
      localModelManager: models,
    );

    await controller.enqueueSources([fixture.audio.path]);
    await _waitFor(() => controller.inboxJobs.single.status == JobStatus.ready);
    expect(localStt.calls, 0);

    await controller.downloadLocalModel(
      LocalSpeechModels.mossDiarizeCoreMlInt8.id,
    );
    await _waitFor(
      () => controller.inboxJobs.single.status == JobStatus.completed,
    );

    expect(localStt.calls, 1);
  });

  test('monitored MOSS Local files auto-transcribe when enabled', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final monitor = _TestInboxMonitor();
    final controller = await fixture.controller(
      settings: const AppSettings(
        defaultTranscriptionProvider: TranscriptionProvider.mossLocal,
        autoTranscribeLocal: true,
      ),
      localStt: _LocalStt(),
      alignment: _Alignment(),
      inboxMonitor: monitor,
      inboxMonitorRepository: _MemoryInboxMonitorRepository(),
    );
    await controller.configureInboxMonitor(
      folderPath: fixture.root.path,
      extensions: const {'wav'},
      launchAtLogin: false,
    );

    await monitor.emit(fixture.audio.path);
    await _waitFor(
      () =>
          controller.inboxJobs.single.sourceOrigin ==
              JobSourceOrigin.monitoredFolder &&
          controller.inboxJobs.single.status == JobStatus.completed,
    );
  });

  test(
    'podcast downloads auto-transcribe only when MOSS Local is required',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      const enclosure = 'https://cdn.example/episode.mp3';
      final gateway = MemoryPodcastGateway(
        enclosures: const {
          enclosure: [1, 2, 3],
        },
      );
      final controller = await fixture.controller(
        settings: const AppSettings(
          defaultTranscriptionProvider: TranscriptionProvider.mossLocal,
          autoTranscribeLocal: true,
        ),
        localStt: _LocalStt(),
        alignment: _Alignment(),
        podcastGateway: gateway,
        podcastManagedRoot: fixture.root.path,
      );

      await controller.enqueuePodcastEpisode(
        const PodcastEpisode(
          id: 'episode',
          feedUrl: 'https://feeds.example/show',
          title: 'Episode',
          enclosureUrl: enclosure,
          mediaExtension: 'mp3',
        ),
      );
      await _waitFor(
        () => controller.inboxJobs.single.status == JobStatus.completed,
      );

      expect(
        controller.inboxJobs.single.transcriptSource,
        TranscriptSource.mossLocal,
      );
    },
  );

  test(
    'publisher-caption podcasts remain manual with local automation enabled',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      const enclosure = 'https://cdn.example/captioned.mp3';
      const transcript = 'https://cdn.example/captioned.vtt';
      final gateway = MemoryPodcastGateway(
        enclosures: const {
          enclosure: [1, 2, 3],
        },
        transcripts: const {
          transcript: 'WEBVTT\n\n00:00.000 --> 00:01.000\nHello',
        },
      );
      final controller = await fixture.controller(
        settings: const AppSettings(
          defaultTranscriptionProvider: TranscriptionProvider.mossLocal,
          autoTranscribeLocal: true,
        ),
        localStt: _LocalStt(),
        alignment: _Alignment(),
        podcastGateway: gateway,
        podcastManagedRoot: fixture.root.path,
      );

      await controller.enqueuePodcastEpisode(
        const PodcastEpisode(
          id: 'captioned',
          feedUrl: 'https://feeds.example/show',
          title: 'Captioned episode',
          enclosureUrl: enclosure,
          mediaExtension: 'mp3',
          transcripts: [
            PodcastTranscriptReference(url: transcript, type: 'text/vtt'),
          ],
        ),
      );
      await _waitFor(
        () => controller.inboxJobs.single.status == JobStatus.ready,
      );

      expect(
        controller.inboxJobs.single.transcriptAcquisitionMode,
        TranscriptAcquisitionMode.publisherCaptions,
      );
      expect(controller.inboxJobs.single.document, isNull);
    },
  );

  test('ready history re-added to Inbox is not auto-started', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final now = DateTime.now().toUtc();
    await LocalJobRepository(fixture.paths).save(
      TranscriptionJob(
        id: 'existing',
        batchId: 'batch',
        sourcePath: fixture.audio.path,
        createdAt: now,
        updatedAt: now,
        status: JobStatus.ready,
        metadata: _metadata,
        transcriptionProvider: TranscriptionProvider.mossLocal,
      ),
    );
    final localStt = _CountingLocalStt();
    final controller = await fixture.controller(
      settings: const AppSettings(autoTranscribeLocal: true),
      localStt: localStt,
      alignment: _Alignment(),
    );

    controller.addToInbox('existing');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(controller.inboxJobs.single.status, JobStatus.ready);
    expect(localStt.calls, 0);
  });

  test(
    'cancelling alignment retains the persisted MOSS segment result',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final controller = await fixture.controller(
        settings: const AppSettings(
          defaultTranscriptionProvider: TranscriptionProvider.mossLocal,
        ),
        localStt: _LocalStt(),
        alignment: _CancellableAlignment(),
      );

      await controller.enqueueSources([fixture.audio.path]);
      await _waitFor(
        () => controller.inboxJobs.single.status == JobStatus.ready,
      );
      final running = controller.startReady();
      await _waitFor(
        () => controller.inboxJobs.single.status == JobStatus.aligning,
      );
      await controller.cancelJob(controller.inboxJobs.single.id);
      await running;

      final job = controller.inboxJobs.single;
      expect(job.status, JobStatus.completed);
      expect(job.document!.segments.single.text, 'Hello world');
      expect(job.document!.tokens, isEmpty);
      expect(job.forcedAlignment.status, ForcedAlignmentStatus.cancelled);
    },
  );

  for (final provider in [
    TranscriptionProvider.mossLocal,
    TranscriptionProvider.qwen3Local,
  ]) {
    test(
      'cancelling ${provider.name} transcription cancels the whole task',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        final localStt = _CancellableLocalStt();
        final controller = await fixture.controller(
          settings: AppSettings(defaultTranscriptionProvider: provider),
          localStt: localStt,
          alignment: _Alignment(),
        );

        await controller.enqueueSources([fixture.audio.path]);
        await _waitFor(
          () => controller.inboxJobs.single.status == JobStatus.ready,
        );
        final running = controller.startReady();
        await localStt.entered.future;
        await controller.cancelJob(controller.inboxJobs.single.id);
        await running;

        final job = controller.inboxJobs.single;
        expect(job.status, JobStatus.cancelled);
        expect(job.document, isNull);
        expect(job.forcedAlignment.status, ForcedAlignmentStatus.notRequested);
      },
    );
  }

  test('local transcription and alignment share one model permit', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final second = File('${fixture.root.path}/second.wav');
    await second.writeAsBytes(List<int>.filled(64, 0));
    final tracker = _ConcurrencyTracker();
    final controller = await fixture.controller(
      settings: const AppSettings(
        defaultTranscriptionProvider: TranscriptionProvider.mossLocal,
      ),
      localStt: _TrackedLocalStt(tracker),
      alignment: _TrackedAlignment(tracker),
    );

    await controller.enqueueSources([fixture.audio.path, second.path]);
    await _waitFor(
      () =>
          controller.inboxJobs.length == 2 &&
          controller.inboxJobs.every((job) => job.status == JobStatus.ready),
    );
    await controller.startReady();

    expect(tracker.maxActive, 1);
    expect(
      controller.inboxJobs.every((job) => job.status == JobStatus.completed),
      isTrue,
    );
  });

  test('MOSS Pro cleanup releases the network lane before alignment', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final second = File('${fixture.root.path}/remote.wav');
    await second.writeAsBytes(List<int>.filled(64, 0));
    final now = DateTime.now().toUtc();
    final repository = LocalJobRepository(fixture.paths);
    await repository.save(
      TranscriptionJob(
        id: 'local',
        batchId: 'batch',
        sourcePath: fixture.audio.path,
        createdAt: now,
        updatedAt: now,
        status: JobStatus.ready,
        metadata: _metadata,
        transcriptionProvider: TranscriptionProvider.mossLocal,
      ),
    );
    await repository.save(
      TranscriptionJob(
        id: 'remote',
        batchId: 'batch',
        sourcePath: second.path,
        createdAt: now,
        updatedAt: now,
        status: JobStatus.ready,
        metadata: _metadata,
        transcriptionProvider: TranscriptionProvider.mossPro,
      ),
    );
    final remote = _MossRemote();
    final alignment = _AlignmentGate();
    final controller = await fixture.controller(
      settings: const AppSettings(),
      localStt: _LocalStt(),
      alignment: alignment,
      mossClient: remote,
    );
    controller.addToInbox('local');
    controller.addToInbox('remote');

    final running = controller.startReady();
    await alignment.entered.future;
    await remote.cleaned.future.timeout(const Duration(seconds: 2));
    await _waitFor(
      () => controller.jobById('remote')!.cleanupState == CleanupState.complete,
    );

    expect(controller.jobById('remote')!.cleanupState, CleanupState.complete);
    expect(controller.jobById('remote')!.status, JobStatus.aligning);
    alignment.release.complete();
    await running;
    expect(controller.jobById('remote')!.status, JobStatus.completed);
  });

  test(
    'restart preserves MOSS segments and marks alignment interrupted',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final now = DateTime.now().toUtc();
      await LocalJobRepository(fixture.paths).save(
        TranscriptionJob(
          id: 'interrupted-alignment',
          batchId: 'batch',
          sourcePath: fixture.audio.path,
          createdAt: now,
          updatedAt: now,
          status: JobStatus.aligning,
          metadata: _metadata,
          transcriptionProvider: TranscriptionProvider.mossLocal,
          transcriptSource: TranscriptSource.mossLocal,
          document: TranscriptDocument(
            tokens: const [],
            segments: const [
              TranscriptSegment(
                id: 'moss-0',
                startMs: 0,
                endMs: 2000,
                text: 'Saved before alignment',
                speaker: 'S01',
              ),
            ],
            speakers: const [SpeakerProfile(id: 'S01', name: 'Speaker 1')],
            updatedAt: now,
          ),
          forcedAlignment: const ForcedAlignmentState(
            status: ForcedAlignmentStatus.running,
            alignedSegments: 0,
            totalSegments: 1,
          ),
        ),
      );

      final controller = await fixture.controller(
        settings: const AppSettings(),
        localStt: _LocalStt(),
        alignment: _Alignment(),
      );

      final recovered = controller.jobById('interrupted-alignment')!;
      expect(recovered.status, JobStatus.completed);
      expect(
        recovered.document!.segments.single.text,
        'Saved before alignment',
      );
      expect(
        recovered.forcedAlignment.status,
        ForcedAlignmentStatus.interrupted,
      );
      expect(recovered.forcedAlignment.warningCode, 'alignment_interrupted');
    },
  );

  test('restart removes persisted control-only MOSS segments', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final now = DateTime.now().toUtc();
    await LocalJobRepository(fixture.paths).save(
      TranscriptionJob(
        id: 'malformed-local-output',
        batchId: 'batch',
        sourcePath: fixture.audio.path,
        createdAt: now,
        updatedAt: now,
        status: JobStatus.completed,
        metadata: _metadata,
        transcriptionProvider: TranscriptionProvider.mossLocal,
        transcriptSource: TranscriptSource.mossLocal,
        document: TranscriptDocument(
          tokens: const [],
          segments: const [
            TranscriptSegment(
              id: 'moss-0',
              startMs: 39 * 60 * 1000,
              endMs: 39 * 60 * 1000 + 30000,
              text: '[2.12][S01][2.62][18.28][S02][18.78]',
              speaker: 'S01',
            ),
          ],
          speakers: const [SpeakerProfile(id: 'S01', name: 'Speaker 1')],
          updatedAt: now,
        ),
      ),
    );

    final controller = await fixture.controller(
      settings: const AppSettings(),
      localStt: _LocalStt(),
      alignment: _Alignment(),
    );

    final recovered = controller.jobById('malformed-local-output')!;
    expect(recovered.status, JobStatus.empty);
    expect(recovered.document!.segments, isEmpty);
    expect(recovered.document!.speakers, isEmpty);
    final persisted = await LocalJobRepository(fixture.paths).loadAll();
    expect(persisted.single.document!.segments, isEmpty);
  });

  test('restart does not merge completed aligned MOSS segments', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final now = DateTime.now().toUtc();
    await LocalJobRepository(fixture.paths).save(
      TranscriptionJob(
        id: 'completed-alignment',
        batchId: 'batch',
        sourcePath: fixture.audio.path,
        createdAt: now,
        updatedAt: now,
        status: JobStatus.completed,
        transcriptionProvider: TranscriptionProvider.mossLocal,
        transcriptSource: TranscriptSource.mossLocal,
        document: TranscriptDocument(
          tokens: const [
            TranscriptToken(
              text: '今天',
              startMs: 0,
              endMs: 400,
              segmentId: 'moss-0',
            ),
            TranscriptToken(
              text: '分享',
              startMs: 500,
              endMs: 900,
              segmentId: 'moss-1',
            ),
          ],
          segments: const [
            TranscriptSegment(id: 'moss-0', startMs: 0, endMs: 450, text: '今天'),
            TranscriptSegment(
              id: 'moss-1',
              startMs: 500,
              endMs: 950,
              text: '分享',
            ),
          ],
          speakers: const [],
          updatedAt: now,
        ),
        forcedAlignment: const ForcedAlignmentState(
          status: ForcedAlignmentStatus.completed,
          alignedSegments: 2,
          totalSegments: 2,
        ),
      ),
    );

    final controller = await fixture.controller(
      settings: const AppSettings(),
      localStt: _LocalStt(),
      alignment: _Alignment(),
    );
    addTearDown(controller.dispose);

    final document = controller.jobById('completed-alignment')!.document!;
    expect(document.segments.map((segment) => segment.id), [
      'moss-0',
      'moss-1',
    ]);
    expect(document.tokens.map((token) => token.segmentId), [
      'moss-0',
      'moss-1',
    ]);
  });

  test(
    'retry alignment without source keeps its saved MOSS segments',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final now = DateTime.now().toUtc();
      await LocalJobRepository(fixture.paths).save(
        TranscriptionJob(
          id: 'missing-source-alignment',
          batchId: 'batch',
          sourcePath: '${fixture.root.path}/gone.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
          transcriptionProvider: TranscriptionProvider.mossPro,
          transcriptSource: TranscriptSource.mossPro,
          document: TranscriptDocument(
            tokens: const [],
            segments: const [
              TranscriptSegment(
                id: 'moss-0',
                startMs: 0,
                endMs: 2000,
                text: 'Saved remote text',
              ),
            ],
            speakers: const [],
            updatedAt: now,
          ),
        ),
      );
      final controller = await fixture.controller(
        settings: const AppSettings(),
        localStt: _LocalStt(),
        alignment: _Alignment(),
      );

      await controller.retryForcedAlignment('missing-source-alignment');

      final job = controller.jobById('missing-source-alignment')!;
      expect(job.status, JobStatus.completed);
      expect(job.document!.segments.single.text, 'Saved remote text');
      expect(job.forcedAlignment.status, ForcedAlignmentStatus.unavailable);
      expect(job.forcedAlignment.warningCode, 'alignment_source_missing');
    },
  );
}

const _metadata = MediaMetadata(
  sizeBytes: 64,
  durationMs: 2000,
  hasAudio: true,
  hasVideo: false,
  formatName: 'wav',
);

Future<void> _waitFor(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 3)) {
      fail('Timed out waiting for controller state.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _Fixture {
  _Fixture(this.root, this.paths, this.audio);

  final Directory root;
  final AppPaths paths;
  final File audio;

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('meow-local-pipeline-');
    final paths = AppPaths.forTesting(root.path);
    await paths.root.create(recursive: true);
    final audio = File('${root.path}/meeting.wav');
    await audio.writeAsBytes(List<int>.filled(64, 0));
    return _Fixture(root, paths, audio);
  }

  Future<AppController> controller({
    required AppSettings settings,
    required LocalSttService localStt,
    required ForcedAlignmentService alignment,
    TranscriptionClient? mossClient,
    LocalModelManager? localModelManager,
    MediaService? media,
    InboxMonitorRepository? inboxMonitorRepository,
    InboxFolderMonitor? inboxMonitor,
    PodcastGateway? podcastGateway,
    String? podcastManagedRoot,
    bool preserveUnselectedAlignmentModel = false,
  }) async {
    final settingsRepository = JsonSettingsRepository(paths);
    final effectiveSettings =
        !preserveUnselectedAlignmentModel &&
            settings.defaultForcedAlignmentModel == null
        ? settings.copyWith(
            defaultForcedAlignmentModel: ForcedAlignmentModel.qwen3CoreMlInt8,
          )
        : settings;
    await settingsRepository.save(effectiveSettings);
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: settingsRepository,
      jobRepository: LocalJobRepository(paths),
      mediaService: media ?? _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _RemoteClient(),
      mossCredentialStore: mossClient == null ? null : _Credentials(),
      mossClient: mossClient,
      exporter: const DefaultTranscriptExporter(),
      localModelManager: localModelManager,
      localSttService: localStt,
      forcedAlignmentService: alignment,
      inboxMonitorRepository: inboxMonitorRepository,
      inboxFolderMonitor: inboxMonitor,
      podcastGateway: podcastGateway,
      podcastManagedRoot: podcastManagedRoot,
    );
    await controller.initialize();
    return controller;
  }

  Future<void> dispose() => root.delete(recursive: true);
}

class _BlockingVerificationModels implements LocalModelManager {
  final verificationStarted = Completer<void>();
  final releaseVerification = Completer<void>();

  @override
  List<LocalModelDescriptor> get models => [
    LocalSpeechModels.mossDiarizeCoreMlInt8,
  ];

  @override
  Future<void> delete(String modelId) async {}

  @override
  Future<void> download(
    String modelId, {
    ModelDownloadProgress? onProgress,
    CancelCheck? shouldCancel,
  }) async {}

  @override
  String pathFor(String modelId) => '/models/$modelId';

  @override
  Future<LocalModelStatus> status(
    String modelId, {
    bool verifyIntegrity = false,
  }) async {
    if (verifyIntegrity) {
      if (!verificationStarted.isCompleted) verificationStarted.complete();
      await releaseVerification.future;
    }
    return LocalModelStatus(
      descriptor: LocalSpeechModels.mossDiarizeCoreMlInt8,
      availability: LocalModelAvailability.ready,
      downloadedBytes: LocalSpeechModels.mossDiarizeCoreMlInt8.sizeBytes,
    );
  }
}

class _InstallableModels implements LocalModelManager {
  bool installed = false;

  @override
  List<LocalModelDescriptor> get models => [
    LocalSpeechModels.mossDiarizeCoreMlInt8,
  ];

  @override
  Future<void> delete(String modelId) async => installed = false;

  @override
  Future<void> download(
    String modelId, {
    ModelDownloadProgress? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    installed = true;
    onProgress?.call(
      LocalSpeechModels.mossDiarizeCoreMlInt8.sizeBytes,
      LocalSpeechModels.mossDiarizeCoreMlInt8.sizeBytes,
    );
  }

  @override
  String pathFor(String modelId) => '/models/$modelId';

  @override
  Future<LocalModelStatus> status(
    String modelId, {
    bool verifyIntegrity = false,
  }) async => LocalModelStatus(
    descriptor: LocalSpeechModels.mossDiarizeCoreMlInt8,
    availability: installed
        ? LocalModelAvailability.ready
        : LocalModelAvailability.missing,
    downloadedBytes: installed
        ? LocalSpeechModels.mossDiarizeCoreMlInt8.sizeBytes
        : 0,
  );
}

class _Credentials implements CredentialStore {
  @override
  Future<void> deleteApiKey() async {}

  @override
  Future<String?> readApiKey() async => 'test';

  @override
  Future<void> writeApiKey(String key) async {}
}

class _Media implements MediaService {
  @override
  bool canUploadDirectly(
    String path,
    MediaMetadata metadata, {
    MediaUploadProfile profile = MediaUploadProfile.standard,
  }) => true;

  @override
  Future<void> clearGeneratedMediaExcept(Set<String> retainedCacheKeys) async {}

  @override
  Future<void> deleteGeneratedMedia(String cacheKey) async {}

  @override
  Future<void> deleteTemporary(String path) async {}

  @override
  Future<MediaDiagnostics> diagnostics() async =>
      const MediaDiagnostics(available: true);

  @override
  Future<String> extractAudio(
    String sourcePath,
    String jobId, {
    required int durationMs,
    MediaUploadProfile profile = MediaUploadProfile.standard,
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async => sourcePath;

  @override
  Future<MediaMetadata> inspect(String sourcePath) async => _metadata;

  @override
  Future<String> renderWaveform(String sourcePath, String cacheKey) async => '';
}

class _FixedMetadataMedia extends _Media {
  _FixedMetadataMedia(this.metadata);

  final MediaMetadata metadata;

  @override
  Future<MediaMetadata> inspect(String sourcePath) async => metadata;
}

class _BlockingMedia extends _Media {
  final inspectStarted = Completer<void>();
  final releaseInspect = Completer<void>();

  @override
  Future<MediaMetadata> inspect(String sourcePath) async {
    if (!inspectStarted.isCompleted) inspectStarted.complete();
    await releaseInspect.future;
    return _metadata;
  }
}

class _RemoteClient implements SonioxClient {
  @override
  Future<String> createTranscription(
    String fileId,
    TranscriptionOptions options,
  ) => throw UnimplementedError();

  @override
  Future<void> deleteFile(String id) async {}

  @override
  Future<void> deleteTranscription(String id) async {}

  @override
  Future<Map<String, dynamic>> getTranscript(String id) =>
      throw UnimplementedError();

  @override
  Future<SonioxTranscriptionState> getTranscription(String id) =>
      throw UnimplementedError();

  @override
  Future<String> uploadFile(
    String path, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) => throw UnimplementedError();

  @override
  Future<void> validateKey({String? apiKey}) async {}
}

class _LocalStt implements LocalSttService {
  @override
  bool get isSupported => true;

  @override
  Future<LocalSttResult> transcribe(
    LocalSttRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async => LocalSttResult(
    document: TranscriptDocument(
      tokens: const [],
      segments: const [
        TranscriptSegment(
          id: 'moss-0',
          startMs: 0,
          endMs: 2000,
          text: 'Hello world',
          speaker: 'S01',
        ),
      ],
      speakers: const [SpeakerProfile(id: 'S01', name: 'Speaker 1')],
      updatedAt: DateTime.now().toUtc(),
    ),
    model: TranscriptionModelReference(
      id: LocalSpeechModels.mossDiarizeCoreMlInt8.id,
      revision: LocalSpeechModels.mossDiarizeCoreMlInt8.revision,
    ),
  );
}

class _QwenLocalStt implements LocalSttService {
  final engines = <LocalSttEngine>[];

  @override
  bool get isSupported => true;

  @override
  Future<LocalSttResult> transcribe(
    LocalSttRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    engines.add(request.engine);
    return LocalSttResult(
      document: TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'qwen3-0',
            startMs: 100,
            endMs: 1800,
            text: 'Higher quality text',
            language: 'en',
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.now().toUtc(),
      ),
      model: TranscriptionModelReference(
        id: LocalSpeechModels.qwen3AsrMlx8Bit.id,
        revision: LocalSpeechModels.qwen3AsrMlx8Bit.revision,
      ),
    );
  }
}

class _CountingLocalStt extends _LocalStt {
  int calls = 0;

  @override
  Future<LocalSttResult> transcribe(
    LocalSttRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) {
    calls++;
    return super.transcribe(
      request,
      onProgress: onProgress,
      shouldCancel: shouldCancel,
    );
  }
}

class _GatedLocalStt extends _CountingLocalStt {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<LocalSttResult> transcribe(
    LocalSttRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return super.transcribe(
      request,
      onProgress: onProgress,
      shouldCancel: shouldCancel,
    );
  }
}

class _IntermittentProgressLocalStt extends _LocalStt {
  final numericProgressEmitted = Completer<void>();
  final emitProgressWithoutFraction = Completer<void>();
  final progressWithoutFractionEmitted = Completer<void>();
  final release = Completer<void>();

  @override
  Future<LocalSttResult> transcribe(
    LocalSttRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    onProgress?.call(0.44, 'transcribing-coreml');
    numericProgressEmitted.complete();
    await emitProgressWithoutFraction.future;
    onProgress?.call(null, 'retrying-coreml-chunk');
    progressWithoutFractionEmitted.complete();
    await release.future;
    return super.transcribe(
      request,
      onProgress: onProgress,
      shouldCancel: shouldCancel,
    );
  }
}

class _MemoryInboxMonitorRepository implements InboxMonitorRepository {
  InboxMonitorStorage value = const InboxMonitorStorage();

  @override
  Future<InboxMonitorStorage> load() async => value;

  @override
  Future<void> save(InboxMonitorStorage storage) async => value = storage;
}

class _TestInboxMonitor implements InboxFolderMonitor {
  MonitoredFileCallback? _onCandidate;

  Future<void> emit(String path) async {
    final fingerprint = await fingerprintMonitoredFile(path);
    if (fingerprint != null) await _onCandidate?.call(fingerprint);
  }

  @override
  Future<void> dispose() => stop();

  @override
  Future<void> scanNow() async {}

  @override
  Future<void> start(
    InboxMonitorConfig config, {
    required MonitoredFileCallback onCandidate,
    required MonitoredFilesSnapshotCallback onSnapshot,
    required InboxMonitorStatusCallback onStatus,
  }) async {
    _onCandidate = onCandidate;
    onStatus(InboxMonitorStatus.active, null);
  }

  @override
  Future<void> stop() async => _onCandidate = null;
}

class _AlignmentModels implements LocalModelManager {
  _AlignmentModels(Set<String> installed) : installed = {...installed};

  final Set<String> installed;

  @override
  List<LocalModelDescriptor> get models =>
      LocalSpeechModels.forcedAligners.values.toList(growable: false);

  @override
  Future<void> delete(String modelId) async => installed.remove(modelId);

  @override
  Future<void> download(
    String modelId, {
    ModelDownloadProgress? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    installed.add(modelId);
    final descriptor = LocalSpeechModels.forcedAlignerById(modelId)!;
    onProgress?.call(descriptor.sizeBytes, descriptor.sizeBytes);
  }

  @override
  String pathFor(String modelId) => '/models/$modelId';

  @override
  Future<LocalModelStatus> status(
    String modelId, {
    bool verifyIntegrity = false,
  }) async {
    final descriptor = LocalSpeechModels.forcedAlignerById(modelId)!;
    final ready = installed.contains(modelId);
    return LocalModelStatus(
      descriptor: descriptor,
      availability: ready
          ? LocalModelAvailability.ready
          : LocalModelAvailability.missing,
      downloadedBytes: ready ? descriptor.sizeBytes : 0,
    );
  }
}

class _QwenModels implements LocalModelManager {
  _QwenModels({this.failId});

  String? failId;
  final installed = <String>{};
  final downloads = <String>[];

  @override
  List<LocalModelDescriptor> get models =>
      LocalSpeechModels.qwen3AsrBundle.artifacts;

  @override
  Future<void> delete(String modelId) async => installed.remove(modelId);

  @override
  Future<void> download(
    String modelId, {
    ModelDownloadProgress? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    downloads.add(modelId);
    if (modelId == failId) {
      throw const LocalModelException('model_checksum_mismatch');
    }
    installed.add(modelId);
    final descriptor = models.singleWhere((model) => model.id == modelId);
    onProgress?.call(descriptor.sizeBytes, descriptor.sizeBytes);
  }

  @override
  String pathFor(String modelId) => '/models/$modelId';

  @override
  Future<LocalModelStatus> status(
    String modelId, {
    bool verifyIntegrity = false,
  }) async {
    final descriptor = models.singleWhere((model) => model.id == modelId);
    final ready = installed.contains(modelId);
    return LocalModelStatus(
      descriptor: descriptor,
      availability: ready
          ? LocalModelAvailability.ready
          : LocalModelAvailability.missing,
      downloadedBytes: ready ? descriptor.sizeBytes : 0,
    );
  }
}

class _CountingAlignment implements ForcedAlignmentService {
  int calls = 0;

  @override
  bool get isSupported => true;

  @override
  Future<AlignmentResult> align(
    ForcedAlignmentRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    calls++;
    return const AlignmentResult(
      tokens: [],
      status: ForcedAlignmentStatus.completed,
      alignedSegments: 0,
      totalSegments: 1,
    );
  }
}

class _ImportedAlignment implements ForcedAlignmentService {
  final requests = <ForcedAlignmentRequest>[];

  @override
  bool get isSupported => true;

  @override
  Future<AlignmentResult> align(
    ForcedAlignmentRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    requests.add(request);
    final segment = request.document.segments.single;
    return AlignmentResult(
      tokens: [
        TranscriptToken(
          text: 'Hello',
          startMs: 250,
          endMs: 900,
          segmentId: segment.id,
        ),
        TranscriptToken(
          text: 'imported',
          startMs: 950,
          endMs: 1750,
          segmentId: segment.id,
        ),
      ],
      status: ForcedAlignmentStatus.completed,
      alignedSegments: 1,
      totalSegments: 1,
    );
  }
}

class _ConflictingImportedAlignment implements ForcedAlignmentService {
  @override
  bool get isSupported => true;

  @override
  Future<AlignmentResult> align(
    ForcedAlignmentRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    final first = request.document.segments.first;
    final second = request.document.segments[1];
    final third = request.document.segments[2];
    return AlignmentResult(
      tokens: [
        TranscriptToken(
          text: 'First ',
          startMs: 400,
          endMs: 1000,
          segmentId: first.id,
        ),
        TranscriptToken(
          text: 'sentence.',
          startMs: 1000,
          endMs: 2100,
          segmentId: first.id,
        ),
        TranscriptToken(
          text: 'Second ',
          startMs: 1800,
          endMs: 2600,
          segmentId: second.id,
        ),
        TranscriptToken(
          text: 'sentence.',
          startMs: 2600,
          endMs: 3600,
          segmentId: second.id,
        ),
        TranscriptToken(
          text: 'Third ',
          startMs: 4300,
          endMs: 5000,
          segmentId: third.id,
        ),
        TranscriptToken(
          text: 'sentence.',
          startMs: 5000,
          endMs: 5700,
          segmentId: third.id,
        ),
      ],
      status: ForcedAlignmentStatus.completed,
      alignedSegments: 3,
      totalSegments: 3,
    );
  }
}

class _RepairingImportedAlignment implements ForcedAlignmentService {
  final requests = <ForcedAlignmentRequest>[];

  @override
  bool get isSupported => true;

  @override
  Future<AlignmentResult> align(
    ForcedAlignmentRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    requests.add(request);
    final first = request.document.segments.first;
    final second = request.document.segments.last;
    return AlignmentResult(
      tokens: [
        TranscriptToken(
          text: 'First sentence.',
          startMs: 400,
          endMs: 1400,
          segmentId: first.id,
        ),
        TranscriptToken(
          text: 'Second sentence.',
          startMs: 1600,
          endMs: 3600,
          segmentId: second.id,
        ),
      ],
      status: ForcedAlignmentStatus.completed,
      alignedSegments: 2,
      totalSegments: 2,
    );
  }
}

class _RollingImportedAlignment implements ForcedAlignmentService {
  final requests = <ForcedAlignmentRequest>[];

  @override
  bool get isSupported => true;

  @override
  Future<AlignmentResult> align(
    ForcedAlignmentRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    requests.add(request);
    return AlignmentResult(
      tokens: [
        for (var index = 0; index < request.document.segments.length; index++)
          TranscriptToken(
            text: request.document.segments[index].text,
            startMs: index * 1000 + 100,
            endMs: index * 1000 + 900,
            segmentId: request.document.segments[index].id,
          ),
      ],
      status: ForcedAlignmentStatus.completed,
      alignedSegments: request.document.segments.length,
      totalSegments: request.document.segments.length,
    );
  }
}

class _CheckpointThenCancelAlignment implements ForcedAlignmentService {
  @override
  bool get isSupported => true;

  @override
  Future<AlignmentResult> align(
    ForcedAlignmentRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    request.onCheckpoint?.call(
      AlignmentResult(
        tokens: [
          TranscriptToken(
            text: 'First',
            startMs: 100,
            endMs: 800,
            segmentId: request.document.segments.first.id,
          ),
        ],
        status: ForcedAlignmentStatus.partial,
        alignedSegments: 1,
        totalSegments: 2,
      ),
    );
    throw const OperationCancelledException();
  }
}

class _SwitchingAlignment implements ForcedAlignmentService {
  final firstEntered = Completer<void>();
  final releaseFirst = Completer<void>();
  final models = <LocalModelDescriptor>[];

  @override
  bool get isSupported => true;

  @override
  Future<AlignmentResult> align(
    ForcedAlignmentRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    models.add(request.model);
    if (models.length == 1) {
      firstEntered.complete();
      await releaseFirst.future;
    }
    return const AlignmentResult(
      tokens: [
        TranscriptToken(
          text: 'Hello',
          startMs: 0,
          endMs: 800,
          segmentId: 'moss-0',
          speaker: 'S01',
        ),
      ],
      status: ForcedAlignmentStatus.completed,
      alignedSegments: 1,
      totalSegments: 1,
    );
  }
}

class _Alignment implements ForcedAlignmentService {
  @override
  bool get isSupported => true;

  @override
  Future<AlignmentResult> align(
    ForcedAlignmentRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async => const AlignmentResult(
    tokens: [
      TranscriptToken(
        text: 'Hello',
        startMs: 0,
        endMs: 800,
        segmentId: 'moss-0',
        speaker: 'S01',
      ),
    ],
    status: ForcedAlignmentStatus.completed,
    alignedSegments: 1,
    totalSegments: 1,
  );
}

class _CancellableAlignment implements ForcedAlignmentService {
  @override
  bool get isSupported => true;

  @override
  Future<AlignmentResult> align(
    ForcedAlignmentRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    while (!(shouldCancel?.call() ?? false)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw const OperationCancelledException();
  }
}

class _CancellableLocalStt extends _LocalStt {
  final entered = Completer<void>();

  @override
  Future<LocalSttResult> transcribe(
    LocalSttRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    entered.complete();
    while (!(shouldCancel?.call() ?? false)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw const OperationCancelledException();
  }
}

class _ConcurrencyTracker {
  int active = 0;
  int maxActive = 0;

  Future<void> run() async {
    active++;
    if (active > maxActive) maxActive = active;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    active--;
  }
}

class _TrackedLocalStt extends _LocalStt {
  _TrackedLocalStt(this.tracker);
  final _ConcurrencyTracker tracker;

  @override
  Future<LocalSttResult> transcribe(
    LocalSttRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    await tracker.run();
    return super.transcribe(
      request,
      onProgress: onProgress,
      shouldCancel: shouldCancel,
    );
  }
}

class _TrackedAlignment extends _Alignment {
  _TrackedAlignment(this.tracker);
  final _ConcurrencyTracker tracker;

  @override
  Future<AlignmentResult> align(
    ForcedAlignmentRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    await tracker.run();
    return super.align(
      request,
      onProgress: onProgress,
      shouldCancel: shouldCancel,
    );
  }
}

class _AlignmentGate extends _Alignment {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<AlignmentResult> align(
    ForcedAlignmentRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return super.align(
      request,
      onProgress: onProgress,
      shouldCancel: shouldCancel,
    );
  }
}

class _MossRemote implements TranscriptionClient {
  final cleaned = Completer<void>();
  var _deletes = 0;

  void _deleted() {
    _deletes++;
    if (_deletes == 2 && !cleaned.isCompleted) cleaned.complete();
  }

  @override
  Future<String> createTranscription(
    String fileId,
    TranscriptionOptions options,
  ) async => 'remote-task';

  @override
  Future<void> deleteFile(String id) async => _deleted();

  @override
  Future<void> deleteTranscription(String id) async => _deleted();

  @override
  Future<Map<String, dynamic>> getTranscript(String id) async => {
    'segments': [
      {
        'id': 'moss-0',
        'start': 0.0,
        'end': 2.0,
        'text': 'Remote words',
        'speaker': 'S01',
      },
    ],
  };

  @override
  Future<RemoteTranscriptionState> getTranscription(String id) async =>
      const RemoteTranscriptionState(status: 'SUCCESS');

  @override
  Future<String> uploadFile(
    String path, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async => 'remote-file';

  @override
  Future<void> validateKey({String? apiKey}) async {}
}
