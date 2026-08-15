import 'dart:convert';

import '../../core/models.dart';
import '../../core/podcast_models.dart';

class PublisherTranscriptParser {
  const PublisherTranscriptParser();

  PublisherTranscript parse({
    required String body,
    String? mimeType,
    String? url,
    DateTime? updatedAt,
  }) {
    final kind = _kind(mimeType: mimeType, url: url, body: body);
    final now = updatedAt ?? DateTime.now().toUtc();
    return switch (kind) {
      _TranscriptKind.vtt => _fromCues(_parseVtt(body), now),
      _TranscriptKind.srt => _fromCues(_parseSrt(body), now),
      _TranscriptKind.json => _fromJson(body, now),
      _TranscriptKind.text => throw const PodcastException(
        'podcast_transcript_untimed',
      ),
    };
  }

  PodcastTranscriptTiming classifyDocument(TranscriptDocument document) {
    final tokens = document.tokens
        .where((token) => token.text.trim().isNotEmpty)
        .toList(growable: false);
    final timed = tokens
        .where((token) => token.startMs != 0 || token.endMs != 0)
        .toList(growable: false);
    if (timed.length < 8) return PodcastTranscriptTiming.cue;
    if (_looksLikeCopiedCueTimes(document, timed)) {
      return PodcastTranscriptTiming.cue;
    }
    if (_looksEvenlyInterpolated(document, timed)) {
      return PodcastTranscriptTiming.cue;
    }
    if (_coverage(document, timed) < 0.5) return PodcastTranscriptTiming.cue;
    final distinctStarts = timed.map((token) => token.startMs).toSet();
    if (distinctStarts.length < timed.length * 0.6) {
      return PodcastTranscriptTiming.cue;
    }
    return PodcastTranscriptTiming.word;
  }

  PublisherTranscript _fromCues(List<_Cue> cues, DateTime updatedAt) {
    if (cues.isEmpty) {
      throw const PodcastException('podcast_transcript_empty');
    }
    final readableCues = _mergeAdjacentCues(cues);
    final segments = <TranscriptSegment>[];
    for (var index = 0; index < readableCues.length; index++) {
      final cue = readableCues[index];
      final text = cue.text.trim();
      if (text.isEmpty) continue;
      segments.add(
        TranscriptSegment(
          id: '${cue.startMs}',
          startMs: cue.startMs,
          endMs: cue.endMs,
          text: text,
        ),
      );
    }
    if (segments.isEmpty) {
      throw const PodcastException('podcast_transcript_empty');
    }
    return PublisherTranscript(
      timing: PodcastTranscriptTiming.cue,
      document: TranscriptDocument(
        tokens: const [],
        segments: segments,
        speakers: const [],
        updatedAt: updatedAt,
      ),
    );
  }

  List<_Cue> _mergeAdjacentCues(List<_Cue> cues) {
    const maxGapMs = 800;
    const maxDurationMs = 24000;
    const maxCharacters = 280;
    final merged = <_Cue>[];
    for (final cue in cues) {
      final text = cue.text.trim();
      if (text.isEmpty) continue;
      if (merged.isEmpty) {
        merged.add(_Cue(startMs: cue.startMs, endMs: cue.endMs, text: text));
        continue;
      }
      final previous = merged.last;
      final gapMs = cue.startMs - previous.endMs;
      final joinedText = '${previous.text} $text';
      final joinedDurationMs = cue.endMs - previous.startMs;
      final previousEndsSentence = RegExp(
        r'''[.!?]["']?$''',
      ).hasMatch(previous.text);
      if (!previousEndsSentence &&
          gapMs >= 0 &&
          gapMs <= maxGapMs &&
          joinedDurationMs <= maxDurationMs &&
          joinedText.length <= maxCharacters) {
        merged[merged.length - 1] = _Cue(
          startMs: previous.startMs,
          endMs: cue.endMs,
          text: joinedText,
        );
      } else {
        merged.add(_Cue(startMs: cue.startMs, endMs: cue.endMs, text: text));
      }
    }
    return merged;
  }

  PublisherTranscript _fromJson(String body, DateTime updatedAt) {
    final decoded = jsonDecode(body);
    if (decoded is! Map && decoded is! List) {
      throw const PodcastException('podcast_transcript_invalid');
    }
    final tokens = <TranscriptToken>[];
    final cues = <_Cue>[];
    if (decoded is List) {
      _collectJsonItems(decoded, tokens: tokens, cues: cues);
    } else {
      final map = Map<String, dynamic>.from(decoded);
      _collectJsonItems(
        map['segments'] ?? map['words'] ?? map['tokens'] ?? const [],
        tokens: tokens,
        cues: cues,
      );
    }
    if (tokens.isNotEmpty) {
      final document = TranscriptDocument(
        tokens: tokens,
        segments: cues.isEmpty
            ? _segmentsFromTokens(tokens)
            : _cuesToSegments(cues),
        speakers: const [],
        updatedAt: updatedAt,
      );
      return PublisherTranscript(
        timing: classifyDocument(document),
        document: document,
      );
    }
    if (cues.isNotEmpty) return _fromCues(cues, updatedAt);
    throw const PodcastException('podcast_transcript_empty');
  }

  void _collectJsonItems(
    Object? raw, {
    required List<TranscriptToken> tokens,
    required List<_Cue> cues,
  }) {
    if (raw is! List) return;
    for (final item in raw) {
      if (item is! Map) continue;
      final json = Map<String, dynamic>.from(item);
      final text =
          (json['text'] ?? json['body'] ?? json['word'] ?? json['value'] ?? '')
              .toString()
              .trim();
      if (text.isEmpty) continue;
      final start = _jsonMs(json, const [
        'start_ms',
        'startMs',
        'startTime',
        'start',
      ]);
      final end = _jsonMs(json, const ['end_ms', 'endMs', 'endTime', 'end']);
      final words = json['words'] ?? json['tokens'];
      if (words is List) {
        cues.add(
          _Cue(startMs: start ?? 0, endMs: end ?? start ?? 0, text: text),
        );
        _collectJsonItems(words, tokens: tokens, cues: cues);
        continue;
      }
      final looksLikeWord =
          text.split(RegExp(r'\s+')).length <= 2 &&
          (json.containsKey('word') ||
              json.containsKey('body') ||
              json.containsKey('start_ms') ||
              json.containsKey('startMs') ||
              json.containsKey('startTime') ||
              json.containsKey('start'));
      if (looksLikeWord && start != null) {
        tokens.add(
          TranscriptToken(
            text: text,
            startMs: start,
            endMs: end ?? start,
            speaker: json['speaker']?.toString(),
          ),
        );
      } else {
        cues.add(
          _Cue(startMs: start ?? 0, endMs: end ?? start ?? 0, text: text),
        );
      }
    }
  }

  int? _jsonMs(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value is num) {
        final asMilliseconds = key.toLowerCase().contains('ms');
        if (asMilliseconds) return value.round();
        return value.abs() >= 1000 ? value.round() : (value * 1000).round();
      }
      if (value is String && value.contains(':')) {
        return _clockToMs(value);
      }
    }
    return null;
  }

  List<TranscriptSegment> _cuesToSegments(List<_Cue> cues) => [
    for (final cue in cues)
      if (cue.text.trim().isNotEmpty)
        TranscriptSegment(
          id: '${cue.startMs}',
          startMs: cue.startMs,
          endMs: cue.endMs,
          text: cue.text.trim(),
        ),
  ];

  List<TranscriptSegment> _segmentsFromTokens(List<TranscriptToken> tokens) {
    final segments = <TranscriptSegment>[];
    final buffer = StringBuffer();
    var start = tokens.first.startMs;
    var end = tokens.first.endMs;
    void flush() {
      final text = buffer.toString().trim();
      if (text.isEmpty) return;
      segments.add(
        TranscriptSegment(id: '$start', startMs: start, endMs: end, text: text),
      );
    }

    for (final token in tokens) {
      final text = token.text.trim();
      if (text.isEmpty) continue;
      if (buffer.isEmpty) start = token.startMs;
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write(text);
      end = token.endMs;
      if (RegExp(r'[.!?]$').hasMatch(text) || buffer.length > 180) {
        flush();
        buffer.clear();
      }
    }
    flush();
    return segments;
  }

  bool _looksLikeCopiedCueTimes(
    TranscriptDocument document,
    List<TranscriptToken> tokens,
  ) {
    if (document.segments.isEmpty) return false;
    var copied = 0;
    for (final token in tokens) {
      for (final segment in document.segments) {
        if (token.startMs == segment.startMs && token.endMs == segment.endMs) {
          copied++;
          break;
        }
      }
    }
    return copied >= tokens.length * 0.8;
  }

  bool _looksEvenlyInterpolated(
    TranscriptDocument document,
    List<TranscriptToken> tokens,
  ) {
    for (final segment in document.segments) {
      final inCue = tokens
          .where(
            (token) =>
                token.startMs >= segment.startMs &&
                token.startMs < (segment.endMs == 0 ? 1 << 30 : segment.endMs),
          )
          .toList();
      if (inCue.length < 3) continue;
      final span = segment.endMs - segment.startMs;
      if (span <= 0) continue;
      final expected = span / inCue.length;
      var matches = 0;
      for (var index = 0; index < inCue.length; index++) {
        final start = segment.startMs + (expected * index).round();
        if ((inCue[index].startMs - start).abs() <= 2) matches++;
      }
      if (matches >= inCue.length - 1) return true;
    }
    return false;
  }

  double _coverage(TranscriptDocument document, List<TranscriptToken> tokens) {
    if (document.segments.isEmpty) return 1;
    final start = document.segments.first.startMs;
    final end = document.segments.last.endMs;
    final span = end - start;
    if (span <= 0) return 1;
    final tokenStart = tokens.first.startMs;
    final tokenEnd = tokens.last.endMs;
    final overlap =
        (tokenEnd < end ? tokenEnd : end) -
        (tokenStart > start ? tokenStart : start);
    return overlap <= 0 ? 0 : overlap / span;
  }

  _TranscriptKind _kind({
    required String? mimeType,
    required String? url,
    required String body,
  }) {
    final type = mimeType?.split(';').first.trim().toLowerCase() ?? '';
    final path = (Uri.tryParse(url ?? '')?.path ?? url ?? '').toLowerCase();
    if (type.contains('vtt') || path.endsWith('.vtt')) {
      return _TranscriptKind.vtt;
    }
    if (type.contains('srt') ||
        type.contains('subrip') ||
        path.endsWith('.srt')) {
      return _TranscriptKind.srt;
    }
    if (type.contains('json') || path.endsWith('.json')) {
      return _TranscriptKind.json;
    }
    final trimmed = body.trimLeft();
    if (trimmed.startsWith('WEBVTT')) return _TranscriptKind.vtt;
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      return _TranscriptKind.json;
    }
    if (RegExp(r'^\d+\s*$', multiLine: true).hasMatch(trimmed) &&
        trimmed.contains('-->')) {
      return _TranscriptKind.srt;
    }
    if (trimmed.contains('-->')) return _TranscriptKind.vtt;
    return _TranscriptKind.text;
  }

  List<_Cue> _parseVtt(String body) {
    final cues = <_Cue>[];
    final lines = body.replaceAll('\r\n', '\n').split('\n');
    var index = 0;
    if (lines.isNotEmpty &&
        lines.first.trim().toUpperCase().startsWith('WEBVTT')) {
      index = 1;
    }
    while (index < lines.length) {
      final line = lines[index].trim();
      if (line.isEmpty || line.startsWith('NOTE') || line.startsWith('STYLE')) {
        index++;
        continue;
      }
      var timing = line;
      if (!timing.contains('-->') && index + 1 < lines.length) {
        timing = lines[index + 1].trim();
        index++;
      }
      final range = _parseTiming(timing);
      index++;
      if (range == null) continue;
      final text = <String>[];
      while (index < lines.length && lines[index].trim().isNotEmpty) {
        text.add(lines[index].trim());
        index++;
      }
      cues.add(_Cue(startMs: range.$1, endMs: range.$2, text: text.join(' ')));
    }
    return cues;
  }

  List<_Cue> _parseSrt(String body) {
    final cues = <_Cue>[];
    final blocks = body.replaceAll('\r\n', '\n').split(RegExp(r'\n\s*\n'));
    for (final block in blocks) {
      final lines = block
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
      if (lines.length < 2) continue;
      final timingIndex = lines[0].contains('-->') ? 0 : 1;
      if (timingIndex >= lines.length) continue;
      final range = _parseTiming(lines[timingIndex].replaceAll(',', '.'));
      if (range == null) continue;
      cues.add(
        _Cue(
          startMs: range.$1,
          endMs: range.$2,
          text: lines.skip(timingIndex + 1).join(' '),
        ),
      );
    }
    return cues;
  }

  (int, int)? _parseTiming(String raw) {
    final match = RegExp(
      r'(\d{1,2}:)?\d{1,2}:\d{2}[.,]\d{1,3}\s*-->\s*(\d{1,2}:)?\d{1,2}:\d{2}[.,]\d{1,3}',
    ).firstMatch(raw.replaceAll(',', '.'));
    if (match == null) return null;
    final parts = raw.split('-->');
    if (parts.length < 2) return null;
    final start = _clockToMs(parts[0].trim().split(' ').first);
    final end = _clockToMs(parts[1].trim().split(' ').first);
    if (start == null || end == null) return null;
    return (start, end);
  }

  int? _clockToMs(String raw) {
    final value = raw.trim().replaceAll(',', '.');
    final match = RegExp(
      r'^(?:(\d{1,2}):)?(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?$',
    ).firstMatch(value);
    if (match == null) return null;
    final hours = int.parse(match.group(1) ?? '0');
    final minutes = int.parse(match.group(2)!);
    final seconds = int.parse(match.group(3)!);
    final fraction = match.group(4) ?? '0';
    final millis = int.parse(fraction.padRight(3, '0'));
    return (((hours * 60) + minutes) * 60 + seconds) * 1000 + millis;
  }
}

enum _TranscriptKind { vtt, srt, json, text }

class _Cue {
  const _Cue({required this.startMs, required this.endMs, required this.text});
  final int startMs;
  final int endMs;
  final String text;
}
