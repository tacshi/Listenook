import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/core/transcript_parser.dart';
import 'package:listenook/core/transcript_structure_editor.dart';

void main() {
  test('split preserves punctuation, timing gap, and token ownership', () {
    final document = TranscriptDocument(
      tokens: const [
        TranscriptToken(
          text: 'Hello',
          startMs: 100,
          endMs: 400,
          segmentId: 'sentence',
        ),
        TranscriptToken(
          text: ' world',
          startMs: 600,
          endMs: 900,
          segmentId: 'sentence',
        ),
        TranscriptToken(
          text: ' again',
          startMs: 1000,
          endMs: 1300,
          segmentId: 'sentence',
        ),
      ],
      segments: const [
        TranscriptSegment(
          id: 'sentence',
          startMs: 0,
          endMs: 1500,
          text: 'Hello, world again.',
          translatedText: 'Hola, mundo otra vez.',
        ),
      ],
      speakers: const [],
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
    final editor = TranscriptStructureEditor(idGenerator: () => 'right');

    final outcome = editor.apply(
      document,
      const SplitAtTokenBoundary('sentence', rightTokenIndex: 1),
    );

    expect(outcome, isA<TranscriptStructureEditResult>());
    final result = outcome as TranscriptStructureEditResult;
    expect(result.document.segments, hasLength(2));
    expect(result.document.segments.first.text, 'Hello,');
    expect(result.document.segments.first.endMs, 400);
    expect(result.document.segments.first.translatedText, isNull);
    expect(result.document.segments.last.id, 'right');
    expect(result.document.segments.last.text, 'world again.');
    expect(result.document.segments.last.startMs, 600);
    expect(result.document.segments.last.preserveBoundaryBefore, isTrue);
    expect(result.document.segments.last.translatedText, isNull);
    expect(result.document.tokens.map((token) => token.segmentId), [
      'sentence',
      'right',
      'right',
    ]);
    expect(result.focusMs, 600);
    expect(result.segmentIdReplacements, {
      'sentence': ['sentence', 'right'],
    });
  });

  test('merge preserves the first cue and joins complete translations', () {
    final document = TranscriptDocument(
      tokens: const [
        TranscriptToken(
          text: 'Hello,',
          startMs: 100,
          endMs: 500,
          segmentId: 'left',
        ),
        TranscriptToken(
          text: 'world.',
          startMs: 700,
          endMs: 1100,
          segmentId: 'right',
        ),
      ],
      segments: const [
        TranscriptSegment(
          id: 'left',
          startMs: 0,
          endMs: 550,
          text: 'Hello,',
          speaker: 'speaker',
          language: 'en',
          translatedText: 'Hola,',
          preserveBoundaryBefore: true,
        ),
        TranscriptSegment(
          id: 'right',
          startMs: 650,
          endMs: 1200,
          text: 'world.',
          speaker: 'speaker',
          language: 'en',
          translatedText: 'mundo.',
          preserveBoundaryBefore: true,
        ),
      ],
      speakers: const [],
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );

    final outcome = TranscriptStructureEditor().apply(
      document,
      const MergeWithNext('left'),
    );

    expect(outcome, isA<TranscriptStructureEditResult>());
    final result = outcome as TranscriptStructureEditResult;
    expect(result.document.segments, hasLength(1));
    final merged = result.document.segments.single;
    expect(merged.id, 'left');
    expect(merged.text, 'Hello, world.');
    expect(merged.translatedText, 'Hola, mundo.');
    expect(merged.startMs, 0);
    expect(merged.endMs, 1200);
    expect(merged.preserveBoundaryBefore, isTrue);
    expect(result.document.tokens.map((token) => token.segmentId), [
      'left',
      'left',
    ]);
    expect(result.focusMs, 650);
    expect(result.segmentIdReplacements, {
      'right': ['left'],
    });
  });

  test('manual boundary survives persistence and startup normalization', () {
    final stored = TranscriptDocument.fromJson(
      TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'left',
            startMs: 0,
            endMs: 500,
            text: 'A continuous',
          ),
          TranscriptSegment(
            id: 'right',
            startMs: 600,
            endMs: 1000,
            text: 'thought without punctuation',
            preserveBoundaryBefore: true,
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      ).toJson(),
    );

    final normalized = const TranscriptParser().normalizeSegments(stored);

    expect(normalized.segments.map((segment) => segment.id), ['left', 'right']);
    expect(normalized.segments.last.preserveBoundaryBefore, isTrue);
  });

  test('split handles untimed punctuation tokens and overlapping words', () {
    final document = TranscriptDocument(
      tokens: const [
        TranscriptToken(
          text: 'Hello',
          startMs: 100,
          endMs: 700,
          segmentId: 'cue',
        ),
        TranscriptToken(text: ',', startMs: 0, endMs: 0, segmentId: 'cue'),
        TranscriptToken(
          text: ' world',
          startMs: 500,
          endMs: 900,
          segmentId: 'cue',
        ),
      ],
      segments: const [
        TranscriptSegment(
          id: 'cue',
          startMs: 0,
          endMs: 1000,
          text: 'Hello, world.',
        ),
      ],
      speakers: const [],
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );

    final result =
        TranscriptStructureEditor(idGenerator: () => 'right').apply(
              document,
              const SplitAtTokenBoundary('cue', rightTokenIndex: 2),
            )
            as TranscriptStructureEditResult;

    expect(result.document.segments.map((segment) => segment.text), [
      'Hello,',
      'world.',
    ]);
    expect(result.document.segments.map((segment) => segment.endMs), [
      600,
      1000,
    ]);
    expect(result.document.segments.last.startMs, 600);
    expect(result.document.tokens.map((token) => token.segmentId), [
      'cue',
      'cue',
      'right',
    ]);
  });

  test('split supports Chinese punctuation without inserting spaces', () {
    final document = TranscriptDocument(
      tokens: const [
        TranscriptToken(text: '今天', startMs: 100, endMs: 400, segmentId: 'cue'),
        TranscriptToken(text: '很好', startMs: 500, endMs: 800, segmentId: 'cue'),
      ],
      segments: const [
        TranscriptSegment(
          id: 'cue',
          startMs: 0,
          endMs: 900,
          text: '今天，很好。',
          language: 'zh',
        ),
      ],
      speakers: const [],
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );

    final result =
        TranscriptStructureEditor(idGenerator: () => 'right').apply(
              document,
              const SplitAtTokenBoundary('cue', rightTokenIndex: 1),
            )
            as TranscriptStructureEditResult;

    expect(result.document.segments.map((segment) => segment.text), [
      '今天，',
      '很好。',
    ]);
  });

  test('split rejects lexical text that is not aligned to a token', () {
    final document = TranscriptDocument(
      tokens: const [
        TranscriptToken(
          text: 'Hello',
          startMs: 100,
          endMs: 300,
          segmentId: 'cue',
        ),
        TranscriptToken(
          text: ' world',
          startMs: 400,
          endMs: 700,
          segmentId: 'cue',
        ),
      ],
      segments: const [
        TranscriptSegment(
          id: 'cue',
          startMs: 0,
          endMs: 800,
          text: 'Hello added world',
        ),
      ],
      speakers: const [],
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );

    final editor = TranscriptStructureEditor();
    expect(editor.splitTargets(document, 'cue'), isEmpty);
    expect(
      (editor.apply(
                document,
                const SplitAtTokenBoundary('cue', rightTokenIndex: 1),
              )
              as TranscriptStructureEditFailure)
          .reason,
      TranscriptStructureFailureReason.invalidBoundary,
    );
  });

  test('split retries generated IDs that collide with existing cues', () {
    final generated = ['cue', 'other', 'new-cue'].iterator;
    final editor = TranscriptStructureEditor(
      idGenerator: () {
        generated.moveNext();
        return generated.current;
      },
    );
    final document = TranscriptDocument(
      tokens: const [
        TranscriptToken(
          text: 'One',
          startMs: 100,
          endMs: 300,
          segmentId: 'cue',
        ),
        TranscriptToken(
          text: ' two',
          startMs: 400,
          endMs: 600,
          segmentId: 'cue',
        ),
      ],
      segments: const [
        TranscriptSegment(id: 'cue', startMs: 0, endMs: 700, text: 'One two'),
        TranscriptSegment(
          id: 'other',
          startMs: 800,
          endMs: 900,
          text: 'Other.',
        ),
      ],
      speakers: const [],
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );

    final result =
        editor.apply(
              document,
              const SplitAtTokenBoundary('cue', rightTokenIndex: 1),
            )
            as TranscriptStructureEditResult;

    expect(result.document.segments[1].id, 'new-cue');
  });

  test(
    'merge blocks conflicting known metadata and inherits missing values',
    () {
      TranscriptDocument document({
        String? rightSpeaker,
        String? rightLanguage,
      }) => TranscriptDocument(
        tokens: const [],
        segments: [
          const TranscriptSegment(
            id: 'left',
            startMs: 0,
            endMs: 500,
            text: 'First.',
            speaker: 'one',
            language: 'en',
          ),
          TranscriptSegment(
            id: 'right',
            startMs: 600,
            endMs: 1000,
            text: 'Second.',
            speaker: rightSpeaker,
            language: rightLanguage,
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      final editor = TranscriptStructureEditor();

      expect(
        (editor.apply(
                  document(rightSpeaker: 'two', rightLanguage: 'en'),
                  const MergeWithNext('left'),
                )
                as TranscriptStructureEditFailure)
            .reason,
        TranscriptStructureFailureReason.incompatibleSpeaker,
      );
      expect(
        (editor.apply(
                  document(rightSpeaker: 'one', rightLanguage: 'fr'),
                  const MergeWithNext('left'),
                )
                as TranscriptStructureEditFailure)
            .reason,
        TranscriptStructureFailureReason.incompatibleLanguage,
      );
      final merged =
          (editor.apply(document(), const MergeWithNext('left'))
                  as TranscriptStructureEditResult)
              .document
              .segments
              .single;
      expect(merged.speaker, 'one');
      expect(merged.language, 'en');
      expect(merged.text, 'First. Second.');
    },
  );

  test('merge clears a partial translation and keeps compact CJK spacing', () {
    final result =
        TranscriptStructureEditor().apply(
              TranscriptDocument(
                tokens: const [],
                segments: const [
                  TranscriptSegment(
                    id: 'left',
                    startMs: 0,
                    endMs: 500,
                    text: '今天，',
                    translatedText: 'Today,',
                  ),
                  TranscriptSegment(
                    id: 'right',
                    startMs: 600,
                    endMs: 1000,
                    text: '很好。',
                  ),
                ],
                speakers: const [],
                updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
              ),
              const MergeWithNext('left'),
            )
            as TranscriptStructureEditResult;

    expect(result.document.segments.single.text, '今天，很好。');
    expect(result.document.segments.single.translatedText, isNull);
  });

  test('normalization keeps a manual boundary after merging a later cue', () {
    final source = TranscriptDocument(
      tokens: const [],
      segments: const [
        TranscriptSegment(id: 'left', startMs: 0, endMs: 300, text: 'One'),
        TranscriptSegment(
          id: 'manual',
          startMs: 400,
          endMs: 700,
          text: 'two',
          preserveBoundaryBefore: true,
        ),
        TranscriptSegment(
          id: 'tail',
          startMs: 750,
          endMs: 1000,
          text: 'three.',
        ),
      ],
      speakers: const [],
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
    const parser = TranscriptParser();

    final once = parser.normalizeSegments(source);
    final twice = parser.normalizeSegments(once);

    expect(once.segments.map((segment) => segment.id), ['left', 'manual']);
    expect(once.segments.last.preserveBoundaryBefore, isTrue);
    expect(twice.segments.map((segment) => segment.id), ['left', 'manual']);
  });

  test('edit availability finds merges and token-backed splits', () {
    final editor = TranscriptStructureEditor();
    final mergeable = TranscriptDocument(
      tokens: const [],
      segments: const [
        TranscriptSegment(id: 'left', startMs: 0, endMs: 400, text: 'One'),
        TranscriptSegment(id: 'right', startMs: 500, endMs: 900, text: 'Two'),
      ],
      speakers: const [],
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
    expect(editor.canMergeWithNext(mergeable, 0), isTrue);
    expect(editor.hasAvailableEdit(mergeable), isTrue);

    final splitOnly = TranscriptDocument(
      tokens: const [
        TranscriptToken(
          text: 'Hello',
          startMs: 100,
          endMs: 300,
          segmentId: 'first',
        ),
        TranscriptToken(
          text: ' world',
          startMs: 400,
          endMs: 700,
          segmentId: 'first',
        ),
      ],
      segments: const [
        TranscriptSegment(
          id: 'first',
          startMs: 0,
          endMs: 800,
          text: 'Hello world.',
          speaker: 'one',
          language: 'en',
        ),
        TranscriptSegment(
          id: 'second',
          startMs: 900,
          endMs: 1200,
          text: 'Bonjour.',
          speaker: 'two',
          language: 'fr',
        ),
      ],
      speakers: const [],
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
    expect(editor.canMergeWithNext(splitOnly, 0), isFalse);
    expect(editor.hasAvailableEdit(splitOnly), isTrue);
  });
}
