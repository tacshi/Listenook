import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);
  final audioDuration = await _wavDuration(File(options.audioPath));
  final temporaryDirectory = await Directory.systemTemp.createTemp(
    'meowstt-moss-benchmark-',
  );

  try {
    var failed = false;
    for (var run = 1; run <= options.runs; run += 1) {
      final requestFile = File('${temporaryDirectory.path}/request-$run.json');
      final outputFile = File('${temporaryDirectory.path}/output-$run.json');
      await requestFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(<String, Object>{
          'protocol': 1,
          'parent_pid': pid,
          'audio_path': options.audioPath,
          'model_directory': options.modelDirectory,
          'chunk_seconds': 30,
          'parallel_chunks': options.parallelChunks,
          'hotwords': <String>[],
          'max_new_tokens_per_chunk': 640,
        }),
        flush: true,
      );
      await Process.run('chmod', <String>['600', requestFile.path]);

      final stopwatch = Stopwatch()..start();
      final process = await Process.start(options.workerPath, <String>[
        'transcribe-moss',
        '--request',
        requestFile.path,
        '--output',
        outputFile.path,
      ]);

      var progressEvents = 0;
      final stdoutDone = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) {
            progressEvents += 1;
            if (options.showProgress) {
              stdout.writeln(line);
            }
          });
      final stderrBuffer = StringBuffer();
      final stderrDone = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) {
            stderrBuffer.writeln(line);
            if (options.showProgress) {
              stderr.writeln(line);
            }
          });

      final exitFuture = process.exitCode;
      final peakRssFuture = _peakResidentKilobytes(process, exitFuture);
      final exitCode = await exitFuture;
      final peakRssKb = await peakRssFuture;
      await Future.wait<void>(<Future<void>>[stdoutDone, stderrDone]);
      stopwatch.stop();

      final elapsedSeconds = stopwatch.elapsedMicroseconds / 1000000;
      final realTimeFactor =
          elapsedSeconds / audioDuration.inMicroseconds * 1000000;
      final resultOkay = exitCode == 0 && await _hasTranscript(outputFile);
      final resultDigest = resultOkay
          ? await _transcriptDigest(outputFile)
          : 'unavailable';
      final withinBudget = realTimeFactor <= options.maxRealTimeFactor;
      stdout.writeln(
        'run=$run duration_s=${_fixed(audioDuration.inMicroseconds / 1000000)} '
        'elapsed_s=${_fixed(elapsedSeconds)} rtf=${_fixed(realTimeFactor)} '
        'events=$progressEvents result=${resultOkay ? 'ok' : 'failed'} '
        'budget=${withinBudget ? 'pass' : 'fail'} '
        'peak_rss_mb=${_fixed(peakRssKb / 1024)} digest=$resultDigest',
      );

      if (!resultOkay) {
        stderr.writeln('Worker exit code: $exitCode');
        stderr.write(stderrBuffer);
      }
      failed = failed || !resultOkay || !withinBudget;
    }

    if (failed) {
      exitCode = 1;
    }
  } finally {
    await temporaryDirectory.delete(recursive: true);
  }
}

Future<int> _peakResidentKilobytes(
  Process process,
  Future<int> exitFuture,
) async {
  var peak = 0;
  var exited = false;
  exitFuture.then((_) => exited = true);
  while (!exited) {
    final sample = await Process.run('/bin/ps', [
      '-o',
      'rss=',
      '-p',
      '${process.pid}',
    ]);
    final kilobytes = int.tryParse(sample.stdout.toString().trim()) ?? 0;
    if (kilobytes > peak) peak = kilobytes;
    if (!exited) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
  return peak;
}

Future<String> _transcriptDigest(File outputFile) async {
  final envelope = jsonDecode(await outputFile.readAsString()) as Map;
  final result = envelope['result'] as Map;
  final segments = (result['segments'] as List).map((value) {
    final segment = value as Map;
    return <String, Object?>{
      'start_ms': segment['start_ms'],
      'end_ms': segment['end_ms'],
      'speaker': segment['speaker'],
      'text': segment['text'],
    };
  }).toList();
  final canonical = jsonEncode(<String, Object?>{
    'text': result['text'],
    'segments': segments,
    'warnings': result['warnings'],
  });
  return sha256.convert(utf8.encode(canonical)).toString();
}

String _fixed(num value) => value.toStringAsFixed(3);

Future<bool> _hasTranscript(File outputFile) async {
  if (!await outputFile.exists()) {
    return false;
  }
  final decoded = jsonDecode(await outputFile.readAsString());
  if (decoded is! Map<String, dynamic>) {
    return false;
  }
  final result = decoded['result'];
  if (result is Map<String, dynamic>) {
    final segments = result['segments'];
    return segments is List && segments.isNotEmpty;
  }
  return false;
}

Future<Duration> _wavDuration(File file) async {
  final handle = await file.open();
  try {
    final length = await handle.length();
    final header = await handle.read(12);
    if (header.length != 12 ||
        ascii.decode(header.sublist(0, 4)) != 'RIFF' ||
        ascii.decode(header.sublist(8, 12)) != 'WAVE') {
      throw FormatException('${file.path} is not a RIFF WAV file.');
    }

    var byteRate = 0;
    var dataBytes = 0;
    var offset = 12;
    while (offset + 8 <= length) {
      await handle.setPosition(offset);
      final chunkHeader = await handle.read(8);
      if (chunkHeader.length != 8) break;
      final chunkName = ascii.decode(chunkHeader.sublist(0, 4));
      final chunkSize = ByteData.sublistView(
        chunkHeader,
      ).getUint32(4, Endian.little);
      final chunkDataOffset = offset + 8;
      final chunkEnd = chunkDataOffset + chunkSize;
      if (chunkEnd > length) {
        throw FormatException('${file.path} has a truncated WAV chunk.');
      }
      if (chunkName == 'fmt ' && chunkSize >= 12) {
        final format = await handle.read(12);
        if (format.length != 12) {
          throw FormatException('${file.path} has a truncated format chunk.');
        }
        byteRate = ByteData.sublistView(format).getUint32(8, Endian.little);
      } else if (chunkName == 'data') {
        dataBytes = chunkSize;
        break;
      }
      offset = chunkEnd + (chunkSize.isOdd ? 1 : 0);
    }

    if (byteRate <= 0 || dataBytes <= 0) {
      throw FormatException('${file.path} has no usable WAV data chunk.');
    }
    return Duration(microseconds: (dataBytes * 1000000 / byteRate).round());
  } finally {
    await handle.close();
  }
}

class _Options {
  const _Options({
    required this.workerPath,
    required this.modelDirectory,
    required this.audioPath,
    required this.runs,
    required this.maxRealTimeFactor,
    required this.showProgress,
    required this.parallelChunks,
  });

  final String workerPath;
  final String modelDirectory;
  final String audioPath;
  final int runs;
  final double maxRealTimeFactor;
  final bool showProgress;
  final int parallelChunks;

  static _Options parse(List<String> arguments) {
    String? value(String name) {
      final index = arguments.indexOf(name);
      if (index < 0 || index + 1 >= arguments.length) {
        return null;
      }
      return arguments[index + 1];
    }

    final worker = value('--worker');
    final model = value('--model-directory');
    final audio = value('--audio');
    if (worker == null || model == null || audio == null) {
      stderr.writeln(
        'Usage: dart run scripts/benchmark_local_moss.dart '
        '--worker PATH --model-directory PATH --audio PATH '
        '[--runs 2] [--max-rtf 1.0] [--show-progress]',
      );
      exit(64);
    }

    return _Options(
      workerPath: worker,
      modelDirectory: model,
      audioPath: audio,
      runs: int.parse(value('--runs') ?? '2'),
      maxRealTimeFactor: double.parse(value('--max-rtf') ?? '1.0'),
      showProgress: arguments.contains('--show-progress'),
      parallelChunks: int.parse(value('--parallel-chunks') ?? '2'),
    );
  }
}
