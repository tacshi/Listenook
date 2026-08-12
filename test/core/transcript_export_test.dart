import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/models.dart';
import 'package:meow_stt/core/transcript_parser.dart';
import 'package:meow_stt/data/transcript_exporter.dart';

void main() {
  const parser = TranscriptParser();
  const exporter = DefaultTranscriptExporter();

  final document = parser.parse({
    'tokens': [
      {
        'text': 'Hello ',
        'start_ms': 0,
        'end_ms': 400,
        'speaker': '1',
        'language': 'en',
        'confidence': 0.98,
      },
      {
        'text': 'world.',
        'start_ms': 450,
        'end_ms': 1100,
        'speaker': '1',
        'language': 'en',
      },
      {
        'text': '你好。',
        'start_ms': 3000,
        'end_ms': 4200,
        'speaker': '2',
        'language': 'zh',
      },
    ],
  });

  test('parser splits punctuation, pauses and speaker changes', () {
    expect(document.tokens, hasLength(3));
    expect(document.segments, hasLength(2));
    expect(document.segments.first.text, 'Hello world.');
    expect(document.speakers, hasLength(2));
  });

  test('parser keeps a Chinese sentence and trailing punctuation together', () {
    final result = parser.parse({
      'tokens': [
        {
          'text': '现在我测试一条新的录音，接下来将会把它传到电脑上进行一个批量转写，总',
          'start_ms': 0,
          'end_ms': 7900,
          'speaker': '1',
          'language': 'zh',
        },
        {
          'text': '共两条录音',
          'start_ms': 8000,
          'end_ms': 10000,
          'speaker': '1',
          'language': 'zh',
        },
        {'text': '。'},
      ],
    });

    expect(result.segments, hasLength(1));
    expect(
      result.segments.single.text,
      '现在我测试一条新的录音，接下来将会把它传到电脑上进行一个批量转写，总共两条录音。',
    );
  });

  test('parser moves a detached closing quote to the previous sentence', () {
    final parsed = parser.parse({
      'tokens': [
        {
          'text': '"You can give it a shot and we\'ll go from there.',
          'start_ms': 0,
          'end_ms': 1800,
          'language': 'en',
        },
        {'text': '"', 'start_ms': 1810, 'end_ms': 1850, 'language': 'en'},
        {
          'text': ' I was so excited.',
          'start_ms': 1900,
          'end_ms': 2800,
          'language': 'en',
        },
      ],
    });

    expect(parsed.segments, hasLength(2));
    expect(parsed.segments.map((segment) => segment.text), [
      '"You can give it a shot and we\'ll go from there."',
      'I was so excited.',
    ]);
  });

  test('normalizer repairs a detached closing quote in saved documents', () {
    final repaired = parser.normalizeSegments(
      TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'first',
            startMs: 0,
            endMs: 1800,
            text: '"You can give it a shot and we\'ll go from there.',
          ),
          TranscriptSegment(
            id: 'second',
            startMs: 1810,
            endMs: 2800,
            text: '" I was so excited.',
          ),
        ],
        speakers: const [],
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );

    expect(repaired.segments, hasLength(2));
    expect(repaired.segments.first.text, endsWith('there."'));
    expect(repaired.segments.last.text, 'I was so excited.');
    expect(repaired.segments.last.id, 'second');
  });

  test('parser omits whitespace-only tokens and empty segments', () {
    final parsed = parser.parse({
      'tokens': [
        {'text': '   ', 'start_ms': 0, 'end_ms': 100},
        {'text': 'Visible.', 'start_ms': 100, 'end_ms': 500},
      ],
    });
    expect(parsed.tokens, hasLength(1));
    expect(parsed.segments.map((segment) => segment.text), ['Visible.']);

    final repaired = parser.normalizeSegments(
      TranscriptDocument(
        tokens: const [],
        segments: const [
          TranscriptSegment(
            id: 'visible',
            startMs: 0,
            endMs: 500,
            text: 'Visible.',
          ),
          TranscriptSegment(id: 'empty', startMs: 500, endMs: 600, text: ''),
        ],
        speakers: const [],
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );
    expect(repaired.segments.map((segment) => segment.id), ['visible']);
  });

  test('parser pairs Soniox original and translation token runs', () {
    final parsed = parser.parse({
      'tokens': [
        {
          'text': 'Good',
          'start_ms': 100,
          'end_ms': 300,
          'speaker': '1',
          'language': 'en',
          'translation_status': 'original',
        },
        {
          'text': ' morning.',
          'start_ms': 300,
          'end_ms': 800,
          'speaker': '1',
          'language': 'en',
          'translation_status': 'original',
        },
        {
          'text': 'Guten',
          'language': 'de',
          'source_language': 'en',
          'translation_status': 'translation',
        },
        {
          'text': ' Morgen.',
          'language': 'de',
          'source_language': 'en',
          'translation_status': 'translation',
        },
        {
          'text': 'Schon gut.',
          'start_ms': 1000,
          'end_ms': 1500,
          'speaker': '2',
          'language': 'de',
          'translation_status': 'none',
        },
      ],
    }, sonioxTranslationTargetLanguage: 'de');

    expect(parsed.segments, hasLength(2));
    expect(parsed.segments.first.text, 'Good morning.');
    expect(parsed.segments.first.translatedText, 'Guten Morgen.');
    expect(parsed.segments.first.startMs, 100);
    expect(parsed.segments.first.endMs, 800);
    expect(parsed.segments.last.text, 'Schon gut.');
    expect(parsed.segments.last.translatedText, 'Schon gut.');
    expect(parsed.speakers.map((speaker) => speaker.id), ['1', '2']);
    expect(parsed.tokens[2].translationStatus, 'translation');
    expect(parsed.tokens[2].sourceLanguage, 'en');
    expect(parsed.tokens[2].startMs, 0);
  });

  test('parser leaves untranslated non-target Soniox speech partial', () {
    final parsed = parser.parse({
      'tokens': [
        {
          'text': 'Sin traducción.',
          'start_ms': 0,
          'end_ms': 600,
          'language': 'es',
          'translation_status': 'original',
        },
      ],
    }, sonioxTranslationTargetLanguage: 'en');

    expect(parsed.segments.single.translatedText, isNull);
  });

  test('TXT and Markdown honor reversible display choices', () {
    expect(
      exporter.render(
        document,
        const ExportOptions(showSpeakers: true, showTimestamps: true),
        title: 'Meeting',
      ),
      '[00:00] Speaker 1: Hello world.\n\n[00:03] Speaker 2: 你好。',
    );
    final markdown = exporter.render(
      document,
      const ExportOptions(format: ExportFormat.markdown, showSpeakers: false),
      title: 'Meeting',
    );
    expect(markdown, startsWith('# Meeting'));
    expect(markdown, contains('你好。'));
  });

  test('SRT and WebVTT always include exact cue timing', () {
    final srt = exporter.render(
      document,
      const ExportOptions(format: ExportFormat.srt, showSpeakers: false),
      title: 'Meeting',
    );
    expect(srt, contains('00:00:00,000 --> 00:00:01,100'));
    final vtt = exporter.render(
      document,
      const ExportOptions(format: ExportFormat.webVtt),
      title: 'Meeting',
    );
    expect(vtt, startsWith('WEBVTT'));
    expect(vtt, contains('00:00:03.000 --> 00:00:04.200'));
  });

  test('translated and bilingual exports fall back safely when partial', () {
    final translated = document.copyWith(
      segments: [
        document.segments.first.copyWith(translatedText: '你好，世界。'),
        document.segments.last,
      ],
    );
    final translatedText = exporter.render(
      translated,
      const ExportOptions(
        showSpeakers: false,
        contentMode: ExportContentMode.translated,
      ),
      title: 'Meeting',
    );
    expect(translatedText, '你好，世界。\n\n你好。');

    final bilingualSrt = exporter.render(
      translated,
      const ExportOptions(
        format: ExportFormat.srt,
        showSpeakers: false,
        contentMode: ExportContentMode.bilingual,
      ),
      title: 'Meeting',
    );
    expect(bilingualSrt, contains('你好，世界。\nHello world.'));
    expect(
      RegExp('你好。').allMatches(bilingualSrt),
      hasLength(1),
      reason: 'A missing translation should emit one original fallback cue.',
    );
  });

  test('Chinese exports localize generated labels and Markdown metadata', () {
    final text = exporter.render(
      document,
      const ExportOptions(showSpeakers: true, localeCode: 'zh'),
      title: '会议',
    );
    expect(text, startsWith('说话人 1'));

    final markdown = exporter.render(
      document,
      const ExportOptions(
        format: ExportFormat.markdown,
        showSpeakers: true,
        localeCode: 'zh',
      ),
      title: '会议',
    );
    expect(markdown, contains('- 由 MeowSTT 导出'));
    expect(markdown, contains('- 时长：'));
    expect(markdown, contains('**说话人 1**'));
  });

  test(
    'Unicode names collide safely and batch ZIP contains each transcript',
    () async {
      final directory = await Directory.systemTemp.createTemp('meow-export-');
      addTearDown(() => directory.delete(recursive: true));
      final now = DateTime.utc(2026);
      TranscriptionJob job(String id) => TranscriptionJob(
        id: id,
        batchId: 'b',
        sourcePath: '${directory.path}/会议?.wav',
        createdAt: now,
        updatedAt: now,
        status: JobStatus.completed,
        document: document,
      );

      final first = await exporter.exportToDirectory(
        job('one'),
        directory.path,
        const ExportOptions(),
      );
      final second = await exporter.exportToDirectory(
        job('two'),
        directory.path,
        const ExportOptions(),
      );
      expect(first, isNot(second));
      final zipPath = '${directory.path}/batch.zip';
      await exporter.exportZip(
        [job('one'), job('two')],
        zipPath,
        const ExportOptions(format: ExportFormat.markdown),
      );
      final archive = ZipDecoder().decodeBytes(
        await File(zipPath).readAsBytes(),
      );
      expect(archive.files.where((file) => file.isFile), hasLength(2));
      expect(archive.files.map((file) => file.name).toSet(), hasLength(2));
    },
  );
}
