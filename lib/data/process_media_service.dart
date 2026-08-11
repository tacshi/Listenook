import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/contracts.dart';
import '../core/models.dart';
import 'local_repositories.dart';

class ProcessMediaService implements MediaService {
  ProcessMediaService(this.paths, {this.overrideDirectory});

  static const sonioxDirectExtensions = {
    '.aac',
    '.aiff',
    '.amr',
    '.asf',
    '.flac',
    '.mp3',
    '.ogg',
    '.wav',
    '.webm',
    '.m4a',
    '.mp4',
  };

  final AppPaths paths;
  final String? overrideDirectory;
  _ToolPaths? _tools;

  @override
  bool canUploadDirectly(String path, MediaMetadata metadata) =>
      !metadata.hasVideo &&
      sonioxDirectExtensions.contains(p.extension(path).toLowerCase());

  @override
  Future<MediaMetadata> inspect(String sourcePath) async {
    final source = File(sourcePath);
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
    final tools = await _resolveTools();
    final result = await Process.run(
      tools.ffprobe,
      buildFfprobeArguments(sourcePath),
    );
    if (result.exitCode != 0) {
      throw MediaException(
        'invalid_media',
        _cleanProcessError(
          result.stderr.toString(),
          'FFprobe could not read this file.',
        ),
      );
    }
    try {
      final json = (jsonDecode(result.stdout.toString()) as Map)
          .cast<String, dynamic>();
      final streams = (json['streams'] as List? ?? const []).whereType<Map>();
      final audio = streams
          .where((stream) => stream['codec_type'] == 'audio')
          .firstOrNull;
      final video = streams
          .where((stream) => stream['codec_type'] == 'video')
          .firstOrNull;
      final format =
          (json['format'] as Map?)?.cast<String, dynamic>() ?? const {};
      final durationSeconds =
          double.tryParse(format['duration']?.toString() ?? '') ??
          streams
              .map(
                (stream) =>
                    double.tryParse(stream['duration']?.toString() ?? ''),
              )
              .whereType<double>()
              .fold<double>(
                0,
                (maximum, value) => value > maximum ? value : maximum,
              );
      final durationMs = (durationSeconds * 1000).round();
      if (audio == null) {
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
          'Soniox supports files up to 300 minutes.',
        );
      }
      return MediaMetadata(
        sizeBytes: await source.length(),
        durationMs: durationMs,
        hasAudio: true,
        hasVideo: video != null,
        formatName: format['format_name']?.toString() ?? 'unknown',
        audioCodec: audio['codec_name']?.toString(),
        videoCodec: video?['codec_name']?.toString(),
      );
    } on MediaException {
      rethrow;
    } on Object {
      throw const MediaException(
        'invalid_media',
        'FFprobe returned unreadable metadata.',
      );
    }
  }

  @override
  Future<String> extractAudio(
    String sourcePath,
    String jobId, {
    required int durationMs,
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    final tools = await _resolveTools();
    final output = p.join(paths.temporary.path, '$jobId.flac');
    final process = await Process.start(
      tools.ffmpeg,
      buildFfmpegExtractionArguments(sourcePath, output),
    );
    final stderr = StringBuffer();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .listen(stderr.write)
        .asFuture<void>();
    await for (final line
        in process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (shouldCancel?.call() ?? false) {
        process.kill();
        await process.exitCode;
        await stderrDone;
        await deleteTemporary(output);
        throw const OperationCancelledException();
      }
      if (!line.startsWith('out_time_')) continue;
      final raw = int.tryParse(line.substring(line.indexOf('=') + 1));
      if (raw == null || durationMs <= 0) continue;
      final milliseconds = line.startsWith('out_time_ms=')
          ? raw ~/ 1000
          : raw ~/ 1000;
      onProgress?.call((milliseconds / durationMs).clamp(0, 1), null);
    }
    final exitCode = await process.exitCode;
    await stderrDone;
    if (exitCode != 0 || !await File(output).exists()) {
      await deleteTemporary(output);
      throw MediaException(
        'conversion_failed',
        _cleanProcessError(
          stderr.toString(),
          'FFmpeg could not extract the audio.',
        ),
      );
    }
    onProgress?.call(1, null);
    return output;
  }

  @override
  Future<String> renderWaveform(String sourcePath, String cacheKey) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw const MediaException(
        'missing_source',
        'The source file is missing.',
      );
    }
    final safeKey = cacheKey.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final output = File(p.join(paths.temporary.path, '$safeKey-waveform.png'));
    if (await output.exists() &&
        (await output.lastModified()).isAfter(await source.lastModified())) {
      return output.path;
    }
    await output.parent.create(recursive: true);
    final tools = await _resolveTools();
    final result = await Process.run(
      tools.ffmpeg,
      buildFfmpegWaveformArguments(sourcePath, output.path),
    );
    if (result.exitCode != 0 ||
        !await output.exists() ||
        await output.length() == 0) {
      await deleteTemporary(output.path);
      throw MediaException(
        'waveform_failed',
        _cleanProcessError(
          result.stderr.toString(),
          'FFmpeg could not render the waveform.',
        ),
      );
    }
    return output.path;
  }

  @override
  Future<void> deleteTemporary(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> deleteGeneratedMedia(String cacheKey) async {
    final safeKey = cacheKey.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    await deleteTemporary(p.join(paths.temporary.path, '$safeKey.flac'));
    await deleteTemporary(
      p.join(paths.temporary.path, '$safeKey-waveform.png'),
    );
  }

  @override
  Future<void> clearGeneratedMediaExcept(Set<String> retainedCacheKeys) async {
    if (!await paths.temporary.exists()) return;
    final retained = retainedCacheKeys
        .map((key) => key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_'))
        .toSet();
    await for (final entity in paths.temporary.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final cacheKey = name.endsWith('-waveform.png')
          ? name.substring(0, name.length - '-waveform.png'.length)
          : name.endsWith('.flac')
          ? name.substring(0, name.length - '.flac'.length)
          : null;
      if (cacheKey != null && !retained.contains(cacheKey)) {
        await deleteTemporary(entity.path);
      }
    }
  }

  @override
  Future<MediaDiagnostics> diagnostics() async {
    try {
      final tools = await _resolveTools(refresh: true);
      final result = await Process.run(tools.ffmpeg, ['-version']);
      return MediaDiagnostics(
        available: result.exitCode == 0,
        ffmpegPath: tools.ffmpeg,
        ffprobePath: tools.ffprobe,
        version: result.stdout.toString().split('\n').first,
        errorCode: result.exitCode == 0 ? null : 'ffmpeg_unavailable',
        error: result.exitCode == 0 ? null : result.stderr.toString().trim(),
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
        errorCode: 'ffmpeg_unavailable',
        error: error.toString(),
      );
    }
  }

  Future<_ToolPaths> _resolveTools({bool refresh = false}) async {
    if (!refresh && _tools != null) return _tools!;
    final executableName = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    final probeName = Platform.isWindows ? 'ffprobe.exe' : 'ffprobe';
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      if (overrideDirectory?.trim().isNotEmpty ?? false)
        overrideDirectory!.trim(),
      if (Platform.environment['MEOWSTT_FFMPEG_DIR']?.trim().isNotEmpty ??
          false)
        Platform.environment['MEOWSTT_FFMPEG_DIR']!.trim(),
      if (Platform.isMacOS)
        p.normalize(p.join(executableDirectory, '..', 'Resources', 'ffmpeg')),
      p.join(executableDirectory, 'ffmpeg'),
      p.join(Directory.current.path, '.tools', 'ffmpeg'),
    ];
    for (final directory in candidates) {
      final ffmpeg = p.join(directory, executableName);
      final ffprobe = p.join(directory, probeName);
      if (await File(ffmpeg).exists() && await File(ffprobe).exists()) {
        return _tools = _ToolPaths(ffmpeg, ffprobe);
      }
    }
    final lookup = await Process.run(
      Platform.isWindows ? 'where.exe' : 'which',
      [executableName],
    );
    final probeLookup = await Process.run(
      Platform.isWindows ? 'where.exe' : 'which',
      [probeName],
    );
    if (lookup.exitCode == 0 && probeLookup.exitCode == 0) {
      return _tools = _ToolPaths(
        lookup.stdout.toString().trim().split(RegExp(r'[\r\n]+')).first,
        probeLookup.stdout.toString().trim().split(RegExp(r'[\r\n]+')).first,
      );
    }
    throw const MediaException(
      'ffmpeg_missing',
      'Bundled FFmpeg and ffprobe were not found. Open Settings for diagnostics.',
    );
  }

  String _cleanProcessError(String error, String fallback) {
    final lines = error.trim().split(RegExp(r'[\r\n]+'));
    return lines.isEmpty || lines.first.isEmpty
        ? fallback
        : lines.take(3).join(' ');
  }
}

class _ToolPaths {
  const _ToolPaths(this.ffmpeg, this.ffprobe);
  final String ffmpeg;
  final String ffprobe;
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

List<String> buildFfprobeArguments(String sourcePath) => [
  '-v',
  'error',
  '-show_format',
  '-show_streams',
  '-of',
  'json',
  sourcePath,
];

List<String> buildFfmpegExtractionArguments(String sourcePath, String output) =>
    [
      '-hide_banner',
      '-nostdin',
      '-y',
      '-i',
      sourcePath,
      '-vn',
      '-ac',
      '1',
      '-ar',
      '16000',
      '-c:a',
      'flac',
      '-progress',
      'pipe:1',
      '-nostats',
      output,
    ];

List<String> buildFfmpegWaveformArguments(
  String sourcePath,
  String output, {
  int width = 1200,
  int height = 160,
}) => [
  '-hide_banner',
  '-loglevel',
  'error',
  '-nostdin',
  '-y',
  '-i',
  sourcePath,
  '-filter_complex',
  'aformat=channel_layouts=mono,showwavespic='
      's=${width}x$height:colors=white:scale=sqrt',
  '-frames:v',
  '1',
  output,
];
