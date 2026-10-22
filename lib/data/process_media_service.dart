import '../core/app_identity.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

import '../core/contracts.dart';
import '../core/models.dart';
import 'local_repositories.dart';
import 'waveform_renderer.dart';

abstract interface class CompactAudioEncoder {
  Future<void> encodeAac({
    required String inputPath,
    required String outputPath,
    required int bitRate,
  });
}

class MacosCompactAudioEncoder implements CompactAudioEncoder {
  const MacosCompactAudioEncoder({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = AppIdentity.encoderChannel;
  final MethodChannel _channel;

  @override
  Future<void> encodeAac({
    required String inputPath,
    required String outputPath,
    required int bitRate,
  }) => _channel.invokeMethod<void>('encodeAac', {
    'inputPath': inputPath,
    'outputPath': outputPath,
    'bitRate': bitRate,
  });
}

class ProcessMediaService implements MediaService {
  ProcessMediaService(
    this.paths, {
    CompactAudioEncoder compactAudioEncoder = const MacosCompactAudioEncoder(),
  }) : _compactAudioEncoder = compactAudioEncoder;

  static const supportedAudioExtensions = {'.mp3', '.wav', '.m4a', '.ogg'};
  static const supportedVideoExtensions = {'.mp4', '.mkv', '.avi'};
  static const supportedExtensions = {
    ...supportedAudioExtensions,
    ...supportedVideoExtensions,
  };

  final AppPaths paths;
  final CompactAudioEncoder _compactAudioEncoder;
  String? _encoderPath;

  @override
  bool canUploadDirectly(
    String path,
    MediaMetadata metadata, {
    MediaUploadProfile profile = MediaUploadProfile.standard,
  }) {
    final extension = p.extension(path).toLowerCase();
    if (metadata.hasVideo || !supportedAudioExtensions.contains(extension)) {
      return false;
    }
    if (profile == MediaUploadProfile.standard || !Platform.isMacOS) {
      return true;
    }
    final codec = metadata.audioCodec?.toLowerCase() ?? '';
    final compactCodec =
        extension == '.mp3' ||
        extension == '.ogg' ||
        (extension == '.m4a' &&
            (codec.contains('aac') || codec.contains('mp4a')));
    if (!compactCodec || metadata.durationMs <= 0) return false;
    final bitsPerSecond = metadata.sizeBytes * 8000 / metadata.durationMs;
    return bitsPerSecond <= 64000;
  }

  @override
  Future<MediaMetadata> inspect(String sourcePath) async {
    final source = File(sourcePath);
    final extension = p.extension(sourcePath).toLowerCase();
    if (!supportedExtensions.contains(extension)) {
      throw const MediaException(
        'unsupported_format',
        'Supported audio: MP3, WAV, M4A, OGG. Supported video: MP4, MKV, AVI.',
      );
    }
    if (!await source.exists()) {
      throw const MediaException(
        'missing_source',
        'The source file is missing.',
      );
    }
    RandomAccessFile? handle;
    try {
      handle = await source.open(mode: FileMode.read);
    } on Object {
      throw const MediaException(
        'unreadable_source',
        'The source file cannot be read.',
      );
    } finally {
      await handle?.close();
    }

    final player = Player();
    final native = player.platform;
    if (native is! NativePlayer) {
      await player.dispose();
      throw const MediaException(
        'media_engine_unavailable',
        'The native media engine is unavailable.',
      );
    }
    final errors = <String>[];
    final errorSubscription = player.stream.error.listen(errors.add);
    try {
      await player.open(Media(source.absolute.path), play: false);
      if (!_hasMediaTracks(player.state.tracks)) {
        await player.stream.tracks
            .firstWhere(_hasMediaTracks)
            .timeout(const Duration(seconds: 10));
      }
      if (player.state.duration <= Duration.zero) {
        await player.stream.duration
            .firstWhere((value) => value > Duration.zero)
            .timeout(const Duration(seconds: 10));
      }

      final tracks = player.state.tracks;
      final audioTracks = tracks.audio.where(_isRealAudioTrack).toList();
      final videoTracks = tracks.video.where(_isRealVideoTrack).toList();
      final durationMs = player.state.duration.inMilliseconds;
      if (audioTracks.isEmpty) {
        throw const MediaException(
          'no_audio',
          'No audio stream was found in this file.',
        );
      }
      if (durationMs <= 0) {
        throw const MediaException(
          'invalid_media',
          'The media duration is unavailable.',
        );
      }
      if (durationMs > maxMediaDurationMs) {
        throw const MediaException(
          'duration_limit',
          'Files can be up to 300 minutes long.',
        );
      }
      var formatName = extension.substring(1);
      try {
        final detected = await native.getProperty('file-format');
        if (detected.trim().isNotEmpty) formatName = detected.trim();
      } on Object {
        // The extension was already restricted and libmpv decoded the file.
      }
      return MediaMetadata(
        sizeBytes: await source.length(),
        durationMs: durationMs,
        hasAudio: true,
        hasVideo: videoTracks.isNotEmpty,
        formatName: formatName,
        audioCodec: audioTracks.first.codec,
        videoCodec: videoTracks.firstOrNull?.codec,
      );
    } on MediaException {
      rethrow;
    } on TimeoutException {
      throw MediaException(
        'invalid_media',
        _playerError(errors, 'The media metadata could not be read.'),
      );
    } on Object {
      throw MediaException(
        'invalid_media',
        _playerError(errors, 'The media file could not be inspected.'),
      );
    } finally {
      await errorSubscription.cancel();
      await player.dispose();
    }
  }

  @override
  Future<String> extractAudio(
    String sourcePath,
    String jobId, {
    required int durationMs,
    MediaUploadProfile profile = MediaUploadProfile.standard,
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    if (shouldCancel?.call() ?? false) {
      throw const OperationCancelledException();
    }
    await paths.temporary.create(recursive: true);
    final safeKey = _safeCacheKey(jobId);
    final pcmPath = p.join(paths.temporary.path, '$safeKey-extract.wav');
    final output = p.join(
      paths.temporary.path,
      Platform.isMacOS ? '$safeKey.m4a' : '$safeKey.flac',
    );
    await deleteTemporary(output);
    try {
      await _extractPcm(
        sourcePath,
        pcmPath,
        sampleRate: 16000,
        durationMs: durationMs,
        onProgress: (fraction, detail) =>
            onProgress?.call(fraction == null ? null : fraction * 0.85, detail),
        shouldCancel: shouldCancel,
      );
      if (shouldCancel?.call() ?? false) {
        throw const OperationCancelledException();
      }
      onProgress?.call(0.9, null);
      if (profile == MediaUploadProfile.compactSpeech && Platform.isMacOS) {
        await _compactAudioEncoder.encodeAac(
          inputPath: pcmPath,
          outputPath: output,
          bitRate: 48000,
        );
      } else {
        await _encodeLossless(pcmPath, output, shouldCancel: shouldCancel);
      }
      if (shouldCancel?.call() ?? false) {
        throw const OperationCancelledException();
      }
      final outputFile = File(output);
      if (!await outputFile.exists() || await outputFile.length() == 0) {
        throw const MediaException(
          'conversion_failed',
          'The audio encoder did not create an output file.',
        );
      }
      onProgress?.call(1, null);
      return output;
    } on OperationCancelledException {
      await deleteTemporary(output);
      rethrow;
    } on MediaException {
      await deleteTemporary(output);
      rethrow;
    } on Object catch (error) {
      await deleteTemporary(output);
      throw MediaException('conversion_failed', error.toString());
    } finally {
      await deleteTemporary(pcmPath);
    }
  }

  Future<String> extractPcm16kMono(
    String sourcePath,
    String cacheKey, {
    required int durationMs,
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    await paths.temporary.create(recursive: true);
    final output = p.join(
      paths.temporary.path,
      '${_safeCacheKey(cacheKey)}-local.wav',
    );
    await _extractPcm(
      sourcePath,
      output,
      sampleRate: 16000,
      durationMs: durationMs,
      onProgress: onProgress,
      shouldCancel: shouldCancel,
    );
    return output;
  }

  @override
  Future<String> renderWaveform(String sourcePath, String cacheKey) =>
      _audioAnalysisFile(sourcePath, cacheKey, _waveformSuffix);

  @override
  Future<String> analyzeSpeechEnergy(String sourcePath, String cacheKey) =>
      _audioAnalysisFile(sourcePath, cacheKey, _speechEnergySuffix);

  @override
  Future<String> analyzeFileSpeechEnergy(String sourcePath) async {
    final digest = sha1.convert(utf8.encode(File(sourcePath).absolute.path));
    final cacheKey =
        '$_fileAnalysisPrefix${digest.toString().substring(0, 20)}';
    final path = await analyzeSpeechEnergy(sourcePath, cacheKey);
    // Marks the analysis as recently used, so pruning keeps it.
    await File(path).setLastModified(DateTime.now());
    await _pruneFileAnalyses();
    return path;
  }

  /// Files played outside the jobs, such as videos opened in the player, are
  /// analyzed under this prefix and only the most recent are kept.
  static const _fileAnalysisPrefix = 'file-';
  static const _keptFileAnalyses = 20;

  Future<void> _pruneFileAnalyses() async {
    final energies = <File, DateTime>{};
    await for (final entity in paths.temporary.list()) {
      final name = p.basename(entity.path);
      if (entity is File &&
          name.startsWith(_fileAnalysisPrefix) &&
          name.endsWith(_speechEnergySuffix)) {
        energies[entity] = await entity.lastModified();
      }
    }
    if (energies.length <= _keptFileAnalyses) return;
    final oldestFirst = energies.keys.toList()
      ..sort((a, b) => energies[a]!.compareTo(energies[b]!));
    for (final energy in oldestFirst.take(
      energies.length - _keptFileAnalyses,
    )) {
      final name = p.basename(energy.path);
      await deleteGeneratedMedia(
        name.substring(0, name.length - _speechEnergySuffix.length),
      );
    }
  }

  static const _waveformSuffix = '-waveform-v4.levels';
  static const _speechEnergySuffix = '-speech-v1.energy';

  /// Returns the cached analysis file of [sourcePath] ending in [suffix],
  /// decoding the audio first when the cache is missing or stale.
  Future<String> _audioAnalysisFile(
    String sourcePath,
    String cacheKey,
    String suffix,
  ) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw const MediaException(
        'missing_source',
        'The source file is missing.',
      );
    }
    final safeKey = _safeCacheKey(cacheKey);
    final output = File(p.join(paths.temporary.path, '$safeKey$suffix'));
    Future<bool> fresh() async =>
        await output.exists() &&
        await output.length() > 0 &&
        (await output.lastModified()).isAfter(await source.lastModified());
    if (await fresh()) return output.path;
    await (_audioAnalyses[safeKey] ??= _analyzeAudio(
      sourcePath,
      safeKey,
    ).whenComplete(() => _audioAnalyses.remove(safeKey)));
    if (!await fresh()) {
      throw const MediaException(
        'waveform_failed',
        'The waveform could not be created.',
      );
    }
    return output.path;
  }

  /// Decodes in progress by cache key, so the waveform and the speech energy
  /// never extract the same PCM file at the same time.
  final Map<String, Future<void>> _audioAnalyses = {};

  /// Decodes [sourcePath] once into both the waveform levels and the speech
  /// energy.
  Future<void> _analyzeAudio(String sourcePath, String safeKey) async {
    String output(String suffix) =>
        p.join(paths.temporary.path, '$safeKey$suffix');
    final outputs = [output(_waveformSuffix), output(_speechEnergySuffix)];
    await paths.temporary.create(recursive: true);
    final pcmPath = output('-waveform.wav');
    try {
      await _extractPcm(sourcePath, pcmPath, sampleRate: 8000);
      await writePcmWaveformLevels(pcmPath, outputs[0]);
      await writePcmSpeechEnergy(pcmPath, outputs[1]);
    } on MediaException {
      for (final path in outputs) {
        await deleteTemporary(path);
      }
      rethrow;
    } on Object catch (error) {
      for (final path in outputs) {
        await deleteTemporary(path);
      }
      throw MediaException('waveform_failed', error.toString());
    } finally {
      await deleteTemporary(pcmPath);
    }
  }

  Future<void> _extractPcm(
    String sourcePath,
    String output, {
    required int sampleRate,
    int durationMs = 0,
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    await deleteTemporary(output);
    await File(output).parent.create(recursive: true);
    final player = Player();
    final native = player.platform;
    if (native is! NativePlayer) {
      await player.dispose();
      throw const MediaException(
        'media_engine_unavailable',
        'The native media engine is unavailable.',
      );
    }

    final completion = Completer<void>();
    final errors = <String>[];
    final completedSubscription = player.stream.completed.listen((completed) {
      if (completed && !completion.isCompleted) completion.complete();
    });
    final errorSubscription = player.stream.error.listen((error) {
      errors.add(error);
      if (!completion.isCompleted) completion.complete();
    });
    final positionSubscription = player.stream.position.listen((position) {
      if (durationMs > 0) {
        onProgress?.call(
          (position.inMilliseconds / durationMs).clamp(0.0, 1.0),
          null,
        );
      }
    });

    try {
      await native.setProperty('vid', 'no');
      await native.setProperty('audio-channels', 'mono');
      await native.setProperty('audio-samplerate', '$sampleRate');
      await native.setProperty('audio-format', 's16');
      await native.setProperty('ao', 'pcm');
      await native.setProperty('ao-pcm-waveheader', 'yes');
      await native.setProperty('ao-pcm-file', File(output).absolute.path);
      await native.setProperty('untimed', 'yes');
      await player.open(Media(File(sourcePath).absolute.path), play: true);

      final timeout = durationMs <= 0
          ? const Duration(minutes: 30)
          : Duration(seconds: (durationMs ~/ 10000).clamp(60, 30 * 60));
      final watch = Stopwatch()..start();
      while (!completion.isCompleted) {
        if (shouldCancel?.call() ?? false) {
          await player.stop();
          throw const OperationCancelledException();
        }
        if (watch.elapsed > timeout) {
          throw const MediaException(
            'conversion_failed',
            'The media decoder timed out.',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      await completion.future;
      if (errors.isNotEmpty) {
        throw MediaException('conversion_failed', errors.take(3).join(' '));
      }
      await player.stop();
    } on OperationCancelledException {
      rethrow;
    } on MediaException {
      rethrow;
    } on Object {
      throw MediaException(
        'conversion_failed',
        _playerError(errors, 'The media engine could not extract the audio.'),
      );
    } finally {
      await completedSubscription.cancel();
      await errorSubscription.cancel();
      await positionSubscription.cancel();
      await player.dispose();
    }

    final file = File(output);
    if (!await file.exists() || await file.length() <= 44) {
      await deleteTemporary(output);
      throw MediaException(
        'conversion_failed',
        _playerError(errors, 'The media engine did not produce PCM audio.'),
      );
    }
  }

  Future<void> _encodeLossless(
    String pcmPath,
    String output, {
    CancelCheck? shouldCancel,
  }) async {
    late final String executable;
    late final List<String> arguments;
    if (Platform.isWindows) {
      executable = await _resolveWindowsEncoder();
      arguments = [
        '--silent',
        '--force',
        '--verify',
        '--output-name=$output',
        pcmPath,
      ];
    } else if (Platform.isMacOS) {
      executable = '/usr/bin/afconvert';
      if (!await File(executable).exists()) {
        throw const MediaException(
          'encoder_missing',
          'The macOS lossless audio encoder is unavailable.',
        );
      }
      arguments = ['-f', 'm4af', '-d', 'alac', pcmPath, output];
    } else {
      throw const MediaException(
        'encoder_missing',
        'No lossless audio encoder is configured for this platform.',
      );
    }

    final process = await Process.start(executable, arguments);
    final stdout = StringBuffer();
    final stderr = StringBuffer();
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .listen(stdout.write)
        .asFuture<void>();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .listen(stderr.write)
        .asFuture<void>();
    final exit = process.exitCode.then(_ProcessExit.new);
    late final int exitCode;
    while (true) {
      final result = await Future.any<Object?>([
        exit,
        Future<void>.delayed(const Duration(milliseconds: 25)),
      ]);
      if (result is _ProcessExit) {
        exitCode = result.code;
        break;
      }
      if (shouldCancel?.call() ?? false) {
        process.kill();
        exitCode = await process.exitCode;
        await stdoutDone;
        await stderrDone;
        throw const OperationCancelledException();
      }
    }
    await stdoutDone;
    await stderrDone;
    if (exitCode != 0) {
      final detail = stderr.toString().trim().isNotEmpty
          ? stderr.toString().trim()
          : stdout.toString().trim();
      throw MediaException(
        'conversion_failed',
        _cleanProcessError(detail, 'The lossless audio encoder failed.'),
      );
    }
  }

  Future<String> _resolveWindowsEncoder({bool refresh = false}) async {
    if (!refresh && _encoderPath != null) return _encoderPath!;
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final override = AppIdentity.environment('LISTENOOK_FLAC_DIR')?.trim();
    final nativeArch =
        (Platform.environment['PROCESSOR_ARCHITEW6432'] ??
                Platform.environment['PROCESSOR_ARCHITECTURE'] ??
                '')
            .toUpperCase()
            .contains('ARM64')
        ? 'arm64'
        : 'x64';
    final candidates = <String>[
      if (override?.isNotEmpty ?? false) override!,
      p.join(executableDirectory, 'flac'),
      p.join(Directory.current.path, '.tools', 'flac', 'windows', nativeArch),
      if (nativeArch == 'x64')
        p.join(
          Directory.current.path,
          '.tools',
          'flac',
          '1.5.0',
          'extracted',
          'flac-1.5.0-win',
          'Win64',
        ),
    ];
    for (final directory in candidates) {
      final executable = p.join(directory, 'flac.exe');
      if (await File(executable).exists()) {
        return _encoderPath = executable;
      }
    }
    throw const MediaException(
      'encoder_missing',
      'The bundled FLAC encoder was not found. Open Settings for diagnostics.',
    );
  }

  @override
  Future<void> deleteTemporary(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> deleteGeneratedMedia(String cacheKey) async {
    final safeKey = _safeCacheKey(cacheKey);
    for (final suffix in const [
      '.flac',
      '.m4a',
      '-extract.wav',
      '-waveform.wav',
      _waveformSuffix,
      _speechEnergySuffix,
      '-waveform-v3.png',
      '-waveform-v2.png',
      '-waveform.png',
    ]) {
      await deleteTemporary(p.join(paths.temporary.path, '$safeKey$suffix'));
    }
  }

  @override
  Future<MediaDiagnostics> diagnostics() async {
    Player? player;
    try {
      player = Player();
      final native = player.platform;
      if (native is! NativePlayer) {
        throw const MediaException(
          'media_engine_unavailable',
          'The native media engine is unavailable.',
        );
      }
      final mpvVersion = await native.getProperty('mpv-version');
      String encoderVersion;
      String encoderPath;
      if (Platform.isWindows) {
        encoderPath = await _resolveWindowsEncoder(refresh: true);
        final result = await Process.run(encoderPath, ['--version']);
        if (result.exitCode != 0) {
          throw MediaException(
            'encoder_unavailable',
            _cleanProcessError(
              result.stderr.toString(),
              'The FLAC encoder diagnostics failed.',
            ),
          );
        }
        encoderVersion = result.stdout.toString().trim().split('\n').first;
      } else if (Platform.isMacOS) {
        encoderPath = '/usr/bin/afconvert';
        if (!await File(encoderPath).exists()) {
          throw const MediaException(
            'encoder_missing',
            'The macOS lossless audio encoder is unavailable.',
          );
        }
        encoderVersion = 'macOS afconvert (ALAC)';
      } else {
        throw const MediaException(
          'encoder_missing',
          'No lossless audio encoder is configured for this platform.',
        );
      }
      return MediaDiagnostics(
        available: true,
        enginePath: 'bundled libmpv',
        encoderPath: encoderPath,
        version: '$mpvVersion · $encoderVersion',
      );
    } on MediaException catch (error) {
      return MediaDiagnostics(
        available: false,
        errorCode: error.code,
        error: error.message,
      );
    } on Object catch (error) {
      return MediaDiagnostics(
        available: false,
        errorCode: 'media_engine_unavailable',
        error: error.toString(),
      );
    } finally {
      await player?.dispose();
    }
  }
}

class _ProcessExit {
  const _ProcessExit(this.code);
  final int code;
}

class MediaException implements Exception {
  const MediaException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => 'MediaException($code): $message';
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

bool _isRealAudioTrack(AudioTrack track) =>
    track.id != 'auto' && track.id != 'no';

bool _isRealVideoTrack(VideoTrack track) =>
    track.id != 'auto' &&
    track.id != 'no' &&
    track.image != true &&
    track.albumart != true;

bool _hasMediaTracks(Tracks tracks) =>
    tracks.audio.any(_isRealAudioTrack) || tracks.video.any(_isRealVideoTrack);

String _safeCacheKey(String cacheKey) =>
    cacheKey.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

String _playerError(List<String> errors, String fallback) =>
    errors.isEmpty ? fallback : errors.take(3).join(' ');

String _cleanProcessError(String error, String fallback) {
  final lines = error.trim().split(RegExp(r'[\r\n]+'));
  return lines.isEmpty || lines.first.isEmpty
      ? fallback
      : lines.take(3).join(' ');
}
