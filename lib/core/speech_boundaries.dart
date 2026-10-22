import 'dart:math' as math;
import 'dart:typed_data';

import 'models.dart';

/// The loudness of a recording in 10ms frames, used to cut sentences at the
/// real pauses between them rather than at their transcript timestamps, which
/// are often a few hundred milliseconds off.
class SpeechEnergy {
  /// [halfDecibels] holds one frame per 10ms, as written by
  /// `writePcmSpeechEnergy`.
  SpeechEnergy(Uint8List halfDecibels)
    : _level = _smoothed(halfDecibels),
      _pauseLevel = _sustained(_smoothed(halfDecibels));

  static const frameMs = 10;

  /// How far past the transcript timestamps a pause may be found.
  static const _searchMs = 300;

  /// Score added per frame that a candidate lies outside the timestamps' gap,
  /// so a nearby pause beats a slightly quieter one further away.
  static const _outsidePenaltyDb = .4;

  /// How much quieter than the surrounding speech a pause must be. Music beds
  /// and run-on speech have no such dip and keep their timestamps.
  static const _minPauseDepthDb = 12.0;

  /// How far above its quietest point a pause extends.
  static const _pauseRiseDb = 6.0;
  static const _contextMs = 500;

  /// Timestamp gaps longer than this may hold music or noise between the
  /// sentences, so each sentence looks for the pause beside its own words.
  static const _sharedGapMs = 500;

  /// Silence kept before a sentence starts and after it ends.
  static const _leadMs = 120;
  static const _tailMs = 200;

  /// Smoothed loudness in decibels.
  final Float32List _level;

  /// The loudest level within 30ms of each frame, which stays low only inside
  /// pauses of at least 70ms and so ignores the closures of stop consonants.
  final Float32List _pauseLevel;
  final Map<String, ({int startMs, int endMs})?> _pauses = {};

  /// Where a repeat of [segment] should start, or null when no clear pause
  /// separates it from [previous].
  int? sentenceStartMs(
    TranscriptSegment segment, {
    TranscriptSegment? previous,
  }) {
    final pause = _pauseBetween(previous, segment, beforeNext: true);
    if (pause == null) return null;
    final middleMs = (pause.startMs + pause.endMs) ~/ 2;
    return math.max(middleMs, pause.endMs - _leadMs);
  }

  /// Where a repeat of [segment] should end, or null when no clear pause
  /// separates it from [next].
  int? sentenceEndMs(TranscriptSegment segment, {TranscriptSegment? next}) {
    final pause = _pauseBetween(segment, next, beforeNext: false);
    if (pause == null) return null;
    final middleMs = (pause.startMs + pause.endMs) ~/ 2;
    return math.min(middleMs, pause.startMs + _tailMs);
  }

  /// The pause between two adjacent sentences, either of which may be absent
  /// at the edges of the transcript. Across a short gap both sentences use the
  /// same pause, so every sound belongs to exactly one of them; across a long
  /// one, [beforeNext] picks the pause just before [next] rather than the one
  /// just after [previous].
  ({int startMs, int endMs})? _pauseBetween(
    TranscriptSegment? previous,
    TranscriptSegment? next, {
    required bool beforeNext,
  }) {
    if (previous == null && next == null) return null;
    var gapEndMs = next?.startMs ?? previous!.endMs;
    // Overlapping sentences, such as rolling captions, hand over where the
    // next one starts, as the timestamp boundaries do.
    var gapStartMs = math.min(previous?.endMs ?? gapEndMs, gapEndMs);
    final previousMiddleMs = previous == null
        ? null
        : (previous.startMs + gapStartMs) ~/ 2;
    if (gapEndMs - gapStartMs > _sharedGapMs) {
      if (beforeNext) {
        gapStartMs = gapEndMs;
      } else {
        gapEndMs = gapStartMs;
      }
    }
    final key =
        '${previous?.startMs}:${previous?.endMs}|'
        '${next?.startMs}:${next?.endMs}|$gapStartMs:$gapEndMs';
    if (_pauses.containsKey(key)) return _pauses[key];
    var fromMs = gapStartMs - _searchMs;
    var toMs = gapEndMs + _searchMs;
    if (previousMiddleMs != null) fromMs = math.max(fromMs, previousMiddleMs);
    if (next != null) {
      toMs = math.min(toMs, (next.startMs + next.endMs) ~/ 2);
    }
    return _pauses[key] = _quietestPause(fromMs, toMs, gapStartMs, gapEndMs);
  }

  ({int startMs, int endMs})? _quietestPause(
    int fromMs,
    int toMs,
    int gapStartMs,
    int gapEndMs,
  ) {
    if (_level.isEmpty) return null;
    final first = math.max(0, fromMs ~/ frameMs);
    final last = math.min(_level.length - 1, toMs ~/ frameMs);
    if (last <= first) return null;

    var best = first;
    var bestScore = double.infinity;
    for (var frame = first; frame <= last; frame++) {
      final ms = frame * frameMs + frameMs ~/ 2;
      final outsideMs = math.max(0, math.max(gapStartMs - ms, ms - gapEndMs));
      final score =
          _pauseLevel[frame] + _outsidePenaltyDb * outsideMs / frameMs;
      if (score < bestScore) {
        best = frame;
        bestScore = score;
      }
    }

    const contextFrames = _contextMs ~/ frameMs;
    final context = _level.sublist(
      math.max(0, first - contextFrames),
      math.min(_level.length, last + contextFrames + 1),
    )..sort();
    final speechLevel = context[context.length * 9 ~/ 10];
    if (_pauseLevel[best] > speechLevel - _minPauseDepthDb) return null;

    final ceiling = _pauseLevel[best] + _pauseRiseDb;
    var start = best;
    var end = best;
    while (start > first && _level[start - 1] <= ceiling) {
      start--;
    }
    while (end < last && _level[end + 1] <= ceiling) {
      end++;
    }
    return (startMs: start * frameMs, endMs: (end + 1) * frameMs);
  }

  static Float32List _smoothed(Uint8List halfDecibels) {
    final level = Float32List(halfDecibels.length);
    final lastIndex = halfDecibels.length - 1;
    for (var index = 0; index <= lastIndex; index++) {
      level[index] =
          (halfDecibels[math.max(0, index - 1)] +
              halfDecibels[index] +
              halfDecibels[math.min(lastIndex, index + 1)]) /
          6;
    }
    return level;
  }

  static Float32List _sustained(Float32List level) {
    final sustained = Float32List(level.length);
    for (var index = 0; index < level.length; index++) {
      var loudest = level[index];
      final end = math.min(level.length - 1, index + 3);
      for (var other = math.max(0, index - 3); other <= end; other++) {
        loudest = math.max(loudest, level[other]);
      }
      sustained[index] = loudest;
    }
    return sustained;
  }
}
