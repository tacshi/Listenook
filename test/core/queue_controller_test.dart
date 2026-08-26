import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/contracts.dart';
import 'package:meow_stt/core/models.dart';
import 'package:meow_stt/core/transcript_structure_editor.dart';
import 'package:meow_stt/data/inbox_folder_monitor.dart';
import 'package:meow_stt/data/local_media_source_resolver.dart';
import 'package:meow_stt/data/openai_translation_service.dart';
import 'package:meow_stt/data/process_media_service.dart';
import 'package:meow_stt/data/transcript_exporter.dart';
import 'package:meow_stt/state/app_controller.dart';

void main() {
  test(
    'playback position survives destination changes for the app session',
    () async {
      final controller = _controller(jobs: _Jobs(), soniox: _Soniox());
      addTearDown(controller.dispose);
      await controller.initialize();

      expect(controller.playbackPositionFor('transcript'), Duration.zero);

      controller.rememberPlaybackPosition(
        'transcript',
        const Duration(minutes: 2, seconds: 7),
      );
      controller.setDestination(AppDestination.library);
      controller.setDestination(AppDestination.workspace);

      expect(
        controller.playbackPositionFor('transcript'),
        const Duration(minutes: 2, seconds: 7),
      );

      controller.rememberPlaybackPosition('transcript', Duration.zero);
      expect(controller.playbackPositionFor('transcript'), Duration.zero);
    },
  );

  test('playback position survives an app controller restart', () async {
    final now = DateTime.now().toUtc();
    final jobs = _Jobs([
      TranscriptionJob(
        id: 'transcript',
        batchId: 'batch',
        sourcePath: '/recording.wav',
        createdAt: now,
        updatedAt: now,
        status: JobStatus.completed,
        document: _document(now),
      ),
    ]);
    final settings = _Settings();
    final first = _controller(
      jobs: jobs,
      soniox: _Soniox(),
      settings: settings,
    );
    addTearDown(first.dispose);
    await first.initialize();

    first.rememberPlaybackPosition(
      'transcript',
      const Duration(hours: 1, minutes: 14, seconds: 9),
    );
    await first.shutdown();

    final restored = _controller(
      jobs: jobs,
      soniox: _Soniox(),
      settings: settings,
    );
    addTearDown(restored.dispose);
    await restored.initialize();

    expect(
      restored.playbackPositionFor('transcript'),
      const Duration(hours: 1, minutes: 14, seconds: 9),
    );
  });

  test(
    'startup restores Podcast and Library but ignores transient views',
    () async {
      final settings = _Settings(
        const AppSettings(
          lastContentDestination: AppContentDestination.library,
        ),
      );
      final controller = _controller(
        jobs: _Jobs(),
        soniox: _Soniox(),
        settings: settings,
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      expect(controller.destination, AppDestination.library);

      controller.setDestination(AppDestination.inbox);
      controller.setDestination(AppDestination.settings);
      expect(
        settings.value.lastContentDestination,
        AppContentDestination.library,
      );

      controller.setDestination(AppDestination.podcast);
      await _waitFor(
        () =>
            settings.value.lastContentDestination ==
            AppContentDestination.podcast,
      );
    },
  );

  test('startup restores a valid Workspace transcript', () async {
    final now = DateTime.now().toUtc();
    final settings = _Settings(
      const AppSettings(
        lastContentDestination: AppContentDestination.workspace,
        lastWorkspaceJobId: 'transcript',
      ),
    );
    final controller = _controller(
      jobs: _Jobs([
        TranscriptionJob(
          id: 'transcript',
          batchId: 'batch',
          sourcePath: '/recording.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
          document: _document(now),
        ),
      ]),
      soniox: _Soniox(),
      settings: settings,
    );
    addTearDown(controller.dispose);

    await controller.initialize();

    expect(controller.destination, AppDestination.workspace);
    expect(controller.activeWorkspaceJobId, 'transcript');
  });

  test(
    'invalid saved Workspace state falls back to Podcast and is cleared',
    () async {
      final settings = _Settings(
        const AppSettings(
          lastContentDestination: AppContentDestination.workspace,
          lastWorkspaceJobId: 'missing',
        ),
      );
      final controller = _controller(
        jobs: _Jobs(),
        soniox: _Soniox(),
        settings: settings,
      );
      addTearDown(controller.dispose);

      await controller.initialize();

      expect(controller.destination, AppDestination.podcast);
      expect(
        settings.value.lastContentDestination,
        AppContentDestination.podcast,
      );
      expect(settings.value.lastWorkspaceJobId, isNull);
    },
  );

  test(
    'initialization checks credential metadata without reading secrets',
    () async {
      final credentials = _AvailabilityCredentials();
      final translationCredentials = _AvailabilityTranslationCredentials();
      final controller = _controller(
        jobs: _Jobs(),
        soniox: _Soniox(),
        credentials: credentials,
        translationCredentials: translationCredentials,
      );

      await controller.initialize();

      expect(controller.keyConfigured, isTrue);
      expect(controller.translationKeyConfigured, isTrue);
      expect(credentials.availabilityChecks, 1);
      expect(translationCredentials.availabilityChecks, 1);
      expect(credentials.secretReads, 0);
      expect(translationCredentials.secretReads, 0);
    },
  );

  test('worker pool runs four queued jobs and persists completion', () async {
    final directory = await Directory.systemTemp.createTemp('meow-queue-');
    addTearDown(() => directory.delete(recursive: true));
    final files = <String>[];
    for (var index = 0; index < 4; index++) {
      final file = File('${directory.path}/$index.wav');
      await file.writeAsBytes([1, 2, 3]);
      files.add(file.path);
    }
    final jobs = _Jobs();
    final soniox = _Soniox(uploadDelay: const Duration(milliseconds: 40));
    final media = _Media()..uploadDirectly = false;
    final controller = _controller(jobs: jobs, soniox: soniox, media: media);
    await controller.initialize();
    expect(controller.destination, AppDestination.podcast);
    await controller.enqueueSources(files);
    await _waitFor(() => controller.readyCount == 4);
    final movedId = controller.inboxJobs.first.id;
    controller.reorderInbox(0, 3);
    await _waitFor(() => jobs.saved[movedId]?.queueIndex == 3);
    expect(controller.inboxJobs.last.id, movedId);

    await controller.startReady();

    expect(soniox.maximumUploads, 4);
    expect(controller.completedCount, 4);
    expect(controller.destination, AppDestination.podcast);
    expect(
      jobs.saved.values.every(
        (job) => job.cleanupState == CleanupState.complete,
      ),
      isTrue,
    );
    expect(soniox.deletedFiles, hasLength(4));
    expect(soniox.deletedTranscriptions, hasLength(4));
    expect(
      media.extractedUploadProfiles,
      everyElement(MediaUploadProfile.standard),
    );
  });

  test(
    'MOSS Pro default routes new jobs and persists its transcript source',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'meow-moss-route-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/meeting.wav');
      await file.writeAsBytes([1, 2, 3]);
      final soniox = _Soniox();
      final moss = _Moss();
      final media = _Media()..uploadDirectly = false;
      final controller = _controller(
        jobs: _Jobs(),
        soniox: soniox,
        media: media,
        moss: moss,
        mossCredentials: _Credentials(),
        settings: _Settings(
          const AppSettings(
            defaultTranscriptionProvider: TranscriptionProvider.mossPro,
          ),
        ),
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.enqueueSources([file.path]);
      await _waitFor(() => controller.readyCount == 1);

      expect(
        controller.sessionTranscriptionProvider,
        TranscriptionProvider.mossPro,
      );
      expect(
        controller.inboxJobs.single.transcriptionProvider,
        TranscriptionProvider.mossPro,
      );
      await controller.startReady();

      final job = controller.inboxJobs.single;
      expect(job.status, JobStatus.completed);
      expect(job.transcriptSource, TranscriptSource.mossPro);
      expect(job.document?.segments.single.speaker, 'S01');
      expect(moss.uploadCalls, 1);
      expect(moss.deletedFiles, ['moss-file-1']);
      expect(moss.deletedTranscriptions, isEmpty);
      expect(soniox.uploadCalls, 0);
      expect(media.checkedUploadProfiles, [MediaUploadProfile.compactSpeech]);
      expect(media.extractedUploadProfiles, [MediaUploadProfile.compactSpeech]);
    },
  );

  test(
    'batch provider switch updates unstarted jobs without changing default',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'meow-moss-switch-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/meeting.wav');
      await file.writeAsBytes([1]);
      final settings = _Settings();
      final controller = _controller(
        jobs: _Jobs(),
        soniox: _Soniox(),
        moss: _Moss(),
        mossCredentials: _Credentials(),
        settings: settings,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.enqueueSources([file.path]);
      await _waitFor(() => controller.readyCount == 1);

      await controller.updateSessionTranscriptionProvider(
        TranscriptionProvider.mossPro,
      );

      expect(
        controller.inboxJobs.single.transcriptionProvider,
        TranscriptionProvider.mossPro,
      );
      expect(
        settings.value.defaultTranscriptionProvider,
        TranscriptionProvider.soniox,
      );
    },
  );

  test(
    'worker pool matches smaller queues and caps larger queues at four',
    () async {
      for (final itemCount in [3, 6]) {
        final directory = await Directory.systemTemp.createTemp(
          'meow-auto-concurrency-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final files = <String>[];
        for (var index = 0; index < itemCount; index++) {
          final file = File('${directory.path}/$index.wav');
          await file.writeAsBytes([1, 2, 3]);
          files.add(file.path);
        }
        final soniox = _Soniox(uploadDelay: const Duration(milliseconds: 40));
        final controller = _controller(jobs: _Jobs(), soniox: soniox);
        addTearDown(controller.dispose);
        await controller.initialize();
        await controller.enqueueSources(files);
        await _waitFor(() => controller.readyCount == itemCount);

        await controller.startReady();

        expect(soniox.maximumUploads, itemCount < 4 ? itemCount : 4);
        expect(controller.completedCount, itemCount);
      }
    },
  );

  test('async balance failures retain an actionable error category', () async {
    final directory = await Directory.systemTemp.createTemp('meow-balance-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/balance.wav');
    await file.writeAsBytes([1, 2, 3]);
    final jobs = _Jobs();
    final controller = _controller(
      jobs: jobs,
      soniox: _Soniox(
        transcriptionState: const SonioxTranscriptionState(
          status: 'failed',
          errorType: 'organization_balance_exhausted',
          errorMessage: 'The organization balance is exhausted.',
        ),
      ),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.enqueueSources([file.path]);
    await _waitFor(() => controller.readyCount == 1);

    await controller.startReady();

    expect(controller.inboxJobs.single.status, JobStatus.failed);
    expect(controller.inboxJobs.single.errorCode, 'exhausted_balance');
  });

  test(
    'restart resumes polling from an owned remote transcription id',
    () async {
      final file = await File(
        '${Directory.systemTemp.path}/meow-recovery.wav',
      ).create();
      addTearDown(() async {
        if (await file.exists()) await file.delete();
      });
      final now = DateTime.now().toUtc();
      final jobs = _Jobs([
        TranscriptionJob(
          id: 'recover',
          batchId: 'batch',
          sourcePath: file.path,
          createdAt: now,
          updatedAt: now,
          status: JobStatus.processing,
          metadata: const MediaMetadata(
            sizeBytes: 1,
            durationMs: 1000,
            hasAudio: true,
            hasVideo: false,
            formatName: 'wav',
          ),
          remoteFileId: 'owned-file',
          remoteTranscriptionId: 'owned-tx',
          cleanupState: CleanupState.pending,
        ),
      ]);
      final soniox = _Soniox();
      final controller = _controller(jobs: jobs, soniox: soniox);

      await controller.initialize();
      await _waitFor(
        () => jobs.saved['recover']?.status == JobStatus.completed,
      );

      expect(soniox.uploadCalls, 0);
      expect(soniox.deletedFiles, contains('owned-file'));
      expect(soniox.deletedTranscriptions, contains('owned-tx'));
    },
  );

  test('restart resumes a MOSS task with its recorded provider', () async {
    final file = await File(
      '${Directory.systemTemp.path}/meow-moss-recovery.wav',
    ).create();
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });
    final now = DateTime.now().toUtc();
    final jobs = _Jobs([
      TranscriptionJob(
        id: 'moss-recover',
        batchId: 'batch',
        sourcePath: file.path,
        createdAt: now,
        updatedAt: now,
        status: JobStatus.processing,
        metadata: const MediaMetadata(
          sizeBytes: 1,
          durationMs: 1000,
          hasAudio: true,
          hasVideo: false,
          formatName: 'wav',
        ),
        remoteFileId: 'moss-file-owned',
        remoteTranscriptionId: 'moss-task-owned',
        cleanupState: CleanupState.pending,
        transcriptionProvider: TranscriptionProvider.mossPro,
      ),
    ]);
    final soniox = _Soniox();
    final moss = _Moss();
    final controller = _controller(
      jobs: jobs,
      soniox: soniox,
      moss: moss,
      mossCredentials: _Credentials(),
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    await _waitFor(
      () => jobs.saved['moss-recover']?.status == JobStatus.completed,
    );

    expect(moss.uploadCalls, 0);
    expect(moss.deletedFiles, contains('moss-file-owned'));
    expect(soniox.deletedFiles, isEmpty);
    expect(
      jobs.saved['moss-recover']?.transcriptSource,
      TranscriptSource.mossPro,
    );
  });

  test('adding a ready library job only restores it to the inbox', () async {
    final directory = await Directory.systemTemp.createTemp(
      'meow-continue-ready-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/ready.wav');
    await source.writeAsBytes(const [1]);
    final now = DateTime.now().toUtc();
    final jobs = _Jobs([
      TranscriptionJob(
        id: 'ready',
        batchId: 'batch',
        sourcePath: source.path,
        createdAt: now,
        updatedAt: now,
        status: JobStatus.ready,
      ),
    ]);
    final soniox = _Soniox();
    final controller = _controller(jobs: jobs, soniox: soniox);
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.setDestination(AppDestination.library);

    controller.addToInbox('ready');

    expect(jobs.saved['ready']?.status, JobStatus.ready);
    expect(controller.inboxJobs.single.id, 'ready');
    expect(controller.activeWorkspaceJobId, isNull);
    expect(controller.destination, AppDestination.inbox);
    expect(controller.processing, isFalse);
    expect(soniox.uploadCalls, 0);
  });

  test(
    'adding a completed job back to Inbox creates a configurable copy',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'meow-retranscribe-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/completed.wav');
      await source.writeAsBytes(const [1]);
      final now = DateTime.now().toUtc();
      final jobs = _Jobs([
        TranscriptionJob(
          id: 'completed',
          batchId: 'old-batch',
          sourcePath: source.path,
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
          metadata: const MediaMetadata(
            sizeBytes: 1,
            durationMs: 1000,
            hasAudio: true,
            hasVideo: false,
            formatName: 'wav',
          ),
          document: _document(now),
        ),
      ]);
      final controller = _controller(jobs: jobs, soniox: _Soniox());
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.updateSessionOptions(
        const TranscriptionOptions(languageHints: ['zh']),
      );

      final queued = await controller.enqueueAgain('completed');
      await _waitFor(
        () => controller.inboxJobs.single.status == JobStatus.ready,
      );

      final original = controller.jobById('completed')!;
      final copy = controller.inboxJobs.single;
      expect(queued?.id, copy.id);
      expect(copy.id, isNot(original.id));
      expect(copy.document, isNull);
      expect(copy.options.languageHints, ['zh']);
      expect(original.status, JobStatus.completed);
      expect(original.document, isNotNull);
      expect(controller.destination, AppDestination.inbox);
      expect(controller.processing, isFalse);

      await controller.updateSessionOptions(
        const TranscriptionOptions(languageHints: ['en']),
      );
      expect(controller.inboxJobs.single.options.languageHints, ['en']);
      expect(original.options.languageHints, isEmpty);
    },
  );

  test('adding a ready library job defers missing-source validation', () async {
    final now = DateTime.now().toUtc();
    final jobs = _Jobs([
      TranscriptionJob(
        id: 'ready',
        batchId: 'batch',
        sourcePath: '${Directory.systemTemp.path}/missing-ready-source.wav',
        createdAt: now,
        updatedAt: now,
        status: JobStatus.ready,
      ),
    ]);
    final soniox = _Soniox();
    final controller = _controller(jobs: jobs, soniox: soniox);
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.setDestination(AppDestination.library);

    controller.addToInbox('ready');

    expect(jobs.saved['ready']?.status, JobStatus.ready);
    expect(controller.inboxJobs.single.id, 'ready');
    expect(controller.activeWorkspaceJobId, isNull);
    expect(controller.destination, AppDestination.inbox);
    expect(controller.processing, isFalse);
    expect(soniox.uploadCalls, 0);

    await controller.startReady();

    expect(jobs.saved['ready']?.status, JobStatus.missingSource);
    expect(soniox.uploadCalls, 0);
  });

  test(
    'cancellation becomes terminal and cleans only the job-owned ids',
    () async {
      final directory = await Directory.systemTemp.createTemp('meow-cancel-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/cancel.wav');
      await file.writeAsBytes([1]);
      final jobs = _Jobs();
      final soniox = _Soniox(uploadDelay: const Duration(milliseconds: 80));
      final controller = _controller(jobs: jobs, soniox: soniox);
      await controller.initialize();
      await controller.enqueueSources([file.path]);
      await _waitFor(() => controller.readyCount == 1);
      final run = controller.startReady();
      await _waitFor(
        () => controller.inboxJobs.single.status == JobStatus.uploading,
      );
      await controller.cancelJob(controller.inboxJobs.single.id);
      await run;

      expect(controller.inboxJobs.single.status, JobStatus.cancelled);
      expect(soniox.deletedFiles, hasLength(1));
      expect(soniox.deletedTranscriptions, isEmpty);
    },
  );

  test(
    'a new session preserves completed history and discards drafts',
    () async {
      final directory = await Directory.systemTemp.createTemp('meow-session-');
      addTearDown(() => directory.delete(recursive: true));
      final completedFile = File('${directory.path}/completed.wav');
      final draftFile = File('${directory.path}/draft.wav');
      final nextFile = File('${directory.path}/next.wav');
      await completedFile.writeAsBytes([1]);
      await draftFile.writeAsBytes([2]);
      await nextFile.writeAsBytes([3]);
      final jobs = _Jobs();
      final controller = _controller(jobs: jobs, soniox: _Soniox());
      await controller.initialize();
      await controller.updateSessionOptions(
        const TranscriptionOptions(
          languageHints: ['zh'],
          contextTerms: ['MeowSTT'],
        ),
      );
      await controller.enqueueSources([completedFile.path]);
      await _waitFor(() => controller.readyCount == 1);
      expect(controller.inboxJobs.single.options.languageHints, ['zh']);
      expect(controller.inboxJobs.single.options.contextTerms, ['MeowSTT']);
      await controller.startReady();
      final completed = controller.inboxJobs.single;
      controller.openInWorkspace(completed.id);
      expect(controller.destination, AppDestination.workspace);

      await controller.enqueueSources([draftFile.path]);
      await _waitFor(() => controller.readyCount == 1);
      expect(controller.untranscribedInboxCount, 1);

      await controller.startNewInboxBatch();

      expect(controller.inboxJobs, isEmpty);
      expect(controller.activeWorkspaceJobId, completed.id);
      expect(controller.destination, AppDestination.workspace);
      expect(controller.allJobs.map((job) => job.id), [completed.id]);
      expect(jobs.saved.keys, [completed.id]);
      expect(controller.sessionOptions.languageHints, isEmpty);
      expect(controller.sessionOptions.contextTerms, isEmpty);

      await controller.enqueueSources([nextFile.path]);
      await _waitFor(() => controller.readyCount == 1);
      expect(controller.inboxJobs.single.batchId, isNot(completed.batchId));
      expect(controller.inboxJobs.single.options.languageHints, isEmpty);
      expect(controller.inboxJobs.single.options.contextTerms, isEmpty);
    },
  );

  test('batch export preserves the explicit completed job order', () async {
    final now = DateTime.now().toUtc();
    final exporter = _RecordingExporter();
    final controller = _controller(
      jobs: _Jobs([
        for (final id in ['first', 'second'])
          TranscriptionJob(
            id: id,
            batchId: 'batch',
            sourcePath: '/missing/$id.wav',
            createdAt: now,
            updatedAt: now,
            status: JobStatus.completed,
            document: _document(now),
          ),
        TranscriptionJob(
          id: 'draft',
          batchId: 'batch',
          sourcePath: '/missing/draft.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.ready,
        ),
      ]),
      soniox: _Soniox(),
      exporter: exporter,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.exportJobs(
      const ['second', 'draft', 'first'],
      '/exports',
      const ExportOptions(),
    );

    expect(exporter.exportedJobIds, ['second', 'first']);
  });

  test(
    'initialization repairs legacy mid-sentence and punctuation fragments',
    () async {
      final now = DateTime.now().toUtc();
      final jobs = _Jobs([
        TranscriptionJob(
          id: 'legacy',
          batchId: 'batch',
          sourcePath: '/missing/legacy.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
          document: TranscriptDocument(
            tokens: const [],
            segments: const [
              TranscriptSegment(
                id: 'segment-1',
                startMs: 0,
                endMs: 7900,
                text: '批量转写，总',
                speaker: '1',
                language: 'zh',
              ),
              TranscriptSegment(
                id: 'segment-2',
                startMs: 8000,
                endMs: 10000,
                text: '共两条录音',
                speaker: '1',
                language: 'zh',
              ),
              TranscriptSegment(
                id: 'segment-3',
                startMs: 0,
                endMs: 0,
                text: '。',
              ),
            ],
            speakers: const [SpeakerProfile(id: '1', name: 'Speaker 1')],
            updatedAt: now,
          ),
        ),
      ]);
      final controller = _controller(jobs: jobs, soniox: _Soniox());

      await controller.initialize();

      final segments = controller.allJobs.single.document!.segments;
      expect(segments, hasLength(1));
      expect(segments.single.text, '批量转写，总共两条录音。');
      expect(jobs.saved['legacy']!.document!.segments, hasLength(1));
    },
  );

  test(
    'relinking a completed transcript preserves its completed state',
    () async {
      final now = DateTime.now().toUtc();
      final jobs = _Jobs([
        TranscriptionJob(
          id: 'completed',
          batchId: 'batch',
          sourcePath: '/missing/original.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
          progress: const JobProgress(stage: 'completed', fraction: 1),
          document: _document(now),
          cleanupState: CleanupState.complete,
        ),
      ]);
      final controller = _controller(jobs: jobs, soniox: _Soniox());
      await controller.initialize();
      controller.openInWorkspace('completed');

      final error = await controller.relink('completed', '/replacement.wav');

      expect(error, isNull);
      final linked = controller.activeWorkspaceJob!;
      expect(linked.status, JobStatus.completed);
      expect(linked.sourcePath, '/replacement.wav');
      expect(linked.document, isNotNull);
      expect(linked.cleanupState, CleanupState.complete);
      expect(linked.metadata?.durationMs, 1000);
      expect(controller.inboxJobs, isEmpty);
      expect(controller.activeWorkspaceJobId, 'completed');
    },
  );

  test('an invalid relink leaves the completed transcript unchanged', () async {
    final now = DateTime.now().toUtc();
    final jobs = _Jobs([
      TranscriptionJob(
        id: 'completed',
        batchId: 'batch',
        sourcePath: '/missing/original.wav',
        createdAt: now,
        updatedAt: now,
        status: JobStatus.completed,
        document: _document(now),
      ),
    ]);
    final controller = _controller(
      jobs: jobs,
      soniox: _Soniox(),
      media: _FailingMedia(),
    );
    await controller.initialize();

    final error = await controller.relink('completed', '/invalid.wav');

    expect(error, 'invalid_media');
    expect(controller.allJobs.single.sourcePath, '/missing/original.wav');
    expect(controller.allJobs.single.status, JobStatus.completed);
    expect(controller.allJobs.single.document, isNotNull);
  });

  test(
    'translation failure never changes completed transcription state',
    () async {
      final now = DateTime.now().toUtc();
      final jobs = _Jobs([
        TranscriptionJob(
          id: 'completed',
          batchId: 'batch',
          sourcePath: '/missing/original.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
          document: _document(now),
        ),
      ]);
      final settings = _Settings(
        const AppSettings(
          translationSettings: TranslationSettings(
            provider: TranslationProviderTemplate.openAi,
            baseUrl: 'https://api.openai.com/v1',
            model: 'translation-model',
            targetLanguage: 'zh-Hans',
          ),
        ),
      );
      final controller = _controller(
        jobs: jobs,
        soniox: _Soniox(),
        settings: settings,
        translationCredentials: _TranslationCredentials(),
        translationService: _FailingTranslation(),
      );
      await controller.initialize();

      await controller.translateJob('completed', targetLanguage: 'zh-Hans');

      final result = controller.allJobs.single;
      expect(result.status, JobStatus.completed);
      expect(result.document, isNotNull);
      expect(result.translationState.status, TranslationStatus.failed);
      expect(result.translationState.origin, TranslationOrigin.llm);
      expect(result.translationState.errorCode, 'translation_rate_limit');
    },
  );

  test(
    'changed remote endpoint needs a new key and local save clears cloud key',
    () async {
      final credentials = _TranslationCredentials();
      final settings = _Settings(
        const AppSettings(
          translationSettings: TranslationSettings(
            provider: TranslationProviderTemplate.openAi,
            baseUrl: 'https://api.openai.com/v1',
            model: 'old-model',
          ),
        ),
      );
      final controller = _controller(
        jobs: _Jobs(),
        soniox: _Soniox(),
        settings: settings,
        translationCredentials: credentials,
        translationService: _FailingTranslation(),
      );
      await controller.initialize();

      final changedEndpoint = await controller.testTranslationConfiguration(
        const TranslationSettings(
          provider: TranslationProviderTemplate.deepSeek,
          baseUrl: 'https://api.deepseek.com/v1',
        ),
      );
      expect(changedEndpoint.errorCode, 'translation_missing_credentials');
      expect(credentials.value, 'translation-key');

      final saveError = await controller.saveTranslationConfiguration(
        const TranslationSettings(
          provider: TranslationProviderTemplate.ollama,
          baseUrl: 'http://localhost:11434/v1',
          model: 'local-model',
        ),
      );
      expect(saveError, isNull);
      expect(credentials.value, isNull);
      expect(
        settings.value.translationSettings.provider,
        TranslationProviderTemplate.ollama,
      );
    },
  );

  test('editing source invalidates only that segment translation', () async {
    final now = DateTime.now().toUtc();
    final document = TranscriptDocument(
      tokens: const [],
      segments: const [
        TranscriptSegment(
          id: 'one',
          startMs: 0,
          endMs: 500,
          text: 'One.',
          translatedText: '一',
        ),
        TranscriptSegment(
          id: 'two',
          startMs: 500,
          endMs: 1000,
          text: 'Two.',
          translatedText: '二',
        ),
      ],
      speakers: const [],
      updatedAt: now,
    );
    final jobs = _Jobs([
      TranscriptionJob(
        id: 'completed',
        batchId: 'batch',
        sourcePath: '/missing/original.wav',
        createdAt: now,
        updatedAt: now,
        status: JobStatus.completed,
        document: document,
        translationState: const TranslationState(
          status: TranslationStatus.completed,
          targetLanguage: 'zh-Hans',
          completedSegments: 2,
          totalSegments: 2,
        ),
      ),
    ]);
    final controller = _controller(jobs: jobs, soniox: _Soniox());
    await controller.initialize();

    await controller.updateSegment('completed', 'one', 'Edited one');

    final result = controller.allJobs.single;
    expect(result.document!.segments.first.translatedText, isNull);
    expect(result.document!.segments.last.translatedText, '二');
    expect(result.translationState.status, TranslationStatus.partial);
    expect(result.translationState.completedSegments, 1);
    expect(result.status, JobStatus.completed);
  });

  test('reassigning a segment speaker persists only that correction', () async {
    final now = DateTime.utc(2026, 8, 12);
    const tokens = [
      TranscriptToken(text: 'One.', startMs: 0, endMs: 500, speaker: '1'),
    ];
    final document = TranscriptDocument(
      tokens: tokens,
      segments: const [
        TranscriptSegment(
          id: 'one',
          startMs: 0,
          endMs: 500,
          text: 'One.',
          speaker: '1',
          translatedText: '一',
        ),
        TranscriptSegment(
          id: 'two',
          startMs: 500,
          endMs: 1000,
          text: 'Two.',
          speaker: '1',
          translatedText: '二',
        ),
      ],
      speakers: const [
        SpeakerProfile(id: '1', name: 'Alice'),
        SpeakerProfile(id: '2', name: 'Bob'),
      ],
      updatedAt: now,
    );
    final job = TranscriptionJob(
      id: 'completed',
      batchId: 'batch',
      sourcePath: '/missing/original.wav',
      createdAt: now,
      updatedAt: now,
      status: JobStatus.completed,
      document: document,
      translationState: const TranslationState(
        status: TranslationStatus.completed,
        targetLanguage: 'zh-Hans',
        completedSegments: 2,
        totalSegments: 2,
      ),
      aiBrief: AiBrief(
        overview: 'Original overview',
        overviewEvidenceSegmentIds: const ['one'],
        chapters: const [],
        insights: const [],
        outputLanguage: 'en',
        model: 'brief-model',
        selectedSections: const {AiBriefSection.overview},
        generatedAt: now,
        sourceTranscriptUpdatedAt: now,
      ),
    );
    final jobs = _Jobs([job]);
    final controller = _controller(jobs: jobs, soniox: _Soniox());
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.updateSegmentSpeaker('completed', 'one', '2');

    final result = controller.allJobs.single;
    final saved = jobs.saved['completed']!;
    expect(result.document!.segments.first.speaker, '2');
    expect(result.document!.segments.last.speaker, '1');
    expect(result.document!.segments.first.text, 'One.');
    expect(result.document!.segments.first.translatedText, '一');
    expect(result.document!.tokens, same(tokens));
    expect(result.translationState.status, TranslationStatus.completed);
    expect(result.translationState.completedSegments, 2);
    expect(result.document!.updatedAt.isAfter(now), isTrue);
    expect(result.aiBrief!.isStaleFor(result.document!), isTrue);
    expect(saved.document!.segments.first.speaker, '2');
  });

  test(
    'Soniox translation completes in the transcription pass without LLM work',
    () async {
      final directory = await Directory.systemTemp.createTemp('meow-soniox-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/translated.wav');
      await file.writeAsBytes([1, 2, 3]);
      final soniox = _Soniox(
        transcriptPayload: {
          'tokens': [
            {
              'text': 'Hello.',
              'start_ms': 0,
              'end_ms': 800,
              'speaker': '1',
              'language': 'en',
              'translation_status': 'original',
            },
            {
              'text': 'Hola.',
              'language': 'es',
              'source_language': 'en',
              'translation_status': 'translation',
            },
          ],
        },
      );
      final llm = _SuccessfulTranslation();
      final settings = _Settings(
        const AppSettings(
          sonioxTranslation: SonioxTranslationOptions(
            enabled: true,
            targetLanguage: 'es',
          ),
          translationSettings: TranslationSettings(
            provider: TranslationProviderTemplate.openAi,
            baseUrl: 'https://api.openai.com/v1',
            model: 'translation-model',
            targetLanguage: 'es',
            autoTranslate: true,
          ),
        ),
      );
      final controller = _controller(
        jobs: _Jobs(),
        soniox: soniox,
        settings: settings,
        translationCredentials: _TranslationCredentials(),
        translationService: llm,
      );
      await controller.initialize();
      await controller.enqueueSources([file.path]);
      await _waitFor(() => controller.readyCount == 1);

      await controller.startReady();

      final result = controller.inboxJobs.single;
      expect(settings.value.translationSettings.autoTranslate, isTrue);
      expect(soniox.createdOptions?.sonioxTranslation.enabled, isTrue);
      expect(result.document!.segments.single.translatedText, 'Hola.');
      expect(result.translationState.status, TranslationStatus.completed);
      expect(result.translationState.origin, TranslationOrigin.soniox);
      expect(result.translationState.targetLanguage, 'es');
      expect(llm.calls, 0);
    },
  );

  test(
    'MOSS Pro uses configured LLM translation after transcription',
    () async {
      final directory = await Directory.systemTemp.createTemp('meow-moss-llm-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/translated.wav');
      await file.writeAsBytes([1]);
      final llm = _SuccessfulTranslation();
      final controller = _controller(
        jobs: _Jobs(),
        soniox: _Soniox(),
        moss: _Moss(),
        mossCredentials: _Credentials(),
        settings: _Settings(
          const AppSettings(
            defaultTranscriptionProvider: TranscriptionProvider.mossPro,
            sonioxTranslation: SonioxTranslationOptions(
              enabled: true,
              targetLanguage: 'es',
            ),
            translationSettings: TranslationSettings(
              provider: TranslationProviderTemplate.openAi,
              baseUrl: 'https://api.openai.com/v1',
              model: 'translation-model',
              targetLanguage: 'es',
              autoTranslate: true,
            ),
          ),
        ),
        translationCredentials: _TranslationCredentials(),
        translationService: llm,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.enqueueSources([file.path]);
      await _waitFor(() => controller.readyCount == 1);

      await controller.startReady();

      final job = controller.inboxJobs.single;
      expect(llm.calls, 1);
      expect(job.document?.segments.single.translatedText, '补充翻译。');
      expect(job.translationState.origin, TranslationOrigin.llm);
    },
  );

  test('Soniox and LLM automatic translation settings can coexist', () async {
    final directory = await Directory.systemTemp.createTemp('meow-modes-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/queued.wav');
    await file.writeAsBytes([1]);
    final settings = _Settings(
      const AppSettings(
        sonioxTranslation: SonioxTranslationOptions(targetLanguage: 'es'),
        translationSettings: TranslationSettings(
          provider: TranslationProviderTemplate.openAi,
          baseUrl: 'https://api.openai.com/v1',
          model: 'translation-model',
          targetLanguage: 'es',
          autoTranslate: true,
        ),
      ),
    );
    final controller = _controller(
      jobs: _Jobs(),
      soniox: _Soniox(),
      settings: settings,
      translationCredentials: _TranslationCredentials(),
      translationService: _SuccessfulTranslation(),
    );
    await controller.initialize();
    await controller.enqueueSources([file.path]);
    await _waitFor(() => controller.readyCount == 1);
    expect(controller.inboxJobs.single.translationOptions.enabled, isTrue);

    final sonioxError = await controller.updateSonioxTranslation(
      const SonioxTranslationOptions(enabled: true, targetLanguage: 'es'),
    );

    expect(sonioxError, isNull);
    expect(controller.settings.sonioxTranslation.enabled, isTrue);
    expect(controller.settings.translationSettings.autoTranslate, isTrue);
    expect(
      controller.inboxJobs.single.options.sonioxTranslation.enabled,
      isTrue,
    );
    expect(controller.inboxJobs.single.translationOptions.enabled, isTrue);

    final llmError = await controller.updateTranslationDefaults(
      controller.settings.translationSettings.copyWith(autoTranslate: true),
    );

    expect(llmError, isNull);
    expect(controller.settings.sonioxTranslation.enabled, isTrue);
    expect(controller.settings.translationSettings.autoTranslate, isTrue);
    expect(
      controller.inboxJobs.single.options.sonioxTranslation.enabled,
      isTrue,
    );
    expect(controller.inboxJobs.single.translationOptions.enabled, isTrue);
  });

  test('automatic mode changes do not alter submitted remote jobs', () async {
    final directory = await Directory.systemTemp.createTemp('meow-submitted-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/submitted.wav');
    await file.writeAsBytes([1]);
    final now = DateTime.now().toUtc();
    final jobs = _Jobs([
      TranscriptionJob(
        id: 'submitted',
        batchId: 'batch',
        sourcePath: file.path,
        createdAt: now,
        updatedAt: now,
        status: JobStatus.processing,
        metadata: const MediaMetadata(
          sizeBytes: 1,
          durationMs: 1000,
          hasAudio: true,
          hasVideo: false,
          formatName: 'wav',
        ),
        remoteFileId: 'file-submitted',
        remoteTranscriptionId: 'tx-submitted',
        cleanupState: CleanupState.pending,
        options: const TranscriptionOptions(
          sonioxTranslation: SonioxTranslationOptions(targetLanguage: 'es'),
        ),
        translationOptions: const TranslationOptions(
          enabled: true,
          targetLanguage: 'es',
          baseUrl: 'https://api.openai.com/v1',
          model: 'translation-model',
        ),
      ),
    ]);
    final pollingGate = Completer<void>();
    final settings = _Settings(
      const AppSettings(
        sonioxTranslation: SonioxTranslationOptions(targetLanguage: 'es'),
        translationSettings: TranslationSettings(
          provider: TranslationProviderTemplate.openAi,
          baseUrl: 'https://api.openai.com/v1',
          model: 'translation-model',
          targetLanguage: 'es',
          autoTranslate: true,
        ),
      ),
    );
    final controller = _controller(
      jobs: jobs,
      soniox: _Soniox(pollingGate: pollingGate),
      settings: settings,
      translationCredentials: _TranslationCredentials(),
      translationService: _SuccessfulTranslation(),
    );
    await controller.initialize();
    await _waitFor(() => controller.processing);

    await controller.updateSonioxTranslation(
      const SonioxTranslationOptions(enabled: true, targetLanguage: 'es'),
    );

    final submitted = controller.inboxJobs.single;
    expect(submitted.options.sonioxTranslation.enabled, isFalse);
    expect(submitted.translationOptions.enabled, isTrue);

    pollingGate.complete();
    await _waitFor(
      () => controller.inboxJobs.single.status == JobStatus.completed,
    );
  });

  test('background progress preserves library metadata edits', () async {
    final directory = await Directory.systemTemp.createTemp(
      'meow-library-metadata-progress-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/submitted.wav');
    await file.writeAsBytes([1]);
    final now = DateTime.now().toUtc();
    final jobs = _Jobs([
      TranscriptionJob(
        id: 'submitted',
        batchId: 'batch',
        sourcePath: file.path,
        createdAt: now,
        updatedAt: now,
        status: JobStatus.processing,
        metadata: const MediaMetadata(
          sizeBytes: 1,
          durationMs: 1000,
          hasAudio: true,
          hasVideo: false,
          formatName: 'wav',
        ),
        remoteFileId: 'file-submitted',
        remoteTranscriptionId: 'tx-submitted',
        cleanupState: CleanupState.pending,
      ),
    ]);
    final pollingGate = Completer<void>();
    final controller = _controller(
      jobs: jobs,
      soniox: _Soniox(pollingGate: pollingGate),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await _waitFor(() => controller.processing);

    await controller.renameLibraryItem('submitted', 'Customer interview');
    pollingGate.complete();
    await _waitFor(
      () => controller.inboxJobs.single.status == JobStatus.completed,
    );

    expect(controller.inboxJobs.single.displayName, 'Customer interview');
    expect(jobs.saved['submitted']!.displayTitle, 'Customer interview');
  });

  test(
    'retry ignores empty transcript segments and completes partial job',
    () async {
      final now = DateTime.now().toUtc();
      final jobs = _Jobs([
        TranscriptionJob(
          id: 'completed',
          batchId: 'batch',
          sourcePath: '/missing/original.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
          document: TranscriptDocument(
            tokens: const [],
            segments: const [
              TranscriptSegment(
                id: 'translated',
                startMs: 0,
                endMs: 500,
                text: 'Already translated.',
                translatedText: '已翻译。',
              ),
              TranscriptSegment(
                id: 'missing',
                startMs: 500,
                endMs: 1000,
                text: '',
              ),
            ],
            speakers: const [],
            updatedAt: now,
          ),
          translationState: const TranslationState(
            status: TranslationStatus.partial,
            targetLanguage: 'zh-Hans',
            completedSegments: 1,
            totalSegments: 2,
          ),
        ),
      ]);
      final translation = _SuccessfulTranslation();
      final controller = _controller(
        jobs: jobs,
        soniox: _Soniox(),
        settings: _Settings(
          const AppSettings(
            translationSettings: TranslationSettings(
              provider: TranslationProviderTemplate.openAi,
              baseUrl: 'https://api.openai.com/v1',
              model: 'translation-model',
              targetLanguage: 'zh-Hans',
            ),
          ),
        ),
        translationCredentials: _TranslationCredentials(),
        translationService: translation,
      );
      await controller.initialize();

      await controller.retryTranslation('completed');

      final result = controller.allJobs.single;
      expect(translation.segmentIds, isEmpty);
      expect(result.translationState.status, TranslationStatus.completed);
      expect(result.translationState.completedSegments, 1);
      expect(result.translationState.totalSegments, 1);
      expect(result.document!.segments, hasLength(1));
      expect(result.document!.segments.single.translatedText, '已翻译。');
    },
  );

  test(
    'clear inactive history retains active work and repairs selection',
    () async {
      final directory = await Directory.systemTemp.createTemp('meow-clear-');
      addTearDown(() => directory.delete(recursive: true));
      final activeFile = File('${directory.path}/active.wav');
      await activeFile.writeAsBytes([1]);
      final now = DateTime.now().toUtc();
      final jobs = _Jobs([
        TranscriptionJob(
          id: 'history',
          batchId: 'old-batch',
          sourcePath: '/missing/history.wav',
          createdAt: now.subtract(const Duration(days: 1)),
          updatedAt: now,
          status: JobStatus.completed,
          document: _document(now),
        ),
      ]);
      final media = _Media();
      final controller = _controller(
        jobs: jobs,
        soniox: _Soniox(uploadDelay: const Duration(milliseconds: 100)),
        media: media,
      );
      await controller.initialize();
      controller.openInWorkspace('history');
      await controller.enqueueSources([activeFile.path]);
      await _waitFor(() => controller.readyCount == 1);
      final activeId = controller.inboxJobs.last.id;
      final run = controller.startReady();
      await _waitFor(
        () => controller.inboxJobs.last.status == JobStatus.uploading,
      );

      expect(controller.processingCount, 1);
      expect(controller.inactiveHistoryCount, 1);
      await controller.clearInactiveHistory();

      expect(jobs.saved.containsKey('history'), isFalse);
      expect(media.deletedGeneratedMedia, contains('history'));
      expect(media.retainedGeneratedMedia, {activeId});
      expect(controller.inboxJobs.single.id, activeId);
      expect(controller.activeWorkspaceJobId, isNull);
      expect(controller.inboxJobs.single.status, JobStatus.uploading);
      await run;
      expect(controller.processingCount, 0);
    },
  );

  test(
    'AI Brief refresh failure preserves the last successful brief',
    () async {
      final now = DateTime.utc(2026, 8, 12);
      final job = TranscriptionJob(
        id: 'brief-job',
        batchId: 'batch',
        sourcePath: '/brief.wav',
        createdAt: now,
        updatedAt: now,
        status: JobStatus.completed,
        document: _document(now),
      );
      final briefService = _AiBrief();
      final controller = _controller(
        jobs: _Jobs([job]),
        soniox: _Soniox(),
        settings: _Settings(
          const AppSettings(
            translationSettings: TranslationSettings(
              baseUrl: 'https://llm.example/v1',
              model: 'brief-model',
            ),
          ),
        ),
        translationCredentials: _TranslationCredentials(),
        aiBriefService: briefService,
      );
      await controller.initialize();

      await controller.generateAiBrief(
        job.id,
        sections: const {AiBriefSection.overview},
        outputLanguage: 'en',
      );
      expect(controller.allJobs.single.aiBrief?.overview, 'Grounded overview');

      await controller.updateAiBriefOverview(job.id, 'User-edited overview');
      briefService.error = const AiBriefException('ai_brief_rate_limit');
      await controller.generateAiBrief(
        job.id,
        sections: const {AiBriefSection.overview},
        outputLanguage: 'en',
      );

      final preserved = controller.allJobs.single;
      expect(preserved.aiBrief?.overview, 'User-edited overview');
      expect(preserved.aiBrief?.edited, isTrue);
      expect(preserved.aiGenerationState.status, AiGenerationStatus.failed);
      expect(preserved.aiGenerationState.errorCode, 'ai_brief_rate_limit');
    },
  );

  test('transcript edits make an existing AI Brief stale', () async {
    final now = DateTime.utc(2026, 8, 12);
    final job = TranscriptionJob(
      id: 'stale-brief',
      batchId: 'batch',
      sourcePath: '/brief.wav',
      createdAt: now,
      updatedAt: now,
      status: JobStatus.completed,
      document: _document(now),
      aiBrief: AiBrief(
        overview: 'Original overview',
        overviewEvidenceSegmentIds: const ['segment'],
        chapters: const [],
        insights: const [],
        outputLanguage: 'en',
        model: 'brief-model',
        selectedSections: const {AiBriefSection.overview},
        generatedAt: now,
        sourceTranscriptUpdatedAt: now,
      ),
    );
    final controller = _controller(jobs: _Jobs([job]), soniox: _Soniox());
    await controller.initialize();

    await controller.updateSegment(job.id, 'segment', 'Edited transcript');

    final updated = controller.allJobs.single;
    expect(updated.aiBrief, isNotNull);
    expect(updated.aiBrief!.isStaleFor(updated.document!), isTrue);
  });

  test(
    'structure edits persist related state and support guarded undo',
    () async {
      final now = DateTime.utc(2026, 8, 12);
      final document = TranscriptDocument(
        tokens: const [
          TranscriptToken(
            text: 'Hello',
            startMs: 100,
            endMs: 400,
            segmentId: 'segment',
          ),
          TranscriptToken(
            text: ' world.',
            startMs: 500,
            endMs: 900,
            segmentId: 'segment',
          ),
        ],
        segments: const [
          TranscriptSegment(
            id: 'segment',
            startMs: 0,
            endMs: 1000,
            text: 'Hello world.',
            translatedText: 'Hola mundo.',
          ),
        ],
        speakers: const [],
        updatedAt: now,
      );
      final brief = AiBrief(
        overview: 'Overview',
        overviewEvidenceSegmentIds: const ['segment'],
        chapters: const [
          AiChapter(
            id: 'chapter',
            title: 'Chapter',
            summary: 'Summary',
            evidenceSegmentIds: ['segment'],
          ),
        ],
        insights: const [
          AiInsight(
            id: 'insight',
            type: AiInsightType.keyIdea,
            text: 'Idea',
            evidenceSegmentIds: ['segment'],
          ),
        ],
        languageNotes: const [
          AiLanguageNote(
            id: 'note',
            kind: AiLanguageNoteKind.vocabulary,
            term: 'Hello',
            explanation: 'Greeting',
            sourceExcerpt: 'Hello',
            evidenceSegmentIds: ['segment'],
          ),
        ],
        outputLanguage: 'en',
        model: 'brief-model',
        selectedSections: const {AiBriefSection.overview},
        generatedAt: now,
        sourceTranscriptUpdatedAt: now,
      );
      final job = TranscriptionJob(
        id: 'job',
        batchId: 'batch',
        sourcePath: '/video.mp4',
        createdAt: now,
        updatedAt: now,
        status: JobStatus.completed,
        document: document,
        translationState: const TranslationState(
          status: TranslationStatus.completed,
          completedSegments: 1,
          totalSegments: 1,
        ),
        aiBrief: brief,
        forcedAlignment: const ForcedAlignmentState(
          status: ForcedAlignmentStatus.completed,
          alignedSegments: 1,
          totalSegments: 1,
        ),
      );
      final jobs = _Jobs([job]);
      final controller = _controller(
        jobs: jobs,
        soniox: _Soniox(),
        structureEditor: TranscriptStructureEditor(idGenerator: () => 'right'),
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      final outcome = await controller.applyTranscriptStructureEdit(
        'job',
        const SplitAtTokenBoundary('segment', rightTokenIndex: 1),
      );

      expect(outcome, isA<TranscriptStructureEditResult>());
      var updated = controller.jobById('job')!;
      expect(updated.document!.segments.map((segment) => segment.id), [
        'segment',
        'right',
      ]);
      expect(updated.translationState.status, TranslationStatus.partial);
      expect(updated.translationState.completedSegments, 0);
      expect(updated.translationState.totalSegments, 2);
      expect(updated.forcedAlignment.status, ForcedAlignmentStatus.completed);
      expect(updated.forcedAlignment.alignedSegments, 2);
      expect(updated.forcedAlignment.totalSegments, 2);
      expect(updated.aiBrief!.overviewEvidenceSegmentIds, ['segment', 'right']);
      expect(updated.aiBrief!.chapters.single.evidenceSegmentIds, [
        'segment',
        'right',
      ]);
      expect(updated.aiBrief!.insights.single.evidenceSegmentIds, [
        'segment',
        'right',
      ]);
      expect(updated.aiBrief!.languageNotes.single.evidenceSegmentIds, [
        'segment',
        'right',
      ]);
      expect(updated.aiBrief!.isStaleFor(updated.document!), isTrue);
      expect(jobs.saved['job']!.document!.segments, hasLength(2));
      expect(controller.canUndoTranscriptStructureEdit('job'), isTrue);

      expect(await controller.undoTranscriptStructureEdit('job'), isTrue);
      updated = controller.jobById('job')!;
      expect(updated.document!.toJson(), document.toJson());
      expect(updated.translationState.status, TranslationStatus.completed);
      expect(updated.forcedAlignment.totalSegments, 1);
      expect(updated.aiBrief!.overviewEvidenceSegmentIds, ['segment']);
      expect(controller.canRedoTranscriptStructureEdit('job'), isTrue);

      expect(await controller.redoTranscriptStructureEdit('job'), isTrue);
      expect(controller.jobById('job')!.document!.segments, hasLength(2));

      expect(
        await controller.applyTranscriptStructureEdit(
          'job',
          const MergeWithNext('segment'),
        ),
        isA<TranscriptStructureEditResult>(),
      );
      updated = controller.jobById('job')!;
      expect(updated.document!.segments, hasLength(1));
      expect(updated.aiBrief!.overviewEvidenceSegmentIds, ['segment']);
      expect(updated.aiBrief!.chapters.single.evidenceSegmentIds, ['segment']);
      expect(updated.aiBrief!.insights.single.evidenceSegmentIds, ['segment']);
      expect(updated.aiBrief!.languageNotes.single.evidenceSegmentIds, [
        'segment',
      ]);

      await controller.updateSegment('job', 'segment', 'Edited later');
      expect(controller.canUndoTranscriptStructureEdit('job'), isFalse);
      expect(controller.canRedoTranscriptStructureEdit('job'), isFalse);
    },
  );

  test('structure history caps at 50 and a new edit clears redo', () async {
    final now = DateTime.utc(2026, 8, 12);
    final job = TranscriptionJob(
      id: 'history',
      batchId: 'batch',
      sourcePath: '/history.wav',
      createdAt: now,
      updatedAt: now,
      status: JobStatus.completed,
      document: TranscriptDocument(
        tokens: const [
          TranscriptToken(
            text: 'One',
            startMs: 100,
            endMs: 300,
            segmentId: 'left',
          ),
          TranscriptToken(
            text: ' two',
            startMs: 400,
            endMs: 700,
            segmentId: 'left',
          ),
        ],
        segments: const [
          TranscriptSegment(
            id: 'left',
            startMs: 0,
            endMs: 800,
            text: 'One two.',
          ),
        ],
        speakers: const [],
        updatedAt: now,
      ),
    );
    final controller = _controller(
      jobs: _Jobs([job]),
      soniox: _Soniox(),
      structureEditor: TranscriptStructureEditor(idGenerator: () => 'right'),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    for (var index = 0; index < 51; index++) {
      final edit = index.isEven
          ? const SplitAtTokenBoundary('left', rightTokenIndex: 1)
          : const MergeWithNext('left');
      expect(
        await controller.applyTranscriptStructureEdit('history', edit),
        isA<TranscriptStructureEditResult>(),
      );
    }
    for (var index = 0; index < 50; index++) {
      expect(await controller.undoTranscriptStructureEdit('history'), isTrue);
    }
    expect(await controller.undoTranscriptStructureEdit('history'), isFalse);
    expect(controller.canRedoTranscriptStructureEdit('history'), isTrue);

    expect(
      await controller.applyTranscriptStructureEdit(
        'history',
        const MergeWithNext('left'),
      ),
      isA<TranscriptStructureEditResult>(),
    );
    expect(controller.canRedoTranscriptStructureEdit('history'), isFalse);
  });

  test('translation changes keep an existing AI Brief current', () async {
    final now = DateTime.utc(2026, 8, 12);
    final document = TranscriptDocument(
      tokens: const [],
      segments: const [
        TranscriptSegment(
          id: 'segment',
          startMs: 0,
          endMs: 1000,
          text: 'Transcript',
          translatedText: 'Ancienne traduction',
        ),
      ],
      speakers: const [],
      updatedAt: now,
    );
    final job = TranscriptionJob(
      id: 'translated-brief',
      batchId: 'batch',
      sourcePath: '/brief.wav',
      createdAt: now,
      updatedAt: now,
      status: JobStatus.completed,
      document: document,
      translationState: const TranslationState(
        status: TranslationStatus.completed,
        targetLanguage: 'fr',
        completedSegments: 1,
        totalSegments: 1,
      ),
      aiBrief: AiBrief(
        overview: 'Current overview',
        overviewEvidenceSegmentIds: const ['segment'],
        chapters: const [],
        insights: const [],
        outputLanguage: 'en',
        model: 'brief-model',
        selectedSections: const {AiBriefSection.overview},
        generatedAt: now,
        sourceTranscriptUpdatedAt: now,
      ),
    );
    final controller = _controller(
      jobs: _Jobs([job]),
      soniox: _Soniox(),
      settings: _Settings(
        const AppSettings(
          translationSettings: TranslationSettings(
            provider: TranslationProviderTemplate.openAi,
            baseUrl: 'https://api.openai.com/v1',
            model: 'translation-model',
            targetLanguage: 'zh-Hans',
          ),
        ),
      ),
      translationCredentials: _TranslationCredentials(),
      translationService: _SuccessfulTranslation(),
    );
    await controller.initialize();

    await controller.translateJob(
      job.id,
      targetLanguage: 'zh-Hans',
      replaceExisting: true,
    );

    var updated = controller.allJobs.single;
    expect(updated.document!.segments.single.translatedText, '补充翻译。');
    expect(updated.document!.updatedAt, now);
    expect(updated.aiBrief!.isStaleFor(updated.document!), isFalse);

    await controller.updateTranslatedSegment(job.id, 'segment', '');

    updated = controller.allJobs.single;
    expect(updated.document!.segments.single.translatedText, isNull);
    expect(updated.document!.updatedAt, now);
    expect(updated.aiBrief!.isStaleFor(updated.document!), isFalse);

    await controller.updateTranslatedSegment(job.id, 'segment', '手动翻译');

    updated = controller.allJobs.single;
    expect(updated.document!.segments.single.translatedText, '手动翻译');
    expect(updated.document!.updatedAt, now);
    expect(updated.aiBrief!.isStaleFor(updated.document!), isFalse);
  });

  test('interrupted AI Brief generation preserves prior output', () async {
    final now = DateTime.utc(2026, 8, 12);
    final job = TranscriptionJob(
      id: 'interrupted-brief',
      batchId: 'batch',
      sourcePath: '/brief.wav',
      createdAt: now,
      updatedAt: now,
      status: JobStatus.completed,
      document: _document(now),
      aiBrief: AiBrief(
        overview: 'Preserved',
        overviewEvidenceSegmentIds: const ['segment'],
        chapters: const [],
        insights: const [],
        outputLanguage: 'en',
        model: 'brief-model',
        selectedSections: const {AiBriefSection.overview},
        generatedAt: now,
        sourceTranscriptUpdatedAt: now,
      ),
      aiGenerationState: const AiGenerationState(
        status: AiGenerationStatus.generating,
        selectedSections: {AiBriefSection.overview},
        outputLanguage: 'en',
      ),
    );
    final jobs = _Jobs([job]);
    final controller = _controller(jobs: jobs, soniox: _Soniox());

    await controller.initialize();

    final recovered = controller.allJobs.single;
    expect(recovered.aiBrief?.overview, 'Preserved');
    expect(recovered.aiGenerationState.status, AiGenerationStatus.interrupted);
    expect(
      jobs.saved[job.id]?.aiGenerationState.status,
      AiGenerationStatus.interrupted,
    );
  });

  test(
    'language settings survive retry and section regeneration preserves edits',
    () async {
      final now = DateTime.utc(2026, 8, 12);
      final job = TranscriptionJob(
        id: 'learning-brief',
        batchId: 'batch',
        sourcePath: '/learning.wav',
        createdAt: now,
        updatedAt: now,
        status: JobStatus.completed,
        document: _document(now),
      );
      final briefService = _AiBrief();
      final controller = _controller(
        jobs: _Jobs([job]),
        soniox: _Soniox(),
        settings: _Settings(
          const AppSettings(
            translationSettings: TranslationSettings(
              baseUrl: 'https://llm.example/v1',
              model: 'brief-model',
            ),
          ),
        ),
        translationCredentials: _TranslationCredentials(),
        aiBriefService: briefService,
      );
      await controller.initialize();

      await controller.generateAiBrief(
        job.id,
        sections: const {AiBriefSection.overview, AiBriefSection.languageNotes},
        outputLanguage: 'zh-Hans',
        learningLanguage: 'ja',
        learningLevel: AiLearningLevel.advanced,
      );
      await controller.updateAiBriefOverview(job.id, 'Keep this edit');

      briefService.error = const AiBriefException('ai_brief_rate_limit');
      await controller.generateAiBrief(
        job.id,
        sections: const {AiBriefSection.languageNotes},
        outputLanguage: 'zh-Hans',
        learningLanguage: 'fr',
        learningLevel: AiLearningLevel.beginner,
        mergeSections: true,
      );
      expect(
        controller.allJobs.single.aiGenerationState.status,
        AiGenerationStatus.failed,
      );

      briefService.error = null;
      await controller.retryAiBrief(job.id);

      final restored = controller.allJobs.single;
      expect(restored.aiBrief?.overview, 'Keep this edit');
      expect(restored.aiBrief?.languageNotes.single.term, 'Transcript 2');
      expect(restored.aiBrief?.learningLanguage, 'fr');
      expect(restored.aiBrief?.learningLevel, AiLearningLevel.beginner);
      expect(briefService.lastLearningLanguage, 'fr');
      expect(briefService.lastLearningLevel, AiLearningLevel.beginner);
      expect(
        controller.renderAiBriefMarkdown(job.id),
        contains('## Language Notes'),
      );
      expect(
        controller.renderAiBriefMarkdown(job.id),
        contains('> Transcript'),
      );
    },
  );

  test(
    'monitored discovery waits for Transcribe and dismissal survives rescans',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'meow-monitor-controller-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/meeting.wav');
      await source.writeAsBytes(const [1, 2, 3]);
      final monitor = _InboxMonitor();
      final monitorRepository = _InboxMonitorRepository();
      final soniox = _Soniox();
      final controller = _controller(
        jobs: _Jobs(),
        soniox: soniox,
        inboxMonitor: monitor,
        inboxMonitorRepository: monitorRepository,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.configureInboxMonitor(
        folderPath: directory.path,
        extensions: const {'wav'},
        launchAtLogin: false,
      );

      await monitor.emit(source.path);
      await _waitFor(() => controller.readyCount == 1);

      final discovered = controller.inboxJobs.single;
      expect(discovered.sourceOrigin, JobSourceOrigin.monitoredFolder);
      expect(discovered.sourceFingerprint, isNotNull);
      expect(soniox.uploadCalls, 0);
      expect(
        monitorRepository.value.records.values.single.disposition,
        MonitoredFileDisposition.queued,
      );

      await controller.removeFromInbox(discovered.id);
      expect(controller.inboxJobs, isEmpty);
      expect(
        monitorRepository.value.records.values.single.disposition,
        MonitoredFileDisposition.dismissed,
      );

      await monitor.emit(source.path);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(controller.inboxJobs, isEmpty);

      await controller.enqueueSources([source.path]);
      await _waitFor(() => controller.readyCount == 1);
      expect(controller.inboxJobs.single.sourceOrigin, JobSourceOrigin.manual);
    },
  );

  test(
    'completed monitored version stays handled after history deletion',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'meow-monitor-history-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/meeting.wav');
      await source.writeAsBytes(const [1, 2, 3]);
      final monitor = _InboxMonitor();
      final monitorRepository = _InboxMonitorRepository();
      final controller = _controller(
        jobs: _Jobs(),
        soniox: _Soniox(),
        inboxMonitor: monitor,
        inboxMonitorRepository: monitorRepository,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.configureInboxMonitor(
        folderPath: directory.path,
        extensions: const {'wav'},
        launchAtLogin: false,
      );
      await monitor.emit(source.path);
      await _waitFor(() => controller.readyCount == 1);

      await controller.startReady();
      final completedId = controller.inboxJobs.single.id;
      expect(controller.completedCount, 1);
      expect(
        monitorRepository.value.records.values.single.disposition,
        MonitoredFileDisposition.completed,
      );

      await controller.deleteHistory(completedId);
      await monitor.emit(source.path);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(controller.inboxJobs, isEmpty);

      await source.writeAsBytes(const [4, 5], mode: FileMode.append);
      await source.setLastModified(
        DateTime.now().add(const Duration(seconds: 2)),
      );
      await monitor.emit(source.path);
      await _waitFor(() => controller.readyCount == 1);
      expect(controller.inboxJobs.single.id, isNot(completedId));
    },
  );

  test(
    'removed monitored source drops an unstarted job and can be re-added',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'meow-monitor-removal-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/meeting.wav');
      await source.writeAsBytes(const [1, 2, 3]);
      final monitor = _InboxMonitor();
      final monitorRepository = _InboxMonitorRepository();
      final jobs = _Jobs();
      final controller = _controller(
        jobs: jobs,
        soniox: _Soniox(),
        inboxMonitor: monitor,
        inboxMonitorRepository: monitorRepository,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.configureInboxMonitor(
        folderPath: directory.path,
        extensions: const {'wav'},
        launchAtLogin: false,
      );
      await monitor.emit(source.path);
      await _waitFor(() => controller.readyCount == 1);
      final removedJobId = controller.inboxJobs.single.id;

      await source.delete();
      await monitor.emitSnapshot(const {});

      expect(controller.inboxJobs, isEmpty);
      expect(jobs.saved, isEmpty);
      expect(monitorRepository.value.records, isEmpty);

      await source.writeAsBytes(const [1, 2, 3]);
      await monitor.emit(source.path);
      await _waitFor(() => controller.readyCount == 1);
      expect(controller.inboxJobs.single.id, isNot(removedJobId));
    },
  );

  test(
    'removed monitored source preserves active and completed work',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'meow-monitor-active-removal-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/meeting.wav');
      await source.writeAsBytes(const [1, 2, 3]);
      final monitor = _InboxMonitor();
      final pollingGate = Completer<void>();
      final controller = _controller(
        jobs: _Jobs(),
        soniox: _Soniox(pollingGate: pollingGate),
        inboxMonitor: monitor,
        inboxMonitorRepository: _InboxMonitorRepository(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.configureInboxMonitor(
        folderPath: directory.path,
        extensions: const {'wav'},
        launchAtLogin: false,
      );
      await monitor.emit(source.path);
      await _waitFor(() => controller.readyCount == 1);
      final jobId = controller.inboxJobs.single.id;
      final processing = controller.startReady();
      await _waitFor(() => controller.inboxJobs.single.status.isActive);

      await source.delete();
      await monitor.emitSnapshot(const {});
      expect(controller.inboxJobs.single.id, jobId);

      pollingGate.complete();
      await processing;
      expect(controller.inboxJobs.single.status, JobStatus.completed);
      await monitor.emitSnapshot(const {});
      expect(controller.inboxJobs.single.id, jobId);
    },
  );
}

TranscriptDocument _document(DateTime now) => TranscriptDocument(
  tokens: const [],
  segments: const [
    TranscriptSegment(
      id: 'segment',
      startMs: 0,
      endMs: 1000,
      text: 'Transcript',
    ),
  ],
  speakers: const [],
  updatedAt: now,
);

AppController _controller({
  required _Jobs jobs,
  required _Soniox soniox,
  CredentialStore? credentials,
  MediaService? media,
  SettingsRepository? settings,
  TranslationCredentialStore? translationCredentials,
  TranslationService? translationService,
  AiBriefService? aiBriefService,
  TranscriptExporter? exporter,
  InboxMonitorRepository? inboxMonitorRepository,
  InboxFolderMonitor? inboxMonitor,
  TranscriptionClient? moss,
  CredentialStore? mossCredentials,
  TranscriptStructureEditor? structureEditor,
}) => AppController(
  credentialStore: credentials ?? _Credentials(),
  settingsRepository: settings ?? _Settings(),
  jobRepository: jobs,
  mediaService: media ?? _Media(),
  sourceResolver: const LocalMediaSourceResolver(),
  sonioxClient: soniox,
  mossClient: moss,
  mossCredentialStore: mossCredentials,
  exporter: exporter ?? const DefaultTranscriptExporter(),
  translationCredentialStore: translationCredentials,
  translationService: translationService,
  aiBriefService: aiBriefService,
  inboxMonitorRepository: inboxMonitorRepository,
  inboxFolderMonitor: inboxMonitor,
  transcriptStructureEditor: structureEditor,
);

class _RecordingExporter implements TranscriptExporter {
  final exportedJobIds = <String>[];

  @override
  Future<String> exportToDirectory(
    TranscriptionJob job,
    String directory,
    ExportOptions options,
  ) async {
    exportedJobIds.add(job.id);
    return '$directory/${job.id}';
  }

  @override
  Future<String> exportZip(
    List<TranscriptionJob> jobs,
    String destination,
    ExportOptions options,
  ) async => destination;

  @override
  String render(
    TranscriptDocument document,
    ExportOptions options, {
    required String title,
    MediaMetadata? metadata,
  }) => '';
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not reached.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _Credentials implements CredentialStore {
  @override
  Future<void> deleteApiKey() async {}

  @override
  Future<String?> readApiKey() async => 'configured';

  @override
  Future<void> writeApiKey(String key) async {}
}

class _AvailabilityCredentials
    implements CredentialStore, CredentialAvailabilityStore {
  int availabilityChecks = 0;
  int secretReads = 0;

  @override
  Future<bool> hasApiKey() async {
    availabilityChecks++;
    return true;
  }

  @override
  Future<String?> readApiKey() async {
    secretReads++;
    return 'configured';
  }

  @override
  Future<void> writeApiKey(String key) async {}

  @override
  Future<void> deleteApiKey() async {}
}

class _Settings implements SettingsRepository {
  _Settings([this.value = const AppSettings()]);

  AppSettings value;

  @override
  Future<AppSettings> load() async => value;

  @override
  Future<void> save(AppSettings settings) async => value = settings;
}

class _InboxMonitorRepository implements InboxMonitorRepository {
  InboxMonitorStorage value = const InboxMonitorStorage();

  @override
  Future<InboxMonitorStorage> load() async => value;

  @override
  Future<void> save(InboxMonitorStorage storage) async => value = storage;
}

class _InboxMonitor implements InboxFolderMonitor {
  MonitoredFileCallback? _onCandidate;
  MonitoredFilesSnapshotCallback? _onSnapshot;
  InboxMonitorConfig config = const InboxMonitorConfig();

  Future<void> emit(String path) async {
    final fingerprint = await fingerprintMonitoredFile(path);
    if (fingerprint != null) await _onCandidate?.call(fingerprint);
  }

  Future<void> emitSnapshot(Set<String> identities) async {
    await _onSnapshot?.call(identities);
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
    this.config = config;
    _onCandidate = onCandidate;
    _onSnapshot = onSnapshot;
    onStatus(
      !config.isConfigured
          ? InboxMonitorStatus.unconfigured
          : config.paused
          ? InboxMonitorStatus.paused
          : InboxMonitorStatus.active,
      null,
    );
  }

  @override
  Future<void> stop() async {
    _onCandidate = null;
    _onSnapshot = null;
  }
}

class _TranslationCredentials implements TranslationCredentialStore {
  String? value = 'translation-key';

  @override
  Future<void> deleteApiKey() async => value = null;

  @override
  Future<String?> readApiKey() async => value;

  @override
  Future<void> writeApiKey(String key) async => value = key;
}

class _AvailabilityTranslationCredentials
    implements TranslationCredentialStore, CredentialAvailabilityStore {
  int availabilityChecks = 0;
  int secretReads = 0;

  @override
  Future<bool> hasApiKey() async {
    availabilityChecks++;
    return true;
  }

  @override
  Future<String?> readApiKey() async {
    secretReads++;
    return 'translation-key';
  }

  @override
  Future<void> writeApiKey(String key) async {}

  @override
  Future<void> deleteApiKey() async {}
}

class _FailingTranslation implements TranslationService {
  @override
  Future<List<String>> listModels(
    TranslationSettings settings, {
    String? candidateApiKey,
  }) async => const [];

  @override
  Future<void> translate({
    required TranslationSettings settings,
    required String targetLanguage,
    required List<TranscriptSegment> segments,
    required Future<void> Function(
      Map<String, String> translatedBySegmentId,
      int completedSegments,
      int totalSegments,
    )
    onBatch,
    CancelCheck? shouldCancel,
  }) async {
    throw const TranslationException('translation_rate_limit');
  }
}

class _SuccessfulTranslation implements TranslationService {
  int calls = 0;
  final segmentIds = <String>[];

  @override
  Future<List<String>> listModels(
    TranslationSettings settings, {
    String? candidateApiKey,
  }) async => const [];

  @override
  Future<void> translate({
    required TranslationSettings settings,
    required String targetLanguage,
    required List<TranscriptSegment> segments,
    required Future<void> Function(
      Map<String, String> translatedBySegmentId,
      int completedSegments,
      int totalSegments,
    )
    onBatch,
    CancelCheck? shouldCancel,
  }) async {
    calls++;
    segmentIds.addAll(segments.map((segment) => segment.id));
    await onBatch(
      {
        for (final segment in segments)
          segment.id: segment.text.trim().isEmpty ? '' : '补充翻译。',
      },
      segments.length,
      segments.length,
    );
  }
}

class _AiBrief implements AiBriefService {
  AiBriefException? error;
  String? lastLearningLanguage;
  AiLearningLevel? lastLearningLevel;
  var successfulGenerations = 0;

  @override
  int estimateRequestCount(
    TranscriptDocument document,
    Set<AiBriefSection> sections,
  ) => 1;

  @override
  Future<AiBrief> generate({
    required LlmProviderSettings settings,
    required TranscriptDocument document,
    required Set<AiBriefSection> sections,
    required String outputLanguage,
    String? learningLanguage,
    AiLearningLevel learningLevel = AiLearningLevel.intermediate,
    AiBriefProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    if (error case final value?) throw value;
    lastLearningLanguage = learningLanguage;
    lastLearningLevel = learningLevel;
    successfulGenerations++;
    await onProgress?.call('analyzing', 1, 1);
    return AiBrief(
      overview: 'Grounded overview',
      overviewEvidenceSegmentIds: [document.segments.single.id],
      chapters: const [],
      insights: const [],
      languageNotes: sections.contains(AiBriefSection.languageNotes)
          ? [
              AiLanguageNote(
                id: 'note-$successfulGenerations',
                kind: AiLanguageNoteKind.vocabulary,
                term: 'Transcript $successfulGenerations',
                explanation: 'A learning explanation.',
                sourceExcerpt: 'Transcript',
                evidenceSegmentIds: [document.segments.single.id],
              ),
            ]
          : const [],
      learningLanguage: learningLanguage,
      learningLevel: learningLevel,
      outputLanguage: outputLanguage,
      model: settings.model,
      selectedSections: sections,
      generatedAt: DateTime.now().toUtc(),
      sourceTranscriptUpdatedAt: document.updatedAt,
    );
  }
}

class _Jobs implements JobRepository {
  _Jobs([Iterable<TranscriptionJob> initial = const []]) {
    for (final job in initial) {
      saved[job.id] = job;
    }
  }

  final Map<String, TranscriptionJob> saved = {};

  @override
  Future<void> delete(String id) async => saved.remove(id);

  @override
  Future<List<TranscriptionJob>> loadAll() async => saved.values.toList();

  @override
  Future<void> save(TranscriptionJob job) async => saved[job.id] = job;
}

class _Media implements MediaService {
  final deletedGeneratedMedia = <String>[];
  Set<String>? retainedGeneratedMedia;
  bool uploadDirectly = true;
  final checkedUploadProfiles = <MediaUploadProfile>[];
  final extractedUploadProfiles = <MediaUploadProfile>[];

  @override
  bool canUploadDirectly(
    String path,
    MediaMetadata metadata, {
    MediaUploadProfile profile = MediaUploadProfile.standard,
  }) {
    checkedUploadProfiles.add(profile);
    return uploadDirectly;
  }

  @override
  Future<void> deleteTemporary(String path) async {}

  @override
  Future<void> deleteGeneratedMedia(String cacheKey) async =>
      deletedGeneratedMedia.add(cacheKey);

  @override
  Future<void> clearGeneratedMediaExcept(Set<String> retainedCacheKeys) async =>
      retainedGeneratedMedia = retainedCacheKeys;

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
  }) async {
    extractedUploadProfiles.add(profile);
    return sourcePath;
  }

  @override
  Future<MediaMetadata> inspect(String sourcePath) async => const MediaMetadata(
    sizeBytes: 3,
    durationMs: 1000,
    hasAudio: true,
    hasVideo: false,
    formatName: 'wav',
  );

  @override
  Future<String> renderWaveform(String sourcePath, String cacheKey) async => '';
}

class _FailingMedia extends _Media {
  @override
  Future<MediaMetadata> inspect(String sourcePath) =>
      throw const MediaException('invalid_media', 'Invalid media.');
}

class _Soniox implements SonioxClient {
  _Soniox({
    this.uploadDelay = Duration.zero,
    this.transcriptPayload,
    this.pollingGate,
    this.transcriptionState,
  });
  final Duration uploadDelay;
  final Map<String, dynamic>? transcriptPayload;
  final Completer<void>? pollingGate;
  final SonioxTranscriptionState? transcriptionState;
  int currentUploads = 0;
  int maximumUploads = 0;
  int uploadCalls = 0;
  final deletedFiles = <String>[];
  final deletedTranscriptions = <String>[];
  TranscriptionOptions? createdOptions;

  @override
  Future<String> createTranscription(
    String fileId,
    TranscriptionOptions options,
  ) async {
    createdOptions = options;
    return 'tx-$fileId';
  }

  @override
  Future<void> deleteFile(String id) async => deletedFiles.add(id);

  @override
  Future<void> deleteTranscription(String id) async =>
      deletedTranscriptions.add(id);

  @override
  Future<Map<String, dynamic>> getTranscript(String id) async =>
      transcriptPayload ??
      {
        'tokens': [
          {'text': 'Done.', 'start_ms': 0, 'end_ms': 800, 'speaker': '1'},
        ],
      };

  @override
  Future<SonioxTranscriptionState> getTranscription(String id) async {
    await pollingGate?.future;
    return transcriptionState ??
        const SonioxTranscriptionState(status: 'completed');
  }

  @override
  Future<String> uploadFile(
    String path, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    uploadCalls++;
    final call = uploadCalls;
    currentUploads++;
    if (currentUploads > maximumUploads) maximumUploads = currentUploads;
    onProgress?.call(.5, null);
    await Future<void>.delayed(uploadDelay);
    currentUploads--;
    onProgress?.call(1, null);
    return 'file-$call';
  }

  @override
  Future<void> validateKey({String? apiKey}) async {}
}

class _Moss implements TranscriptionClient {
  int uploadCalls = 0;
  final deletedFiles = <String>[];
  final deletedTranscriptions = <String>[];

  @override
  Future<String> createTranscription(
    String fileId,
    TranscriptionOptions options,
  ) async => 'moss-task-1';

  @override
  Future<void> deleteFile(String id) async => deletedFiles.add(id);

  @override
  Future<void> deleteTranscription(String id) async {}

  @override
  Future<Map<String, dynamic>> getTranscript(String id) async => {
    'duration': 1,
    'text': 'MOSS result',
    'segments': [
      {
        'id': 'moss-segment',
        'start': 0,
        'end': 1,
        'text': 'MOSS result',
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
  }) async {
    uploadCalls++;
    onProgress?.call(1, null);
    return 'moss-file-$uploadCalls';
  }

  @override
  Future<void> validateKey({String? apiKey}) async {}
}
