import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/contracts.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/data/soniox_api_client.dart';

void main() {
  final key = Platform.environment['SONIOX_API_KEY']?.trim();
  test(
    'live Soniox upload, async transcription, transcript fetch, and cleanup',
    () async {
      final directory = await Directory.systemTemp.createTemp('meow-live-');
      final audio = File('${directory.path}/silence.wav');
      await audio.writeAsBytes(_silentWav());
      final client = SonioxApiClient(_EnvironmentCredential(key!));
      String? fileId;
      String? transcriptionId;
      try {
        await client.validateKey();
        fileId = await client.uploadFile(audio.path);
        transcriptionId = await client.createTranscription(
          fileId,
          const TranscriptionOptions(languageHints: ['en']),
        );
        while (true) {
          final status = await client.getTranscription(transcriptionId);
          if (status.isComplete) {
            break;
          }
          if (status.isFailed) {
            fail(status.errorMessage ?? status.errorType ?? 'Soniox error');
          }
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        expect(await client.getTranscript(transcriptionId), contains('tokens'));
      } finally {
        if (transcriptionId != null) {
          await client.deleteTranscription(transcriptionId);
        }
        if (fileId != null) {
          await client.deleteFile(fileId);
        }
        await directory.delete(recursive: true);
      }
    },
    skip: key == null || key.isEmpty
        ? 'Set SONIOX_API_KEY to opt into billable live smoke testing.'
        : false,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

Uint8List _silentWav() {
  const sampleRate = 16000;
  const seconds = 2;
  final dataLength = sampleRate * seconds * 2;
  final bytes = ByteData(44 + dataLength);
  void ascii(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      bytes.setUint8(offset + index, value.codeUnitAt(index));
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataLength, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bytes.setUint32(40, dataLength, Endian.little);
  return bytes.buffer.asUint8List();
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
