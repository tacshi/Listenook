import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/contracts.dart';
import 'package:meow_stt/core/models.dart';
import 'package:meow_stt/data/ai_brief_service.dart';

void main() {
  const settings = LlmProviderSettings(
    baseUrl: 'https://llm.example/v1',
    model: 'brief-model',
  );

  test(
    'validates evidence, removes duplicates, and omits unsupported items',
    () async {
      final client = _LlmClient([
        jsonEncode({
          'overview': 'A grounded overview.',
          'overview_evidence': ['s1', 'missing'],
          'chapters': [
            {
              'title': 'Opening',
              'summary': 'The opening topic.',
              'evidence': ['s1'],
            },
            {
              'title': 'Invented',
              'summary': 'Unsupported.',
              'evidence': ['missing'],
            },
          ],
          'insights': [
            {
              'type': 'keyIdea',
              'text': 'Ship the grounded feature.',
              'owner': null,
              'deadline': null,
              'evidence': ['s2'],
            },
            {
              'type': 'keyIdea',
              'text': '  SHIP the grounded feature. ',
              'evidence': ['s2'],
            },
            {
              'type': 'decision',
              'text': 'Unsupported decision.',
              'evidence': ['missing'],
            },
            {
              'type': 'actionItem',
              'text': 'Prepare the launch.',
              'owner': 'Invented owner',
              'deadline': 'tomorrow',
              'evidence': ['s2'],
            },
          ],
        }),
      ]);
      final brief = await DefaultAiBriefService(client).generate(
        settings: settings,
        document: _document(),
        sections: defaultAiBriefSections,
        outputLanguage: 'en',
      );

      expect(brief.overviewEvidenceSegmentIds, ['s1']);
      expect(brief.chapters.single.title, 'Opening');
      expect(brief.insights, hasLength(2));
      final action = brief.insights.singleWhere(
        (item) => item.type == AiInsightType.actionItem,
      );
      expect(action.owner, isNull);
      expect(action.deadline, isNull);
      expect(brief.model, 'brief-model');
    },
  );

  test('chunks long transcripts and synthesizes candidate analyses', () async {
    final emptyCandidate = jsonEncode({
      'overview': '',
      'overview_evidence': <String>[],
      'chapters': <Object>[],
      'insights': <Object>[],
    });
    final client = _LlmClient([
      emptyCandidate,
      emptyCandidate,
      jsonEncode({
        'overview': 'Combined overview.',
        'overview_evidence': ['s1', 's2'],
        'chapters': <Object>[],
        'insights': <Object>[],
      }),
    ]);
    final document = TranscriptDocument(
      tokens: const [],
      segments: [
        TranscriptSegment(
          id: 's1',
          startMs: 0,
          endMs: 1,
          text: List.filled(5000, 'a').join(),
        ),
        TranscriptSegment(
          id: 's2',
          startMs: 2,
          endMs: 3,
          text: List.filled(5000, 'b').join(),
        ),
      ],
      speakers: const [],
      updatedAt: DateTime.utc(2026, 8, 12),
    );
    final service = DefaultAiBriefService(client);

    expect(
      service.estimateRequestCount(document, {AiBriefSection.overview}),
      3,
    );
    final brief = await service.generate(
      settings: settings,
      document: document,
      sections: const {AiBriefSection.overview},
      outputLanguage: 'en',
    );

    expect(client.prompts, hasLength(3));
    expect(client.prompts.last, contains('Candidates:'));
    expect(brief.overview, 'Combined overview.');
  });

  test('retries malformed structured output once', () async {
    final client = _LlmClient([
      'not json',
      jsonEncode({
        'overview': 'Recovered.',
        'overview_evidence': ['s1'],
        'chapters': <Object>[],
        'insights': <Object>[],
      }),
    ]);

    final brief = await DefaultAiBriefService(client).generate(
      settings: settings,
      document: _document(),
      sections: const {AiBriefSection.overview},
      outputLanguage: 'en',
    );

    expect(client.prompts, hasLength(2));
    expect(client.prompts.last, contains('previous response was not valid'));
    expect(brief.overview, 'Recovered.');
  });

  test(
    'creates level-aware language notes and rejects ungrounded examples',
    () async {
      final client = _LlmClient([
        jsonEncode({
          'overview': '',
          'overview_evidence': <String>[],
          'chapters': <Object>[],
          'insights': <Object>[],
          'language_notes': [
            {
              'kind': 'expression',
              'term': 'build a trustworthy brief',
              'explanation': '表示制作一份可靠、可核查的简报。',
              'source_excerpt': 'build a trustworthy brief',
              'evidence': ['s1'],
            },
            {
              'kind': 'expression',
              'term': '  BUILD A TRUSTWORTHY BRIEF ',
              'explanation': '重复内容。',
              'source_excerpt': 'build a trustworthy brief',
              'evidence': ['s1'],
            },
            {
              'kind': 'grammar',
              'term': 'should + verb',
              'explanation': '用于表达建议。',
              'source_excerpt': 'We should build',
              'evidence': ['s1'],
            },
            {
              'kind': 'vocabulary',
              'term': 'invented',
              'explanation': '不受支持。',
              'source_excerpt': 'This was never said.',
              'evidence': ['s1'],
            },
            {
              'kind': 'vocabulary',
              'term': 'missing evidence',
              'explanation': '不受支持。',
              'source_excerpt': 'Ship',
              'evidence': ['missing'],
            },
          ],
        }),
      ]);
      final document = TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 's1',
            startMs: 0,
            endMs: 1000,
            text: 'We should build a trustworthy brief.',
            language: 'en',
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.utc(2026, 8, 12),
      );

      final brief = await DefaultAiBriefService(client).generate(
        settings: settings,
        document: document,
        sections: const {AiBriefSection.languageNotes},
        outputLanguage: 'zh-Hans',
        learningLevel: AiLearningLevel.beginner,
      );

      expect(brief.languageNotes, hasLength(2));
      expect(brief.languageNotes.map((item) => item.kind), [
        AiLanguageNoteKind.expression,
        AiLanguageNoteKind.grammar,
      ]);
      expect(brief.learningLanguage, isNull);
      expect(brief.learningLevel, AiLearningLevel.beginner);
      expect(client.prompts.single, contains('language code "en"'));
      expect(client.prompts.single, contains('at beginner level'));
      expect(client.prompts.single, contains('[language=en]'));
    },
  );

  test('language notes use the explicit language during synthesis', () async {
    final candidate = jsonEncode({
      'overview': '',
      'overview_evidence': <String>[],
      'chapters': <Object>[],
      'insights': <Object>[],
      'language_notes': <Object>[],
    });
    final client = _LlmClient([
      candidate,
      candidate,
      jsonEncode({
        'overview': '',
        'overview_evidence': <String>[],
        'chapters': <Object>[],
        'insights': <Object>[],
        'language_notes': [
          {
            'kind': 'vocabulary',
            'term': 'a',
            'explanation': 'An advanced explanation.',
            'source_excerpt': 'a',
            'evidence': ['s1'],
          },
        ],
      }),
    ]);
    final document = TranscriptDocument(
      tokens: const [],
      segments: [
        TranscriptSegment(
          id: 's1',
          startMs: 0,
          endMs: 1,
          text: List.filled(5000, 'a').join(),
        ),
        TranscriptSegment(
          id: 's2',
          startMs: 2,
          endMs: 3,
          text: List.filled(5000, 'b').join(),
        ),
      ],
      speakers: const [],
      updatedAt: DateTime.utc(2026, 8, 12),
    );

    final brief = await DefaultAiBriefService(client).generate(
      settings: settings,
      document: document,
      sections: const {AiBriefSection.languageNotes},
      outputLanguage: 'en',
      learningLanguage: 'ja',
      learningLevel: AiLearningLevel.advanced,
    );

    expect(brief.languageNotes.single.term, 'a');
    expect(brief.learningLanguage, 'ja');
    expect(client.prompts.last, contains('language code "ja"'));
    expect(client.prompts.last, contains('at advanced level'));
    expect(client.prompts.last, contains('Select 6–12 high-value notes'));
  });

  test('cancellation stops before contacting the LLM', () async {
    final client = _LlmClient(const []);

    await expectLater(
      DefaultAiBriefService(client).generate(
        settings: settings,
        document: _document(),
        sections: const {AiBriefSection.overview},
        outputLanguage: 'en',
        shouldCancel: () => true,
      ),
      throwsA(isA<OperationCancelledException>()),
    );
    expect(client.prompts, isEmpty);
  });
}

TranscriptDocument _document() => TranscriptDocument(
  tokens: const [],
  segments: const [
    TranscriptSegment(
      id: 's1',
      startMs: 0,
      endMs: 1000,
      text: 'We should build a trustworthy brief.',
      speaker: '1',
    ),
    TranscriptSegment(
      id: 's2',
      startMs: 1000,
      endMs: 2000,
      text: 'Ship the grounded feature.',
      speaker: '2',
    ),
  ],
  speakers: const [
    SpeakerProfile(id: '1', name: 'Ada'),
    SpeakerProfile(id: '2', name: 'Lin'),
  ],
  updatedAt: DateTime.utc(2026, 8, 12),
);

class _LlmClient implements LlmClient {
  _LlmClient(this._responses);

  final List<String> _responses;
  final List<String> prompts = [];
  var _index = 0;

  @override
  Future<String> complete({
    required LlmProviderSettings settings,
    required String systemPrompt,
    required String userPrompt,
    CancelCheck? shouldCancel,
  }) async {
    prompts.add(userPrompt);
    return _responses[_index++];
  }

  @override
  Future<List<String>> listModels(
    LlmProviderSettings settings, {
    String? candidateApiKey,
  }) async => const [];
}
