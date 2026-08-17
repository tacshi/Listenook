import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meow_stt/data/process_media_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS compact audio encoder channel is registered', (
    tester,
  ) async {
    final root = await Directory.systemTemp.createTemp(
      'meow-audio-encoder-channel-',
    );
    addTearDown(() => root.delete(recursive: true));
    final input = File('${root.path}/input.wav');
    final output = File('${root.path}/output.m4a');
    await input.writeAsBytes(_pcm16MonoWav());

    await const MacosCompactAudioEncoder().encodeAac(
      inputPath: input.path,
      outputPath: output.path,
      bitRate: 48000,
    );

    expect(await output.exists(), isTrue);
    expect(await output.length(), greaterThan(0));
  }, skip: !Platform.isMacOS);
}

List<int> _pcm16MonoWav() {
  const sampleRate = 16000;
  const dataBytes = sampleRate * 2;
  final bytes = ByteData(44 + dataBytes);
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
  uint16(1);
  uint32(sampleRate);
  uint32(sampleRate * 2);
  uint16(2);
  uint16(16);
  ascii('data');
  uint32(dataBytes);
  return bytes.buffer.asUint8List();
}
