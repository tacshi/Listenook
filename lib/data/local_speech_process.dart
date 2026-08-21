import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../core/contracts.dart';
import '../core/local_speech.dart';
import 'process_media_service.dart';

class ProcessLocalPcmPreparer implements LocalPcmPreparer {
  ProcessLocalPcmPreparer(this._media);

  final ProcessMediaService _media;

  @override
  Future<PreparedLocalPcm> prepare(
    String sourcePath, {
    required int durationMs,
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    final cacheKey =
        'local-$pid-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 31)}';
    final path = await _media.extractPcm16kMono(
      sourcePath,
      cacheKey,
      durationMs: durationMs,
      onProgress: onProgress,
      shouldCancel: shouldCancel,
    );
    return PreparedLocalPcm(path);
  }

  @override
  Future<void> release(PreparedLocalPcm pcm) =>
      _media.deleteTemporary(pcm.path);
}

class ProcessLocalSpeechWorker implements LocalSpeechWorker {
  ProcessLocalSpeechWorker({
    required Directory temporaryDirectory,
    String? executablePath,
    this.terminationGrace = const Duration(seconds: 2),
  }) : _temporaryDirectory = temporaryDirectory,
       _executablePath = executablePath;

  final Directory _temporaryDirectory;
  final String? _executablePath;
  final Duration terminationGrace;
  Future<void>? _staleCleanup;

  String get executablePath {
    final override = _executablePath?.trim();
    if (override != null && override.isNotEmpty) return override;
    final environment = Platform.environment['MEOWSTT_SPEECH_WORKER']?.trim();
    if (environment != null && environment.isNotEmpty) return environment;
    final executable = File(Platform.resolvedExecutable);
    return p.join(
      executable.parent.parent.path,
      'Helpers',
      'MeowSTTSpeechWorker',
    );
  }

  @override
  Future<Map<String, dynamic>> run(
    SpeechWorkerCommand command,
    Map<String, dynamic> request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    if (!Platform.isMacOS) {
      throw const LocalSpeechException('local_worker_unsupported');
    }
    final helper = File(executablePath);
    if (!await helper.exists()) {
      throw const LocalSpeechException('local_worker_missing');
    }
    if (shouldCancel?.call() ?? false) {
      throw const OperationCancelledException();
    }

    await _temporaryDirectory.create(recursive: true);
    await (_staleCleanup ??= _cleanupStaleExchangeFiles());
    final nonce =
        '$pid-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 31)}';
    final requestFile = File(
      p.join(_temporaryDirectory.path, 'speech-$nonce-request.json'),
    );
    final outputFile = File(
      p.join(_temporaryDirectory.path, 'speech-$nonce-output.json'),
    );
    Process? process;
    StreamSubscription<String>? stdoutSubscription;
    StreamSubscription<String>? stderrSubscription;
    final stderr = StringBuffer();
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();
    try {
      await requestFile.writeAsString(
        jsonEncode({...request, 'protocol': 1, 'parent_pid': pid}),
        flush: true,
      );
      await outputFile.create();
      await _makePrivate(requestFile);
      await _makePrivate(outputFile);

      process = await Process.start(executablePath, [
        _commandName(command),
        '--request',
        requestFile.path,
        '--output',
        outputFile.path,
      ]);
      stdoutSubscription = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) => _forwardProgress(line, onProgress),
            onDone: stdoutDone.complete,
          );
      stderrSubscription = process.stderr.transform(utf8.decoder).listen((
        chunk,
      ) {
        if (stderr.length < 8192) stderr.write(chunk);
      }, onDone: stderrDone.complete);

      final exitFuture = process.exitCode;
      late int exitCode;
      while (true) {
        final outcome = await Future.any<Object?>([
          exitFuture,
          Future<void>.delayed(const Duration(milliseconds: 25)),
        ]);
        if (outcome is int) {
          exitCode = outcome;
          break;
        }
        if (shouldCancel?.call() ?? false) {
          process.kill(ProcessSignal.sigterm);
          try {
            await exitFuture.timeout(terminationGrace);
          } on TimeoutException {
            process.kill(ProcessSignal.sigkill);
            await exitFuture;
          }
          throw const OperationCancelledException();
        }
      }
      await stdoutDone.future;
      await stderrDone.future;

      final envelope = await _readEnvelope(outputFile);
      if (exitCode != 0 || envelope['ok'] != true) {
        final error = envelope['error'];
        final errorMap = error is Map
            ? error.cast<String, dynamic>()
            : const <String, dynamic>{};
        throw LocalSpeechException(
          errorMap['code']?.toString() ?? 'local_worker_failed',
          message:
              errorMap['message']?.toString() ?? _cleanError(stderr.toString()),
        );
      }
      final result = envelope['result'];
      if (result is! Map) {
        throw const LocalSpeechException('local_worker_invalid_output');
      }
      return result.cast<String, dynamic>();
    } on ProcessException catch (error) {
      throw LocalSpeechException(
        'local_worker_launch_failed',
        message: _cleanError(error.message),
      );
    } finally {
      await stdoutSubscription?.cancel();
      await stderrSubscription?.cancel();
      if (process != null) process.kill(ProcessSignal.sigkill);
      await _deleteIfPresent(requestFile);
      await _deleteIfPresent(outputFile);
    }
  }

  Future<void> _makePrivate(File file) async {
    final result = await Process.run('/bin/chmod', ['600', file.path]);
    if (result.exitCode != 0) {
      throw const LocalSpeechException('local_worker_private_file_failed');
    }
  }

  void _forwardProgress(String line, ProgressCallback? callback) {
    if (callback == null || line.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map ||
          decoded['protocol'] != 1 ||
          decoded['event'] != 'progress') {
        return;
      }
      callback(
        (decoded['fraction'] as num?)?.toDouble(),
        decoded['detail']?.toString(),
      );
    } on FormatException {
      // stdout is an event stream. Invalid diagnostic lines are ignored.
    }
  }

  Future<Map<String, dynamic>> _readEnvelope(File output) async {
    if (!await output.exists() || await output.length() == 0) {
      return const <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(await output.readAsString());
      if (decoded is Map && decoded['protocol'] == 1) {
        return decoded.cast<String, dynamic>();
      }
    } on FormatException {
      // Report the stable protocol error below.
    }
    throw const LocalSpeechException('local_worker_invalid_output');
  }

  String _commandName(SpeechWorkerCommand command) => switch (command) {
    SpeechWorkerCommand.transcribeMoss => 'transcribe-moss',
    SpeechWorkerCommand.transcribeQwen3 => 'transcribe-qwen3',
    SpeechWorkerCommand.alignQwen3 => 'align-qwen3',
  };

  String? _cleanError(String raw) {
    final value = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (value.isEmpty) return null;
    return value.length <= 500 ? value : value.substring(0, 500);
  }

  Future<void> _deleteIfPresent(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // The next application launch can clear stale temporary files.
    }
  }

  Future<void> _cleanupStaleExchangeFiles() async {
    final cutoff = DateTime.now().subtract(const Duration(hours: 1));
    try {
      await for (final entity in _temporaryDirectory.list(followLinks: false)) {
        if (entity is! File ||
            !RegExp(
              r'^speech-.+-(request|output)\.json$',
            ).hasMatch(p.basename(entity.path))) {
          continue;
        }
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) await entity.delete();
      }
    } on FileSystemException {
      // Private exchange files are still removed by the per-run finally block.
    }
  }
}
