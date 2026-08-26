import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../core/contracts.dart';
import '../core/models.dart';
import '../core/subtitle_text.dart';

const supportedSubtitleExtensions = {'srt', 'vtt'};
const supportedAlignmentLanguageCodes = {
  'zh',
  'yue',
  'en',
  'de',
  'es',
  'fr',
  'it',
  'pt',
  'ru',
  'ko',
  'ja',
};

class TimedSubtitleParseResult {
  const TimedSubtitleParseResult({
    required this.format,
    required this.document,
    required this.ignoredCueCount,
    required this.longCueCount,
  });

  final SubtitleFormat format;
  final TranscriptDocument document;
  final int ignoredCueCount;
  final int longCueCount;
}

class SubtitleFileCandidate {
  const SubtitleFileCandidate({
    required this.path,
    required this.displayName,
    required this.format,
    required this.parseResult,
    this.languageCode,
    this.errorCode,
  });

  final String path;
  final String displayName;
  final SubtitleFormat format;
  final TimedSubtitleParseResult? parseResult;
  final String? languageCode;
  final String? errorCode;

  bool get isValid =>
      parseResult != null && parseResult!.document.segments.isNotEmpty;
}

class MediaSubtitleMatch {
  const MediaSubtitleMatch({required this.media, required this.candidates});

  final ResolvedMediaSource media;
  final List<SubtitleFileCandidate> candidates;

  SubtitleFileCandidate? get automaticCandidate {
    if (candidates.length != 1 || !candidates.single.isValid) return null;
    return candidates.single;
  }
}

class SubtitleImportReview {
  const SubtitleImportReview({
    required this.media,
    required this.unmatchedSubtitles,
  });

  final List<MediaSubtitleMatch> media;
  final List<SubtitleFileCandidate> unmatchedSubtitles;
}

class SubtitleImportSelection {
  const SubtitleImportSelection({
    required this.media,
    this.subtitle,
    this.languageCode,
  });

  final ResolvedMediaSource media;
  final SubtitleFileCandidate? subtitle;
  final String? languageCode;
}

class TimedSubtitleImportException implements Exception {
  const TimedSubtitleImportException(this.code);

  final String code;
}

class TimedSubtitleImportService {
  const TimedSubtitleImportService();

  static const _maximumAlignmentWindowMs = 29000;

  Future<SubtitleImportReview?> preview(
    Iterable<String> inputs, {
    required MediaSourceResolver resolver,
  }) async {
    final resolved = await resolver.resolve(inputs);
    final media = <ResolvedMediaSource>[];
    final subtitles = <String, String>{};
    for (final source in resolved) {
      final extension = _extension(source.path);
      if (supportedMonitoredMediaExtensions.contains(extension)) {
        media.add(source);
      } else if (supportedSubtitleExtensions.contains(extension)) {
        subtitles[resolver.identityFor(source.path)] = source.path;
      }
    }

    for (final source in media) {
      final directory = Directory(p.dirname(source.path));
      try {
        await for (final entity in directory.list(followLinks: false)) {
          if (entity is! File || !_isPotentialMatch(source.path, entity.path)) {
            continue;
          }
          subtitles[resolver.identityFor(entity.path)] = entity.path;
        }
      } on FileSystemException {
        // The explicitly selected media remains importable without a sibling.
      }
    }

    if (subtitles.isEmpty) return null;
    final parsed = <String, SubtitleFileCandidate>{};
    for (final path in subtitles.values) {
      parsed[path] = await _candidate(path);
    }

    final usedPaths = <String>{};
    final matches = <MediaSubtitleMatch>[];
    for (final source in media) {
      final candidates =
          parsed.values
              .where(
                (candidate) => _isPotentialMatch(source.path, candidate.path),
              )
              .toList(growable: false)
            ..sort(
              (left, right) => left.displayName.compareTo(right.displayName),
            );
      usedPaths.addAll(candidates.map((candidate) => candidate.path));
      matches.add(MediaSubtitleMatch(media: source, candidates: candidates));
    }
    final unmatched =
        parsed.values
            .where((candidate) => !usedPaths.contains(candidate.path))
            .toList(growable: false)
          ..sort(
            (left, right) => left.displayName.compareTo(right.displayName),
          );
    return SubtitleImportReview(
      media: List.unmodifiable(matches),
      unmatchedSubtitles: List.unmodifiable(unmatched),
    );
  }

  Future<SubtitleFileCandidate> parseCandidate(String path) => _candidate(path);

  TimedSubtitleParseResult constrainToDuration(
    TimedSubtitleParseResult source,
    int durationMs,
  ) {
    final segments = <TranscriptSegment>[];
    var ignored = source.ignoredCueCount;
    var long = 0;
    for (final segment in source.document.segments) {
      if (segment.startMs >= durationMs) {
        ignored++;
        continue;
      }
      final endMs = min(segment.endMs, durationMs);
      if (endMs <= segment.startMs) {
        ignored++;
        continue;
      }
      if (endMs - segment.startMs > _maximumAlignmentWindowMs) long++;
      segments.add(segment.copyWith(endMs: endMs, alignmentWindowEndMs: endMs));
    }
    return TimedSubtitleParseResult(
      format: source.format,
      document: source.document.copyWith(segments: segments),
      ignoredCueCount: ignored,
      longCueCount: long,
    );
  }

  Future<SubtitleFileCandidate> _candidate(String path) async {
    final format = _format(path);
    final displayName = p.basename(path);
    try {
      final result = await parseFile(path);
      return SubtitleFileCandidate(
        path: p.absolute(path),
        displayName: displayName,
        format: format,
        parseResult: result,
        languageCode: _languageSuffix(path),
        errorCode: result.document.segments.isEmpty
            ? 'subtitle_no_valid_cues'
            : null,
      );
    } on TimedSubtitleImportException catch (error) {
      return SubtitleFileCandidate(
        path: p.absolute(path),
        displayName: displayName,
        format: format,
        parseResult: null,
        languageCode: _languageSuffix(path),
        errorCode: error.code,
      );
    } on Object {
      return SubtitleFileCandidate(
        path: p.absolute(path),
        displayName: displayName,
        format: format,
        parseResult: null,
        languageCode: _languageSuffix(path),
        errorCode: 'subtitle_read_failed',
      );
    }
  }

  Future<TimedSubtitleParseResult> parseFile(
    String path, {
    int? durationMs,
  }) async {
    final format = _format(path);
    final bytes = await File(path).readAsBytes();
    final body = _decode(bytes);
    final rawCues = switch (format) {
      SubtitleFormat.srt => _parseSrt(body),
      SubtitleFormat.webVtt => _parseVtt(body),
    };
    final segments = <TranscriptSegment>[];
    final speakers = <SpeakerProfile>[];
    final speakerIds = <String, String>{};
    var ignored = 0;
    var long = 0;
    for (var index = 0; index < rawCues.cues.length; index++) {
      final cue = rawCues.cues[index];
      final cleaned = _cleanText(cue.text);
      var startMs = cue.startMs;
      var endMs = cue.endMs;
      if (cleaned.text.trim().isEmpty || endMs <= startMs) {
        ignored++;
        continue;
      }
      if (durationMs != null) {
        if (startMs >= durationMs) {
          ignored++;
          continue;
        }
        endMs = min(endMs, durationMs);
        if (endMs <= startMs) {
          ignored++;
          continue;
        }
      }
      if (endMs - startMs > _maximumAlignmentWindowMs) long++;
      String? speakerId;
      final speakerName = cleaned.speaker?.trim();
      if (speakerName != null && speakerName.isNotEmpty) {
        speakerId = speakerIds.putIfAbsent(
          speakerName,
          () => 'subtitle-speaker-${speakerIds.length + 1}',
        );
        if (!speakers.any((speaker) => speaker.id == speakerId)) {
          speakers.add(SpeakerProfile(id: speakerId, name: speakerName));
        }
      }
      segments.add(
        TranscriptSegment(
          id: 'subtitle-cue-${index + 1}',
          startMs: startMs,
          endMs: endMs,
          text: cleaned.text.trim(),
          speaker: speakerId,
          preserveBoundaryBefore: true,
          alignmentWindowStartMs: startMs,
          alignmentWindowEndMs: endMs,
        ),
      );
    }
    ignored += rawCues.invalidCount;
    return TimedSubtitleParseResult(
      format: format,
      document: TranscriptDocument(
        tokens: const [],
        segments: List.unmodifiable(segments),
        speakers: List.unmodifiable(speakers),
        updatedAt: DateTime.now().toUtc(),
      ),
      ignoredCueCount: ignored,
      longCueCount: long,
    );
  }

  SubtitleFormat _format(String path) => switch (_extension(path)) {
    'srt' => SubtitleFormat.srt,
    'vtt' => SubtitleFormat.webVtt,
    _ => throw const TimedSubtitleImportException(
      'subtitle_format_unsupported',
    ),
  };

  String _decode(List<int> bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf) {
      return utf8.decode(bytes.sublist(3));
    }
    if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: false);
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return String.fromCharCodes(bytes.map(_windows1252CodePoint));
    }
  }

  String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
    final units = <int>[];
    for (var index = 0; index + 1 < bytes.length; index += 2) {
      final first = bytes[index];
      final second = bytes[index + 1];
      units.add(littleEndian ? first | (second << 8) : (first << 8) | second);
    }
    return String.fromCharCodes(units);
  }

  int _windows1252CodePoint(int byte) => _windows1252[byte] ?? byte;

  _CueParse _parseSrt(String body) {
    final cues = <_RawCue>[];
    var invalid = 0;
    final blocks = body
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split(RegExp(r'\n[ \t]*\n'));
    for (final block in blocks) {
      final lines = block.split('\n');
      if (lines.every((line) => line.trim().isEmpty)) continue;
      final timingIndex = lines.indexWhere((line) => line.contains('-->'));
      if (timingIndex < 0) {
        invalid++;
        continue;
      }
      final timing = _timing(lines[timingIndex]);
      if (timing == null) {
        invalid++;
        continue;
      }
      cues.add(
        _RawCue(
          startMs: timing.$1,
          endMs: timing.$2,
          text: lines.skip(timingIndex + 1).join('\n').trim(),
        ),
      );
    }
    return _CueParse(cues, invalid);
  }

  _CueParse _parseVtt(String body) {
    final cues = <_RawCue>[];
    var invalid = 0;
    var normalized = body.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (normalized.startsWith('\uFEFF')) normalized = normalized.substring(1);
    final firstLineEnd = normalized.indexOf('\n');
    final firstLine =
        (firstLineEnd < 0 ? normalized : normalized.substring(0, firstLineEnd))
            .trim();
    if (firstLine.toUpperCase().startsWith('WEBVTT')) {
      normalized = firstLineEnd < 0
          ? ''
          : normalized.substring(firstLineEnd + 1);
    }
    normalized = normalized.replaceFirst(RegExp(r'^\n+'), '');
    final blocks = normalized.split(RegExp(r'\n[ \t]*\n'));
    for (final block in blocks) {
      final lines = block.split('\n');
      final first = lines.firstOrNull?.trim().toUpperCase() ?? '';
      if (first.isEmpty ||
          first.startsWith('NOTE') ||
          first.startsWith('STYLE') ||
          first.startsWith('REGION')) {
        continue;
      }
      final timingIndex = lines.indexWhere((line) => line.contains('-->'));
      if (timingIndex < 0) {
        invalid++;
        continue;
      }
      final timing = _timing(lines[timingIndex]);
      if (timing == null) {
        invalid++;
        continue;
      }
      cues.add(
        _RawCue(
          startMs: timing.$1,
          endMs: timing.$2,
          text: lines.skip(timingIndex + 1).join('\n').trim(),
        ),
      );
    }
    return _CueParse(cues, invalid);
  }

  (int, int)? _timing(String raw) {
    final parts = raw.split('-->');
    if (parts.length != 2) return null;
    final start = _clock(parts.first.trim().split(RegExp(r'\s+')).first);
    final end = _clock(parts.last.trim().split(RegExp(r'\s+')).first);
    if (start == null || end == null) return null;
    return (start, end);
  }

  int? _clock(String raw) {
    final match = RegExp(
      r'^(?:(\d+):)?(\d{1,2}):(\d{2})(?:[.,](\d{1,3}))?$',
    ).firstMatch(raw);
    if (match == null) return null;
    final hours = int.parse(match.group(1) ?? '0');
    final minutes = int.parse(match.group(2)!);
    final seconds = int.parse(match.group(3)!);
    if (minutes >= 60 || seconds >= 60) return null;
    final milliseconds = int.parse((match.group(4) ?? '0').padRight(3, '0'));
    return hours * 3600000 + minutes * 60000 + seconds * 1000 + milliseconds;
  }

  _CleanedText _cleanText(String raw) {
    final voice = RegExp(
      r'<v(?:\.\S+)*\s+([^>]+)>',
      caseSensitive: false,
    ).firstMatch(raw);
    final speaker = voice?.group(1)?.trim();
    final withoutTags = raw.replaceAll(RegExp(r'<[^>]*>'), '');
    return _CleanedText(
      cleanSubtitleCaptionArtifacts(_decodeEntities(withoutTags)),
      speaker,
    );
  }

  String _decodeEntities(String value) => value
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');

  bool _isPotentialMatch(String mediaPath, String subtitlePath) {
    if (!supportedSubtitleExtensions.contains(_extension(subtitlePath)) ||
        p.dirname(p.absolute(mediaPath)) !=
            p.dirname(p.absolute(subtitlePath))) {
      return false;
    }
    final mediaStem = p.basenameWithoutExtension(mediaPath).toLowerCase();
    final subtitleStem = p.basenameWithoutExtension(subtitlePath).toLowerCase();
    return subtitleStem == mediaStem ||
        _withoutLanguageSuffix(subtitleStem) == mediaStem;
  }

  String _withoutLanguageSuffix(String stem) {
    final dot = stem.lastIndexOf('.');
    if (dot < 0) return stem;
    final suffix = stem.substring(dot + 1).replaceAll('_', '-');
    final base = suffix.split('-').first;
    return supportedAlignmentLanguageCodes.contains(base)
        ? stem.substring(0, dot)
        : stem;
  }

  String? _languageSuffix(String path) {
    final stem = p.basenameWithoutExtension(path).toLowerCase();
    final dot = stem.lastIndexOf('.');
    if (dot < 0) return null;
    final suffix = stem.substring(dot + 1).replaceAll('_', '-');
    final base = suffix.split('-').first;
    return supportedAlignmentLanguageCodes.contains(base) ? base : null;
  }

  String _extension(String path) =>
      p.extension(path).replaceFirst('.', '').toLowerCase();
}

class _RawCue {
  const _RawCue({
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  final int startMs;
  final int endMs;
  final String text;
}

class _CueParse extends Iterable<_RawCue> {
  const _CueParse(this.cues, this.invalidCount);

  final List<_RawCue> cues;
  final int invalidCount;

  @override
  Iterator<_RawCue> get iterator => cues.iterator;
}

class _CleanedText {
  const _CleanedText(this.text, this.speaker);

  final String text;
  final String? speaker;
}

const _windows1252 = <int, int>{
  0x80: 0x20ac,
  0x82: 0x201a,
  0x83: 0x0192,
  0x84: 0x201e,
  0x85: 0x2026,
  0x86: 0x2020,
  0x87: 0x2021,
  0x88: 0x02c6,
  0x89: 0x2030,
  0x8a: 0x0160,
  0x8b: 0x2039,
  0x8c: 0x0152,
  0x8e: 0x017d,
  0x91: 0x2018,
  0x92: 0x2019,
  0x93: 0x201c,
  0x94: 0x201d,
  0x95: 0x2022,
  0x96: 0x2013,
  0x97: 0x2014,
  0x98: 0x02dc,
  0x99: 0x2122,
  0x9a: 0x0161,
  0x9b: 0x203a,
  0x9c: 0x0153,
  0x9e: 0x017e,
  0x9f: 0x0178,
};

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
