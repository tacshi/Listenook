import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/contracts.dart';
import 'package:meow_stt/core/local_speech.dart';
import 'package:meow_stt/core/models.dart';
import 'package:meow_stt/core/podcast_models.dart';
import 'package:meow_stt/data/inbox_folder_monitor.dart';
import 'package:meow_stt/data/local_media_source_resolver.dart';
import 'package:meow_stt/data/local_repositories.dart';
import 'package:meow_stt/data/podcast/http_podcast_gateway.dart';
import 'package:meow_stt/data/transcript_exporter.dart';
import 'package:meow_stt/state/app_controller.dart';

void main() {
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
      await controller.startReady();

      final job = controller.inboxJobs.single;
      expect(job.status, JobStatus.completed);
      expect(job.transcriptSource, TranscriptSource.mossLocal);
      expect(job.document!.segments.single.text, 'Hello world');
      expect(job.document!.tokens.single.segmentId, 'moss-0');
      expect(job.forcedAlignment.status, ForcedAlignmentStatus.completed);
      expect(job.progress.stage, 'complete');
    },
  );

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

  test('cancelling local MOSS transcription cancels the whole task', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final localStt = _CancellableLocalStt();
    final controller = await fixture.controller(
      settings: const AppSettings(
        defaultTranscriptionProvider: TranscriptionProvider.mossLocal,
      ),
      localStt: localStt,
      alignment: _Alignment(),
    );

    await controller.enqueueSources([fixture.audio.path]);
    await _waitFor(() => controller.inboxJobs.single.status == JobStatus.ready);
    final running = controller.startReady();
    await localStt.entered.future;
    await controller.cancelJob(controller.inboxJobs.single.id);
    await running;

    final job = controller.inboxJobs.single;
    expect(job.status, JobStatus.cancelled);
    expect(job.document, isNull);
    expect(job.forcedAlignment.status, ForcedAlignmentStatus.notRequested);
  });

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
  Future<TranscriptDocument> transcribe(
    LocalSttRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async => TranscriptDocument(
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
  );
}

class _CountingLocalStt extends _LocalStt {
  int calls = 0;

  @override
  Future<TranscriptDocument> transcribe(
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
  Future<TranscriptDocument> transcribe(
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
  Future<TranscriptDocument> transcribe(
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
  Future<TranscriptDocument> transcribe(
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
