import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

Future<void> renderPcmWaveform(
  String inputPath,
  String outputPath, {
  int width = 1200,
  int height = 160,
}) async {
  if (width <= 0 || height <= 0) {
    throw const FormatException('Waveform dimensions must be positive.');
  }
  final envelope = await readPcm16MonoEnvelope(inputPath, width);
  final rowBytes = width * 4 + 1;
  final pixels = Uint8List(rowBytes * height);
  final center = height ~/ 2;
  for (var x = 0; x < width; x++) {
    final positive = math.sqrt(envelope.positiveAverages[x] / 32767.0);
    final negative = math.sqrt(envelope.negativeAverages[x] / 32768.0);
    final top = math.max(0, center - (positive * center).round());
    final bottom = math.min(
      height - 1,
      center + (negative * (height - 1 - center)).round(),
    );
    if (top == center && bottom == center) continue;
    for (var y = top; y <= bottom; y++) {
      final offset = y * rowBytes + 1 + x * 4;
      pixels[offset] = 255;
      pixels[offset + 1] = 255;
      pixels[offset + 2] = 255;
      pixels[offset + 3] = 255;
    }
  }

  final png = BytesBuilder(copy: false)..add(_pngSignature);
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 6)
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  _addPngChunk(png, 'IHDR', header.buffer.asUint8List());
  _addPngChunk(png, 'IDAT', Uint8List.fromList(ZLibCodec().encode(pixels)));
  _addPngChunk(png, 'IEND', Uint8List(0));
  final output = File(outputPath);
  await output.parent.create(recursive: true);
  await output.writeAsBytes(png.takeBytes(), flush: true);
}

class Pcm16MonoEnvelope {
  const Pcm16MonoEnvelope({
    required this.minima,
    required this.maxima,
    required this.positiveAverages,
    required this.negativeAverages,
  });

  final Int16List minima;
  final Int16List maxima;
  final Uint16List positiveAverages;
  final Uint16List negativeAverages;
}

Future<Pcm16MonoEnvelope> readPcm16MonoEnvelope(String path, int width) async {
  if (width <= 0) throw const FormatException('Peak count must be positive.');
  final file = File(path);
  final input = await file.open(mode: FileMode.read);
  try {
    final header = await input.read(12);
    if (header.length != 12 ||
        ascii.decode(header.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
        ascii.decode(header.sublist(8, 12), allowInvalid: true) != 'WAVE') {
      throw const FormatException('Not a RIFF/WAVE file.');
    }

    bool? pcmFormat;
    int? channels;
    int? bitsPerSample;
    int? dataOffset;
    int? dataLength;
    final fileLength = await file.length();
    while (await input.position() + 8 <= fileLength) {
      final chunkHeader = await input.read(8);
      if (chunkHeader.length != 8) break;
      final id = ascii.decode(chunkHeader.sublist(0, 4), allowInvalid: true);
      final size = ByteData.sublistView(
        Uint8List.fromList(chunkHeader),
      ).getUint32(4, Endian.little);
      final start = await input.position();
      if (id == 'fmt ') {
        if (size < 16) throw const FormatException('Invalid WAVE fmt chunk.');
        final bytes = await input.read(math.min(size, 40));
        if (bytes.length < 16) {
          throw const FormatException('Truncated WAVE fmt chunk.');
        }
        final data = ByteData.sublistView(Uint8List.fromList(bytes));
        final formatTag = data.getUint16(0, Endian.little);
        pcmFormat =
            formatTag == 1 ||
            (formatTag == 0xfffe &&
                bytes.length >= 40 &&
                data.getUint32(24, Endian.little) == 1);
        channels = data.getUint16(2, Endian.little);
        bitsPerSample = data.getUint16(14, Endian.little);
      } else if (id == 'data') {
        dataOffset = start;
        dataLength = math.min(size, fileLength - start);
      }
      final next = math.min(fileLength, start + size + (size.isOdd ? 1 : 0));
      await input.setPosition(next);
      if (pcmFormat != null && dataOffset != null) break;
    }
    if (pcmFormat != true || channels != 1 || bitsPerSample != 16) {
      throw const FormatException('Expected mono 16-bit PCM WAVE audio.');
    }
    if (dataOffset == null || dataLength == null || dataLength < 2) {
      throw const FormatException('WAVE audio data is missing.');
    }

    final sampleCount = dataLength ~/ 2;
    final minima = Int16List(width);
    final maxima = Int16List(width);
    final positiveSums = List<int>.filled(width, 0);
    final negativeSums = List<int>.filled(width, 0);
    final bucketCounts = Uint32List(width);
    await input.setPosition(dataOffset);
    var sampleIndex = 0;
    var remaining = sampleCount * 2;
    while (remaining > 0) {
      final bytes = await input.read(math.min(remaining, 64 * 1024));
      if (bytes.isEmpty) break;
      final evenLength = bytes.length - bytes.length % 2;
      final data = ByteData.sublistView(
        Uint8List.fromList(bytes.sublist(0, evenLength)),
      );
      for (var offset = 0; offset < evenLength; offset += 2) {
        final signed = data.getInt16(offset, Endian.little);
        final bucket = math.min(width - 1, sampleIndex * width ~/ sampleCount);
        if (signed < minima[bucket]) minima[bucket] = signed;
        if (signed > maxima[bucket]) maxima[bucket] = signed;
        if (signed > 0) {
          positiveSums[bucket] += signed;
        } else if (signed < 0) {
          negativeSums[bucket] += signed == -32768 ? 32768 : -signed;
        }
        bucketCounts[bucket]++;
        sampleIndex++;
      }
      remaining -= evenLength;
    }
    if (sampleIndex != sampleCount) {
      throw const FormatException('WAVE audio data is truncated.');
    }
    final positiveAverages = Uint16List(width);
    final negativeAverages = Uint16List(width);
    for (var index = 0; index < width; index++) {
      final count = bucketCounts[index];
      if (count == 0) continue;
      positiveAverages[index] = (positiveSums[index] / count).round();
      negativeAverages[index] = (negativeSums[index] / count).round();
    }
    return Pcm16MonoEnvelope(
      minima: minima,
      maxima: maxima,
      positiveAverages: positiveAverages,
      negativeAverages: negativeAverages,
    );
  } finally {
    await input.close();
  }
}

const _pngSignature = <int>[137, 80, 78, 71, 13, 10, 26, 10];

void _addPngChunk(BytesBuilder output, String type, Uint8List data) {
  final typeBytes = ascii.encode(type);
  final length = ByteData(4)..setUint32(0, data.length);
  output.add(length.buffer.asUint8List());
  output.add(typeBytes);
  output.add(data);
  final crcInput = BytesBuilder(copy: false)
    ..add(typeBytes)
    ..add(data);
  final crc = ByteData(4)..setUint32(0, _crc32(crcInput.takeBytes()));
  output.add(crc.buffer.asUint8List());
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
