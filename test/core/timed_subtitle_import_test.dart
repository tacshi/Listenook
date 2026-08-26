import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/models.dart';
import 'package:meow_stt/data/local_media_source_resolver.dart';
import 'package:meow_stt/data/timed_subtitle_import.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('meow-subtitle-import-');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'SRT parsing preserves cue order, line breaks, and source windows',
    () async {
      final file = File('${directory.path}/movie.srt');
      await file.writeAsString('''
1
00:00:01,000 --> 00:00:03,000
<i>Hello</i>
world

2
00:00:01,000 --> 00:00:32,500
Second cue

broken cue
no timing
''');

      final result = await const TimedSubtitleImportService().parseFile(
        file.path,
      );

      expect(result.format, SubtitleFormat.srt);
      expect(result.document.segments, hasLength(2));
      expect(result.document.segments.first.id, 'subtitle-cue-1');
      expect(result.document.segments.first.text, 'Hello\nworld');
      expect(result.document.segments.first.startMs, 1000);
      expect(result.document.segments.first.alignmentWindowStartMs, 1000);
      expect(result.document.segments.first.alignmentWindowEndMs, 3000);
      expect(result.document.segments.last.id, 'subtitle-cue-2');
      expect(result.longCueCount, 1);
      expect(result.ignoredCueCount, 1);
    },
  );

  test('WebVTT voice labels become speaker metadata', () async {
    final file = File('${directory.path}/meeting.vtt');
    await file.writeAsString('''WEBVTT

speaker-one
00:00.100 --> 00:01.000 align:start
<v Alice><b>Hello &amp; welcome</b>

00:01.100 --> 00:02.000
<v Bob>Hi Alice
''');

    final result = await const TimedSubtitleImportService().parseFile(
      file.path,
    );

    expect(result.document.segments.map((segment) => segment.text), [
      'Hello & welcome',
      'Hi Alice',
    ]);
    expect(result.document.speakers.map((speaker) => speaker.name), [
      'Alice',
      'Bob',
    ]);
    expect(result.document.segments.first.speaker, 'subtitle-speaker-1');
  });

  test(
    'caption speaker markers and bracketed annotations are removed',
    () async {
      final file = File('${directory.path}/captions.srt');
      await file.writeAsString('''
1
00:00:00,000 --> 00:00:01,000
>> Oh,>> no.

2
00:00:01,000 --> 00:00:02,000
[Music] It is semi-public. [applause]

3
00:00:02,000 --> 00:00:03,000
[Laughter]
''');

      final result = await const TimedSubtitleImportService().parseFile(
        file.path,
      );

      expect(result.document.segments.map((segment) => segment.text), [
        'Oh, no.',
        'It is semi-public.',
      ]);
      expect(result.ignoredCueCount, 1);
    },
  );

  test('decodes UTF-16 and Windows-1252 subtitle files', () async {
    final utf16 = File('${directory.path}/utf16.srt');
    const utf16Text = '1\n00:00:00,000 --> 00:00:01,000\n你好\n';
    final utf16Units = utf16Text.codeUnits;
    await utf16.writeAsBytes([
      0xff,
      0xfe,
      for (final unit in utf16Units) ...[unit & 0xff, unit >> 8],
    ]);
    final windows = File('${directory.path}/windows.srt');
    await windows.writeAsBytes([
      ...'1\n00:00:00,000 --> 00:00:01,000\n'.codeUnits,
      0x93,
      ...'Hello'.codeUnits,
      0x94,
    ]);

    final service = const TimedSubtitleImportService();
    expect(
      (await service.parseFile(utf16.path)).document.segments.single.text,
      '你好',
    );
    expect(
      (await service.parseFile(windows.path)).document.segments.single.text,
      '“Hello”',
    );
  });

  test(
    'duration validation drops late cues and clamps the final cue',
    () async {
      final file = File('${directory.path}/movie.srt');
      await file.writeAsString('''
1
00:00:00,000 --> 00:00:03,000
First

2
00:00:04,000 --> 00:00:06,000
Late
''');
      final service = const TimedSubtitleImportService();
      final parsed = await service.parseFile(file.path);
      final constrained = service.constrainToDuration(parsed, 2000);

      expect(constrained.document.segments, hasLength(1));
      expect(constrained.document.segments.single.endMs, 2000);
      expect(constrained.document.segments.single.alignmentWindowEndMs, 2000);
      expect(constrained.ignoredCueCount, 1);
    },
  );

  test(
    'a subtitle with no valid cues remains reviewable but blocked',
    () async {
      final file = File('${directory.path}/invalid.srt');
      await file.writeAsString('''
1
not a timestamp
No timing

2
00:00:02,000 --> 00:00:01,000
Backwards
''');

      final candidate = await const TimedSubtitleImportService().parseCandidate(
        file.path,
      );

      expect(candidate.isValid, isFalse);
      expect(candidate.errorCode, 'subtitle_no_valid_cues');
      expect(candidate.parseResult, isNotNull);
      expect(candidate.parseResult!.document.segments, isEmpty);
      expect(candidate.parseResult!.ignoredCueCount, 2);
    },
  );

  test('pairing auto-matches exact and language-suffixed siblings', () async {
    final firstMedia = File('${directory.path}/movie.mp4')
      ..writeAsBytesSync([0]);
    final exact = File('${directory.path}/movie.srt')
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nExact');
    final localized = File('${directory.path}/movie.en.vtt')
      ..writeAsStringSync('WEBVTT\n\n00:00.000 --> 00:01.000\nEnglish');
    final unrelated = File('${directory.path}/other.srt')
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nOther');

    final review = await const TimedSubtitleImportService().preview([
      firstMedia.path,
      unrelated.path,
    ], resolver: const LocalMediaSourceResolver());

    expect(review, isNotNull);
    expect(
      review!.media.single.candidates.map((candidate) => candidate.path),
      containsAll([exact.path, localized.path]),
    );
    expect(review.media.single.automaticCandidate, isNull);
    expect(review.unmatchedSubtitles.single.path, unrelated.path);
    expect(
      review.media.single.candidates
          .singleWhere((candidate) => candidate.path == localized.path)
          .languageCode,
      'en',
    );
  });

  test('pairing never crosses directories', () async {
    final mediaDirectory = Directory('${directory.path}/media')
      ..createSync(recursive: true);
    final subtitleDirectory = Directory('${directory.path}/subs')
      ..createSync(recursive: true);
    final media = File('${mediaDirectory.path}/movie.mp4')
      ..writeAsBytesSync([0]);
    final subtitle = File('${subtitleDirectory.path}/movie.srt')
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nText');

    final review = await const TimedSubtitleImportService().preview([
      media.path,
      subtitle.path,
    ], resolver: const LocalMediaSourceResolver());

    expect(review!.media.single.candidates, isEmpty);
    expect(review.unmatchedSubtitles.single.path, subtitle.path);
  });
}
