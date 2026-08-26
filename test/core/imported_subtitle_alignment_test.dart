import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/imported_subtitle_alignment.dart';
import 'package:meow_stt/core/models.dart';

void main() {
  const planner = ImportedSubtitleAlignmentPlanner();

  test('rolling captions become ordered sentence text before alignment', () {
    final plan = planner.prepare(
      _document(overlapping: true),
      sentenceBreaksNormalized: false,
    );

    expect(plan.timelineMode, ImportedSubtitleTimelineMode.orderedText);
    expect(plan.sentenceBreaksNormalized, isTrue);
    expect(plan.document.segments.map((segment) => segment.text), [
      for (var index = 0; index < 8; index++) 'Sentence $index.',
    ]);
    expect(
      plan.document.segments.every(
        (segment) => segment.id.startsWith('imported-sentence-'),
      ),
      isTrue,
    );
  });

  test('ordinary subtitles retain their cue-bounded alignment mode', () {
    final source = _document(overlapping: false);
    final plan = planner.prepare(source, sentenceBreaksNormalized: false);

    expect(plan.timelineMode, ImportedSubtitleTimelineMode.cueBounded);
    expect(plan.sentenceBreaksNormalized, isFalse);
    expect(
      plan.document.segments.map((segment) => segment.id),
      source.segments.map((segment) => segment.id),
    );
  });

  test('rolling detection survives tightened retry boundaries', () {
    final source = _document(overlapping: true);
    final tightened = source.copyWith(
      segments: [
        for (var index = 0; index < source.segments.length; index++)
          source.segments[index].copyWith(
            startMs: index * 1000 + 100,
            endMs: index * 1000 + 900,
          ),
      ],
    );

    final plan = planner.prepare(tightened, sentenceBreaksNormalized: true);

    expect(plan.timelineMode, ImportedSubtitleTimelineMode.orderedText);
    expect(plan.document.segments.first.startMs, 100);
    expect(plan.document.segments.first.endMs, 900);
  });
}

TranscriptDocument _document({required bool overlapping}) {
  return TranscriptDocument(
    tokens: const [],
    segments: [
      for (var index = 0; index < 8; index++)
        TranscriptSegment(
          id: 'cue-$index',
          startMs: index * 1000,
          endMs: overlapping ? index * 1000 + 5000 : index * 1000 + 900,
          alignmentWindowStartMs: index * 1000,
          alignmentWindowEndMs: overlapping
              ? index * 1000 + 5000
              : index * 1000 + 900,
          text: 'Sentence $index.',
        ),
    ],
    speakers: const [],
    updatedAt: DateTime.utc(2026, 8, 26),
  );
}
