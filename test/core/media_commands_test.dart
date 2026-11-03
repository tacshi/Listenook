import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/contracts.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/data/local_repositories.dart';
import 'package:listenook/data/process_media_service.dart';
import 'package:listenook/data/waveform_renderer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('compact speech profile keeps only efficient lossy audio direct', () {
    final service = ProcessMediaService(
      AppPaths.forTesting(Directory.systemTemp.path),
    );
    const compactAac = MediaMetadata(
      sizeBytes: 360000,
      durationMs: 60000,
      hasAudio: true,
      hasVideo: false,
      formatName: 'm4a',
      audioCodec: 'aac',
    );
    const highBitrateAac = MediaMetadata(
      sizeBytes: 1200000,
      durationMs: 60000,
      hasAudio: true,
      hasVideo: false,
      formatName: 'm4a',
      audioCodec: 'aac',
    );
    const losslessM4a = MediaMetadata(
      sizeBytes: 360000,
      durationMs: 60000,
      hasAudio: true,
      hasVideo: false,
      formatName: 'm4a',
      audioCodec: 'alac',
    );

    if (Platform.isMacOS) {
      expect(
        service.canUploadDirectly(
          'compact.m4a',
          compactAac,
          profile: MediaUploadProfile.compactSpeech,
        ),
        isTrue,
      );
      expect(
        service.canUploadDirectly(
          'large.m4a',
          highBitrateAac,
          profile: MediaUploadProfile.compactSpeech,
        ),
        isFalse,
      );
      expect(
        service.canUploadDirectly(
          'lossless.m4a',
          losslessM4a,
          profile: MediaUploadProfile.compactSpeech,
        ),
        isFalse,
      );
      expect(
        service.canUploadDirectly(
          'speech.wav',
          compactAac,
          profile: MediaUploadProfile.compactSpeech,
        ),
        isFalse,
      );
    }
    expect(service.canUploadDirectly('large.m4a', highBitrateAac), isTrue);
  });

  test(
    'macOS compact encoder sends the AAC contract to the native channel',
    () async {
      const channel = MethodChannel('app.listenook.test/audio_encoder');
      MethodCall? received;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            received = call;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      await const AppleAudioEncoder(channel: channel).encodeAac(
        inputPath: '/tmp/input.wav',
        outputPath: '/tmp/output.m4a',
        bitRate: 48000,
      );

      expect(received?.method, 'encodeAac');
      expect(received?.arguments, {
        'inputPath': '/tmp/input.wav',
        'outputPath': '/tmp/output.m4a',
        'bitRate': 48000,
      });
    },
  );

  test('iOS encodes uploads with AVFoundation like macOS', () {
    final ios = ProcessMediaService(
      AppPaths.forTesting(Directory.systemTemp.path),
      host: MediaHost.iOS,
    );
    final windows = ProcessMediaService(
      AppPaths.forTesting(Directory.systemTemp.path),
      host: MediaHost.windows,
    );
    const highBitrateAac = MediaMetadata(
      sizeBytes: 1200000,
      durationMs: 60000,
      hasAudio: true,
      hasVideo: false,
      formatName: 'm4a',
      audioCodec: 'aac',
    );
    // Compact AAC exists on Apple platforms, so a large file is re-encoded.
    expect(
      ios.canUploadDirectly(
        'large.m4a',
        highBitrateAac,
        profile: MediaUploadProfile.compactSpeech,
      ),
      isFalse,
    );
    expect(
      windows.canUploadDirectly(
        'large.m4a',
        highBitrateAac,
        profile: MediaUploadProfile.compactSpeech,
      ),
      isTrue,
    );
    expect(MediaHost.iOS.apple, isTrue);
    expect(MediaHost.windows.apple, isFalse);
  });

  test('the lossless encoder sends the ALAC contract to the channel', () async {
    const channel = MethodChannel('app.listenook.test/audio_encoder_alac');
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await const AppleAudioEncoder(
      channel: channel,
    ).encodeAlac(inputPath: '/tmp/input.wav', outputPath: '/tmp/output.m4a');

    expect(received?.method, 'encodeAlac');
    expect(received?.arguments, {
      'inputPath': '/tmp/input.wav',
      'outputPath': '/tmp/output.m4a',
    });
  });

  test('PCM waveform levels stream loudness per bucket', () async {
    final root = await Directory.systemTemp.createTemp('meow-waveform-');
    addTearDown(() => root.delete(recursive: true));
    final wav = File('${root.path}/input.wav');
    final levels = File('${root.path}/output.levels');
    await wav.writeAsBytes(
      _pcmWave(<int>[0, 1000, -2000, -3000, 32767, 1, -10, -20]),
    );

    expect(await readPcm16MonoPeaks(wav.path, 4), [1000, 3000, 32767, 20]);
    expect((await readPcm16MonoEnvelope(wav.path, 4)).rms, [
      707,
      2550,
      23170,
      16,
    ]);
    await writePcmWaveformLevels(wav.path, levels.path, buckets: 4);
    expect(await levels.readAsBytes(), [16, 44, 255, 1]);
  });

  test('speech energy has one half-decibel level per 10ms frame', () async {
    final root = await Directory.systemTemp.createTemp('meow-energy-');
    addTearDown(() => root.delete(recursive: true));
    final wav = File('${root.path}/input.wav');
    final energy = File('${root.path}/output.energy');
    await wav.writeAsBytes(
      _pcmWave(<int>[
        ...List<int>.filled(80, 1000),
        ...List<int>.filled(80, 0),
        ...List<int>.filled(40, 100),
      ]),
    );

    await writePcmSpeechEnergy(wav.path, energy.path);

    expect(await energy.readAsBytes(), [120, 0, 80]);
  });

  test('waveform levels are not flattened by an isolated burst', () {
    final rms = Uint16List.fromList([
      for (var index = 0; index < 99; index++) 1000,
      30000,
      250,
    ]);

    final levels = waveformLevels(rms);

    expect(levels.take(100), everyElement(255));
    expect(levels.last, inInclusiveRange(60, 100));
  });

  test('silent audio has flat waveform levels', () {
    expect(waveformLevels(Uint16List(3)), [0, 0, 0]);
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

  test('files outside the jobs keep their 20 most recent analyses', () async {
    final root = await Directory.systemTemp.createTemp('meow-file-energy-');
    addTearDown(() => root.delete(recursive: true));
    final paths = AppPaths.forTesting(root.path);
    await paths.temporary.create(recursive: true);
    final video = File('${root.path}/movie.mkv')..writeAsBytesSync([1]);
    final long = DateTime.now().subtract(const Duration(days: 30));
    await video.setLastModified(long);
    final key =
        'file-${sha1.convert(utf8.encode(video.absolute.path)).toString().substring(0, 20)}';
    final cached = File('${paths.temporary.path}/$key-speech-v1.energy')
      ..writeAsBytesSync([1, 2, 3]);
    final older = [
      for (var index = 0; index < 20; index++)
        File('${paths.temporary.path}/file-$index-speech-v1.energy')
          ..writeAsBytesSync([1])
          ..setLastModifiedSync(long.add(Duration(minutes: index))),
    ];
    final jobEnergy = File('${paths.temporary.path}/job-speech-v1.energy')
      ..writeAsBytesSync([1])
      ..setLastModifiedSync(long);
    await cached.setLastModified(long.add(const Duration(days: 1)));

    final path = await ProcessMediaService(
      paths,
    ).analyzeFileSpeechEnergy(video.path);

    expect(path, cached.path);
    expect(await cached.readAsBytes(), [1, 2, 3]);
    expect(await older.first.exists(), isFalse);
    expect(await older[1].exists(), isTrue);
    expect(await older.last.exists(), isTrue);
    expect(await jobEnergy.exists(), isTrue);
  });

  test('generated media cleanup removes only job-owned cache files', () async {
    final root = await Directory.systemTemp.createTemp('meow-media-cleanup-');
    addTearDown(() => root.delete(recursive: true));
    final paths = AppPaths.forTesting(root.path);
    await paths.temporary.create(recursive: true);
    final audio = File('${paths.temporary.path}/job.flac');
    final macAudio = File('${paths.temporary.path}/job.m4a');
    final extraction = File('${paths.temporary.path}/job-extract.wav');
    final waveformPcm = File('${paths.temporary.path}/job-waveform.wav');
    final levels = File('${paths.temporary.path}/job-waveform-v4.levels');
    final speechEnergy = File('${paths.temporary.path}/job-speech-v1.energy');
    final currentWaveform = File('${paths.temporary.path}/job-waveform-v3.png');
    final priorWaveform = File('${paths.temporary.path}/job-waveform-v2.png');
    final waveform = File('${paths.temporary.path}/job-waveform.png');
    final unrelated = File('${paths.temporary.path}/other.flac');
    for (final file in [
      audio,
      macAudio,
      extraction,
      waveformPcm,
      levels,
      speechEnergy,
      currentWaveform,
      priorWaveform,
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
    expect(await levels.exists(), isFalse);
    expect(await speechEnergy.exists(), isFalse);
    expect(await currentWaveform.exists(), isFalse);
    expect(await priorWaveform.exists(), isFalse);
    expect(await waveform.exists(), isFalse);
    expect(await unrelated.exists(), isTrue);
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

/// The largest magnitude in each of [width] buckets.
Future<Uint16List> readPcm16MonoPeaks(String path, int width) async {
  final envelope = await readPcm16MonoEnvelope(path, width);
  final peaks = Uint16List(width);
  for (var index = 0; index < width; index++) {
    final negative = envelope.minima[index] == -32768
        ? 32768
        : envelope.minima[index].abs();
    peaks[index] = math.max(negative, envelope.maxima[index]);
  }
  return peaks;
}
