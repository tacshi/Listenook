import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../tool/score_transcripts.dart'
    show scoreTranscript, transcriptTextFromFile;

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);
  final duration = await _wavDuration(File(options.audioPath));
  final referenceText = await _referenceText(options.referencePath);
  final exchange = await Directory.systemTemp.createTemp(
    'listenook-qwen-benchmark-',
  );
  var failed = false;
  try {
    for (var run = 1; run <= options.runs; run++) {
      final request = File('${exchange.path}/request-$run.json');
      final output = File('${exchange.path}/output-$run.json');
      await request.writeAsString(
        jsonEncode({
          'protocol': 1,
          'parent_pid': pid,
          'audio_path': options.audioPath,
          'model_directory': options.modelDirectory,
          'vad_model_directory': options.vadDirectory,
          'max_segment_seconds': 10,
          'language_hints': <String>[],
          'context_terms': <String>[],
        }),
        flush: true,
      );
      await Process.run('chmod', ['600', request.path]);

      final stopwatch = Stopwatch()..start();
      final process = await Process.start(options.workerPath, [
        'transcribe-qwen3',
        '--request',
        request.path,
        '--output',
        output.path,
      ]);
      final stdoutDone = process.stdout.drain<void>();
      final stderrText = process.stderr.transform(utf8.decoder).join();
      final exitFuture = process.exitCode;
      final peakRssFuture = _peakResidentKilobytes(process, exitFuture);
      final workerExit = await exitFuture;
      final peakRssKb = await peakRssFuture;
      await stdoutDone;
      final diagnostics = await stderrText;
      stopwatch.stop();

      final elapsedSeconds = stopwatch.elapsedMicroseconds / 1000000;
      final durationSeconds = duration.inMicroseconds / 1000000;
      final rtf = elapsedSeconds / durationSeconds;
      final valid = workerExit == 0 && await _validTranscript(output);
      final withinRtf = rtf < options.maxRtf;
      final withinMemory = peakRssKb < options.maxRssGiB * 1024 * 1024;
      final accuracy = valid && referenceText != null
          ? scoreTranscript(
              referenceText,
              transcriptTextFromFile(output.path, await output.readAsString()),
            )
          : null;
      stdout.writeln(
        'run=$run duration_s=${_fixed(durationSeconds)} '
        'elapsed_s=${_fixed(elapsedSeconds)} rtf=${_fixed(rtf)} '
        'peak_rss_gib=${_fixed(peakRssKb / 1024 / 1024)} '
        'timestamps=${valid ? 'pass' : 'fail'} '
        'rtf_budget=${withinRtf ? 'pass' : 'fail'} '
        'rss_budget=${withinMemory ? 'pass' : 'fail'}'
        '${accuracy == null ? '' : ' ${accuracy.summary}'}',
      );
      if (!valid) {
        stderr.writeln('Worker exit code: $workerExit');
        stderr.write(diagnostics);
      }
      failed = failed || !valid || !withinRtf || !withinMemory;
    }
  } finally {
    await exchange.delete(recursive: true);
  }
  if (failed) exitCode = 1;
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
    peak = maxInt(peak, int.tryParse(sample.stdout.toString().trim()) ?? 0);
    if (!exited) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
  return peak;
}

Future<bool> _validTranscript(File output) async {
  if (!await output.exists()) return false;
  final envelope = jsonDecode(await output.readAsString());
  if (envelope is! Map || envelope['ok'] != true) return false;
  final result = envelope['result'];
  if (result is! Map || result['segments'] is! List) return false;
  var previousEnd = 0;
  for (final value in result['segments'] as List) {
    if (value is! Map) return false;
    final start = (value['start_ms'] as num?)?.toInt();
    final end = (value['end_ms'] as num?)?.toInt();
    if (start == null ||
        end == null ||
        start < previousEnd ||
        end <= start ||
        end - start > 10000 ||
        value['speaker'] != null ||
        (value['text']?.toString().trim().isEmpty ?? true)) {
      return false;
    }
    previousEnd = end;
  }
  return true;
}

/// A human-reviewed transcript of the benchmark audio, scored per run.
Future<String?> _referenceText(String? path) async => path == null
    ? null
    : transcriptTextFromFile(path, await File(path).readAsString());

int maxInt(int a, int b) => a > b ? a : b;

String _fixed(num value) => value.toStringAsFixed(3);

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
    required this.vadDirectory,
    required this.audioPath,
    required this.runs,
    required this.maxRtf,
    required this.maxRssGiB,
    required this.referencePath,
  });

  final String workerPath;
  final String modelDirectory;
  final String vadDirectory;
  final String audioPath;
  final int runs;
  final double maxRtf;
  final double maxRssGiB;
  final String? referencePath;

  static _Options parse(List<String> arguments) {
    String? value(String name) {
      final index = arguments.indexOf(name);
      return index < 0 || index + 1 >= arguments.length
          ? null
          : arguments[index + 1];
    }

    final worker = value('--worker');
    final model = value('--model-directory');
    final vad = value('--vad-directory');
    final audio = value('--audio');
    if (worker == null || model == null || vad == null || audio == null) {
      stderr.writeln(
        'Usage: dart run scripts/benchmark_local_qwen.dart '
        '--worker PATH --model-directory PATH --vad-directory PATH '
        '--audio TWO_HOUR_PCM.wav [--runs 1] [--max-rtf 0.7] '
        '[--max-rss-gib 8] [--reference TRANSCRIPT]',
      );
      exit(64);
    }
    return _Options(
      workerPath: worker,
      modelDirectory: model,
      vadDirectory: vad,
      audioPath: audio,
      runs: int.parse(value('--runs') ?? '1'),
      maxRtf: double.parse(value('--max-rtf') ?? '0.7'),
      maxRssGiB: double.parse(value('--max-rss-gib') ?? '8'),
      referencePath: value('--reference'),
    );
  }
}
