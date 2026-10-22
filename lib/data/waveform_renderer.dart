import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Writes one loudness level (0–255) per bucket of [inputPath] to
/// [outputPath], scaled so that the loud passages of the recording reach the
/// top of the range.
Future<void> writePcmWaveformLevels(
  String inputPath,
  String outputPath, {
  int buckets = 1200,
}) async {
  final envelope = await readPcm16MonoEnvelope(inputPath, buckets);
  final output = File(outputPath);
  await output.parent.create(recursive: true);
  await output.writeAsBytes(waveformLevels(envelope.rms), flush: true);
}

/// Scales RMS values to 0–255 against the 98th percentile, so a single loud
/// burst cannot flatten the rest of the recording.
Uint8List waveformLevels(Uint16List rms) {
  final levels = Uint8List(rms.length);
  final sorted = rms.where((value) => value > 0).toList()..sort();
  if (sorted.isEmpty) return levels;
  final reference = sorted[((sorted.length - 1) * .98).round()];
  for (var index = 0; index < rms.length; index++) {
    final scaled = math.min(1.0, rms[index] / reference);
    levels[index] = (math.pow(scaled, .8) * 255).round();
  }
  return levels;
}

class Pcm16MonoEnvelope {
  const Pcm16MonoEnvelope({
    required this.minima,
    required this.maxima,
    required this.rms,
  });

  final Int16List minima;
  final Int16List maxima;
  final Uint16List rms;
}

Future<Pcm16MonoEnvelope> readPcm16MonoEnvelope(String path, int width) async {
  if (width <= 0) throw const FormatException('Peak count must be positive.');
  final minima = Int16List(width);
  final maxima = Int16List(width);
  final squareSums = List<int>.filled(width, 0);
  final bucketCounts = Uint32List(width);
  var sampleCount = 0;
  var sampleIndex = 0;
  await _readPcm16Mono(
    path,
    onFormat: (_, count) => sampleCount = count,
    onSample: (signed) {
      final bucket = math.min(width - 1, sampleIndex * width ~/ sampleCount);
      if (signed < minima[bucket]) minima[bucket] = signed;
      if (signed > maxima[bucket]) maxima[bucket] = signed;
      squareSums[bucket] += signed * signed;
      bucketCounts[bucket]++;
      sampleIndex++;
    },
  );
  final rms = Uint16List(width);
  for (var index = 0; index < width; index++) {
    final count = bucketCounts[index];
    if (count == 0) continue;
    rms[index] = math.sqrt(squareSums[index] / count).round();
  }
  return Pcm16MonoEnvelope(minima: minima, maxima: maxima, rms: rms);
}

/// Writes the loudness of [inputPath] in 10ms frames to [outputPath], one
/// byte of half-decibels per frame, for finding the pauses between sentences.
Future<void> writePcmSpeechEnergy(String inputPath, String outputPath) async {
  final energy = await readPcm16MonoEnergy(inputPath);
  final output = File(outputPath);
  await output.parent.create(recursive: true);
  await output.writeAsBytes(energy, flush: true);
}

/// The mean power of each 10ms frame in half-decibels above digital silence.
Future<Uint8List> readPcm16MonoEnergy(String path) async {
  var frameLength = 1;
  var frames = Uint8List(0);
  var frame = 0;
  var squareSum = 0;
  var count = 0;
  void closeFrame() {
    final meanSquare = squareSum / count;
    frames[frame++] = math.min(
      255,
      (20 * math.log(meanSquare + 1) / math.ln10).round(),
    );
    squareSum = 0;
    count = 0;
  }

  await _readPcm16Mono(
    path,
    onFormat: (sampleRate, sampleCount) {
      frameLength = math.max(1, sampleRate ~/ 100);
      frames = Uint8List((sampleCount + frameLength - 1) ~/ frameLength);
    },
    onSample: (signed) {
      squareSum += signed * signed;
      if (++count == frameLength) closeFrame();
    },
  );
  if (count > 0) closeFrame();
  return frames;
}

/// Streams the samples of a mono 16-bit PCM WAVE file to [onSample], after
/// reporting its sample rate and sample count to [onFormat].
Future<void> _readPcm16Mono(
  String path, {
  required void Function(int sampleRate, int sampleCount) onFormat,
  required void Function(int sample) onSample,
}) async {
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
    int? sampleRate;
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
        sampleRate = data.getUint32(4, Endian.little);
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
    onFormat(sampleRate ?? 0, sampleCount);
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
        onSample(data.getInt16(offset, Endian.little));
        sampleIndex++;
      }
      remaining -= evenLength;
    }
    if (sampleIndex != sampleCount) {
      throw const FormatException('WAVE audio data is truncated.');
    }
  } finally {
    await input.close();
  }
}
