import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/contracts.dart';
import 'package:meow_stt/core/models.dart';
import 'package:meow_stt/data/moss_api_client.dart';

void main() {
  final key = Platform.environment['MOSS_API_KEY']?.trim();
  final canRun = Platform.isMacOS && key != null && key.isNotEmpty;
  test(
    'live MOSS Pro upload, diarized task polling, transcript, and cleanup',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'meow-moss-live-',
      );
      final aiff = '${directory.path}/speech.aiff';
      final audio = '${directory.path}/speech.wav';
      final client = MossApiClient(_EnvironmentCredential(key!));
      String? fileId;
      try {
        final spoken = await Process.run('say', [
          '-o',
          aiff,
          'Hello from Meow S T T. This is a MOSS Pro transcription test.',
        ]);
        expect(spoken.exitCode, 0, reason: spoken.stderr.toString());
        final converted = await Process.run('afconvert', [
          '-f',
          'WAVE',
          '-d',
          'LEI16@16000',
          aiff,
          audio,
        ]);
        expect(converted.exitCode, 0, reason: converted.stderr.toString());
        await client.validateKey();
        fileId = await client.uploadFile(audio);
        final taskId = await client.createTranscription(
          fileId,
          const TranscriptionOptions(),
        );
        while (true) {
          final state = await client.getTranscription(taskId);
          if (state.isComplete) break;
          if (state.isFailed) {
            fail(state.errorMessage ?? state.errorType ?? 'MOSS error');
          }
          await Future<void>.delayed(
            state.retryAfter ?? const Duration(seconds: 3),
          );
        }
        final document = const MossTranscriptParser().parse(
          await client.getTranscript(taskId),
        );
        expect(document.segments, isNotEmpty);
        expect(
          document.segments.any((segment) => segment.text.isNotEmpty),
          isTrue,
        );
        expect(document.speakers, isNotEmpty);
      } finally {
        if (fileId != null) await client.deleteFile(fileId);
        await directory.delete(recursive: true);
      }
    },
    skip: canRun
        ? false
        : 'Set MOSS_API_KEY on macOS to opt into billable live smoke testing.',
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

class _EnvironmentCredential implements CredentialStore {
  const _EnvironmentCredential(this.key);

  final String key;

  @override
  Future<void> deleteApiKey() async {}

  @override
  Future<String?> readApiKey() async => key;

  @override
  Future<void> writeApiKey(String key) async {}
}
