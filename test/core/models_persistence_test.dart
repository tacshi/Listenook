import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/data/local_repositories.dart';

void main() {
  test('mimic pause defaults to automatic for missing or invalid settings', () {
    expect(const AppSettings().mimicPauseSeconds, 0);
    expect(AppSettings.fromJson({}).mimicPauseSeconds, 0);
    for (final invalid in [null, -1, 15, 20, 30, 31, '5', 2.5, true]) {
      expect(
        AppSettings.fromJson({
          'mimic_pause_seconds': invalid,
        }).mimicPauseSeconds,
        0,
      );
    }
  });

  test('mimic rep goal defaults to three for missing or invalid settings', () {
    expect(const AppSettings().mimicRepGoal, 3);
    expect(AppSettings.fromJson({}).mimicRepGoal, 3);
    for (final invalid in [null, 0, -1, '5', 2.5]) {
      expect(AppSettings.fromJson({'mimic_rep_goal': invalid}).mimicRepGoal, 3);
    }
  });

  test(
    'mimic practice settings persist through saves and unrelated edits',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'listenook-mimic-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final paths = AppPaths.forTesting(temporary.path);
      final settings = const AppSettings()
          .copyWith(mimicRepGoal: 5, mimicPauseSeconds: 10)
          .copyWith(showTimestamps: true);
      await JsonSettingsRepository(paths).save(settings);
      final restored = await JsonSettingsRepository(paths).load();
      expect(restored.mimicRepGoal, 5);
      expect(restored.mimicPauseSeconds, 10);
      expect(restored.showTimestamps, isTrue);
      await JsonSettingsRepository(
        paths,
      ).save(restored.copyWith(mimicPauseSeconds: 0));
      expect((await JsonSettingsRepository(paths).load()).mimicPauseSeconds, 0);
    },
  );

  test('blind listening defaults off and persists independently', () {
    expect(AppSettings.fromJson({}).blindListeningEnabled, isFalse);
    final settings = const AppSettings().copyWith(blindListeningEnabled: true);
    expect(
      settings.exportOptions.toJson(),
      isNot(contains('blind_listening_enabled')),
    );
    expect(
      AppSettings.fromJson(settings.toJson()).blindListeningEnabled,
      isTrue,
    );
    expect(
      settings.copyWith(showTimestamps: true).blindListeningEnabled,
      isTrue,
    );
    expect(
      settings.copyWith(blindListeningEnabled: false).blindListeningEnabled,
      isFalse,
    );
  });

  test('translation provider defaults blank and migrates known endpoints', () {
    const defaults = TranslationSettings();
    expect(defaults.provider, TranslationProviderTemplate.custom);
    expect(defaults.baseUrl, isEmpty);

    final migrated = TranslationSettings.fromJson({
      'base_url': 'https://api.groq.com/openai/v1',
      'model': 'example-model',
    });
    expect(migrated.provider, TranslationProviderTemplate.groq);
    expect(migrated.toJson()['provider'], 'groq');

    final inferredOpenRouter = TranslationSettings.fromJson({
      'base_url': 'https://openrouter.ai/api/v1/',
      'model': 'openai/gpt-4o-mini',
    });
    expect(inferredOpenRouter.provider, TranslationProviderTemplate.openRouter);
    expect(inferredOpenRouter.toJson()['provider'], 'openRouter');

    const explicitOpenRouter = TranslationSettings(
      provider: TranslationProviderTemplate.openRouter,
      baseUrl: 'https://openrouter.ai/api/v1',
      model: 'anthropic/claude-3.5-haiku',
    );
    final restoredOpenRouter = TranslationSettings.fromJson(
      explicitOpenRouter.toJson(),
    );
    expect(restoredOpenRouter.provider, TranslationProviderTemplate.openRouter);
    expect(restoredOpenRouter.toJson(), explicitOpenRouter.toJson());
  });

  test(
    'legacy translation settings migrate into split provider preferences',
    () {
      final settings = AppSettings.fromJson({
        'translation_settings': {
          'provider': 'openRouter',
          'base_url': 'https://openrouter.ai/api/v1',
          'model': 'brief-model',
          'target_language': 'zh-Hans',
          'auto_translate': true,
        },
      });

      expect(
        settings.llmProviderSettings.provider,
        TranslationProviderTemplate.openRouter,
      );
      expect(settings.llmProviderSettings.model, 'brief-model');
      expect(settings.translationPreferences.targetLanguage, 'zh-Hans');
      expect(settings.translationPreferences.autoTranslate, isTrue);
      expect(settings.toJson(), contains('llm_provider_settings'));
      expect(settings.toJson(), contains('translation_preferences'));
      expect(settings.toJson(), isNot(contains('translation_settings')));
    },
  );

  test('legacy fullscreen shortcut preference is ignored', () {
    final restored = AppSettings.fromJson(const {
      'show_fullscreen_shortcuts': false,
    });

    expect(restored.toJson(), isNot(contains('show_fullscreen_shortcuts')));
  });

  test('legacy concurrency setting is ignored and no longer persisted', () {
    final restored = AppSettings.fromJson(const {'concurrency': 1});

    expect(restored.toJson(), isNot(contains('concurrency')));
  });

  test('older manifests migrate with safe defaults', () {
    final job = TranscriptionJob.fromJson({
      'id': 'job_1',
      'source_path': '/recording.wav',
      'created_at': '2025-01-01T00:00:00Z',
      'updated_at': '2025-01-01T00:00:00Z',
      'status': 'completed',
      'document': {
        'tokens': [
          {'text': 'Hello', 'start_ms': 0, 'end_ms': 500},
        ],
        'segments': [
          {'text': 'Hello', 'start_ms': 0, 'end_ms': 500},
        ],
      },
    });

    expect(job.batchId, 'recovered');
    expect(job.cleanupState, CleanupState.none);
    expect(job.options.languageHints, isEmpty);
    expect(job.document!.segments.single.id, '0');
    expect(job.document!.segments.single.translatedText, isNull);
    expect(job.translationState.status, TranslationStatus.idle);
    expect(job.translationOptions.enabled, isFalse);
    expect(job.options.sonioxTranslation.enabled, isFalse);
    expect(job.displayTitle, isNull);
    expect(job.displayName, 'recording.wav');
    expect(job.groupId, isNull);
    expect(job.tagIds, isEmpty);
    expect(job.sourceOrigin, JobSourceOrigin.manual);
    expect(job.sourceFingerprint, isNull);
    expect(job.transcriptionProvider, TranscriptionProvider.soniox);
  });

  test(
    'transcription provider defaults to Soniox and round-trips local modes',
    () {
      final defaults = AppSettings.fromJson(const {});
      expect(
        defaults.defaultTranscriptionProvider,
        TranscriptionProvider.soniox,
      );

      final settings = AppSettings.fromJson(const {
        'default_transcription_provider': 'mossPro',
      });
      expect(
        settings.defaultTranscriptionProvider,
        TranscriptionProvider.mossPro,
      );
      expect(settings.toJson()['default_transcription_provider'], 'mossPro');

      final now = DateTime.utc(2026, 8, 16);
      final restored = TranscriptionJob.fromJson(
        TranscriptionJob(
          id: 'moss-job',
          batchId: 'batch',
          sourcePath: '/meeting.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.ready,
          transcriptionProvider: TranscriptionProvider.mossPro,
        ).toJson(),
      );
      expect(restored.transcriptionProvider, TranscriptionProvider.mossPro);
      expect(
        restored.transcriptAcquisitionMode,
        TranscriptAcquisitionMode.mossPro,
      );

      final inferred = TranscriptionJob.fromJson(
        {...restored.toJson(), 'transcript_acquisition_mode': 'mossPro'}
          ..remove('transcription_provider'),
      );
      expect(inferred.transcriptionProvider, TranscriptionProvider.mossPro);
      expect(
        inferred.transcriptAcquisitionMode,
        TranscriptAcquisitionMode.mossPro,
      );

      final local = TranscriptionJob.fromJson(
        TranscriptionJob(
          id: 'moss-local-job',
          batchId: 'batch',
          sourcePath: '/meeting.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.aligning,
          transcriptionProvider: TranscriptionProvider.mossLocal,
          transcriptSource: TranscriptSource.mossLocal,
          forcedAlignment: const ForcedAlignmentState(
            status: ForcedAlignmentStatus.running,
            modelId: 'qwen3-forced-aligner-0.6b-q8_0',
            modelRevision: 'pinned-revision',
            alignedSegments: 2,
            totalSegments: 3,
            languageAutomaticallyDetermined: true,
          ),
        ).toJson(),
      );
      expect(local.transcriptionProvider, TranscriptionProvider.mossLocal);
      expect(
        local.transcriptAcquisitionMode,
        TranscriptAcquisitionMode.mossLocal,
      );
      expect(local.transcriptSource, TranscriptSource.mossLocal);
      expect(local.status, JobStatus.aligning);
      expect(local.forcedAlignment.status, ForcedAlignmentStatus.running);
      expect(local.forcedAlignment.alignedSegments, 2);
      expect(local.forcedAlignment.languageAutomaticallyDetermined, isTrue);

      final qwen = TranscriptionJob.fromJson(
        TranscriptionJob(
          id: 'qwen-local-job',
          batchId: 'batch',
          sourcePath: '/multilingual.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
          transcriptionProvider: TranscriptionProvider.qwen3Local,
          transcriptSource: TranscriptSource.qwen3Local,
          transcriptionModel: const TranscriptionModelReference(
            id: 'qwen3-asr-1.7b-mlx-8bit',
            revision: 'pinned-qwen-revision',
          ),
        ).toJson(),
      );
      expect(qwen.transcriptionProvider, TranscriptionProvider.qwen3Local);
      expect(
        qwen.transcriptAcquisitionMode,
        TranscriptAcquisitionMode.qwen3Local,
      );
      expect(qwen.transcriptSource, TranscriptSource.qwen3Local);
      expect(qwen.transcriptionModel?.id, 'qwen3-asr-1.7b-mlx-8bit');
      expect(qwen.transcriptionModel?.revision, 'pinned-qwen-revision');
      expect(local.transcriptionModel, isNull);
    },
  );

  test(
    'word timing provenance survives persistence and old data stays safe',
    () {
      const token = TranscriptToken(
        text: 'Hello',
        startMs: 120,
        endMs: 420,
        segmentId: 'moss-7',
        speaker: 'S02',
      );
      final restored = TranscriptToken.fromJson(token.toJson());
      expect(restored.segmentId, 'moss-7');
      expect(restored.speaker, 'S02');

      final legacy = TranscriptToken.fromJson(const {
        'text': 'Legacy',
        'start_ms': 0,
        'end_ms': 300,
      });
      expect(legacy.segmentId, isNull);

      final document = TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'moss-7',
            startMs: 0,
            endMs: 500,
            text: 'Hello',
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.utc(2026, 8, 16),
      );
      expect(
        document.copyWith(tokens: const [token]).tokens.single.segmentId,
        'moss-7',
      );
    },
  );

  test('imported subtitle provenance round-trips', () {
    final now = DateTime.utc(2026, 8, 24, 9, 30);
    final fingerprint = SourceFingerprint(
      identity: '/media/movie.en.srt',
      path: '/media/movie.en.srt',
      sizeBytes: 128,
      modifiedAt: now,
    );
    final restored = TranscriptionJob.fromJson(
      TranscriptionJob(
        id: 'imported-subtitles',
        batchId: 'batch',
        sourcePath: '/media/movie.mp4',
        createdAt: now,
        updatedAt: now,
        status: JobStatus.completed,
        transcriptionProvider: TranscriptionProvider.soniox,
        transcriptAcquisitionMode: TranscriptAcquisitionMode.importedSubtitles,
        transcriptSource: TranscriptSource.importedSubtitle,
        importedSubtitleProvenance: ImportedSubtitleProvenance(
          sourcePath: fingerprint.path,
          displayName: 'movie.en.srt',
          format: SubtitleFormat.srt,
          importedAt: now,
          sourceFingerprint: fingerprint,
        ),
        document: TranscriptDocument(
          tokens: const [],
          segments: const [
            TranscriptSegment(
              id: 'subtitle-cue-1',
              startMs: 1250,
              endMs: 2800,
              text: 'Unchanged subtitle text',
            ),
          ],
          speakers: const [],
          updatedAt: now,
        ),
      ).toJson(),
    );

    expect(
      restored.transcriptAcquisitionMode,
      TranscriptAcquisitionMode.importedSubtitles,
    );
    expect(restored.transcriptSource, TranscriptSource.importedSubtitle);
    expect(restored.transcriptionProvider, TranscriptionProvider.soniox);
    expect(restored.importedSubtitleProvenance!.format, SubtitleFormat.srt);
    expect(
      restored.importedSubtitleProvenance!.sourceFingerprint!.sameVersion(
        fingerprint,
      ),
      isTrue,
    );
    expect(restored.document!.segments.single.startMs, 1250);
    expect(restored.document!.segments.single.endMs, 2800);
    expect(restored.toJson()['manifest_version'], manifestVersion);
  });

  test('automatic word timing migrates the legacy MOSS setting', () {
    const defaults = AppSettings();
    expect(defaults.automaticWordTiming, isTrue);
    expect(defaults.defaultForcedAlignmentModel, isNull);

    final disabled = AppSettings.fromJson(const {
      'auto_align_moss': false,
      'default_forced_alignment_model': 'qwen3CoreMlFp16',
    });
    expect(disabled.automaticWordTiming, isFalse);
    expect(
      disabled.defaultForcedAlignmentModel,
      ForcedAlignmentModel.qwen3CoreMlFp16,
    );
    expect(disabled.toJson()['auto_align_transcripts'], isFalse);
    expect(disabled.toJson(), isNot(contains('auto_align_moss')));
    expect(
      disabled.toJson()['default_forced_alignment_model'],
      'qwen3CoreMlFp16',
    );

    final int8 = AppSettings.fromJson(const {
      'default_forced_alignment_model': 'qwen3CoreMlInt8',
    });
    expect(
      int8.defaultForcedAlignmentModel,
      ForcedAlignmentModel.qwen3CoreMlInt8,
    );
    expect(
      AppSettings.fromJson(const {
        'default_forced_alignment_model': 'unknown',
      }).defaultForcedAlignmentModel,
      isNull,
    );
    expect(
      AppSettings.fromJson(const {
        'auto_align_transcripts': true,
        'auto_align_moss': false,
      }).automaticWordTiming,
      isTrue,
    );
  });

  test('local automation and restorable content state round-trip safely', () {
    const defaults = AppSettings();
    expect(defaults.autoTranscribeLocal, isFalse);
    expect(defaults.lastContentDestination, AppContentDestination.podcast);
    expect(defaults.lastWorkspaceJobId, isNull);
    expect(defaults.playbackPositionsMs, isEmpty);

    final restored = AppSettings.fromJson(
      const AppSettings(
        autoTranscribeLocal: true,
        lastContentDestination: AppContentDestination.workspace,
        lastWorkspaceJobId: 'workspace-job',
        playbackPositionsMs: {'workspace-job': 4449000},
      ).toJson(),
    );
    expect(restored.autoTranscribeLocal, isTrue);
    expect(restored.lastContentDestination, AppContentDestination.workspace);
    expect(restored.lastWorkspaceJobId, 'workspace-job');
    expect(restored.playbackPositionsMs, {'workspace-job': 4449000});
    expect(restored.toJson()['manifest_version'], manifestVersion);

    final legacy = AppSettings.fromJson(const {});
    expect(legacy.autoTranscribeLocal, isFalse);
    expect(legacy.lastContentDestination, AppContentDestination.podcast);
    expect(legacy.playbackPositionsMs, isEmpty);
    expect(
      restored.copyWith(clearLastWorkspaceJobId: true).lastWorkspaceJobId,
      isNull,
    );
  });

  test('version 6 manifests round-trip monitored source provenance', () {
    final now = DateTime.utc(2026, 8, 14, 8, 30);
    final fingerprint = SourceFingerprint(
      identity: '/inbox/meeting.wav',
      path: '/inbox/meeting.wav',
      sizeBytes: 4096,
      modifiedAt: now,
    );
    final restored = TranscriptionJob.fromJson(
      TranscriptionJob(
        id: 'monitored',
        batchId: 'batch',
        sourcePath: fingerprint.path,
        createdAt: now,
        updatedAt: now,
        status: JobStatus.ready,
        sourceOrigin: JobSourceOrigin.monitoredFolder,
        sourceFingerprint: fingerprint,
      ).toJson(),
    );

    expect(restored.sourceOrigin, JobSourceOrigin.monitoredFolder);
    expect(restored.sourceFingerprint?.sameVersion(fingerprint), isTrue);
    expect(restored.toJson()['manifest_version'], manifestVersion);
  });

  test('version 7 manifests round-trip podcast provenance', () {
    final now = DateTime.utc(2026, 8, 15, 9);
    final provenance = PodcastEpisodeProvenance(
      feedUrl: 'https://feeds.example/show',
      episodeId: 'https://feeds.example/show\nguid-1',
      enclosureUrl: 'https://cdn.example/ep.mp3',
      showTitle: 'All Ears English',
      episodeTitle: 'AEE 2231',
      guid: 'guid-1',
      publishedAt: now,
      language: 'en',
      description: 'A show notes paragraph for later.',
      transcriptTiming: PodcastTranscriptTiming.cue,
      transcripts: const [
        PodcastTranscriptReference(
          url: 'https://cdn.example/ep.vtt',
          type: 'text/vtt',
        ),
      ],
    );
    final restored = TranscriptionJob.fromJson(
      TranscriptionJob(
        id: 'podcast',
        batchId: 'batch',
        sourcePath: '/Inbox/Podcasts/ep.mp3',
        createdAt: now,
        updatedAt: now,
        status: JobStatus.downloading,
        sourceOrigin: JobSourceOrigin.podcast,
        displayTitle: provenance.displayName,
        podcastProvenance: provenance,
        transcriptAcquisitionMode: TranscriptAcquisitionMode.soniox,
      ).toJson(),
    );

    expect(restored.sourceOrigin, JobSourceOrigin.podcast);
    expect(restored.status, JobStatus.downloading);
    expect(restored.podcastProvenance?.episodeTitle, 'AEE 2231');
    expect(
      restored.podcastProvenance?.description,
      'A show notes paragraph for later.',
    );
    expect(
      restored.podcastProvenance?.transcriptTiming,
      PodcastTranscriptTiming.cue,
    );
    expect(
      restored.transcriptAcquisitionMode,
      TranscriptAcquisitionMode.soniox,
    );
    expect(restored.toJson()['manifest_version'], manifestVersion);
  });

  test('legacy publisherWordTimed jobs load as publisher captions', () {
    final restored = TranscriptionJob.fromJson({
      'id': 'legacy-captions',
      'batch_id': 'batch',
      'source_path': '/cache/ep.mp3',
      'created_at': '2026-08-01T00:00:00.000Z',
      'updated_at': '2026-08-01T00:00:00.000Z',
      'status': 'ready',
      'source_origin': 'podcast',
      'transcript_acquisition_mode': 'publisherWordTimed',
    });

    expect(
      restored.transcriptAcquisitionMode,
      TranscriptAcquisitionMode.publisherCaptions,
    );
    expect(restored.transcriptAcquisitionMode.usesPublisherTranscript, isTrue);
  });

  test('Inbox monitor configuration and ledger persist atomically', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'listenook-monitor-store-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final paths = AppPaths.forTesting(temporary.path);
    final repository = JsonInboxMonitorRepository(paths);
    final now = DateTime.utc(2026, 8, 14);
    final fingerprint = SourceFingerprint(
      identity: '/watch/clip.mp4',
      path: '/watch/clip.mp4',
      sizeBytes: 99,
      modifiedAt: now,
    );
    final storage = InboxMonitorStorage(
      config: const InboxMonitorConfig(
        folderPath: '/watch',
        paused: true,
        extensions: {'wav', 'mp4'},
        launchAtLogin: true,
        showTrayIcon: false,
      ),
      records: {
        fingerprint.identity: MonitoredFileRecord(
          fingerprint: fingerprint,
          disposition: MonitoredFileDisposition.dismissed,
          updatedAt: now,
          jobId: 'job-1',
        ),
      },
    );

    await repository.save(storage);
    final restored = await repository.load();

    expect(restored.config.folderPath, '/watch');
    expect(restored.config.paused, isTrue);
    expect(restored.config.extensions, {'wav', 'mp4'});
    expect(restored.config.launchAtLogin, isTrue);
    expect(restored.config.showTrayIcon, isFalse);
    expect(InboxMonitorConfig.fromJson(const {}).showTrayIcon, isTrue);
    expect(
      restored.records[fingerprint.identity]?.disposition,
      MonitoredFileDisposition.dismissed,
    );
    expect(await paths.inboxMonitor.exists(), isTrue);
    expect(
      temporary.listSync().whereType<File>().any(
        (file) => file.path.endsWith('.tmp'),
      ),
      isFalse,
    );
  });

  test(
    'version 6 manifests preserve library metadata without renaming source',
    () {
      final now = DateTime.utc(2026, 8, 13);
      final job = TranscriptionJob(
        id: 'organized',
        batchId: 'batch',
        sourcePath: '/recordings/original.wav',
        createdAt: now,
        updatedAt: now,
        status: JobStatus.completed,
        displayTitle: 'Weekly sync',
        groupId: 'work',
        tagIds: const {'important', 'meeting'},
      );

      final json = job.toJson();
      final restored = TranscriptionJob.fromJson(json);

      expect(json['manifest_version'], manifestVersion);
      expect(restored.sourcePath, '/recordings/original.wav');
      expect(restored.fileName, 'original.wav');
      expect(restored.displayName, 'Weekly sync');
      expect(restored.groupId, 'work');
      expect(restored.tagIds, {'important', 'meeting'});
    },
  );

  test('version 6 manifests round-trip translation without credentials', () {
    final now = DateTime.utc(2026, 8, 11);
    final job = TranscriptionJob(
      id: 'translated',
      batchId: 'batch',
      sourcePath: '/recording.wav',
      createdAt: now,
      updatedAt: now,
      status: JobStatus.completed,
      options: const TranscriptionOptions(
        sonioxTranslation: SonioxTranslationOptions(
          enabled: true,
          targetLanguage: 'zh',
        ),
      ),
      document: TranscriptDocument(
        tokens: const [
          TranscriptToken(
            text: '你好',
            startMs: 0,
            endMs: 0,
            language: 'zh',
            sourceLanguage: 'en',
            translationStatus: 'translation',
          ),
        ],
        segments: const [
          TranscriptSegment(
            id: 'one',
            startMs: 0,
            endMs: 500,
            text: 'Hello',
            translatedText: '你好',
          ),
        ],
        speakers: const [],
        updatedAt: now,
      ),
      translationOptions: const TranslationOptions(
        enabled: true,
        targetLanguage: 'zh-Hans',
        baseUrl: 'https://example.com/v1',
        model: 'example-model',
      ),
      translationState: const TranslationState(
        status: TranslationStatus.completed,
        targetLanguage: 'zh-Hans',
        model: 'example-model',
        origin: TranslationOrigin.llm,
        completedSegments: 1,
        totalSegments: 1,
      ),
    );

    final json = job.toJson();
    final restored = TranscriptionJob.fromJson(json);

    expect(json['manifest_version'], manifestVersion);
    expect(job.toJsonString(), isNot(contains('api_key')));
    expect(restored.document!.segments.single.translatedText, '你好');
    expect(restored.translationState.status, TranslationStatus.completed);
    expect(restored.translationState.origin, TranslationOrigin.llm);
    expect(restored.options.sonioxTranslation.enabled, isTrue);
    expect(restored.options.sonioxTranslation.targetLanguage, 'zh');
    expect(restored.document!.tokens.single.translationStatus, 'translation');
    expect(restored.document!.tokens.single.sourceLanguage, 'en');
    expect(const AppSettings().toJson().toString(), isNot(contains('api_key')));

    final appSettings = AppSettings.fromJson(
      const AppSettings(
        sonioxTranslation: SonioxTranslationOptions(
          enabled: true,
          targetLanguage: 'ja',
        ),
      ).toJson(),
    );
    expect(appSettings.sonioxTranslation.enabled, isTrue);
    expect(appSettings.sonioxTranslation.targetLanguage, 'ja');
  });

  test('version 6 manifests round-trip evidence-backed AI Briefs', () {
    final now = DateTime.utc(2026, 8, 12);
    final job = TranscriptionJob(
      id: 'brief',
      batchId: 'batch',
      sourcePath: '/recording.wav',
      createdAt: now,
      updatedAt: now,
      status: JobStatus.completed,
      document: TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 's1',
            startMs: 0,
            endMs: 1000,
            text: 'Supported statement.',
          ),
        ],
        speakers: const [],
        updatedAt: now,
      ),
      aiBrief: AiBrief(
        overview: 'Overview',
        overviewEvidenceSegmentIds: const ['s1'],
        chapters: const [
          AiChapter(
            id: 'c1',
            title: 'Opening',
            summary: 'Summary',
            evidenceSegmentIds: ['s1'],
          ),
        ],
        insights: const [
          AiInsight(
            id: 'i1',
            type: AiInsightType.actionItem,
            text: 'Follow up.',
            evidenceSegmentIds: ['s1'],
          ),
        ],
        languageNotes: const [
          AiLanguageNote(
            id: 'l1',
            kind: AiLanguageNoteKind.expression,
            term: 'Supported statement',
            explanation: 'A reusable expression.',
            sourceExcerpt: 'Supported statement.',
            evidenceSegmentIds: ['s1'],
          ),
        ],
        learningLanguage: 'en',
        learningLevel: AiLearningLevel.advanced,
        outputLanguage: 'en',
        model: 'brief-model',
        selectedSections: const {
          AiBriefSection.overview,
          AiBriefSection.actionItems,
          AiBriefSection.languageNotes,
        },
        generatedAt: now,
        sourceTranscriptUpdatedAt: now,
      ),
      aiGenerationState: const AiGenerationState(
        status: AiGenerationStatus.completed,
        model: 'brief-model',
        outputLanguage: 'en',
        learningLanguage: 'en',
        learningLevel: AiLearningLevel.advanced,
        selectedSections: {
          AiBriefSection.overview,
          AiBriefSection.languageNotes,
        },
      ),
    );

    final json = job.toJson();
    final restored = TranscriptionJob.fromJson(json);

    expect(restored.aiBrief?.overviewEvidenceSegmentIds, ['s1']);
    expect(restored.aiBrief?.chapters.single.title, 'Opening');
    expect(restored.aiBrief?.insights.single.type, AiInsightType.actionItem);
    expect(
      restored.aiBrief?.languageNotes.single.kind,
      AiLanguageNoteKind.expression,
    );
    expect(restored.aiBrief?.learningLanguage, 'en');
    expect(restored.aiBrief?.learningLevel, AiLearningLevel.advanced);
    expect(restored.aiGenerationState.status, AiGenerationStatus.completed);
    expect(restored.aiGenerationState.learningLanguage, 'en');
    expect(restored.aiGenerationState.learningLevel, AiLearningLevel.advanced);
    expect(job.toJsonString(), isNot(contains('api_key')));
  });

  test('older AI Brief JSON uses backward-compatible learning defaults', () {
    final restored = AiBrief.fromJson({
      'overview': 'Legacy brief',
      'chapters': <Object>[],
      'insights': <Object>[],
      'output_language': 'en',
      'model': 'brief-model',
      'selected_sections': ['overview'],
      'generated_at': '2026-08-12T00:00:00.000Z',
      'source_transcript_updated_at': '2026-08-12T00:00:00.000Z',
    });

    expect(restored.languageNotes, isEmpty);
    expect(restored.learningLanguage, isNull);
    expect(restored.learningLevel, AiLearningLevel.intermediate);
    expect(
      restored.selectedSections,
      isNot(contains(AiBriefSection.languageNotes)),
    );
  });

  test('job persistence is atomic and round-trips edits', () async {
    final temporary = await Directory.systemTemp.createTemp('listenook-test-');
    addTearDown(() => temporary.delete(recursive: true));
    final repository = LocalJobRepository(AppPaths.forTesting(temporary.path));
    final now = DateTime.utc(2026, 1, 2);
    final job = TranscriptionJob(
      id: 'job_safe',
      batchId: 'batch',
      sourcePath: '/tmp/猫.wav',
      createdAt: now,
      updatedAt: now,
      status: JobStatus.completed,
      document: TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 's1',
            startMs: 1,
            endMs: 999,
            text: 'Edited text',
            speaker: '1',
          ),
        ],
        speakers: const [SpeakerProfile(id: '1', name: 'Ada')],
        updatedAt: now,
      ),
    );

    await repository.save(job);
    final loaded = await repository.loadAll();
    expect(loaded.single.document!.segments.single.text, 'Edited text');
    expect(loaded.single.document!.speakers.single.name, 'Ada');
    expect(
      File('${temporary.path}/jobs/job_safe/manifest.json.tmp').existsSync(),
      isFalse,
    );
  });

  test(
    'library catalog atomically persists reusable empty organizers',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'listenook-library-catalog-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final paths = AppPaths.forTesting(temporary.path);
      final repository = JsonLibraryCatalogRepository(paths);

      await repository.save(
        const LibraryCatalog(
          groups: [LibraryGroup(id: 'group-work', name: 'Work')],
          tags: [LibraryTag(id: 'tag-urgent', name: 'Urgent')],
        ),
      );
      final restored = await repository.load();

      expect(restored.groups.single.name, 'Work');
      expect(restored.tags.single.name, 'Urgent');
      expect(
        File('${temporary.path}/library_catalog.json.tmp').existsSync(),
        isFalse,
      );
    },
  );

  test(
    'missing or corrupt catalogs do not prevent jobs from loading',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'listenook-corrupt-library-catalog-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final paths = AppPaths.forTesting(temporary.path);
      final catalogRepository = JsonLibraryCatalogRepository(paths);
      final jobRepository = LocalJobRepository(paths);
      final now = DateTime.utc(2026, 8, 13);
      await jobRepository.save(
        TranscriptionJob(
          id: 'survives',
          batchId: 'batch',
          sourcePath: '/recordings/survives.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
        ),
      );

      expect((await catalogRepository.load()).groups, isEmpty);
      await paths.libraryCatalog.writeAsString('{not-json');

      expect((await catalogRepository.load()).tags, isEmpty);
      expect((await jobRepository.loadAll()).single.id, 'survives');
    },
  );

  test('concurrent progress and stage saves do not collide', () async {
    final temporary = await Directory.systemTemp.createTemp('listenook-race-');
    addTearDown(() => temporary.delete(recursive: true));
    final repository = LocalJobRepository(AppPaths.forTesting(temporary.path));
    final now = DateTime.utc(2026, 8, 11);
    final job = TranscriptionJob(
      id: 'converting_job',
      batchId: 'batch',
      sourcePath: '/tmp/video.mp4',
      createdAt: now,
      updatedAt: now,
      status: JobStatus.converting,
    );
    await repository.save(job);

    final updates = List.generate(
      32,
      (index) => job.copyWith(
        status: index == 31 ? JobStatus.uploading : JobStatus.converting,
        progress: JobProgress(
          stage: index == 31 ? 'uploading' : 'converting',
          fraction: index / 31,
        ),
      ),
    );
    await Future.wait(updates.map(repository.save));

    final loaded = await repository.loadAll();
    expect(loaded.single.status, JobStatus.uploading);
    expect(
      File(
        '${temporary.path}/jobs/converting_job/manifest.json.tmp',
      ).existsSync(),
      isFalse,
    );
  });
}
