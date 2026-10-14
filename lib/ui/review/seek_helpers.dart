import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import 'highlighted_text.dart';

class LatestSeekDispatcher {
  LatestSeekDispatcher(this._performSeek);

  final Future<void> Function(Duration position) _performSeek;
  Duration? _pendingPosition;
  Completer<void>? _drainCompleter;

  Future<void> seek(Duration position) {
    _pendingPosition = position;
    final active = _drainCompleter;
    if (active != null) return active.future;

    final completer = Completer<void>();
    _drainCompleter = completer;
    unawaited(_drain(completer));
    return completer.future;
  }

  Future<void> get idle => _drainCompleter?.future ?? Future<void>.value();

  bool get isBusy => _drainCompleter != null;

  Future<void> _drain(Completer<void> completer) async {
    try {
      while (_pendingPosition != null) {
        final position = _pendingPosition!;
        _pendingPosition = null;
        await _performSeek(position);
      }
      completer.complete();
    } catch (error, stackTrace) {
      _pendingPosition = null;
      completer.completeError(error, stackTrace);
    } finally {
      if (identical(_drainCompleter, completer)) _drainCompleter = null;
    }
  }
}

const _sentenceRepeatPreRollMs = 350;
const _sentenceRepeatPreviousCueSafetyMs = 100;
const _repeatSeekUndershootToleranceMs = 250;
const _overlappingRepeatBoundaryGuardMs = 120;

int sentenceRepeatStartMs(
  TranscriptSegment segment, {
  TranscriptSegment? previousSegment,
}) {
  final requestedStartMs = segment.startMs - _sentenceRepeatPreRollMs;
  final clampedStartMs = requestedStartMs < 0 ? 0 : requestedStartMs;
  if (previousSegment == null) return clampedStartMs;
  final previousEndMs = previousSegment.endMs.clamp(0, segment.startMs).toInt();
  final safeStartMs = (previousEndMs + _sentenceRepeatPreviousCueSafetyMs)
      .clamp(0, segment.startMs)
      .toInt();
  return clampedStartMs < safeStartMs ? safeStartMs : clampedStartMs;
}

bool shouldAutoFollowPlaybackSegment({
  required bool playing,
  required int? previousIndex,
  required int? nextIndex,
  required bool repeating,
}) => playing && !repeating && previousIndex != nextIndex;

enum TranscriptSeekReason {
  standard,
  videoProgressScrub,
  sentenceClick,
  repeatRestart,
}

typedef TranscriptSeekCallback =
    Future<void> Function(Duration position, {TranscriptSeekReason reason});

typedef TranscriptSegmentSeekCallback =
    void Function({required TranscriptSeekReason reason});

bool shouldFocusTranscriptAfterSeek(TranscriptSeekReason reason) =>
    reason == TranscriptSeekReason.standard;

bool shouldFocusTranscriptOnPlaybackResume({required bool repeating}) =>
    !repeating;

bool shouldRestartRepeatedSentence(
  TranscriptSegment segment,
  int positionMs, {
  TranscriptSegment? previousSegment,
  TranscriptSegment? nextSegment,
}) =>
    sentenceRepeatEndMs(segment, nextSegment: nextSegment) > segment.startMs &&
    (positionMs <
            sentenceRepeatStartMs(segment, previousSegment: previousSegment) -
                _repeatSeekUndershootToleranceMs ||
        positionMs >=
            sentenceRepeatRestartMs(segment, nextSegment: nextSegment));

int sentenceRepeatRestartMs(
  TranscriptSegment segment, {
  TranscriptSegment? nextSegment,
}) {
  final endMs = sentenceRepeatEndMs(segment, nextSegment: nextSegment);
  final nextStartMs = nextSegment?.startMs;
  final hasOverlappingNext =
      nextStartMs != null &&
      nextStartMs > segment.startMs &&
      nextStartMs < segment.endMs;
  if (!hasOverlappingNext) return endMs;
  return max(segment.startMs + 1, endMs - _overlappingRepeatBoundaryGuardMs);
}

int sentenceRepeatEndMs(
  TranscriptSegment segment, {
  TranscriptSegment? nextSegment,
}) {
  final nextStartMs = nextSegment?.startMs;
  if (nextStartMs == null ||
      nextStartMs <= segment.startMs ||
      nextStartMs >= segment.endMs) {
    return segment.endMs;
  }
  return nextStartMs;
}

/// Detects playback wrapping from near the loop end back to the loop start,
/// which marks one completed repetition of the segment.
bool isRepeatLoopWrap(
  TranscriptSegment segment, {
  required int previousMs,
  required int currentMs,
  TranscriptSegment? previousSegment,
  TranscriptSegment? nextSegment,
}) {
  if (currentMs >= previousMs) return false;
  final startMs = sentenceRepeatStartMs(
    segment,
    previousSegment: previousSegment,
  );
  final restartMs = sentenceRepeatRestartMs(segment, nextSegment: nextSegment);
  const wrapToleranceMs = 1200;
  return previousMs >= restartMs - wrapToleranceMs &&
      currentMs <= startMs + wrapToleranceMs &&
      previousMs - currentMs >= max(1, (restartMs - startMs) ~/ 2);
}

/// Detects playback running from inside the loop past its restart point,
/// which marks one completed repetition when the loop is driven in Dart.
bool isRepeatLoopEndCrossing(
  TranscriptSegment segment, {
  required int previousMs,
  required int currentMs,
  TranscriptSegment? previousSegment,
  TranscriptSegment? nextSegment,
}) {
  final startMs = sentenceRepeatStartMs(
    segment,
    previousSegment: previousSegment,
  );
  final restartMs = sentenceRepeatRestartMs(segment, nextSegment: nextSegment);
  return previousMs >= startMs &&
      previousMs < restartMs &&
      currentMs >= restartMs;
}

int? currentTranscriptSegmentIndex(
  List<TranscriptSegment> segments,
  int positionMs, {
  String? pinnedSegmentId,
}) {
  if (pinnedSegmentId != null) {
    final pinnedIndex = segments.indexWhere(
      (segment) => segment.id == pinnedSegmentId,
    );
    if (pinnedIndex >= 0) return pinnedIndex;
  }
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

String? fullscreenTranscriptSubtitle(
  List<TranscriptSegment> segments,
  int positionMs,
  TranslationViewMode viewMode, {
  String? pinnedSegmentId,
}) {
  final index = currentTranscriptSegmentIndex(
    segments,
    positionMs,
    pinnedSegmentId: pinnedSegmentId,
  );
  if (index == null) return null;
  final segment = segments[index];
  final isPinned = segment.id == pinnedSegmentId;
  if (!isPinned &&
      (positionMs < segment.startMs || positionMs >= segment.endMs)) {
    return null;
  }

  final original = segment.text.trim();
  final translated = segment.translatedText?.trim() ?? '';
  final lines = switch (viewMode) {
    TranslationViewMode.original => [original],
    TranslationViewMode.translated => [
      translated.isNotEmpty ? translated : original,
    ],
    TranslationViewMode.bilingual => [original, translated],
  }.where((line) => line.isNotEmpty).toList();
  return lines.isEmpty ? null : lines.join('\n');
}

TextRange? fullscreenTranscriptWordRange(
  TranscriptDocument document,
  int positionMs,
  TranslationViewMode viewMode, {
  String? pinnedSegmentId,
}) {
  final index = currentTranscriptSegmentIndex(
    document.segments,
    positionMs,
    pinnedSegmentId: pinnedSegmentId,
  );
  if (index == null) return null;
  final segment = document.segments[index];
  if (positionMs < segment.startMs || positionMs >= segment.endMs) return null;

  final original = segment.text.trim();
  final translated = segment.translatedText?.trim() ?? '';
  final originalIsVisible = switch (viewMode) {
    TranslationViewMode.original => original.isNotEmpty,
    TranslationViewMode.translated => translated.isEmpty && original.isNotEmpty,
    TranslationViewMode.bilingual => original.isNotEmpty,
  };
  if (!originalIsVisible) return null;

  final tokens = document.tokens
      .where(
        (token) =>
            token.startMs >= segment.startMs && token.startMs < segment.endMs,
      )
      .toList(growable: false);
  return currentTimedTextRange(
    text: original,
    tokens: tokens,
    positionMs: positionMs,
    segmentStartMs: segment.startMs,
    segmentEndMs: segment.endMs,
  );
}
