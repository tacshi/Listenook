import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('speech worker build and packaging stay pinned and arm64-only', () async {
    final root = Directory.current.path;
    final build = await File(
      '$root/scripts/build-speech-worker.sh',
    ).readAsString();
    final package = await File('$root/scripts/build-macos.sh').readAsString();
    final signing = await File('$root/scripts/macos-signing.sh').readAsString();
    final verification = await File(
      '$root/scripts/verify-macos-app.sh',
    ).readAsString();
    final manifest = await File(
      '$root/native/speech_worker/Package.swift',
    ).readAsString();
    final worker = await File(
      '$root/native/speech_worker/Sources/ListenookSpeechWorker/WorkerMain.swift',
    ).readAsString();

    expect(build, contains('13643ab4361da8f33c8002026c9d357ded0b6896'));
    expect(build, contains('swift build'));
    expect(build, contains('--configuration release'));
    expect(build, contains('--show-bin-path'));
    expect(
      build,
      isNot(contains(r'BINARY="$SCRATCH/arm64-apple-macosx/release')),
    );
    expect(build, contains('CoreML.framework'));
    expect(manifest, contains('.macOS("15.0")'));
    expect(manifest, contains('MossTranscribe'));
    expect(manifest, contains('Qwen3ASR'));
    expect(manifest, contains('SpeechVAD'));
    expect(manifest, contains('revision:'));
    expect(package, contains(r'$APP/Contents/Helpers/ListenookSpeechWorker'));
    expect(package, contains(r'$APP/Contents/Helpers/mlx.metallib'));
    expect(signing, contains("-name 'ListenookSpeechWorker'"));
    expect(signing, contains("-name '*.metallib'"));
    expect(verification, contains(r'lipo -archs "$SPEECH_WORKER"'));
    expect(
      verification,
      contains(r'codesign --verify --strict "$SPEECH_WORKER"'),
    );
    expect(build, contains('build_mlx_metallib.sh'));
    expect(build, contains('-showComponent MetalToolchain -json'));
    expect(build, contains('toolchainIdentifier'));
    expect(build, contains(r'TOOLCHAINS="$METAL_TOOLCHAIN_ID"'));
    expect(build, contains('== "MTLB"'));
    expect(verification, contains(r'[[ ! -s "$MLX_METALLIB" ]]'));
    expect(verification, contains('!= "MTLB"'));
    expect(
      verification,
      contains(r'codesign --verify --strict "$MLX_METALLIB"'),
    );
    expect(worker, contains('MossTranscribeModel.fromDirectory'));
    expect(worker, contains('case "transcribe-qwen3"'));
    expect(worker, contains('offlineMode: true'));
    expect(worker, contains('StreamingVADProcessor'));
    expect(worker, contains('let maximumSeconds = min(10'));
    expect(worker, isNot(contains('transcribeBatch(')));
    expect(worker, contains('transcribeDetailed('));
    expect(worker, contains('result.segments'));
    expect(worker, contains('result.metrics.stopReason'));
    expect(worker, contains('CoreMLForcedAligner.fromDirectory'));
    expect(
      worker,
      contains('(value["classify_num"] as? NSNumber)?.intValue == 5000'),
    );
    expect(worker, contains('let chunkSeconds = min(30'));
    expect(worker, contains('kill(expectedParent, 0)'));
    expect(worker, contains('_exit(74)'));
    expect(
      '$build\n$manifest\n$worker'.toLowerCase(),
      isNot(anyOf(contains('gguf'), contains('crispasr'))),
    );
  });

  final executable = Platform.environment['LISTENOOK_TEST_SPEECH_WORKER'];
  test(
    'native worker validates arguments and protocol with stable exit codes',
    () async {
      final invalid = await Process.run(executable!, ['unknown']);
      expect(invalid.exitCode, 2);

      final root = await Directory.systemTemp.createTemp(
        'meow-native-protocol-',
      );
      addTearDown(() => root.delete(recursive: true));
      final request = File('${root.path}/request.json');
      final output = File('${root.path}/output.json');
      await request.writeAsString(
        jsonEncode({'protocol': 999, 'parent_pid': pid}),
      );
      await output.create();
      final result = await Process.run(executable, [
        'transcribe-moss',
        '--request',
        request.path,
        '--output',
        output.path,
      ]);

      expect(result.exitCode, 3);
      final envelope = jsonDecode(await output.readAsString()) as Map;
      expect(envelope['protocol'], 1);
      expect(envelope['ok'], isFalse);
      expect(
        (envelope['error'] as Map)['code'],
        'local_worker_protocol_unsupported',
      );
    },
    skip: executable == null || !Platform.isMacOS,
  );

  test('native worker accepts mpv WAVE_FORMAT_EXTENSIBLE PCM', () async {
    final root = await Directory.systemTemp.createTemp(
      'meow-native-extensible-pcm-',
    );
    addTearDown(() => root.delete(recursive: true));
    final audio = File('${root.path}/audio.wav');
    final request = File('${root.path}/request.json');
    final output = File('${root.path}/output.json');
    await audio.writeAsBytes(_extensiblePcm16MonoWav());
    await request.writeAsString(
      jsonEncode({
        'protocol': 1,
        'parent_pid': pid,
        'audio_path': audio.path,
        'model_directory': '${root.path}/missing-coreml',
        'windows': <Object>[],
      }),
    );
    await output.create();

    final result = await Process.run(executable!, [
      'align-qwen3',
      '--request',
      request.path,
      '--output',
      output.path,
    ]);

    expect(result.exitCode, 4);
    final envelope = jsonDecode(await output.readAsString()) as Map;
    expect((envelope['error'] as Map)['code'], 'alignment_model_head_invalid');
  }, skip: executable == null || !Platform.isMacOS);

  test('native Qwen worker rejects an incomplete offline bundle', () async {
    final root = await Directory.systemTemp.createTemp(
      'meow-native-qwen-model-',
    );
    addTearDown(() => root.delete(recursive: true));
    final audio = File('${root.path}/audio.wav');
    final request = File('${root.path}/request.json');
    final output = File('${root.path}/output.json');
    await audio.writeAsBytes(_extensiblePcm16MonoWav());
    await request.writeAsString(
      jsonEncode({
        'protocol': 1,
        'parent_pid': pid,
        'audio_path': audio.path,
        'model_directory': '${root.path}/missing-qwen',
        'vad_model_directory': '${root.path}/missing-silero',
      }),
    );
    await output.create();

    final result = await Process.run(executable!, [
      'transcribe-qwen3',
      '--request',
      request.path,
      '--output',
      output.path,
    ]);

    expect(result.exitCode, 4);
    final envelope = jsonDecode(await output.readAsString()) as Map;
    expect((envelope['error'] as Map)['code'], 'local_stt_model_invalid');
  }, skip: executable == null || !Platform.isMacOS);
}

List<int> _extensiblePcm16MonoWav() {
  const sampleCount = 160;
  const dataBytes = sampleCount * 2;
  const formatBytes = 40;
  final bytes = ByteData(12 + 8 + formatBytes + 8 + dataBytes);
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
  uint32(formatBytes);
  uint16(0xfffe); // WAVE_FORMAT_EXTENSIBLE, emitted by mpv's PCM output.
  uint16(1);
  uint32(16000);
  uint32(32000);
  uint16(2);
  uint16(16);
  uint16(22);
  uint16(16);
  uint32(0x4); // SPEAKER_FRONT_CENTER.
  uint32(1); // KSDATAFORMAT_SUBTYPE_PCM GUID, Data1.
  uint16(0);
  uint16(0x10);
  for (final byte in const [0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71]) {
    bytes.setUint8(offset++, byte);
  }
  ascii('data');
  uint32(dataBytes);
  return bytes.buffer.asUint8List();
}
