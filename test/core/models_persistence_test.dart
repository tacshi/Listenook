import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/models.dart';
import 'package:meow_stt/data/local_repositories.dart';

void main() {
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
  });

  test('version 3 manifests round-trip translation without credentials', () {
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

    expect(json['manifest_version'], 3);
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

  test('job persistence is atomic and round-trips edits', () async {
    final temporary = await Directory.systemTemp.createTemp('meowstt-test-');
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

  test('concurrent progress and stage saves do not collide', () async {
    final temporary = await Directory.systemTemp.createTemp('meowstt-race-');
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
