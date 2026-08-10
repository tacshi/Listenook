import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/contracts.dart';
import 'package:meow_stt/core/models.dart';
import 'package:meow_stt/data/transcript_exporter.dart';
import 'package:meow_stt/state/app_controller.dart';

void main() {
  test(
    'worker pool respects configured concurrency and persists completion',
    () async {
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

      expect(soniox.maximumUploads, 2);
      expect(controller.completedCount, 4);
      expect(
        jobs.saved.values.every(
          (job) => job.cleanupState == CleanupState.complete,
        ),
        isTrue,
      );
      expect(soniox.deletedFiles, hasLength(4));
      expect(soniox.deletedTranscriptions, hasLength(4));
    },
  );

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
      await controller.addSources([completedFile.path]);
      await _waitFor(() => controller.readyCount == 1);
      await controller.startReady();
      final completed = controller.workspaceJobs.single;

      await controller.addSources([draftFile.path]);
      await _waitFor(() => controller.readyCount == 1);
      expect(controller.untranscribedWorkspaceCount, 1);

      await controller.startNewSession();

      expect(controller.workspaceJobs, isEmpty);
      expect(controller.allJobs.map((job) => job.id), [completed.id]);
      expect(jobs.saved.keys, [completed.id]);

      await controller.addSources([nextFile.path]);
      await _waitFor(() => controller.readyCount == 1);
      expect(controller.workspaceJobs.single.batchId, isNot(completed.batchId));
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
}

AppController _controller({required _Jobs jobs, required _Soniox soniox}) =>
    AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: jobs,
      mediaService: _Media(),
      sonioxClient: soniox,
      exporter: const DefaultTranscriptExporter(),
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

class _Settings implements SettingsRepository {
  AppSettings value = const AppSettings(concurrency: 2);

  @override
  Future<AppSettings> load() async => value;

  @override
  Future<void> save(AppSettings settings) async => value = settings;
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
  @override
  bool canUploadDirectly(String path, MediaMetadata metadata) => true;

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

class _Soniox implements SonioxClient {
  _Soniox({this.uploadDelay = Duration.zero});
  final Duration uploadDelay;
  int currentUploads = 0;
  int maximumUploads = 0;
  int uploadCalls = 0;
  final deletedFiles = <String>[];
  final deletedTranscriptions = <String>[];

  @override
  Future<String> createTranscription(
    String fileId,
    TranscriptionOptions options,
  ) async => 'tx-$fileId';

  @override
  Future<void> deleteFile(String id) async => deletedFiles.add(id);

  @override
  Future<void> deleteTranscription(String id) async =>
      deletedTranscriptions.add(id);

  @override
  Future<Map<String, dynamic>> getTranscript(String id) async => {
    'tokens': [
      {'text': 'Done.', 'start_ms': 0, 'end_ms': 800, 'speaker': '1'},
    ],
  };

  @override
  Future<SonioxTranscriptionState> getTranscription(String id) async =>
      const SonioxTranscriptionState(status: 'completed');

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
