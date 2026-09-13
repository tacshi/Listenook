import 'dart:math';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';

sealed class TranscriptStructureEdit {
  const TranscriptStructureEdit();
}

class SplitAtTokenBoundary extends TranscriptStructureEdit {
  const SplitAtTokenBoundary(this.segmentId, {required this.rightTokenIndex});

  final String segmentId;
  final int rightTokenIndex;
}

class MergeWithNext extends TranscriptStructureEdit {
  const MergeWithNext(this.leftSegmentId);

  final String leftSegmentId;
}

enum TranscriptStructureFailureReason {
  segmentNotFound,
  invalidBoundary,
  insufficientTiming,
  incompatibleSpeaker,
  incompatibleLanguage,
  duplicateSegmentId,
  busy,
}

sealed class TranscriptStructureEditOutcome {
  const TranscriptStructureEditOutcome();
}

class TranscriptStructureEditFailure extends TranscriptStructureEditOutcome {
  const TranscriptStructureEditFailure(this.reason);

  final TranscriptStructureFailureReason reason;
}

class TranscriptStructureEditResult extends TranscriptStructureEditOutcome {
  const TranscriptStructureEditResult({
    required this.document,
    required this.focusMs,
    required this.affectedSegmentIds,
    required this.segmentIdReplacements,
  });

  final TranscriptDocument document;
  final int focusMs;
  final Set<String> affectedSegmentIds;
  final Map<String, List<String>> segmentIdReplacements;
}

class TranscriptSplitTarget {
  const TranscriptSplitTarget({
    required this.rightTokenIndex,
    required this.textOffset,
    required this.focusMs,
  });

  final int rightTokenIndex;
  final int textOffset;
  final int focusMs;
}

class TranscriptStructureEditor {
  TranscriptStructureEditor({String Function()? idGenerator})
    : _idGenerator = idGenerator ?? const Uuid().v4;

  final String Function() _idGenerator;

  TranscriptStructureEditOutcome apply(
    TranscriptDocument document,
    TranscriptStructureEdit edit,
  ) => switch (edit) {
    SplitAtTokenBoundary() => _split(document, edit),
    MergeWithNext() => _merge(document, edit),
  };

  bool hasAvailableEdit(TranscriptDocument document) {
    for (var index = 0; index + 1 < document.segments.length; index++) {
      if (canMergeWithNext(document, index)) return true;
    }
    if (document.tokens.length < 2) return false;
    final tokensBySegment = _groupOwnedTokens(document);
    for (final segment in document.segments) {
      if (_splitTargetsFor(
        segment,
        tokensBySegment[segment.id] ?? const [],
      ).isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  bool canMergeWithNext(TranscriptDocument document, int leftIndex) {
    if (leftIndex < 0 || leftIndex + 1 >= document.segments.length) {
      return false;
    }
    final left = document.segments[leftIndex];
    final right = document.segments[leftIndex + 1];
    return (left.speaker == null ||
            right.speaker == null ||
            left.speaker == right.speaker) &&
        (left.language == null ||
            right.language == null ||
            left.language == right.language);
  }

  List<TranscriptSplitTarget> splitTargets(
    TranscriptDocument document,
    String segmentId,
  ) {
    final segmentIndex = document.segments.indexWhere(
      (segment) => segment.id == segmentId,
    );
    if (segmentIndex < 0) return const [];
    final segment = document.segments[segmentIndex];
    final owned = _ownedTokens(document, segment, segmentIndex);
    return _splitTargetsFor(segment, owned);
  }

  List<TranscriptSplitTarget> _splitTargetsFor(
    TranscriptSegment segment,
    List<_OwnedToken> owned,
  ) {
    if (owned.length < 2) return const [];
    final ranges = alignTranscriptTokenRanges(
      segment.text,
      owned.map((item) => item.token).toList(growable: false),
    );
    if (!_onlyPunctuationIsUnmapped(segment.text, ranges)) return const [];
    final result = <TranscriptSplitTarget>[];
    for (var rightIndex = 1; rightIndex < owned.length; rightIndex++) {
      final right = owned[rightIndex].token;
      final range = ranges[rightIndex];
      if (range == null || _punctuationOnly(right.text)) continue;
      final leftText = segment.text.substring(0, range.start).trim();
      final rightText = segment.text.substring(range.start).trim();
      if (leftText.isEmpty ||
          rightText.isEmpty ||
          _punctuationOnly(leftText) ||
          _punctuationOnly(rightText)) {
        continue;
      }
      if (!_hasLexicalToken(owned.take(rightIndex)) ||
          !_hasLexicalToken(owned.skip(rightIndex))) {
        continue;
      }
      final timing = _splitTimingAtBoundary(segment, owned, rightIndex);
      if (timing == null) continue;
      result.add(
        TranscriptSplitTarget(
          rightTokenIndex: rightIndex,
          textOffset: range.start,
          focusMs: timing.$2,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  TranscriptStructureEditOutcome _split(
    TranscriptDocument document,
    SplitAtTokenBoundary edit,
  ) {
    final segmentIndex = document.segments.indexWhere(
      (segment) => segment.id == edit.segmentId,
    );
    if (segmentIndex < 0) {
      return const TranscriptStructureEditFailure(
        TranscriptStructureFailureReason.segmentNotFound,
      );
    }
    final segment = document.segments[segmentIndex];
    final owned = _ownedTokens(document, segment, segmentIndex);
    final target = splitTargets(
      document,
      edit.segmentId,
    ).where((item) => item.rightTokenIndex == edit.rightTokenIndex).firstOrNull;
    if (target == null) {
      return TranscriptStructureEditFailure(
        owned.length < 2
            ? TranscriptStructureFailureReason.insufficientTiming
            : TranscriptStructureFailureReason.invalidBoundary,
      );
    }
    final newId = _uniqueId(document);
    if (newId == null) {
      return const TranscriptStructureEditFailure(
        TranscriptStructureFailureReason.duplicateSegmentId,
      );
    }
    final timing = _splitTimingAtBoundary(
      segment,
      owned,
      edit.rightTokenIndex,
    )!;
    final left = TranscriptSegment(
      id: segment.id,
      startMs: segment.startMs,
      endMs: timing.$1,
      text: segment.text.substring(0, target.textOffset).trim(),
      speaker: segment.speaker,
      language: segment.language,
      preserveBoundaryBefore: segment.preserveBoundaryBefore,
    );
    final right = TranscriptSegment(
      id: newId,
      startMs: timing.$2,
      endMs: segment.endMs,
      text: segment.text.substring(target.textOffset).trim(),
      speaker: segment.speaker,
      language: segment.language,
      preserveBoundaryBefore: true,
    );
    final rightTokenIndexes = {
      for (final item in owned.skip(edit.rightTokenIndex)) item.documentIndex,
    };
    final tokens = [
      for (var index = 0; index < document.tokens.length; index++)
        if (rightTokenIndexes.contains(index))
          _copyToken(document.tokens[index], segmentId: newId)
        else
          document.tokens[index],
    ];
    final segments = [
      ...document.segments.take(segmentIndex),
      left,
      right,
      ...document.segments.skip(segmentIndex + 1),
    ];
    return TranscriptStructureEditResult(
      document: document.copyWith(tokens: tokens, segments: segments),
      focusMs: timing.$2,
      affectedSegmentIds: {segment.id, newId},
      segmentIdReplacements: {
        segment.id: [segment.id, newId],
      },
    );
  }

  TranscriptStructureEditOutcome _merge(
    TranscriptDocument document,
    MergeWithNext edit,
  ) {
    final leftIndex = document.segments.indexWhere(
      (segment) => segment.id == edit.leftSegmentId,
    );
    if (leftIndex < 0) {
      return const TranscriptStructureEditFailure(
        TranscriptStructureFailureReason.segmentNotFound,
      );
    }
    if (leftIndex + 1 >= document.segments.length) {
      return const TranscriptStructureEditFailure(
        TranscriptStructureFailureReason.invalidBoundary,
      );
    }
    final left = document.segments[leftIndex];
    final right = document.segments[leftIndex + 1];
    if (left.speaker != null &&
        right.speaker != null &&
        left.speaker != right.speaker) {
      return const TranscriptStructureEditFailure(
        TranscriptStructureFailureReason.incompatibleSpeaker,
      );
    }
    if (left.language != null &&
        right.language != null &&
        left.language != right.language) {
      return const TranscriptStructureEditFailure(
        TranscriptStructureFailureReason.incompatibleLanguage,
      );
    }
    final leftTranslation = left.translatedText?.trim();
    final rightTranslation = right.translatedText?.trim();
    final translated =
        leftTranslation?.isNotEmpty == true &&
            rightTranslation?.isNotEmpty == true
        ? _joinText(leftTranslation!, rightTranslation!)
        : null;
    final merged = TranscriptSegment(
      id: left.id,
      startMs: min(left.startMs, right.startMs),
      endMs: max(left.endMs, right.endMs),
      text: _joinText(left.text, right.text),
      speaker: left.speaker ?? right.speaker,
      language: left.language ?? right.language,
      translatedText: translated,
      preserveBoundaryBefore: left.preserveBoundaryBefore,
    );
    final rightTokenIndexes = {
      for (final item in _ownedTokens(document, right, leftIndex + 1))
        item.documentIndex,
    };
    final tokens = [
      for (var index = 0; index < document.tokens.length; index++)
        if (rightTokenIndexes.contains(index))
          _copyToken(document.tokens[index], segmentId: left.id)
        else
          document.tokens[index],
    ];
    final segments = [
      ...document.segments.take(leftIndex),
      merged,
      ...document.segments.skip(leftIndex + 2),
    ];
    return TranscriptStructureEditResult(
      document: document.copyWith(tokens: tokens, segments: segments),
      focusMs: right.startMs,
      affectedSegmentIds: {left.id, right.id},
      segmentIdReplacements: {
        right.id: [left.id],
      },
    );
  }

  String? _uniqueId(TranscriptDocument document) {
    final existing = document.segments.map((segment) => segment.id).toSet();
    for (var attempt = 0; attempt < 32; attempt++) {
      final candidate = _idGenerator();
      if (candidate.isNotEmpty && !existing.contains(candidate)) {
        return candidate;
      }
    }
    return null;
  }
}

class _OwnedToken {
  const _OwnedToken(this.documentIndex, this.token);

  final int documentIndex;
  final TranscriptToken token;
}

List<_OwnedToken> _ownedTokens(
  TranscriptDocument document,
  TranscriptSegment segment,
  int segmentIndex,
) {
  final nextStart = segmentIndex + 1 < document.segments.length
      ? document.segments[segmentIndex + 1].startMs
      : null;
  return [
    for (var index = 0; index < document.tokens.length; index++)
      if (_tokenBelongsToSegment(document.tokens[index], segment, nextStart))
        _OwnedToken(index, document.tokens[index]),
  ];
}

Map<String, List<_OwnedToken>> _groupOwnedTokens(TranscriptDocument document) {
  final result = <String, List<_OwnedToken>>{
    for (final segment in document.segments) segment.id: <_OwnedToken>[],
  };
  for (var tokenIndex = 0; tokenIndex < document.tokens.length; tokenIndex++) {
    final token = document.tokens[tokenIndex];
    if (token.translationStatus == 'translation') continue;
    final segmentId = token.segmentId;
    if (segmentId != null && result.containsKey(segmentId)) {
      result[segmentId]!.add(_OwnedToken(tokenIndex, token));
      continue;
    }
    if (token.startMs == 0 && token.endMs == 0) continue;
    final segmentIndex = _segmentIndexAtOrBefore(
      document.segments,
      token.startMs,
    );
    if (segmentIndex == null) continue;
    final segment = document.segments[segmentIndex];
    final nextStart = segmentIndex + 1 < document.segments.length
        ? document.segments[segmentIndex + 1].startMs
        : null;
    if (_tokenBelongsToSegment(token, segment, nextStart)) {
      result[segment.id]!.add(_OwnedToken(tokenIndex, token));
    }
  }
  return result;
}

int? _segmentIndexAtOrBefore(List<TranscriptSegment> segments, int positionMs) {
  if (segments.isEmpty || positionMs < segments.first.startMs) return null;
  var low = 0;
  var high = segments.length - 1;
  while (low <= high) {
    final middle = (low + high) >> 1;
    if (segments[middle].startMs <= positionMs) {
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return high;
}

bool _tokenBelongsToSegment(
  TranscriptToken token,
  TranscriptSegment segment,
  int? nextStartMs,
) {
  if (token.translationStatus == 'translation') return false;
  if (token.segmentId != null) return token.segmentId == segment.id;
  if (token.startMs == 0 && token.endMs == 0) return false;
  return token.startMs >= segment.startMs &&
      token.startMs < (nextStartMs ?? segment.endMs + 1) &&
      token.startMs <= segment.endMs;
}

(int, int)? _splitTimingAtBoundary(
  TranscriptSegment segment,
  List<_OwnedToken> tokens,
  int rightIndex,
) {
  final right = tokens[rightIndex].token;
  TranscriptToken? left;
  for (final item in tokens.take(rightIndex)) {
    if (_hasTiming(item.token)) left = item.token;
  }
  if (left == null) return null;
  if ((left.startMs == 0 && left.endMs == 0) ||
      (right.startMs == 0 && right.endMs == 0)) {
    return null;
  }
  var leftEnd = left.endMs.clamp(segment.startMs, segment.endMs);
  var rightStart = right.startMs.clamp(segment.startMs, segment.endMs);
  if (leftEnd > rightStart) {
    final shared = ((leftEnd + rightStart) ~/ 2).clamp(
      segment.startMs,
      segment.endMs,
    );
    leftEnd = shared;
    rightStart = shared;
  }
  if (leftEnd <= segment.startMs || rightStart >= segment.endMs) return null;
  return (leftEnd, rightStart);
}

bool _hasTiming(TranscriptToken token) =>
    token.startMs != 0 || token.endMs != 0;

TranscriptToken _copyToken(
  TranscriptToken token, {
  required String segmentId,
}) => TranscriptToken(
  text: token.text,
  startMs: token.startMs,
  endMs: token.endMs,
  segmentId: segmentId,
  speaker: token.speaker,
  language: token.language,
  confidence: token.confidence,
  translationStatus: token.translationStatus,
  sourceLanguage: token.sourceLanguage,
);

bool _hasLexicalToken(Iterable<_OwnedToken> tokens) => tokens.any(
  (item) =>
      !_punctuationOnly(item.token.text) && item.token.text.trim().isNotEmpty,
);

bool _punctuationOnly(String text) {
  final value = text.trim();
  return value.isNotEmpty &&
      value.codeUnits.every(
        (codeUnit) =>
            _isPunctuationCodeUnit(codeUnit) || _isWhitespaceCodeUnit(codeUnit),
      );
}

String _joinText(String first, String second) {
  final left = first.trimRight();
  final right = second.trimLeft();
  if (left.isEmpty || right.isEmpty || _punctuationOnly(right)) {
    return '$left$right';
  }
  final leftCodePoint = left.runes.last;
  final rightCodePoint = right.runes.first;
  final needsSpace =
      !_usesCompactSpacing(leftCodePoint) &&
      !_usesCompactSpacing(rightCodePoint) &&
      !_isOpeningPunctuation(leftCodePoint);
  return needsSpace ? '$left $right' : '$left$right';
}

bool _onlyPunctuationIsUnmapped(String text, List<TextRange?> ranges) {
  var cursor = 0;
  for (final range in ranges.whereType<TextRange>()) {
    if (range.start < cursor || range.end > text.length) return false;
    if (!_ignorableUnmappedText(text.substring(cursor, range.start))) {
      return false;
    }
    cursor = range.end;
  }
  return _ignorableUnmappedText(text.substring(cursor));
}

bool _ignorableUnmappedText(String text) =>
    text.trim().isEmpty || _punctuationOnly(text);

bool _usesCompactSpacing(int codePoint) =>
    (codePoint >= 0x0e00 && codePoint <= 0x0eff) ||
    (codePoint >= 0x1000 && codePoint <= 0x109f) ||
    (codePoint >= 0x1780 && codePoint <= 0x17ff) ||
    (codePoint >= 0x2e80 && codePoint <= 0x9fff) ||
    (codePoint >= 0xac00 && codePoint <= 0xd7af) ||
    (codePoint >= 0xf900 && codePoint <= 0xfaff) ||
    (codePoint >= 0x20000 && codePoint <= 0x3134f);

bool _isOpeningPunctuation(int codePoint) => const {
  0x28,
  0x5b,
  0x7b,
  0xab,
  0x2018,
  0x201c,
  0x3008,
  0x300a,
  0x300c,
  0x300e,
  0x3010,
  0xff08,
  0xff3b,
  0xff5b,
}.contains(codePoint);

bool _isWhitespaceCodeUnit(int codeUnit) =>
    String.fromCharCode(codeUnit).trim().isEmpty;

bool _isPunctuationCodeUnit(int codeUnit) =>
    (codeUnit >= 0x21 && codeUnit <= 0x2f) ||
    (codeUnit >= 0x3a && codeUnit <= 0x40) ||
    (codeUnit >= 0x5b && codeUnit <= 0x60) ||
    (codeUnit >= 0x7b && codeUnit <= 0x7e) ||
    (codeUnit >= 0x2000 && codeUnit <= 0x206f) ||
    (codeUnit >= 0x2e00 && codeUnit <= 0x2e7f) ||
    (codeUnit >= 0x3000 && codeUnit <= 0x303f) ||
    (codeUnit >= 0xfe10 && codeUnit <= 0xfe1f) ||
    (codeUnit >= 0xfe30 && codeUnit <= 0xfe4f) ||
    (codeUnit >= 0xff01 && codeUnit <= 0xff0f) ||
    (codeUnit >= 0xff1a && codeUnit <= 0xff20) ||
    (codeUnit >= 0xff3b && codeUnit <= 0xff40) ||
    (codeUnit >= 0xff5b && codeUnit <= 0xff65);

List<TextRange?> alignTranscriptTokenRanges(
  String text,
  List<TranscriptToken> tokens,
) {
  if (tokens.isEmpty) return const [];
  final raw = StringBuffer();
  final rawRanges = <TextRange>[];
  for (final token in tokens) {
    final start = raw.length;
    raw.write(token.text);
    rawRanges.add(TextRange(start: start, end: raw.length));
  }
  final joined = raw.toString();
  final leading = joined.length - joined.trimLeft().length;
  final trailing = joined.trimRight().length;
  final normalized = joined.substring(leading, trailing);
  if (normalized == text) {
    return [
      for (final range in rawRanges)
        TextRange(
          start: (range.start - leading).clamp(0, text.length),
          end: (range.end - leading).clamp(0, text.length),
        ),
    ];
  }

  final normalizedText = text.toLowerCase();
  final result = <TextRange?>[];
  var cursor = 0;
  for (final token in tokens) {
    final part = token.text.trim();
    if (part.isEmpty) {
      result.add(null);
      continue;
    }
    final match = normalizedText.indexOf(part.toLowerCase(), cursor);
    if (match < 0) {
      result.add(null);
      continue;
    }
    final end = match + part.length;
    result.add(TextRange(start: match, end: end));
    cursor = end;
  }
  return result;
}
