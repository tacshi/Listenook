import 'models.dart';
import 'transcript_parser.dart';

enum ImportedSubtitleTimelineMode { cueBounded, orderedText }

class ImportedSubtitleAlignmentPlan {
  const ImportedSubtitleAlignmentPlan({
    required this.document,
    required this.timelineMode,
    required this.sentenceBreaksNormalized,
  });

  final TranscriptDocument document;
  final ImportedSubtitleTimelineMode timelineMode;
  final bool sentenceBreaksNormalized;
}

class ImportedSubtitleAlignmentPlanner {
  const ImportedSubtitleAlignmentPlanner({
    TranscriptParser parser = const TranscriptParser(),
  }) : _parser = parser;

  static const minimumRollingCueCount = 8;
  static const minimumRollingOverlapRatio = 0.6;
  static const minimumForwardAnchorRatio = 0.8;

  final TranscriptParser _parser;

  ImportedSubtitleAlignmentPlan prepare(
    TranscriptDocument source, {
    required bool sentenceBreaksNormalized,
  }) {
    final cleaned = _parser.removeImportedSubtitleCaptionArtifacts(source);
    if (!_isRollingTimeline(cleaned.segments)) {
      return ImportedSubtitleAlignmentPlan(
        document: cleaned,
        timelineMode: ImportedSubtitleTimelineMode.cueBounded,
        sentenceBreaksNormalized: sentenceBreaksNormalized,
      );
    }
    return ImportedSubtitleAlignmentPlan(
      document: sentenceBreaksNormalized
          ? cleaned
          : _parser.resegmentAlignedSubtitles(cleaned, const []),
      timelineMode: ImportedSubtitleTimelineMode.orderedText,
      sentenceBreaksNormalized: true,
    );
  }

  bool _isRollingTimeline(List<TranscriptSegment> segments) {
    if (segments.length < minimumRollingCueCount) return false;
    var overlaps = 0;
    var forwardAnchors = 0;
    for (var index = 0; index + 1 < segments.length; index++) {
      final current = segments[index];
      final next = segments[index + 1];
      final currentEnd = current.alignmentWindowEndMs ?? current.endMs;
      final nextStart = next.alignmentWindowStartMs ?? next.startMs;
      final currentStart = current.alignmentWindowStartMs ?? current.startMs;
      if (currentEnd > nextStart) overlaps++;
      if (nextStart > currentStart) forwardAnchors++;
    }
    final boundaries = segments.length - 1;
    return overlaps / boundaries >= minimumRollingOverlapRatio &&
        forwardAnchors / boundaries >= minimumForwardAnchorRatio;
  }
}
