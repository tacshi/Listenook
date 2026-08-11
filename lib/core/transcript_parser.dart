import 'models.dart';

class TranscriptParser {
  const TranscriptParser();

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
    return hasSonioxTranslation ? normalizeSegments(document) : document;
  }

  /// Repairs documents produced by older parser versions that split a single
  /// sentence at an arbitrary duration boundary or emitted punctuation alone.
  TranscriptDocument normalizeSegments(TranscriptDocument document) {
    final sourceSegments = document.segments
        .where((segment) => segment.text.trim().isNotEmpty)
        .toList(growable: false);
    var changed = sourceSegments.length != document.segments.length;
    if (sourceSegments.length < 2) {
      return changed ? document.copyWith(segments: sourceSegments) : document;
    }

    final normalized = <TranscriptSegment>[];
    for (final segment in sourceSegments) {
      if (normalized.isEmpty) {
        normalized.add(segment);
        continue;
      }

      final previous = normalized.last;
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
        );
        changed = true;
      } else {
        normalized.add(segment);
      }
    }

    return changed ? document.copyWith(segments: normalized) : document;
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

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
