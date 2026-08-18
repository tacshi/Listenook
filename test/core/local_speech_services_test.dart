import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/local_speech.dart';
import 'package:meow_stt/core/models.dart';
import 'package:meow_stt/data/local_speech_services.dart';

void main() {
  const alignmentModel = LocalSpeechModels.qwen3ForcedAlignerCoreMlInt8;

  test('MOSS tagged output becomes speaker-attributed segments', () {
    final document = const MossTaggedTranscriptParser().parse(
      '[0.48][S01]Welcome everyone[1.66]'
      '[12.26][S02]The pipeline is ready[13.81]',
      durationMs: 15000,
    );

    expect(document.segments, hasLength(2));
    expect(document.segments.first.startMs, 480);
    expect(document.segments.first.endMs, 1660);
    expect(document.segments.last.speaker, 'S02');
    expect(document.speakers.map((speaker) => speaker.id), ['S01', 'S02']);
  });

  test('MOSS tagged output rejects a truncated trailing segment', () {
    expect(
      () => const MossTaggedTranscriptParser().parse(
        '[0.48][S01]Welcome everyone',
        durationMs: 15000,
      ),
      throwsA(
        isA<LocalSpeechException>().having(
          (error) => error.code,
          'code',
          'moss_truncated_output',
        ),
      ),
    );
  });

  test('MOSS parser repairs harmless spacing inside structural tags', () {
    final document = const MossTaggedTranscriptParser().parse(
      '[0.48] [s1]Welcome[1.66]\n[1.70]\t[S02]Next[2.00]',
      durationMs: 3000,
    );

    expect(document.segments, hasLength(2));
    expect(document.segments.first.speaker, 'S1');
    expect(document.segments.last.text, 'Next');
  });

  test('structured MOSS output drops control-only malformed segments', () {
    final document = const MossTaggedTranscriptParser().parseStructured(
      [
        {
          'start_ms': 39 * 60 * 1000,
          'end_ms': 39 * 60 * 1000 + 30000,
          'text': '[2.12][S01][2.62][18.28][S02][18.78]',
        },
      ],
      durationMs: 60 * 60 * 1000,
      plainText: '[2.12][S01][2.62][18.28][S02][18.78]',
    );

    expect(document.segments, isEmpty);
    expect(document.speakers, isEmpty);
  });

  test(
    'Qwen unitizer drops punctuation and keeps script-appropriate units',
    () {
      expect(const QwenAlignmentUnitizer().units("Hello, l'été 2026!"), [
        'Hello',
        "l'été",
        '2026',
      ]);
      expect(const QwenAlignmentUnitizer().units('PS5 RTX5080 Swift4'), [
        'PS',
        '5',
        'RTX',
        '5080',
        'Swift',
        '4',
      ]);
      expect(const QwenAlignmentUnitizer().units('你好，世界。'), [
        '你',
        '好',
        '世',
        '界',
      ]);
      expect(const QwenAlignmentUnitizer().units('日本語 테스트'), [
        '日',
        '本',
        '語',
        '테',
        '스',
        '트',
      ]);
      expect(const QwenAlignmentUnitizer().canAutoAlign('مرحبا'), isFalse);
    },
  );

  test(
    'local Core ML MOSS consumes structured segments without generated-tag parsing',
    () async {
      final worker = _Worker({
        'text': 'Hello local world',
        'segments': [
          {
            'start_ms': 0,
            'end_ms': 2500,
            'speaker': 'S01',
            'text': 'Hello local world',
          },
        ],
      });
      final service = ProcessLocalSttService(
        models: _Models(ready: true),
        pcm: _Pcm(),
        worker: worker,
        platformSupported: true,
      );

      final document = await service.transcribe(
        const LocalSttRequest(
          sourcePath: '/meeting.mp4',
          durationMs: 10 * 60 * 1000,
          options: TranscriptionOptions(contextTerms: ['MeowSTT']),
        ),
      );

      expect(document.segments.single.text, 'Hello local world');
      expect(worker.command, SpeechWorkerCommand.transcribeMoss);
      expect(worker.request?['chunk_seconds'], 30);
      expect(worker.request?['parallel_chunks'], 2);
      expect(worker.request?['max_new_tokens_per_chunk'], 640);
      expect(worker.request?['hotwords'], ['MeowSTT']);
      expect(worker.request?['audio_path'], '/tmp/local.wav');
      expect(worker.request?['model_directory'], contains('coreml-int8'));
      expect(worker.request, isNot(contains('model_path')));
    },
  );

  test(
    'local MOSS accepts the inclusive 300-minute application limit',
    () async {
      final worker = _Worker({
        'text': 'Long local recording',
        'segments': [
          {
            'start_ms': maxMediaDurationMs - 1000,
            'end_ms': maxMediaDurationMs,
            'speaker': 'S01',
            'text': 'Long local recording',
          },
        ],
      });
      final service = ProcessLocalSttService(
        models: _Models(ready: true),
        pcm: _Pcm(),
        worker: worker,
        platformSupported: true,
      );

      final document = await service.transcribe(
        const LocalSttRequest(
          sourcePath: '/five-hour-video.mp4',
          durationMs: maxMediaDurationMs,
          options: TranscriptionOptions(),
        ),
      );

      expect(document.segments.single.endMs, maxMediaDurationMs);
      expect(worker.command, SpeechWorkerCommand.transcribeMoss);
    },
  );

  test('local MOSS rejects media above the application limit', () async {
    final worker = _Worker(const {});
    final service = ProcessLocalSttService(
      models: _Models(ready: true),
      pcm: _Pcm(),
      worker: worker,
      platformSupported: true,
    );

    await expectLater(
      service.transcribe(
        const LocalSttRequest(
          sourcePath: '/too-long.wav',
          durationMs: maxMediaDurationMs + 1,
          options: TranscriptionOptions(),
        ),
      ),
      throwsA(
        isA<LocalSpeechException>().having(
          (error) => error.code,
          'code',
          'duration_limit',
        ),
      ),
    );
    expect(worker.command, isNull);
  });

  test('local MOSS refuses to start without its verified model', () async {
    final worker = _Worker(const {});
    final service = ProcessLocalSttService(
      models: _Models(ready: false),
      pcm: _Pcm(),
      worker: worker,
      platformSupported: true,
    );

    await expectLater(
      service.transcribe(
        const LocalSttRequest(
          sourcePath: '/meeting.wav',
          durationMs: 1000,
          options: TranscriptionOptions(),
        ),
      ),
      throwsA(
        isA<LocalSpeechException>().having(
          (error) => error.code,
          'code',
          'local_stt_model_missing',
        ),
      ),
    );
    expect(worker.command, isNull);
  });

  test(
    'forced alignment adds segment-owned tokens without changing segments',
    () async {
      final source = _document();
      final worker = _Worker({
        'tokens': [
          {
            'segment_id': 'one',
            'text': 'Hello',
            'start_ms': -40,
            'end_ms': 440,
          },
          {
            'segment_id': 'two',
            'text': 'World',
            'start_ms': 300,
            'end_ms': 1300,
          },
        ],
        'aligned_segment_ids': ['one', 'two'],
      });
      final service = ProcessForcedAlignmentService(
        models: _Models(ready: true),
        pcm: _Pcm(),
        worker: worker,
        platformSupported: true,
      );

      final result = await service.align(
        ForcedAlignmentRequest(
          model: alignmentModel,
          sourcePath: '/meeting.wav',
          document: source,
          languageHints: const ['en'],
        ),
      );

      expect(result.status, ForcedAlignmentStatus.completed);
      expect(result.tokens.map((token) => token.segmentId), ['one', 'two']);
      expect(result.tokens.first.startMs, 0);
      expect(result.tokens.last.endMs, 1000);
      expect(result.tokens.last.speaker, 'S02');
      expect(source.tokens, isEmpty);
      expect(worker.request?['segments'], hasLength(2));
      expect(worker.request?['windows'], hasLength(2));
    },
  );

  test(
    'alignment keeps reliable neighbors when one segment has a count mismatch',
    () async {
      final document = TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'one',
            startMs: 100,
            endMs: 800,
            text: 'Hello world',
          ),
          TranscriptSegment(
            id: 'two',
            startMs: 800,
            endMs: 1400,
            text: 'Again',
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.utc(2026, 8, 16),
      );
      final worker = _Worker({
        'tokens': [
          {
            'segment_id': 'one',
            'text': 'Hello',
            'start_ms': 100,
            'end_ms': 400,
          },
          // "world" is absent, so only its owning segment is discarded.
          {
            'segment_id': 'two',
            'text': 'Again',
            'start_ms': 800,
            'end_ms': 1200,
          },
        ],
      });
      final service = ProcessForcedAlignmentService(
        models: _Models(ready: true),
        pcm: _Pcm(),
        worker: worker,
        platformSupported: true,
      );

      final result = await service.align(
        ForcedAlignmentRequest(
          model: alignmentModel,
          sourcePath: '/meeting.wav',
          document: document,
          languageHints: const ['en'],
        ),
      );

      expect(worker.request?['windows'], hasLength(1));
      expect(result.tokens.map((token) => token.text), ['Again']);
      expect(result.tokens.single.segmentId, 'two');
      expect(result.status, ForcedAlignmentStatus.partial);
      expect(result.warningCode, 'alignment_partial');
    },
  );

  test(
    'dense CJK is split before the Core ML prompt budget drops whole windows',
    () async {
      final segments = <TranscriptSegment>[
        for (var index = 0; index < 20; index++)
          TranscriptSegment(
            id: 'dense-$index',
            startMs: index * 1200,
            endMs: (index + 1) * 1200,
            text: '一二三四五六七八九十',
          ),
      ];
      final worker = _CapacityLimitedAlignmentWorker();
      final service = ProcessForcedAlignmentService(
        models: _Models(ready: true),
        pcm: _Pcm(),
        worker: worker,
        platformSupported: true,
      );

      final result = await service.align(
        ForcedAlignmentRequest(
          model: alignmentModel,
          sourcePath: '/dense-cjk.wav',
          document: TranscriptDocument(
            tokens: const [],
            segments: segments,
            speakers: const [],
            updatedAt: DateTime.utc(2026, 8, 16),
          ),
          languageHints: const ['zh'],
        ),
      );

      expect(result.status, ForcedAlignmentStatus.completed);
      expect(result.alignedSegments, segments.length);
      expect(worker.rejectedWindows, isEmpty);
      expect(worker.request?['windows'], hasLength(greaterThan(1)));
    },
  );

  test('alignment rejects a same-count unit mismatch', () async {
    final document = TranscriptDocument(
      tokens: const [],
      segments: const [
        TranscriptSegment(
          id: 'one',
          startMs: 0,
          endMs: 1000,
          text: 'Hello world',
        ),
      ],
      speakers: const [],
      updatedAt: DateTime.utc(2026, 8, 16),
    );
    final worker = _Worker({
      'tokens': [
        {'segment_id': 'one', 'text': 'Hello', 'start_ms': 0, 'end_ms': 400},
        {'segment_id': 'one', 'text': 'wrong', 'start_ms': 400, 'end_ms': 800},
      ],
    });
    final service = ProcessForcedAlignmentService(
      models: _Models(ready: true),
      pcm: _Pcm(),
      worker: worker,
      platformSupported: true,
    );

    final result = await service.align(
      ForcedAlignmentRequest(
        model: alignmentModel,
        sourcePath: '/meeting.wav',
        document: document,
        languageHints: const ['en'],
      ),
    );

    expect(result.status, ForcedAlignmentStatus.failed);
    expect(result.tokens, isEmpty);
  });

  test('alignment preserves an isolated tied 80 ms timestamp class', () async {
    final document = TranscriptDocument(
      tokens: const [],
      segments: const [
        TranscriptSegment(id: 'one', startMs: 100, endMs: 300, text: '日本語'),
      ],
      speakers: const [],
      updatedAt: DateTime.utc(2026, 8, 16),
    );
    final worker = _Worker({
      'tokens': [
        {'segment_id': 'one', 'text': '日', 'start_ms': 100, 'end_ms': 180},
        {'segment_id': 'one', 'text': '本', 'start_ms': 180, 'end_ms': 180},
        {'segment_id': 'one', 'text': '語', 'start_ms': 180, 'end_ms': 260},
      ],
    });
    final service = ProcessForcedAlignmentService(
      models: _Models(ready: true),
      pcm: _Pcm(),
      worker: worker,
      platformSupported: true,
    );

    final result = await service.align(
      ForcedAlignmentRequest(
        model: alignmentModel,
        sourcePath: '/meeting.wav',
        document: document,
        languageHints: const ['ja'],
      ),
    );

    expect(result.status, ForcedAlignmentStatus.completed);
    expect(result.tokens.map((token) => token.text), ['日', '本', '語']);
    expect(result.tokens.map((token) => token.startMs), [100, 160, 200]);
    expect(result.tokens.every((token) => token.endMs > token.startMs), isTrue);
  });

  test(
    'alignment advances late word transitions across uncertain gaps',
    () async {
      final document = TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'opening',
            startMs: 110,
            endMs: 3590,
            text: 'This BBC podcast is supported by ads outside the UK.',
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.utc(2026, 8, 17),
      );
      final worker = _Worker({
        'tokens': [
          {
            'segment_id': 'opening',
            'text': 'This',
            'start_ms': 110,
            'end_ms': 720,
          },
          {
            'segment_id': 'opening',
            'text': 'BBC',
            'start_ms': 960,
            'end_ms': 1040,
          },
          {
            'segment_id': 'opening',
            'text': 'podcast',
            'start_ms': 1040,
            'end_ms': 1440,
          },
          {
            'segment_id': 'opening',
            'text': 'is',
            'start_ms': 1600,
            'end_ms': 2160,
          },
          {
            'segment_id': 'opening',
            'text': 'supported',
            'start_ms': 2160,
            'end_ms': 2320,
          },
          {
            'segment_id': 'opening',
            'text': 'by',
            'start_ms': 2320,
            'end_ms': 2720,
          },
          {
            'segment_id': 'opening',
            'text': 'ads',
            'start_ms': 2720,
            'end_ms': 2880,
          },
          {
            'segment_id': 'opening',
            'text': 'outside',
            'start_ms': 3200,
            'end_ms': 3280,
          },
          {
            'segment_id': 'opening',
            'text': 'the',
            'start_ms': 3280,
            'end_ms': 3435,
          },
          {
            'segment_id': 'opening',
            'text': 'UK',
            'start_ms': 3435,
            'end_ms': 3590,
          },
        ],
      });
      final service = ProcessForcedAlignmentService(
        models: _Models(ready: true),
        pcm: _Pcm(),
        worker: worker,
        platformSupported: true,
      );

      final result = await service.align(
        ForcedAlignmentRequest(
          model: alignmentModel,
          sourcePath: '/opening.wav',
          document: document,
          languageHints: const ['en'],
        ),
      );

      expect(result.status, ForcedAlignmentStatus.completed);
      expect(result.tokens[1].startMs, 840);
      expect(result.tokens[3].startMs, 1520);
      expect(result.tokens[7].startMs, 3040);
      expect(
        result.tokens.every((token) => token.endMs > token.startMs),
        isTrue,
      );
    },
  );

  test(
    'alignment gives a visible span to a point clamped at a segment boundary',
    () async {
      final document = TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(id: 'one', startMs: 100, endMs: 300, text: '日本語'),
        ],
        speakers: const [],
        updatedAt: DateTime.utc(2026, 8, 16),
      );
      final worker = _Worker({
        'tokens': [
          {'segment_id': 'one', 'text': '日', 'start_ms': 20, 'end_ms': 80},
          {'segment_id': 'one', 'text': '本', 'start_ms': 100, 'end_ms': 180},
          {'segment_id': 'one', 'text': '語', 'start_ms': 180, 'end_ms': 260},
        ],
      });
      final service = ProcessForcedAlignmentService(
        models: _Models(ready: true),
        pcm: _Pcm(),
        worker: worker,
        platformSupported: true,
      );

      final result = await service.align(
        ForcedAlignmentRequest(
          model: alignmentModel,
          sourcePath: '/meeting.wav',
          document: document,
          languageHints: const ['ja'],
        ),
      );

      expect(result.status, ForcedAlignmentStatus.completed);
      expect(result.tokens.first.startMs, 100);
      expect(result.tokens.first.endMs, 140);
      expect(
        result.tokens.every((token) => token.endMs > token.startMs),
        isTrue,
      );
    },
  );

  test('alignment repairs a sentence tail clamped past its end', () async {
    final document = TranscriptDocument(
      tokens: const [],
      segments: const [
        TranscriptSegment(id: 'one', startMs: 100, endMs: 600, text: '分享一下'),
      ],
      speakers: const [],
      updatedAt: DateTime.utc(2026, 8, 17),
    );
    final worker = _Worker({
      'tokens': [
        {'segment_id': 'one', 'text': '分', 'start_ms': 100, 'end_ms': 220},
        {'segment_id': 'one', 'text': '享', 'start_ms': 220, 'end_ms': 340},
        {'segment_id': 'one', 'text': '一', 'start_ms': 340, 'end_ms': 520},
        {'segment_id': 'one', 'text': '下', 'start_ms': 640, 'end_ms': 720},
      ],
    });
    final service = ProcessForcedAlignmentService(
      models: _Models(ready: true),
      pcm: _Pcm(),
      worker: worker,
      platformSupported: true,
    );

    final result = await service.align(
      ForcedAlignmentRequest(
        model: alignmentModel,
        sourcePath: '/meeting.wav',
        document: document,
        languageHints: const ['zh'],
      ),
    );

    expect(result.status, ForcedAlignmentStatus.completed);
    expect(result.tokens.last.text, '下');
    expect(result.tokens.last.startMs, 520);
    expect(result.tokens.last.endMs, 600);
  });

  test('alignment repairs multiple tail tokens clamped past its end', () async {
    final document = TranscriptDocument(
      tokens: const [],
      segments: const [
        TranscriptSegment(id: 'one', startMs: 100, endMs: 700, text: '送的礼物'),
      ],
      speakers: const [],
      updatedAt: DateTime.utc(2026, 8, 17),
    );
    final worker = _Worker({
      'tokens': [
        {'segment_id': 'one', 'text': '送', 'start_ms': 100, 'end_ms': 500},
        {'segment_id': 'one', 'text': '的', 'start_ms': 500, 'end_ms': 700},
        {'segment_id': 'one', 'text': '礼', 'start_ms': 740, 'end_ms': 800},
        {'segment_id': 'one', 'text': '物', 'start_ms': 800, 'end_ms': 860},
      ],
    });
    final service = ProcessForcedAlignmentService(
      models: _Models(ready: true),
      pcm: _Pcm(),
      worker: worker,
      platformSupported: true,
    );

    final result = await service.align(
      ForcedAlignmentRequest(
        model: alignmentModel,
        sourcePath: '/meeting.wav',
        document: document,
        languageHints: const ['zh'],
      ),
    );

    expect(result.status, ForcedAlignmentStatus.completed);
    expect(result.tokens.map((token) => token.text), ['送', '的', '礼', '物']);
    expect(result.tokens[1].startMs, 500);
    expect(result.tokens[1].endMs, 566);
    expect(result.tokens[2].startMs, 566);
    expect(result.tokens[2].endMs, 633);
    expect(result.tokens[3].startMs, 633);
    expect(result.tokens[3].endMs, 700);
  });

  test(
    'alignment estimates timing when every token falls before its segment',
    () async {
      final document = TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'moss-223',
            startMs: 426099,
            endMs: 427619,
            text: '啊，对，这个感觉',
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.utc(2026, 8, 17),
      );
      final units = const ['啊', '对', '这', '个', '感', '觉'];
      final worker = _Worker({
        'tokens': [
          for (var index = 0; index < units.length; index++)
            {
              'segment_id': 'moss-223',
              'text': units[index],
              'start_ms': 424659 + index * 160,
              'end_ms': 424899 + index * 160,
            },
        ],
      });
      final service = ProcessForcedAlignmentService(
        models: _Models(ready: true),
        pcm: _Pcm(),
        worker: worker,
        platformSupported: true,
      );

      final result = await service.align(
        ForcedAlignmentRequest(
          model: alignmentModel,
          sourcePath: '/meeting.wav',
          document: document,
          languageHints: const ['zh'],
        ),
      );

      expect(result.status, ForcedAlignmentStatus.completed);
      expect(result.tokens.map((token) => token.text), units);
      expect(result.tokens.first.startMs, 426099);
      expect(result.tokens.last.endMs, 427619);
      expect(
        result.tokens.every((token) => token.endMs > token.startMs),
        isTrue,
      );
    },
  );

  test(
    'explicit unsupported alignment language fails open to segment timing',
    () async {
      final worker = _Worker(const {});
      final service = ProcessForcedAlignmentService(
        models: _Models(ready: true),
        pcm: _Pcm(),
        worker: worker,
        platformSupported: true,
      );

      final result = await service.align(
        ForcedAlignmentRequest(
          model: alignmentModel,
          sourcePath: '/meeting.wav',
          document: _document(),
          languageHints: const ['ar'],
        ),
      );

      expect(result.status, ForcedAlignmentStatus.unavailable);
      expect(result.warningCode, 'alignment_language_unsupported');
      expect(worker.command, isNull);
    },
  );

  test(
    'missing alignment model is an unavailable local post-process',
    () async {
      final worker = _Worker(const {});
      final service = ProcessForcedAlignmentService(
        models: _Models(ready: false),
        pcm: _Pcm(),
        worker: worker,
        platformSupported: true,
      );

      final result = await service.align(
        ForcedAlignmentRequest(
          model: alignmentModel,
          sourcePath: '/meeting.wav',
          document: _document(),
          languageHints: const ['en'],
        ),
      );

      expect(result.status, ForcedAlignmentStatus.unavailable);
      expect(result.warningCode, 'alignment_model_missing');
      expect(worker.command, isNull);
    },
  );

  test('alignment loads the selected FP16 model directory', () async {
    final worker = _Worker(const {
      'tokens': <Object>[],
      'failed_window_ids': <Object>[],
    });
    final models = _Models(ready: true);
    final service = ProcessForcedAlignmentService(
      models: models,
      pcm: _Pcm(),
      worker: worker,
      platformSupported: true,
    );

    await service.align(
      ForcedAlignmentRequest(
        model: LocalSpeechModels.qwen3ForcedAlignerCoreMlFp16,
        sourcePath: '/meeting.wav',
        document: _document(),
        languageHints: const ['en'],
      ),
    );

    expect(models.statusRequests, [
      LocalSpeechModels.qwen3ForcedAlignerCoreMlFp16.id,
    ]);
    expect(
      worker.request?['model_directory'],
      '/models/${LocalSpeechModels.qwen3ForcedAlignerCoreMlFp16.id}',
    );
  });

  test('missing selected FP16 model does not fall back to INT8', () async {
    final worker = _Worker(const {});
    final models = _Models(
      ready: false,
      readyIds: {LocalSpeechModels.qwen3ForcedAlignerCoreMlInt8.id},
    );
    final service = ProcessForcedAlignmentService(
      models: models,
      pcm: _Pcm(),
      worker: worker,
      platformSupported: true,
    );

    final result = await service.align(
      ForcedAlignmentRequest(
        model: LocalSpeechModels.qwen3ForcedAlignerCoreMlFp16,
        sourcePath: '/meeting.wav',
        document: _document(),
        languageHints: const ['en'],
      ),
    );

    expect(result.status, ForcedAlignmentStatus.unavailable);
    expect(result.warningCode, 'alignment_model_missing');
    expect(models.statusRequests, [
      LocalSpeechModels.qwen3ForcedAlignerCoreMlFp16.id,
    ]);
    expect(worker.command, isNull);
  });

  test(
    'one invalid overlap window publishes only the reliable tokens',
    () async {
      final worker = _Worker({
        'tokens': [
          {'segment_id': 'one', 'text': 'Hello', 'start_ms': 0, 'end_ms': 400},
        ],
      });
      final service = ProcessForcedAlignmentService(
        models: _Models(ready: true),
        pcm: _Pcm(),
        worker: worker,
        platformSupported: true,
      );

      final result = await service.align(
        ForcedAlignmentRequest(
          model: alignmentModel,
          sourcePath: '/meeting.wav',
          document: _document(),
          languageHints: const ['en'],
        ),
      );

      expect(result.status, ForcedAlignmentStatus.partial);
      expect(result.tokens.single.segmentId, 'one');
      expect(result.alignedSegments, 1);
      expect(result.totalSegments, 2);
    },
  );

  test(
    'every segment in an overlap chain gets an independent window',
    () async {
      final document = TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(id: 'a', startMs: 0, endMs: 1000, text: 'A'),
          TranscriptSegment(id: 'b', startMs: 500, endMs: 700, text: 'B'),
          TranscriptSegment(id: 'c', startMs: 700, endMs: 1200, text: 'C'),
          TranscriptSegment(id: 'd', startMs: 1200, endMs: 1500, text: 'D'),
        ],
        speakers: const [],
        updatedAt: DateTime.utc(2026, 8, 16),
      );
      final worker = _Worker(const {'tokens': []});
      final service = ProcessForcedAlignmentService(
        models: _Models(ready: true),
        pcm: _Pcm(),
        worker: worker,
        platformSupported: true,
      );

      await service.align(
        ForcedAlignmentRequest(
          model: alignmentModel,
          sourcePath: '/meeting.wav',
          document: document,
          languageHints: const ['en'],
        ),
      );

      final windows = worker.request!['windows'] as List;
      expect(windows, hasLength(4));
      expect(
        windows.map((window) => (window as Map)['segments'] as List),
        everyElement(hasLength(1)),
      );
    },
  );

  test('an oversized segment is skipped with a partial warning', () async {
    final document = TranscriptDocument(
      tokens: const [],
      segments: const [
        TranscriptSegment(
          id: 'long',
          startMs: 0,
          endMs: 29001,
          text: 'Long anomaly',
        ),
      ],
      speakers: const [],
      updatedAt: DateTime.utc(2026, 8, 16),
    );
    final worker = _Worker(const {});
    final service = ProcessForcedAlignmentService(
      models: _Models(ready: true),
      pcm: _Pcm(),
      worker: worker,
      platformSupported: true,
    );

    final result = await service.align(
      ForcedAlignmentRequest(
        model: alignmentModel,
        sourcePath: '/meeting.wav',
        document: document,
        languageHints: const ['en'],
      ),
    );

    expect(result.status, ForcedAlignmentStatus.partial);
    expect(result.alignedSegments, 0);
    expect(result.totalSegments, 1);
    expect(result.warningCode, 'alignment_segment_too_long');
    expect(worker.command, isNull);
  });

  test(
    'automatic script eligibility is recorded on alignment results',
    () async {
      final worker = _Worker({
        'tokens': [
          {'segment_id': 'one', 'text': 'Hello', 'start_ms': 0, 'end_ms': 400},
          {
            'segment_id': 'two',
            'text': 'World',
            'start_ms': 400,
            'end_ms': 900,
          },
        ],
      });
      final service = ProcessForcedAlignmentService(
        models: _Models(ready: true),
        pcm: _Pcm(),
        worker: worker,
        platformSupported: true,
      );

      final result = await service.align(
        ForcedAlignmentRequest(
          model: alignmentModel,
          sourcePath: '/meeting.wav',
          document: _document(),
        ),
      );

      expect(result.status, ForcedAlignmentStatus.completed);
      expect(result.languageAutomaticallyDetermined, isTrue);
    },
  );

  test(
    'alignment progress stays monotonic across PCM and model stages',
    () async {
      final worker = _Worker({
        'tokens': [
          {'segment_id': 'one', 'text': 'Hello', 'start_ms': 0, 'end_ms': 400},
          {
            'segment_id': 'two',
            'text': 'World',
            'start_ms': 400,
            'end_ms': 900,
          },
        ],
      }, progressFraction: 0.5);
      final service = ProcessForcedAlignmentService(
        models: _Models(ready: true),
        pcm: _Pcm(progressFraction: 0.5),
        worker: worker,
        platformSupported: true,
      );
      final progress = <double>[];

      await service.align(
        ForcedAlignmentRequest(
          model: alignmentModel,
          sourcePath: '/meeting.wav',
          document: _document(),
          languageHints: const ['en'],
        ),
        onProgress: (fraction, detail) {
          if (fraction != null) progress.add(fraction);
        },
      );

      expect(progress, [closeTo(0.1, 1e-9), closeTo(0.6, 1e-9)]);
      expect(progress, orderedEquals(progress.toList()..sort()));
    },
  );
}

TranscriptDocument _document() => TranscriptDocument(
  tokens: const [],
  segments: const [
    TranscriptSegment(
      id: 'one',
      startMs: 0,
      endMs: 600,
      text: 'Hello',
      speaker: 'S01',
    ),
    TranscriptSegment(
      id: 'two',
      startMs: 300,
      endMs: 1000,
      text: 'World',
      speaker: 'S02',
    ),
  ],
  speakers: const [
    SpeakerProfile(id: 'S01', name: 'Speaker 1'),
    SpeakerProfile(id: 'S02', name: 'Speaker 2'),
  ],
  updatedAt: DateTime.utc(2026, 8, 16),
);

class _Models implements LocalModelManager {
  _Models({required this.ready, this.readyIds});
  final bool ready;
  final Set<String>? readyIds;
  final statusRequests = <String>[];

  @override
  List<LocalModelDescriptor> get models => LocalSpeechModels.all;

  @override
  Future<void> delete(String modelId) async {}

  @override
  Future<void> download(
    String modelId, {
    ModelDownloadProgress? onProgress,
    bool Function()? shouldCancel,
  }) async {}

  @override
  String pathFor(String modelId) => '/models/$modelId';

  @override
  Future<LocalModelStatus> status(
    String modelId, {
    bool verifyIntegrity = false,
  }) async {
    statusRequests.add(modelId);
    return LocalModelStatus(
      descriptor: models.singleWhere((model) => model.id == modelId),
      availability: (readyIds?.contains(modelId) ?? ready)
          ? LocalModelAvailability.ready
          : LocalModelAvailability.missing,
      downloadedBytes: 0,
    );
  }
}

class _Pcm implements LocalPcmPreparer {
  _Pcm({this.progressFraction});

  final double? progressFraction;

  @override
  Future<PreparedLocalPcm> prepare(
    String sourcePath, {
    required int durationMs,
    void Function(double? fraction, String? detail)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    if (progressFraction case final fraction?) {
      onProgress?.call(fraction, 'converting');
    }
    return const PreparedLocalPcm('/tmp/local.wav');
  }

  @override
  Future<void> release(PreparedLocalPcm pcm) async {}
}

class _Worker implements LocalSpeechWorker {
  _Worker(this.response, {this.progressFraction});
  final Map<String, dynamic> response;
  final double? progressFraction;
  SpeechWorkerCommand? command;
  Map<String, dynamic>? request;

  @override
  Future<Map<String, dynamic>> run(
    SpeechWorkerCommand command,
    Map<String, dynamic> request, {
    void Function(double? fraction, String? detail)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    this.command = command;
    this.request = request;
    if (progressFraction case final fraction?) {
      onProgress?.call(fraction, 'aligning');
    }
    return response;
  }
}

class _CapacityLimitedAlignmentWorker implements LocalSpeechWorker {
  Map<String, dynamic>? request;
  final rejectedWindows = <String>[];

  @override
  Future<Map<String, dynamic>> run(
    SpeechWorkerCommand command,
    Map<String, dynamic> request, {
    void Function(double? fraction, String? detail)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    this.request = request;
    final tokens = <Map<String, dynamic>>[];
    final windows = (request['windows'] as List).cast<Map>();
    for (final rawWindow in windows) {
      final window = rawWindow.cast<String, dynamic>();
      final startMs = (window['start_ms'] as num).toInt();
      final endMs = (window['end_ms'] as num).toInt();
      final segments = (window['segments'] as List).cast<Map>();
      final unitCount = segments.fold<int>(
        0,
        (total, segment) => total + ((segment['units'] as List?)?.length ?? 0),
      );
      final estimatedAudioTokens = ((endMs - startMs) * 13 / 1000).ceil();
      final promptTokens = 15 + estimatedAudioTokens + unitCount * 3;
      if (promptTokens > 720) {
        rejectedWindows.add(window['id'].toString());
        continue;
      }
      for (final rawSegment in segments) {
        final segment = rawSegment.cast<String, dynamic>();
        final id = segment['id'].toString();
        final segmentStart = (segment['start_ms'] as num).toInt();
        final segmentEnd = (segment['end_ms'] as num).toInt();
        final units = (segment['units'] as List).cast<String>();
        for (var index = 0; index < units.length; index++) {
          final start =
              segmentStart +
              ((segmentEnd - segmentStart) * index / units.length).floor();
          final end =
              segmentStart +
              ((segmentEnd - segmentStart) * (index + 1) / units.length)
                  .floor();
          tokens.add({
            'segment_id': id,
            'text': units[index],
            'start_ms': start,
            'end_ms': end,
          });
        }
      }
    }
    return {
      'tokens': tokens,
      'failed_window_ids': rejectedWindows,
      if (rejectedWindows.isNotEmpty) 'warning_code': 'alignment_partial',
    };
  }
}
