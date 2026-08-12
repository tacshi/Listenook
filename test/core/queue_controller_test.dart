import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/contracts.dart';
import 'package:meow_stt/core/models.dart';
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
      controller.setDestination(1);
      controller.setDestination(0);

      expect(
        controller.playbackPositionFor('transcript'),
        const Duration(minutes: 2, seconds: 7),
      );

      controller.rememberPlaybackPosition('transcript', Duration.zero);
      expect(controller.playbackPositionFor('transcript'), Duration.zero);
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
    final controller = _controller(jobs: jobs, soniox: soniox);
    await controller.initialize();
    await controller.addSources(files);
    await _waitFor(() => controller.readyCount == 4);
    final movedId = controller.workspaceJobs.first.id;
    controller.reorderWorkspace(0, 3);
    await _waitFor(() => jobs.saved[movedId]?.queueIndex == 3);
    expect(controller.workspaceJobs.last.id, movedId);

    await controller.startReady();

    expect(soniox.maximumUploads, 4);
    expect(controller.completedCount, 4);
    expect(
      jobs.saved.values.every(
        (job) => job.cleanupState == CleanupState.complete,
      ),
      isTrue,
    );
    expect(soniox.deletedFiles, hasLength(4));
    expect(soniox.deletedTranscriptions, hasLength(4));
  });

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
        await controller.addSources(files);
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
    await controller.addSources([file.path]);
    await _waitFor(() => controller.readyCount == 1);

    await controller.startReady();

    expect(controller.workspaceJobs.single.status, JobStatus.failed);
    expect(controller.workspaceJobs.single.errorCode, 'exhausted_balance');
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

  test(
    'continuing a ready history job only restores it to the workspace',
    () async {
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
      controller.setDestination(1);

      controller.continueReadyJob('ready');

      expect(jobs.saved['ready']?.status, JobStatus.ready);
      expect(controller.workspaceJobs.single.id, 'ready');
      expect(controller.selectedJobId, 'ready');
      expect(controller.destinationIndex, 0);
      expect(controller.processing, isFalse);
      expect(soniox.uploadCalls, 0);
    },
  );

  test(
    'continuing a ready history job defers missing-source validation',
    () async {
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
      controller.setDestination(1);

      controller.continueReadyJob('ready');

      expect(jobs.saved['ready']?.status, JobStatus.ready);
      expect(controller.workspaceJobs.single.id, 'ready');
      expect(controller.selectedJobId, 'ready');
      expect(controller.destinationIndex, 0);
      expect(controller.processing, isFalse);
      expect(soniox.uploadCalls, 0);

      await controller.startReady();

      expect(jobs.saved['ready']?.status, JobStatus.missingSource);
      expect(soniox.uploadCalls, 0);
    },
  );

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
      await controller.addSources([file.path]);
      await _waitFor(() => controller.readyCount == 1);
      final run = controller.startReady();
      await _waitFor(
        () => controller.workspaceJobs.single.status == JobStatus.uploading,
      );
      await controller.cancelJob(controller.workspaceJobs.single.id);
      await run;

      expect(controller.workspaceJobs.single.status, JobStatus.cancelled);
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
      await controller.addSources([completedFile.path]);
      await _waitFor(() => controller.readyCount == 1);
      expect(controller.workspaceJobs.single.options.languageHints, ['zh']);
      expect(controller.workspaceJobs.single.options.contextTerms, ['MeowSTT']);
      await controller.startReady();
      final completed = controller.workspaceJobs.single;

      await controller.addSources([draftFile.path]);
      await _waitFor(() => controller.readyCount == 1);
      expect(controller.untranscribedWorkspaceCount, 1);

      await controller.startNewSession();

      expect(controller.workspaceJobs, isEmpty);
      expect(controller.allJobs.map((job) => job.id), [completed.id]);
      expect(jobs.saved.keys, [completed.id]);
      expect(controller.sessionOptions.languageHints, isEmpty);
      expect(controller.sessionOptions.contextTerms, isEmpty);

      await controller.addSources([nextFile.path]);
      await _waitFor(() => controller.readyCount == 1);
      expect(controller.workspaceJobs.single.batchId, isNot(completed.batchId));
      expect(controller.workspaceJobs.single.options.languageHints, isEmpty);
      expect(controller.workspaceJobs.single.options.contextTerms, isEmpty);
    },
  );

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
      controller.reopen('completed');

      final error = await controller.relink('completed', '/replacement.wav');

      expect(error, isNull);
      final linked = controller.selectedJob!;
      expect(linked.status, JobStatus.completed);
      expect(linked.sourcePath, '/replacement.wav');
      expect(linked.document, isNotNull);
      expect(linked.cleanupState, CleanupState.complete);
      expect(linked.metadata?.durationMs, 1000);
      expect(controller.workspaceJobs.single.id, 'completed');
      expect(controller.selectedJobId, 'completed');
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
      await controller.addSources([file.path]);
      await _waitFor(() => controller.readyCount == 1);

      await controller.startReady();

      final result = controller.workspaceJobs.single;
      expect(settings.value.translationSettings.autoTranslate, isFalse);
      expect(soniox.createdOptions?.sonioxTranslation.enabled, isTrue);
      expect(result.document!.segments.single.translatedText, 'Hola.');
      expect(result.translationState.status, TranslationStatus.completed);
      expect(result.translationState.origin, TranslationOrigin.soniox);
      expect(result.translationState.targetLanguage, 'es');
      expect(llm.calls, 0);
    },
  );

  test('automatic Soniox and LLM translation settings are exclusive', () async {
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
    await controller.addSources([file.path]);
    await _waitFor(() => controller.readyCount == 1);
    expect(controller.workspaceJobs.single.translationOptions.enabled, isTrue);

    final sonioxError = await controller.updateSonioxTranslation(
      const SonioxTranslationOptions(enabled: true, targetLanguage: 'es'),
    );

    expect(sonioxError, isNull);
    expect(controller.settings.sonioxTranslation.enabled, isTrue);
    expect(controller.settings.translationSettings.autoTranslate, isFalse);
    expect(
      controller.workspaceJobs.single.options.sonioxTranslation.enabled,
      isTrue,
    );
    expect(controller.workspaceJobs.single.translationOptions.enabled, isFalse);

    final llmError = await controller.updateTranslationDefaults(
      controller.settings.translationSettings.copyWith(autoTranslate: true),
    );

    expect(llmError, isNull);
    expect(controller.settings.sonioxTranslation.enabled, isFalse);
    expect(controller.settings.translationSettings.autoTranslate, isTrue);
    expect(
      controller.workspaceJobs.single.options.sonioxTranslation.enabled,
      isFalse,
    );
    expect(controller.workspaceJobs.single.translationOptions.enabled, isTrue);
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

    final submitted = controller.workspaceJobs.single;
    expect(submitted.options.sonioxTranslation.enabled, isFalse);
    expect(submitted.translationOptions.enabled, isTrue);

    pollingGate.complete();
    await _waitFor(
      () => controller.workspaceJobs.single.status == JobStatus.completed,
    );
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
      controller.reopen('history');
      await controller.addSources([activeFile.path]);
      await _waitFor(() => controller.readyCount == 1);
      final activeId = controller.workspaceJobs.last.id;
      final run = controller.startReady();
      await _waitFor(
        () => controller.workspaceJobs.last.status == JobStatus.uploading,
      );

      expect(controller.processingCount, 1);
      expect(controller.inactiveHistoryCount, 1);
      await controller.clearInactiveHistory();

      expect(jobs.saved.containsKey('history'), isFalse);
      expect(media.deletedGeneratedMedia, contains('history'));
      expect(media.retainedGeneratedMedia, {activeId});
      expect(controller.workspaceJobs.single.id, activeId);
      expect(controller.selectedJobId, activeId);
      expect(controller.workspaceJobs.single.status, JobStatus.uploading);
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
}) => AppController(
  credentialStore: credentials ?? _Credentials(),
  settingsRepository: settings ?? _Settings(),
  jobRepository: jobs,
  mediaService: media ?? _Media(),
  sonioxClient: soniox,
  exporter: const DefaultTranscriptExporter(),
  translationCredentialStore: translationCredentials,
  translationService: translationService,
  aiBriefService: aiBriefService,
);

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
    AiBriefProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    if (error case final value?) throw value;
    await onProgress?.call('analyzing', 1, 1);
    return AiBrief(
      overview: 'Grounded overview',
      overviewEvidenceSegmentIds: [document.segments.single.id],
      chapters: const [],
      insights: const [],
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

  @override
  bool canUploadDirectly(String path, MediaMetadata metadata) => true;

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
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async => sourcePath;

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
