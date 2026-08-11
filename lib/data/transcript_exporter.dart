import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../core/contracts.dart';
import '../core/models.dart';

class DefaultTranscriptExporter implements TranscriptExporter {
  const DefaultTranscriptExporter();

  @override
  String render(
    TranscriptDocument document,
    ExportOptions options, {
    required String title,
    MediaMetadata? metadata,
  }) => switch (options.format) {
    ExportFormat.txt => _plain(document, options),
    ExportFormat.markdown => _markdown(document, options, title, metadata),
    ExportFormat.srt => _subtitle(document, options, vtt: false),
    ExportFormat.webVtt => _subtitle(document, options, vtt: true),
  };

  @override
  Future<String> exportToDirectory(
    TranscriptionJob job,
    String directory,
    ExportOptions options,
  ) async {
    final document = job.document;
    if (document == null) throw StateError('The job has no transcript.');
    final extension = _extension(options.format);
    final base = _sanitize(p.basenameWithoutExtension(job.fileName));
    final output = await _availableFile(directory, base, extension);
    final contents = render(
      document,
      options,
      title: job.fileName,
      metadata: job.metadata,
    );
    await output.writeAsString(contents, encoding: utf8, flush: true);
    return output.path;
  }

  @override
  Future<String> exportZip(
    List<TranscriptionJob> jobs,
    String destination,
    ExportOptions options,
  ) async {
    final archive = Archive();
    final names = <String>{};
    for (final job in jobs.where((item) => item.document != null)) {
      final extension = _extension(options.format);
      final base = _sanitize(p.basenameWithoutExtension(job.fileName));
      var name = '$base.$extension';
      var suffix = 2;
      while (!names.add(name.toLowerCase())) {
        name = '$base-$suffix.$extension';
        suffix++;
      }
      final bytes = utf8.encode(
        render(
          job.document!,
          options,
          title: job.fileName,
          metadata: job.metadata,
        ),
      );
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }
    final data = ZipEncoder().encode(archive);
    final file = File(destination);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data, flush: true);
    return file.path;
  }

  String _plain(TranscriptDocument document, ExportOptions options) => document
      .segments
      .map((segment) {
        final prefix = <String>[
          if (options.showTimestamps) '[${formatClock(segment.startMs)}]',
          if (options.showSpeakers)
            _speakerName(document, segment.speaker, options),
        ].where((part) => part.isNotEmpty).join(' ');
        final content = _content(segment, options.contentMode);
        return prefix.isEmpty ? content : '$prefix: $content';
      })
      .join('\n\n');

  String _markdown(
    TranscriptDocument document,
    ExportOptions options,
    String title,
    MediaMetadata? metadata,
  ) {
    final buffer = StringBuffer()
      ..writeln('# $title')
      ..writeln()
      ..writeln(
        options.localeCode == 'zh' ? '- 由 MeowSTT 导出' : '- Exported by MeowSTT',
      )
      ..writeln(
        options.localeCode == 'zh'
            ? '- 时长：${formatClock(metadata?.durationMs ?? 0)}'
            : '- Duration: ${formatClock(metadata?.durationMs ?? 0)}',
      )
      ..writeln();
    for (final segment in document.segments) {
      final labels = <String>[
        if (options.showSpeakers)
          _speakerName(document, segment.speaker, options),
        if (options.showTimestamps) formatClock(segment.startMs),
      ].where((part) => part.isNotEmpty).join(' · ');
      if (labels.isNotEmpty) buffer.writeln('**$labels**');
      buffer.writeln();
      if (options.contentMode == ExportContentMode.bilingual) {
        if (segment.translatedText?.trim().isNotEmpty ?? false) {
          buffer
            ..writeln(segment.translatedText!.trim())
            ..writeln()
            ..writeln('*${segment.text}*')
            ..writeln();
        } else {
          buffer
            ..writeln(segment.text)
            ..writeln();
        }
      } else {
        buffer
          ..writeln(_content(segment, options.contentMode))
          ..writeln();
      }
    }
    return buffer.toString().trimRight();
  }

  String _subtitle(
    TranscriptDocument document,
    ExportOptions options, {
    required bool vtt,
  }) {
    final buffer = StringBuffer();
    if (vtt) buffer.writeln('WEBVTT\n');
    for (var index = 0; index < document.segments.length; index++) {
      final segment = document.segments[index];
      if (!vtt) buffer.writeln(index + 1);
      buffer.writeln(
        '${_cueTime(segment.startMs, vtt)} --> ${_cueTime(segment.endMs, vtt)}',
      );
      final speaker = options.showSpeakers
          ? _speakerName(document, segment.speaker, options)
          : '';
      final content = _content(segment, options.contentMode);
      buffer.writeln(speaker.isEmpty ? content : '<v $speaker>$content');
      buffer.writeln();
    }
    return buffer.toString().trimRight();
  }

  String _content(TranscriptSegment segment, ExportContentMode mode) {
    final translated = segment.translatedText?.trim();
    return switch (mode) {
      ExportContentMode.original => segment.text,
      ExportContentMode.translated =>
        translated?.isNotEmpty ?? false ? translated! : segment.text,
      ExportContentMode.bilingual =>
        translated?.isNotEmpty ?? false
            ? '$translated\n${segment.text}'
            : segment.text,
    };
  }

  String _speakerName(
    TranscriptDocument document,
    String? speakerId,
    ExportOptions options,
  ) {
    final stored = document.speakerName(speakerId);
    if (options.localeCode != 'zh') return stored;
    final match = RegExp(r'^Speaker (\d+)$').firstMatch(stored);
    return match == null ? stored : '说话人 ${match.group(1)}';
  }

  String _cueTime(int milliseconds, bool vtt) {
    final hours = milliseconds ~/ 3600000;
    final minutes = (milliseconds ~/ 60000) % 60;
    final seconds = (milliseconds ~/ 1000) % 60;
    final millis = milliseconds % 1000;
    final separator = vtt ? '.' : ',';
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}$separator'
        '${millis.toString().padLeft(3, '0')}';
  }

  String _extension(ExportFormat format) => switch (format) {
    ExportFormat.txt => 'txt',
    ExportFormat.markdown => 'md',
    ExportFormat.srt => 'srt',
    ExportFormat.webVtt => 'vtt',
  };

  String _sanitize(String value) {
    final result = value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '')
        .trim();
    return result.isEmpty ? 'transcript' : result;
  }

  Future<File> _availableFile(
    String directory,
    String base,
    String extension,
  ) async {
    var candidate = File(p.join(directory, '$base.$extension'));
    var suffix = 2;
    while (await candidate.exists()) {
      candidate = File(p.join(directory, '$base-$suffix.$extension'));
      suffix++;
    }
    return candidate;
  }
}

String formatClock(int milliseconds) {
  final duration = Duration(milliseconds: milliseconds.clamp(0, 1 << 62));
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}
