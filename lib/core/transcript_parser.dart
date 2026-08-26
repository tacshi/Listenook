import 'dart:math';

import 'models.dart';
import 'subtitle_text.dart';
import 'transcript_structure_editor.dart';

final _mossSpeakerControlTag = RegExp(r'\[S\d+\]', caseSensitive: false);
final _mossStructuralControlTag = RegExp(
  r'\[(?:S\d+|\d+(?:\.\d+)?)\]',
  caseSensitive: false,
);

bool isMossControlOnlyTranscriptText(String text) {
  if (!_mossSpeakerControlTag.hasMatch(text)) return false;
  return text.replaceAll(_mossStructuralControlTag, '').trim().isEmpty;
}

class TranscriptParser {
  const TranscriptParser();

  TranscriptDocument removeImportedSubtitleCaptionArtifacts(
    TranscriptDocument source,
  ) {
    var changed = false;
    final segments = <TranscriptSegment>[];
    final retainedSegmentIds = <String>{};
    for (final segment in source.segments) {
      final text = cleanSubtitleCaptionArtifacts(
        segment.text,
        preserveLineBreaks: false,
      );
      final translatedText = segment.translatedText == null
          ? null
          : cleanSubtitleCaptionArtifacts(
              segment.translatedText!,
              preserveLineBreaks: false,
            );
      if (text.isEmpty) {
        changed = true;
        continue;
      }
      retainedSegmentIds.add(segment.id);
      if (text == segment.text && translatedText == segment.translatedText) {
        segments.add(segment);
        continue;
      }
      changed = true;
      segments.add(
        segment.copyWith(
          text: text,
          translatedText: translatedText,
          clearTranslatedText:
              segment.translatedText != null && translatedText!.isEmpty,
        ),
      );
    }
    final tokens = <TranscriptToken>[];
    for (final token in source.tokens) {
      if (token.segmentId case final owner?
          when !retainedSegmentIds.contains(owner)) {
        changed = true;
        continue;
      }
      final text = cleanSubtitleCaptionArtifacts(
        token.text,
        preserveLineBreaks: false,
      );
      if (text.isEmpty) {
        changed = true;
        continue;
      }
      if (text == token.text) {
        tokens.add(token);
        continue;
      }
      changed = true;
      tokens.add(
        TranscriptToken(
          text: text,
          startMs: token.startMs,
          endMs: token.endMs,
          segmentId: token.segmentId,
          speaker: token.speaker,
          language: token.language,
          confidence: token.confidence,
          translationStatus: token.translationStatus,
          sourceLanguage: token.sourceLanguage,
        ),
      );
    }
    if (!changed) return source;
    return TranscriptDocument(
      tokens: List.unmodifiable(tokens),
      segments: List.unmodifiable(segments),
      speakers: source.speakers,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  TranscriptDocument resegmentAlignedSubtitles(
    TranscriptDocument source,
    List<TranscriptToken> alignedTokens,
  ) {
    source = removeImportedSubtitleCaptionArtifacts(source);
    const maximumSentenceDurationMs = 24000;
    const maximumSentenceCharacters = 280;
    final tokensBySegment = <String, List<TranscriptToken>>{};
    for (final token in alignedTokens) {
      final owner = token.segmentId;
      if (owner == null) continue;
      tokensBySegment.putIfAbsent(owner, () => []).add(token);
    }
    final units = <_AlignedSubtitleUnit>[];
    for (final segment in source.segments) {
      final text = segment.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) continue;
      final owned = tokensBySegment[segment.id] ?? const [];
      final ranges = alignTranscriptTokenRanges(text, owned);
      final hasReliableRanges =
          owned.isNotEmpty &&
          ranges.length == owned.length &&
          ranges.every((range) => range != null);
      if (hasReliableRanges) {
        for (var index = 0; index < owned.length; index++) {
          final range = ranges[index]!;
          final start = index == 0 ? 0 : range.start;
          final end = index + 1 < ranges.length
              ? ranges[index + 1]!.start
              : text.length;
          var unitText = text.substring(start, end);
          if (index == 0 && units.isNotEmpty) {
            unitText = _subtitleBoundaryText(units.last.text, unitText);
          }
          final token = owned[index];
          units.add(
            _AlignedSubtitleUnit(
              text: unitText,
              startMs: token.startMs,
              endMs: token.endMs,
              alignmentWindowStartMs:
                  segment.alignmentWindowStartMs ?? segment.startMs,
              alignmentWindowEndMs:
                  segment.alignmentWindowEndMs ?? segment.endMs,
              speaker: segment.speaker,
              language: segment.language,
              token: token,
            ),
          );
        }
        continue;
      }
      final chunks = _subtitleSentenceChunks(text);
      final duration = max(0, segment.endMs - segment.startMs);
      var offset = 0;
      for (var index = 0; index < chunks.length; index++) {
        final chunk = chunks[index];
        final chunkStart = text.indexOf(chunk, offset);
        final safeStart = chunkStart < 0 ? offset : chunkStart;
        final safeEnd = min(text.length, safeStart + chunk.length);
        offset = safeEnd;
        var unitText = chunk;
        if (index == 0 && units.isNotEmpty) {
          unitText = _subtitleBoundaryText(units.last.text, unitText);
        }
        units.add(
          _AlignedSubtitleUnit(
            text: unitText,
            startMs:
                segment.startMs +
                (duration * safeStart / max(1, text.length)).round(),
            endMs:
                segment.startMs +
                (duration * safeEnd / max(1, text.length)).round(),
            alignmentWindowStartMs:
                segment.alignmentWindowStartMs ?? segment.startMs,
            alignmentWindowEndMs: segment.alignmentWindowEndMs ?? segment.endMs,
            speaker: segment.speaker,
            language: segment.language,
          ),
        );
      }
    }

    final segments = <TranscriptSegment>[];
    final tokens = <TranscriptToken>[];
    var sentence = <_AlignedSubtitleUnit>[];
    var sentenceCharacters = 0;

    void flush() {
      if (sentence.isEmpty) return;
      final text = sentence.map((unit) => unit.text).join().trim();
      if (text.isEmpty) {
        sentence = <_AlignedSubtitleUnit>[];
        sentenceCharacters = 0;
        return;
      }
      final id = 'imported-sentence-${segments.length + 1}';
      final startMs = sentence
          .map((unit) => unit.startMs)
          .reduce((left, right) => min(left, right));
      final endMs = sentence
          .map((unit) => unit.endMs)
          .reduce((left, right) => max(left, right));
      segments.add(
        TranscriptSegment(
          id: id,
          startMs: startMs,
          endMs: max(startMs, endMs),
          text: text,
          speaker: sentence
              .map((unit) => unit.speaker)
              .whereType<String>()
              .firstOrNull,
          language: sentence
              .map((unit) => unit.language)
              .whereType<String>()
              .firstOrNull,
          alignmentWindowStartMs: sentence
              .map((unit) => unit.alignmentWindowStartMs)
              .reduce((left, right) => min(left, right)),
          alignmentWindowEndMs: sentence
              .map((unit) => unit.alignmentWindowEndMs)
              .reduce((left, right) => max(left, right)),
          alignmentIncomplete: sentence.any((unit) => unit.token == null),
        ),
      );
      for (final unit in sentence) {
        final token = unit.token;
        if (token == null) continue;
        tokens.add(
          TranscriptToken(
            text: unit.text,
            startMs: token.startMs,
            endMs: token.endMs,
            segmentId: id,
            speaker: token.speaker,
            language: token.language,
            confidence: token.confidence,
            translationStatus: token.translationStatus,
            sourceLanguage: token.sourceLanguage,
          ),
        );
      }
      sentence = <_AlignedSubtitleUnit>[];
      sentenceCharacters = 0;
    }

    for (final unit in units) {
      if (sentence.isNotEmpty) {
        final previous = sentence.last;
        final speakerChanged =
            previous.speaker != null &&
            unit.speaker != null &&
            previous.speaker != unit.speaker;
        final pause = unit.startMs - previous.endMs > 1500;
        final tooLong =
            unit.endMs - sentence.first.startMs > maximumSentenceDurationMs;
        final tooLarge =
            sentenceCharacters + unit.text.length > maximumSentenceCharacters;
        if (speakerChanged || pause || tooLong || tooLarge) flush();
      }
      sentence.add(unit);
      sentenceCharacters += unit.text.length;
      if (_endsSentence(unit.text)) flush();
    }
    flush();
    return TranscriptDocument(
      tokens: List.unmodifiable(tokens),
      segments: List.unmodifiable(segments),
      speakers: source.speakers,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  TranscriptDocument parse(
    Map<String, dynamic> payload, {
    String? sonioxTranslationTargetLanguage,
  }) {
    final rawTokens = payload['tokens'] is List
        ? payload['tokens'] as List
        : payload['transcript'] is Map &&
              (payload['transcript'] as Map)['tokens'] is List
        ? (payload['transcript'] as Map)['tokens'] as List
        : const [];

    final tokens = rawTokens
        .whereType<Map>()
        .map((json) => TranscriptToken.fromJson(json.cast<String, dynamic>()))
        .where((token) => token.text.trim().isNotEmpty)
        .toList(growable: false);
    final hasSonioxTranslation =
        sonioxTranslationTargetLanguage != null ||
        tokens.any(
          (token) =>
              token.translationStatus == 'original' ||
              token.translationStatus == 'translation',
        );
    final segments = hasSonioxTranslation
        ? _translatedSegments(tokens, sonioxTranslationTargetLanguage)
        : _segments(tokens);
    final speakerIds =
        tokens
            .map((token) => token.speaker)
            .whereType<String>()
            .where((id) => id.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final speakers = <SpeakerProfile>[
      for (var index = 0; index < speakerIds.length; index++)
        SpeakerProfile(id: speakerIds[index], name: 'Speaker ${index + 1}'),
    ];

    final document = TranscriptDocument(
      tokens: tokens,
      segments: segments,
      speakers: speakers,
      updatedAt: DateTime.now().toUtc(),
    );
    return normalizeSegments(document);
  }

  /// Repairs documents produced by older parser versions that split a single
  /// sentence at an arbitrary duration boundary or emitted punctuation alone.
  TranscriptDocument normalizeSegments(TranscriptDocument document) {
    final sourceSegments = document.segments
        .where((segment) => segment.text.trim().isNotEmpty)
        .toList(growable: false);
    var changed = sourceSegments.length != document.segments.length;
    final mergedInto = <String, String>{};
    if (sourceSegments.length < 2) {
      return changed ? document.copyWith(segments: sourceSegments) : document;
    }

    final normalized = <TranscriptSegment>[];
    for (final sourceSegment in sourceSegments) {
      var segment = sourceSegment;
      if (normalized.isEmpty) {
        normalized.add(segment);
        continue;
      }

      var previous = normalized.last;
      if (segment.preserveBoundaryBefore) {
        normalized.add(segment);
        continue;
      }
      final closingQuote = _takeDetachedClosingQuote(
        previous.text,
        segment.text,
      );
      if (closingQuote != null) {
        final translatedQuote = _takeDetachedClosingQuote(
          previous.translatedText ?? '',
          segment.translatedText ?? '',
        );
        previous = TranscriptSegment(
          id: previous.id,
          startMs: previous.startMs,
          endMs: segment.startMs > previous.endMs
              ? segment.startMs
              : previous.endMs,
          text: '${previous.text.trimRight()}${closingQuote.quote}',
          speaker: previous.speaker,
          language: previous.language,
          translatedText: translatedQuote == null
              ? previous.translatedText
              : '${previous.translatedText!.trimRight()}'
                    '${translatedQuote.quote}',
          preserveBoundaryBefore: previous.preserveBoundaryBefore,
        );
        normalized[normalized.length - 1] = previous;
        segment = TranscriptSegment(
          id: segment.id,
          startMs: segment.startMs,
          endMs: segment.endMs,
          text: closingQuote.remainder,
          speaker: segment.speaker,
          language: segment.language,
          translatedText: translatedQuote == null
              ? segment.translatedText
              : translatedQuote.remainder,
          preserveBoundaryBefore: segment.preserveBoundaryBefore,
        );
        changed = true;
        if (segment.text.trim().isEmpty) {
          mergedInto[segment.id] = previous.id;
          continue;
        }
      }

      final punctuationOnly = _isPunctuationOnly(segment.text);
      final speakersCompatible =
          previous.speaker == segment.speaker ||
          previous.speaker == null ||
          segment.speaker == null;
      final timingKnown = previous.endMs > 0 && segment.startMs > 0;
      final continuous =
          !timingKnown || segment.startMs - previous.endMs <= 1500;
      final continuesSentence = !_endsSentence(previous.text);

      if (punctuationOnly ||
          (speakersCompatible && continuous && continuesSentence)) {
        mergedInto[segment.id] = previous.id;
        normalized[normalized.length - 1] = TranscriptSegment(
          id: previous.id,
          startMs: previous.startMs,
          endMs: segment.endMs > previous.endMs
              ? segment.endMs
              : previous.endMs,
          text: _joinSegmentText(previous.text, segment.text),
          speaker: previous.speaker ?? segment.speaker,
          language: previous.language ?? segment.language,
          translatedText: _joinTranslations(
            previous.translatedText,
            segment.translatedText,
          ),
          preserveBoundaryBefore: previous.preserveBoundaryBefore,
        );
        changed = true;
      } else {
        normalized.add(segment);
      }
    }

    if (!changed) return document;
    final retainedIds = normalized.map((segment) => segment.id).toSet();
    final tokens = document.tokens
        .map((token) {
          final owner = token.segmentId;
          if (owner == null) return token;
          final remappedOwner = mergedInto[owner];
          if (remappedOwner == null && retainedIds.contains(owner)) {
            return token;
          }
          return TranscriptToken(
            text: token.text,
            startMs: token.startMs,
            endMs: token.endMs,
            segmentId: remappedOwner,
            speaker: token.speaker,
            language: token.language,
            confidence: token.confidence,
            translationStatus: token.translationStatus,
            sourceLanguage: token.sourceLanguage,
          );
        })
        .toList(growable: false);
    return document.copyWith(segments: normalized, tokens: tokens);
  }

  TranscriptDocument removeMossControlOnlySegments(
    TranscriptDocument document,
  ) {
    final removedIds = document.segments
        .where(
          (segment) => isMossControlOnlyTranscriptText(segment.text.trim()),
        )
        .map((segment) => segment.id)
        .toSet();
    if (removedIds.isEmpty) return document;

    final segments = document.segments
        .where((segment) => !removedIds.contains(segment.id))
        .toList(growable: false);
    final tokens = document.tokens
        .where(
          (token) =>
              token.segmentId == null || !removedIds.contains(token.segmentId),
        )
        .toList(growable: false);
    final retainedSpeakerIds = <String>{
      for (final segment in segments)
        if (segment.speaker case final speaker?) speaker,
      for (final token in tokens)
        if (token.speaker case final speaker?) speaker,
    };
    final speakers = document.speakers
        .where((speaker) => retainedSpeakerIds.contains(speaker.id))
        .toList(growable: false);
    return document.copyWith(
      tokens: tokens,
      segments: segments,
      speakers: speakers,
    );
  }

  List<TranscriptSegment> _segments(List<TranscriptToken> tokens) {
    if (tokens.isEmpty) return const [];
    final result = <TranscriptSegment>[];
    var current = <TranscriptToken>[];

    void flush() {
      if (current.isEmpty) return;
      result.add(
        TranscriptSegment(
          id: 'segment-${result.length + 1}',
          startMs: current.first.startMs,
          endMs: current.last.endMs,
          text: current.map((token) => token.text).join().trim(),
          speaker: current.first.speaker,
          language: current
              .map((token) => token.language)
              .whereType<String>()
              .firstOrNull,
        ),
      );
      current = <TranscriptToken>[];
    }

    for (final token in tokens) {
      final punctuationOnly = _isPunctuationOnly(token.text);
      if (current.isNotEmpty && !punctuationOnly) {
        final previous = current.last;
        final speakerChanged =
            token.speaker != null &&
            previous.speaker != null &&
            token.speaker != previous.speaker;
        final hasTiming = token.startMs > 0 && previous.endMs > 0;
        final pause = hasTiming && token.startMs - previous.endMs > 1500;
        if (speakerChanged || pause) flush();
      }
      current.add(token);
      if (_endsSentence(token.text)) flush();
    }
    flush();
    return result;
  }

  List<TranscriptSegment> _translatedSegments(
    List<TranscriptToken> tokens,
    String? targetLanguage,
  ) {
    final result = <TranscriptSegment>[];
    var plain = <TranscriptToken>[];
    var originals = <TranscriptToken>[];
    var translations = <TranscriptToken>[];

    void flushPlain() {
      if (plain.isEmpty) return;
      result.addAll(_segments(plain));
      plain = <TranscriptToken>[];
    }

    void flushTranslated() {
      if (originals.isNotEmpty) {
        final timed = originals
            .where((token) => token.startMs != 0 || token.endMs != 0)
            .toList(growable: false);
        final text = originals.map((token) => token.text).join().trim();
        final language = originals
            .map((token) => token.language)
            .whereType<String>()
            .firstOrNull;
        final translated = translations
            .map((token) => token.text)
            .join()
            .trim();
        final alreadyInTarget =
            translated.isEmpty &&
            language != null &&
            targetLanguage != null &&
            language.toLowerCase() == targetLanguage.toLowerCase();
        if (text.isNotEmpty) {
          result.add(
            TranscriptSegment(
              id: '',
              startMs: timed.isEmpty ? 0 : timed.first.startMs,
              endMs: timed.isEmpty ? 0 : timed.last.endMs,
              text: text,
              speaker: originals
                  .map((token) => token.speaker)
                  .whereType<String>()
                  .firstOrNull,
              language: language,
              translatedText: translated.isNotEmpty
                  ? translated
                  : alreadyInTarget
                  ? text
                  : null,
            ),
          );
        }
      }
      originals = <TranscriptToken>[];
      translations = <TranscriptToken>[];
    }

    for (final token in tokens) {
      switch (token.translationStatus) {
        case 'translation':
          flushPlain();
          translations.add(token);
        case 'original':
          flushPlain();
          if (translations.isNotEmpty) flushTranslated();
          originals.add(token);
        default:
          flushTranslated();
          plain.add(token);
      }
    }
    flushTranslated();
    flushPlain();

    return [
      for (var index = 0; index < result.length; index++)
        TranscriptSegment(
          id: 'segment-${index + 1}',
          startMs: result[index].startMs,
          endMs: result[index].endMs,
          text: result[index].text,
          speaker: result[index].speaker,
          language: result[index].language,
          translatedText:
              result[index].translatedText ??
              (targetLanguage != null &&
                      result[index].language?.toLowerCase() ==
                          targetLanguage.toLowerCase()
                  ? result[index].text
                  : null),
        ),
    ];
  }

  bool _endsSentence(String text) =>
      RegExp(r'''[.!?。！？]["'”’)]?\s*$''').hasMatch(text);

  bool _isPunctuationOnly(String text) =>
      RegExp(r'''^\s*[,.;:!?，。；：！？、…—\-"'“”‘’()[\]{}]+\s*$''').hasMatch(text);

  ({String quote, String remainder})? _takeDetachedClosingQuote(
    String previous,
    String current,
  ) {
    if (!_endsSentence(previous)) return null;
    final match = RegExp(r'''^\s*(["”’])(?:\s+|$)''').firstMatch(current);
    if (match == null) return null;
    final quote = match.group(1)!;
    final closesPrevious = switch (quote) {
      '"' => _count(previous, '"').isOdd,
      '”' => _count(previous, '“') > _count(previous, '”'),
      '’' => _count(previous, '‘') > _count(previous, '’'),
      _ => false,
    };
    if (!closesPrevious) return null;
    return (quote: quote, remainder: current.substring(match.end).trimLeft());
  }

  int _count(String text, String character) =>
      character.allMatches(text).length;

  String _joinSegmentText(String first, String second) {
    final left = first.trimRight();
    final right = second.trimLeft();
    if (left.isEmpty || right.isEmpty || _isPunctuationOnly(right)) {
      return '$left$right';
    }
    final needsSpace =
        RegExp(r'[A-Za-z0-9,;:]$').hasMatch(left) &&
        RegExp(r'^[A-Za-z0-9]').hasMatch(right);
    return needsSpace ? '$left $right' : '$left$right';
  }

  String? _joinTranslations(String? first, String? second) {
    if (first == null || first.trim().isEmpty) return second;
    if (second == null || second.trim().isEmpty) return first;
    return _joinSegmentText(first, second);
  }
}

class _AlignedSubtitleUnit {
  const _AlignedSubtitleUnit({
    required this.text,
    required this.startMs,
    required this.endMs,
    required this.alignmentWindowStartMs,
    required this.alignmentWindowEndMs,
    this.speaker,
    this.language,
    this.token,
  });

  final String text;
  final int startMs;
  final int endMs;
  final int alignmentWindowStartMs;
  final int alignmentWindowEndMs;
  final String? speaker;
  final String? language;
  final TranscriptToken? token;
}

List<String> _subtitleSentenceChunks(String text) {
  final matches = RegExp(
    r'''.*?[.!?。！？]+["'”’)]?(?:\s+|$)|.+$''',
    dotAll: true,
  ).allMatches(text);
  final result = [
    for (final match in matches) match.group(0) ?? '',
  ].where((chunk) => chunk.isNotEmpty).toList(growable: false);
  return result.isEmpty ? [text] : result;
}

String _subtitleBoundaryText(String previous, String current) {
  final right = current.trimLeft();
  if (right.isEmpty) return right;
  final left = previous.trimRight();
  final needsSpace =
      RegExp(r'[A-Za-z0-9,;:]$').hasMatch(left) &&
      RegExp(r'^[A-Za-z0-9]').hasMatch(right);
  return needsSpace ? ' $right' : right;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
