import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/models.dart';
import 'package:meow_stt/data/local_repositories.dart';

void main() {
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
}
