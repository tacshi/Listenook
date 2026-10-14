import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../core/contracts.dart';
import '../core/models.dart';
import '../core/subtitle_text.dart';

const supportedSubtitleExtensions = {'srt', 'vtt', 'ass', 'ssa'};
const supportedSubtitleLanguageCodes = {
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
  });

  final SubtitleFormat format;
  final TranscriptDocument document;
  final int ignoredCueCount;
}

class SubtitleFileCandidate {
  const SubtitleFileCandidate({
    required this.path,
    required this.displayName,
    required this.format,
    required this.parseResult,
    this.errorCode,
  });

  final String path;
  final String displayName;
  final SubtitleFormat format;
  final TimedSubtitleParseResult? parseResult;
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
  const SubtitleImportSelection({required this.media, this.subtitle});

  final ResolvedMediaSource media;
  final SubtitleFileCandidate? subtitle;
}

class TimedSubtitleImportException implements Exception {
  const TimedSubtitleImportException(this.code);

  final String code;
}

class TimedSubtitleImportService {
  const TimedSubtitleImportService();

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
      segments.add(segment.copyWith(endMs: endMs));
    }
    return TimedSubtitleParseResult(
      format: source.format,
      document: source.document.copyWith(segments: segments),
      ignoredCueCount: ignored,
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
        errorCode: error.code,
      );
    } on Object {
      return SubtitleFileCandidate(
        path: p.absolute(path),
        displayName: displayName,
        format: format,
        parseResult: null,
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
      SubtitleFormat.ass => _CueParse(parseAssScript(body), 0),
      SubtitleFormat.movText => throw const TimedSubtitleImportException(
        'subtitle_format_unsupported',
      ),
    };
    return documentFromCues(
      rawCues.cues,
      format: format,
      invalidCount: rawCues.invalidCount,
      durationMs: durationMs,
    );
  }

  /// Builds the transcript document shared by subtitle files and subtitle
  /// tracks embedded in a video container.
  TimedSubtitleParseResult documentFromCues(
    List<TimedSubtitleCue> cues, {
    required SubtitleFormat format,
    int invalidCount = 0,
    int? durationMs,
  }) {
    final rawCues = _CueParse(cues, invalidCount);
    final segments = <TranscriptSegment>[];
    final speakers = <SpeakerProfile>[];
    final speakerIds = <String, String>{};
    var ignored = 0;
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
    );
  }

  SubtitleFormat _format(String path) => switch (_extension(path)) {
    'srt' => SubtitleFormat.srt,
    'vtt' => SubtitleFormat.webVtt,
    'ass' || 'ssa' => SubtitleFormat.ass,
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
    final cues = <TimedSubtitleCue>[];
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
        TimedSubtitleCue(
          startMs: timing.$1,
          endMs: timing.$2,
          text: lines.skip(timingIndex + 1).join('\n').trim(),
        ),
      );
    }
    return _CueParse(cues, invalid);
  }

  _CueParse _parseVtt(String body) {
    final cues = <TimedSubtitleCue>[];
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
        TimedSubtitleCue(
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

  /// Subtitle files beside [mediaPath] whose name matches the media, such as
  /// `movie.srt` or `movie.en.ass`.
  Future<List<String>> subtitleSidecarsFor(String mediaPath) async {
    final matches = <String>[];
    try {
      await for (final entity in Directory(
        p.dirname(p.absolute(mediaPath)),
      ).list(followLinks: false)) {
        if (entity is File && _isPotentialMatch(mediaPath, entity.path)) {
          matches.add(p.absolute(entity.path));
        }
      }
    } on FileSystemException {
      return const [];
    }
    matches.sort(
      (left, right) => p.basename(left).compareTo(p.basename(right)),
    );
    return matches;
  }

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
    return supportedSubtitleLanguageCodes.contains(base)
        ? stem.substring(0, dot)
        : stem;
  }

  String _extension(String path) =>
      p.extension(path).replaceFirst('.', '').toLowerCase();
}

class TimedSubtitleCue {
  const TimedSubtitleCue({
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  final int startMs;
  final int endMs;
  final String text;
}

const _defaultAssEventFields = [
  'layer',
  'start',
  'end',
  'style',
  'name',
  'marginl',
  'marginr',
  'marginv',
  'effect',
  'text',
];

/// Reads the `Dialogue:` events of an ASS/SSA script as plain-text cues.
///
/// Styling is dropped. Events that share a time range (positioned lines,
/// shadow layers) collapse into one cue so sentence navigation sees a single
/// subtitle per moment.
List<TimedSubtitleCue> parseAssScript(String body) {
  var fields = _defaultAssEventFields;
  var inEvents = false;
  final cues = <TimedSubtitleCue>[];
  for (final rawLine in const LineSplitter().convert(body)) {
    final line = rawLine.trim();
    if (line.startsWith('[')) {
      inEvents = line.toLowerCase() == '[events]';
      continue;
    }
    if (!inEvents) continue;
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final kind = line.substring(0, colon).trim().toLowerCase();
    final value = line.substring(colon + 1).trimLeft();
    if (kind == 'format') {
      fields = value
          .split(',')
          .map((field) => field.trim().toLowerCase())
          .toList(growable: false);
      continue;
    }
    if (kind != 'dialogue') continue;
    final textIndex = fields.indexOf('text');
    if (textIndex < 0) continue;
    final parts = _splitAssFields(value, fields.length);
    if (parts.length <= textIndex) continue;
    final start = _assClock(parts[fields.indexOf('start')]);
    final end = _assClock(parts[fields.indexOf('end')]);
    if (start == null || end == null) continue;
    final text = cleanAssText(parts[textIndex]);
    if (text.isEmpty) continue;
    cues.add(TimedSubtitleCue(startMs: start, endMs: end, text: text));
  }
  return mergeSimultaneousCues(cues);
}

/// Extracts the text of one Matroska ASS/SSA block, whose payload is
/// `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`.
String matroskaAssBlockText(String payload) {
  final parts = _splitAssFields(payload, 9);
  return parts.length < 9 ? '' : cleanAssText(parts.last);
}

/// Removes ASS override blocks and drawings, keeping the spoken text.
String cleanAssText(String raw) {
  final drawing = RegExp(r'\\p[1-9]');
  final buffer = StringBuffer();
  var drawingMode = false;
  var index = 0;
  while (index < raw.length) {
    if (raw[index] == '{') {
      final close = raw.indexOf('}', index);
      if (close < 0) break;
      final block = raw.substring(index, close + 1);
      if (drawing.hasMatch(block)) {
        drawingMode = true;
      } else if (block.contains(r'\p0')) {
        drawingMode = false;
      }
      index = close + 1;
      continue;
    }
    if (!drawingMode) buffer.write(raw[index]);
    index++;
  }
  final text = buffer
      .toString()
      .replaceAll(r'\N', '\n')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\h', ' ');
  return cleanSubtitleCaptionArtifacts(text);
}

List<TimedSubtitleCue> mergeSimultaneousCues(List<TimedSubtitleCue> cues) {
  final sorted = List.of(cues)
    ..sort((left, right) {
      final start = left.startMs.compareTo(right.startMs);
      return start != 0 ? start : left.endMs.compareTo(right.endMs);
    });
  final merged = <TimedSubtitleCue>[];
  for (final cue in sorted) {
    final last = merged.isEmpty ? null : merged.last;
    if (last != null &&
        last.startMs == cue.startMs &&
        last.endMs == cue.endMs) {
      if (!'\n${last.text}\n'.contains('\n${cue.text}\n')) {
        merged[merged.length - 1] = TimedSubtitleCue(
          startMs: last.startMs,
          endMs: last.endMs,
          text: '${last.text}\n${cue.text}',
        );
      }
      continue;
    }
    merged.add(cue);
  }
  return merged;
}

List<String> _splitAssFields(String value, int count) {
  final parts = <String>[];
  var start = 0;
  while (parts.length < count - 1) {
    final comma = value.indexOf(',', start);
    if (comma < 0) break;
    parts.add(value.substring(start, comma).trim());
    start = comma + 1;
  }
  parts.add(value.substring(start));
  return parts;
}

int? _assClock(String raw) {
  final match = RegExp(
    r'^(\d+):(\d{1,2}):(\d{1,2})(?:[.,](\d{1,3}))?$',
  ).firstMatch(raw.trim());
  if (match == null) return null;
  final fraction = (match.group(4) ?? '0').padRight(3, '0');
  return int.parse(match.group(1)!) * 3600000 +
      int.parse(match.group(2)!) * 60000 +
      int.parse(match.group(3)!) * 1000 +
      int.parse(fraction);
}

class _CueParse extends Iterable<TimedSubtitleCue> {
  const _CueParse(this.cues, this.invalidCount);

  final List<TimedSubtitleCue> cues;
  final int invalidCount;

  @override
  Iterator<TimedSubtitleCue> get iterator => cues.iterator;
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
