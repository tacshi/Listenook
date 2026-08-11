import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/models.dart';
import 'package:meow_stt/data/local_repositories.dart';
import 'package:meow_stt/data/process_media_service.dart';
import 'package:meow_stt/data/waveform_renderer.dart';

void main() {
  test('input policy is restricted to the requested seven formats', () {
    expect(ProcessMediaService.supportedAudioExtensions, {
      '.mp3',
      '.wav',
      '.m4a',
      '.ogg',
    });
    expect(ProcessMediaService.supportedVideoExtensions, {
      '.mp4',
      '.mkv',
      '.avi',
    });
  });

  test('video is always extracted and never uploaded as a fallback', () async {
    final root = await Directory.systemTemp.createTemp('meow-media-policy-');
    addTearDown(() => root.delete(recursive: true));
    final service = ProcessMediaService(AppPaths.forTesting(root.path));
    const audio = MediaMetadata(
      sizeBytes: 1,
      durationMs: 1000,
      hasAudio: true,
      hasVideo: false,
      formatName: 'mp3',
    );
    const video = MediaMetadata(
      sizeBytes: 1,
      durationMs: 1000,
      hasAudio: true,
      hasVideo: true,
      formatName: 'matroska',
    );
    expect(service.canUploadDirectly('voice.mp3', audio), isTrue);
    expect(service.canUploadDirectly('voice.flac', audio), isFalse);
    expect(service.canUploadDirectly('clip.mp4', video), isFalse);
    expect(service.canUploadDirectly('renamed.mp3', video), isFalse);
  });

  test('PCM waveform renderer streams peaks and writes a valid PNG', () async {
    final root = await Directory.systemTemp.createTemp('meow-waveform-');
    addTearDown(() => root.delete(recursive: true));
    final wav = File('${root.path}/input.wav');
    final png = File('${root.path}/output.png');
    await wav.writeAsBytes(
      _pcmWave(<int>[0, 1000, -2000, -3000, 32767, 1, -10, -20]),
    );

    expect(await readPcm16MonoPeaks(wav.path, 4), [1000, 3000, 32767, 20]);
    await renderPcmWaveform(wav.path, png.path, width: 4, height: 8);
    final bytes = await png.readAsBytes();
    expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    expect(bytes.length, greaterThan(50));
  });

  test(
    'PCM waveform renderer accepts libmpv extensible WAVE headers',
    () async {
      final root = await Directory.systemTemp.createTemp('meow-waveform-ext-');
      addTearDown(() => root.delete(recursive: true));
      final wav = File('${root.path}/input.wav');
      await wav.writeAsBytes(_extensiblePcmWave(<int>[0, -32768, 100, -200]));
      expect(await readPcm16MonoPeaks(wav.path, 2), [32768, 200]);
    },
  );

  test('generated media cleanup removes only job-owned cache files', () async {
    final root = await Directory.systemTemp.createTemp('meow-media-cleanup-');
    addTearDown(() => root.delete(recursive: true));
    final paths = AppPaths.forTesting(root.path);
    await paths.temporary.create(recursive: true);
    final audio = File('${paths.temporary.path}/job.flac');
    final macAudio = File('${paths.temporary.path}/job.m4a');
    final extraction = File('${paths.temporary.path}/job-extract.wav');
    final waveformPcm = File('${paths.temporary.path}/job-waveform.wav');
    final waveform = File('${paths.temporary.path}/job-waveform.png');
    final unrelated = File('${paths.temporary.path}/other.flac');
    for (final file in [
      audio,
      macAudio,
      extraction,
      waveformPcm,
      waveform,
      unrelated,
    ]) {
      await file.writeAsBytes([1]);
    }

    await ProcessMediaService(paths).deleteGeneratedMedia('job');

    expect(await audio.exists(), isFalse);
    expect(await macAudio.exists(), isFalse);
    expect(await extraction.exists(), isFalse);
    expect(await waveformPcm.exists(), isFalse);
    expect(await waveform.exists(), isFalse);
    expect(await unrelated.exists(), isTrue);

    final orphan = File('${paths.temporary.path}/orphan-waveform.png');
    await orphan.writeAsBytes([4]);
    await ProcessMediaService(paths).clearGeneratedMediaExcept({'other'});

    expect(await unrelated.exists(), isTrue);
    expect(await orphan.exists(), isFalse);
  });
}

Uint8List _pcmWave(List<int> samples) {
  final dataLength = samples.length * 2;
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
  bytes.setUint32(24, 8000, Endian.little);
  bytes.setUint32(28, 16000, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bytes.setUint32(40, dataLength, Endian.little);
  for (var index = 0; index < samples.length; index++) {
    bytes.setInt16(44 + index * 2, samples[index], Endian.little);
  }
  return bytes.buffer.asUint8List();
}

Uint8List _extensiblePcmWave(List<int> samples) {
  final dataLength = samples.length * 2;
  final bytes = ByteData(68 + dataLength);
  void ascii(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      bytes.setUint8(offset + index, value.codeUnitAt(index));
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, 60 + dataLength, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bytes.setUint32(16, 40, Endian.little);
  bytes.setUint16(20, 0xfffe, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, 8000, Endian.little);
  bytes.setUint32(28, 16000, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  bytes.setUint16(36, 22, Endian.little);
  bytes.setUint16(38, 16, Endian.little);
  bytes.setUint32(40, 4, Endian.little);
  bytes.setUint32(44, 1, Endian.little);
  bytes.setUint16(48, 0, Endian.little);
  bytes.setUint16(50, 0x0010, Endian.little);
  for (final entry in const <int>[
    0x80,
    0,
    0,
    0xaa,
    0,
    0x38,
    0x9b,
    0x71,
  ].indexed) {
    bytes.setUint8(52 + entry.$1, entry.$2);
  }
  ascii(60, 'data');
  bytes.setUint32(64, dataLength, Endian.little);
  for (var index = 0; index < samples.length; index++) {
    bytes.setInt16(68 + index * 2, samples[index], Endian.little);
  }
  return bytes.buffer.asUint8List();
}
