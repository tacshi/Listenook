import 'package:flutter/material.dart';

import '../../core/models.dart';

class PlaybackHighlightedText extends StatelessWidget {
  const PlaybackHighlightedText({
    super.key,
    required this.text,
    required this.tokens,
    required this.positionMs,
    required this.segmentStartMs,
    required this.segmentEndMs,
    this.enabled = true,
    this.style,
    this.textAlign = TextAlign.start,
  });

  final String text;
  final List<TranscriptToken> tokens;
  final int positionMs;
  final int segmentStartMs;
  final int segmentEndMs;
  final bool enabled;
  final TextStyle? style;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    final currentRange = enabled
        ? currentTimedTextRange(
            text: text,
            tokens: tokens,
            positionMs: positionMs,
            segmentStartMs: segmentStartMs,
            segmentEndMs: segmentEndMs,
          )
        : null;
    final selectionColor =
        DefaultSelectionStyle.of(context).selectionColor ??
        Theme.of(context).colorScheme.primaryContainer;
    final highlight = TextStyle(backgroundColor: selectionColor);
    final spans = <InlineSpan>[];
    if (currentRange == null) {
      spans.add(TextSpan(text: text));
    } else {
      if (currentRange.start > 0) {
        spans.add(TextSpan(text: text.substring(0, currentRange.start)));
      }
      spans.add(
        TextSpan(
          text: text.substring(currentRange.start, currentRange.end),
          style: highlight,
        ),
      );
      if (currentRange.end < text.length) {
        spans.add(TextSpan(text: text.substring(currentRange.end)));
      }
    }
    return Text.rich(
      TextSpan(style: style, children: spans),
      textAlign: textAlign,
    );
  }
}

TextRange? currentTimedTextRange({
  required String text,
  required List<TranscriptToken> tokens,
  required int positionMs,
  required int segmentStartMs,
  required int segmentEndMs,
}) {
  if (text.isEmpty || positionMs < segmentStartMs) return null;
  if (segmentEndMs > segmentStartMs && positionMs >= segmentEndMs) return null;
  final timedTokens = tokens
      .where(
        (token) =>
            (token.startMs != 0 ||
                token.endMs != 0 ||
                token.segmentId != null) &&
            token.startMs >= segmentStartMs &&
            (segmentEndMs <= segmentStartMs || token.startMs < segmentEndMs),
      )
      .toList(growable: false);
  final timedRanges = _alignTokenRanges(text, timedTokens);
  int? currentIndex;
  for (
    var index = 0;
    index < timedTokens.length && index < timedRanges.length;
    index++
  ) {
    final range = timedRanges[index];
    if (timedTokens[index].startMs > positionMs) break;
    if (range != null) currentIndex = index;
  }
  if (currentIndex == null) return null;

  var currentRange = _trimTextRange(text, timedRanges[currentIndex]!);
  if (currentRange.isCollapsed) return null;
  if (_isPunctuationToken(timedTokens[currentIndex].text)) {
    TextRange? previousWordRange;
    for (var index = currentIndex - 1; index >= 0; index--) {
      final previous = timedRanges[index];
      if (previous == null) continue;
      final previousRange = _trimTextRange(text, previous);
      if (previousRange.isCollapsed) continue;
      if (_isPunctuationToken(timedTokens[index].text)) continue;
      previousWordRange = previousRange;
      break;
    }
    if (previousWordRange == null) return null;
    currentRange = previousWordRange;
  }
  final expandedRange = _expandToWholeLatinWord(text, currentRange);
  final highlightRange = _trimPunctuationEdges(text, expandedRange);
  return highlightRange.isCollapsed ? null : highlightRange;
}

TextRange _trimTextRange(String text, TextRange range) {
  var start = range.start.clamp(0, text.length);
  var end = range.end.clamp(start, text.length);
  while (start < end && text.substring(start, start + 1).trim().isEmpty) {
    start++;
  }
  while (end > start && text.substring(end - 1, end).trim().isEmpty) {
    end--;
  }
  return TextRange(start: start, end: end);
}

bool _isPunctuationToken(String text) {
  final value = text.trim();
  return value.isNotEmpty && value.codeUnits.every(_isPunctuationCodeUnit);
}

TextRange _trimPunctuationEdges(String text, TextRange range) {
  var start = range.start.clamp(0, text.length);
  var end = range.end.clamp(start, text.length);
  while (start < end &&
      (_isWhitespaceCodeUnit(text.codeUnitAt(start)) ||
          _isPunctuationCodeUnit(text.codeUnitAt(start)))) {
    start++;
  }
  while (end > start &&
      (_isWhitespaceCodeUnit(text.codeUnitAt(end - 1)) ||
          _isPunctuationCodeUnit(text.codeUnitAt(end - 1)))) {
    end--;
  }
  return TextRange(start: start, end: end);
}

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

TextRange _expandToWholeLatinWord(String text, TextRange range) {
  final selected = text.substring(range.start, range.end);
  if (!selected.codeUnits.any(_isLatinLetterOrDigit)) return range;
  var start = range.start;
  var end = range.end;
  while (start > 0 && _isLatinWordCodeUnit(text.codeUnitAt(start - 1))) {
    start--;
  }
  while (end < text.length && _isLatinWordCodeUnit(text.codeUnitAt(end))) {
    end++;
  }
  return TextRange(start: start, end: end);
}

bool _isLatinLetterOrDigit(int codeUnit) =>
    (codeUnit >= 0x30 && codeUnit <= 0x39) ||
    (codeUnit >= 0x41 && codeUnit <= 0x5a) ||
    (codeUnit >= 0x61 && codeUnit <= 0x7a) ||
    (codeUnit >= 0x00c0 && codeUnit <= 0x024f);

bool _isLatinWordCodeUnit(int codeUnit) =>
    _isLatinLetterOrDigit(codeUnit) ||
    (codeUnit >= 0x0300 && codeUnit <= 0x036f) ||
    codeUnit == 0x27 ||
    codeUnit == 0x2019 ||
    codeUnit == 0x2d;

List<TextRange?> _alignTokenRanges(String text, List<TranscriptToken> tokens) {
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
