import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:listenook/core/contracts.dart';
import 'package:listenook/data/local_repositories.dart';
import 'package:listenook/data/process_media_service.dart';
import 'package:media_kit/media_kit.dart';

import 'support/results_file.dart';

/// Runs the real libmpv and encoder pipeline on the device (iOS has no
/// command-line encoders): inspect, PCM extraction, upload encoding and the
/// waveform.
void main() {
  saveResultsWhenDone(IntegrationTestWidgetsFlutterBinding.ensureInitialized());
  MediaKit.ensureInitialized();

  late Directory root;
  late ProcessMediaService media;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('listenook-media-pipeline-');
    media = ProcessMediaService(AppPaths.forTesting(root.path));
  });

  tearDown(() => root.delete(recursive: true));

  testWidgets('a WAV is inspected, decoded and encoded for upload', (
    tester,
  ) async {
    // 44.1 kHz stereo, like real recordings: extraction must resample and
    // downmix to 16 kHz mono.
    final source = File('${root.path}/tone.wav');
    await source.writeAsBytes(
      _toneWav(seconds: 3, sampleRate: 44100, channels: 2),
    );

    // Each step gets its own limit, so a hang names the step that hung.
    Future<T> step<T>(String name, Future<T> Function() run) => run().timeout(
      const Duration(seconds: 90),
      onTimeout: () => throw TimeoutException('$name did not finish'),
    );

    final metadata = await step('inspect', () => media.inspect(source.path));
    expect(metadata.hasAudio, isTrue);
    expect(metadata.durationMs, closeTo(3000, 200));

    final pcm = await step(
      'PCM extraction',
      () => media.extractPcm16kMono(
        source.path,
        'pipeline-pcm',
        durationMs: metadata.durationMs,
      ),
    );
    // 16 kHz mono 16-bit: about 32 kB per second plus the header.
    expect(await File(pcm).length(), greaterThan(80000));

    for (final profile in MediaUploadProfile.values) {
      final upload = await step(
        '${profile.name} upload encoding',
        () => media.extractAudio(
          source.path,
          'pipeline-${profile.name}',
          durationMs: metadata.durationMs,
          profile: profile,
        ),
      );
      expect(upload, endsWith(Platform.isWindows ? '.flac' : '.m4a'));
      expect(await File(upload).length(), greaterThan(0));
      final encoded = await step('inspect upload', () => media.inspect(upload));
      expect(encoded.durationMs, closeTo(3000, 300));
    }

    await step(
      'speech energy',
      () => media.analyzeSpeechEnergy(source.path, 'pipeline-energy'),
    );
    final waveform = await step(
      'waveform',
      () => media.renderWaveform(source.path, 'pipeline-wave'),
    );
    expect(await File(waveform).length(), greaterThan(0));

    final diagnostics = await step('diagnostics', media.diagnostics);
    expect(diagnostics.available, isTrue, reason: diagnostics.error);
  });
}

List<int> _toneWav({
  required int seconds,
  int sampleRate = 16000,
  int channels = 1,
}) {
  final frames = sampleRate * seconds;
  final samples = frames * channels;
  final bytes = ByteData(44 + samples * 2);
  var offset = 0;
  void ascii(String value) {
    for (final unit in value.codeUnits) {
      bytes.setUint8(offset++, unit);
    }
  }

  void uint16(int value) {
    bytes.setUint16(offset, value, Endian.little);
    offset += 2;
  }

  void uint32(int value) {
    bytes.setUint32(offset, value, Endian.little);
    offset += 4;
  }

  ascii('RIFF');
  uint32(bytes.lengthInBytes - 8);
  ascii('WAVE');
  ascii('fmt ');
  uint32(16);
  uint16(1);
  uint16(channels);
  uint32(sampleRate);
  uint32(sampleRate * channels * 2);
  uint16(channels * 2);
  uint16(16);
  ascii('data');
  uint32(samples * 2);
  for (var i = 0; i < frames; i++) {
    final value = (math.sin(2 * math.pi * 440 * i / sampleRate) * 8000).round();
    for (var channel = 0; channel < channels; channel++) {
      bytes.setInt16(offset, value, Endian.little);
      offset += 2;
    }
  }
  return bytes.buffer.asUint8List();
}
