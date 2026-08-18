import 'dart:math';

import 'models.dart';

const minimumAlignedTokenDurationMs = 40;

List<TranscriptToken> stabilizeAlignedTokenTransitions({
  required Iterable<TranscriptToken> tokens,
  required TranscriptSegment segment,
}) {
  final stabilized = tokens.toList(growable: true);
  if (stabilized.length < 2) return List.unmodifiable(stabilized);
  for (var index = 1; index < stabilized.length; index++) {
    final previous = stabilized[index - 1];
    final current = stabilized[index];
    var startMs = current.startMs;
    if (previous.endMs < current.startMs) {
      startMs = (previous.endMs + current.startMs) ~/ 2;
    } else if (current.startMs <= previous.startMs ||
        current.startMs == current.endMs) {
      final previousCenter = (previous.startMs + previous.endMs) ~/ 2;
      final currentCenter = (current.startMs + current.endMs) ~/ 2;
      startMs = (previousCenter + currentCenter) ~/ 2;
    }
    final minimumStart = previous.startMs + minimumAlignedTokenDurationMs;
    if (startMs < minimumStart) startMs = minimumStart;
    final remaining = stabilized.length - index;
    final latestStart =
        segment.endMs - remaining * minimumAlignedTokenDurationMs;
    if (latestStart >= minimumStart && startMs > latestStart) {
      startMs = latestStart;
    }
    stabilized[index] = TranscriptToken(
      text: current.text,
      startMs: startMs,
      endMs: max(startMs, current.endMs),
      segmentId: current.segmentId,
      speaker: current.speaker,
      language: current.language,
    );
  }
  for (var index = 0; index < stabilized.length; index++) {
    final token = stabilized[index];
    final endMs = index + 1 < stabilized.length
        ? stabilized[index + 1].startMs
        : max(token.endMs, segment.endMs);
    stabilized[index] = TranscriptToken(
      text: token.text,
      startMs: token.startMs,
      endMs: max(token.startMs, endMs),
      segmentId: token.segmentId,
      speaker: token.speaker,
      language: token.language,
    );
  }
  return List.unmodifiable(stabilized);
}
