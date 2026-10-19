import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
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

      await const MacosCompactAudioEncoder(channel: channel).encodeAac(
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

  test('PCM waveform keeps quiet detail visible beside loud peaks', () async {
    final root = await Directory.systemTemp.createTemp('meow-waveform-range-');
    addTearDown(() => root.delete(recursive: true));
    final wav = File('${root.path}/input.wav');
    final png = File('${root.path}/output.png');
    await wav.writeAsBytes(_pcmWave(<int>[0, 32767, 8192, 2048, 512]));

    await renderPcmWaveform(wav.path, png.path, width: 5, height: 32);
    final rendered = image.decodePng(await png.readAsBytes());
    expect(rendered, isNotNull);
    final background = rendered!.getPixel(0, 0);
    final backgroundRgba = (
      background.r,
      background.g,
      background.b,
      background.a,
    );

    int paintedRows(int x) =>
        List<int>.generate(rendered.height, (y) => y).where((y) {
          final pixel = rendered.getPixel(x, y);
          return (pixel.r, pixel.g, pixel.b, pixel.a) != backgroundRgba;
        }).length;

    expect(paintedRows(1), greaterThanOrEqualTo(15));
    expect(paintedRows(2), greaterThanOrEqualTo(7));
    expect(paintedRows(3), greaterThanOrEqualTo(4));
    expect(paintedRows(4), greaterThanOrEqualTo(2));
  });

  test('PCM waveform overview is not saturated by isolated peaks', () async {
    final root = await Directory.systemTemp.createTemp(
      'meow-waveform-transients-',
    );
    addTearDown(() => root.delete(recursive: true));
    final wav = File('${root.path}/input.wav');
    final png = File('${root.path}/output.png');
    final samples = <int>[
      for (var bucket = 0; bucket < 8; bucket++) ...[
        32767,
        for (var index = 1; index < 64; index++) index.isEven ? 1024 : -1024,
      ],
    ];
    await wav.writeAsBytes(_pcmWave(samples));

    await renderPcmWaveform(wav.path, png.path, width: 8, height: 100);
    final rendered = image.decodePng(await png.readAsBytes())!;
    var painted = 0;
    for (final pixel in rendered) {
      if (pixel.a > 0) painted++;
    }

    expect(painted / (rendered.width * rendered.height), lessThan(0.35));
  });

  test('PCM waveform preserves the signed average envelope', () async {
    final root = await Directory.systemTemp.createTemp('meow-waveform-sign-');
    addTearDown(() => root.delete(recursive: true));
    final wav = File('${root.path}/input.wav');
    final png = File('${root.path}/output.png');
    await wav.writeAsBytes(_pcmWave(<int>[30000, -1000, 1000, -30000]));

    await renderPcmWaveform(wav.path, png.path, width: 2, height: 32);
    final rendered = image.decodePng(await png.readAsBytes())!;
    final background = rendered.getPixel(0, 0);
    final backgroundRgba = (
      background.r,
      background.g,
      background.b,
      background.a,
    );

    List<int> paintedRows(int x) =>
        List<int>.generate(rendered.height, (y) => y).where((y) {
          final pixel = rendered.getPixel(x, y);
          return (pixel.r, pixel.g, pixel.b, pixel.a) != backgroundRgba;
        }).toList();

    final positiveHeavy = paintedRows(0);
    final negativeHeavy = paintedRows(1);
    expect(positiveHeavy.first, 5);
    expect(positiveHeavy.last, 18);
    expect(negativeHeavy.first, 14);
    expect(negativeHeavy.last, 26);
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
    final currentWaveform = File('${paths.temporary.path}/job-waveform-v3.png');
    final priorWaveform = File('${paths.temporary.path}/job-waveform-v2.png');
    final waveform = File('${paths.temporary.path}/job-waveform.png');
    final unrelated = File('${paths.temporary.path}/other.flac');
    for (final file in [
      audio,
      macAudio,
      extraction,
      waveformPcm,
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
