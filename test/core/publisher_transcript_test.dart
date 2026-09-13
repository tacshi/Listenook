import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/core/podcast_models.dart';
import 'package:listenook/data/podcast/publisher_transcript.dart';

void main() {
  const parser = PublisherTranscriptParser();

  test('classifies VTT and SRT as cue-level transcripts', () {
    final vtt = parser.parse(body: _vtt, mimeType: 'text/vtt');
    final srt = parser.parse(body: _srt, mimeType: 'application/x-subrip');

    expect(vtt.timing, PodcastTranscriptTiming.cue);
    expect(vtt.document.tokens, isEmpty);
    expect(vtt.document.segments, hasLength(2));
    expect(vtt.document.segments.first.text, 'Hello there.');
    expect(srt.timing, PodcastTranscriptTiming.cue);
    expect(srt.document.segments.single.text, 'Welcome back.');
  });

  test('accepts word-timed JSON and rejects copied or interpolated times', () {
    final word = parser.parse(body: _wordJson, mimeType: 'application/json');
    expect(word.timing, PodcastTranscriptTiming.word);
    expect(word.document.tokens, hasLength(8));

    final copied = parser.parse(
      body: _copiedWordJson,
      mimeType: 'application/json',
    );
    expect(copied.timing, PodcastTranscriptTiming.cue);

    final interpolated = parser.parse(
      body: _interpolatedJson,
      mimeType: 'application/json',
    );
    expect(interpolated.timing, PodcastTranscriptTiming.cue);
  });

  test('plain text without timestamps cannot replace Soniox', () {
    expect(
      () => parser.parse(body: 'just words', mimeType: 'text/plain'),
      throwsA(
        isA<PodcastException>().having(
          (error) => error.code,
          'code',
          'podcast_transcript_untimed',
        ),
      ),
    );
  });

  test('joins adjacent transport cues into sentence-sized captions', () {
    final parsed = parser.parse(
      body: _fragmentedSrt,
      mimeType: 'application/x-subrip',
    );

    expect(parsed.document.segments, hasLength(2));
    expect(parsed.document.segments.first.startMs, 9199);
    expect(parsed.document.segments.first.endMs, 30320);
    expect(
      parsed.document.segments.first.text,
      "Speaker 1: Before I even opened my eyes, I knew I wasn't in my bed. "
      'The pillow, the smell, the soft sound of snoring beside me, it was all '
      'very unfamiliar. I cautiously sat up and looked over at the sleeping '
      'man beside me. His blonde hair was sticking up in every direction,',
    );
    expect(parsed.document.segments.last.text, 'A new sentence starts here.');
  });
}

const _vtt = '''
WEBVTT

00:00:00.000 --> 00:00:01.500
Hello there.

00:00:01.500 --> 00:00:03.000
How are you?
''';

const _srt = '''
1
00:00:00,000 --> 00:00:02,000
Welcome back.
''';

const _fragmentedSrt = '''
1
00:00:09,199 --> 00:00:12,640
Speaker 1: Before I even opened my eyes, I knew I wasn't

2
00:00:12,679 --> 00:00:17,280
in my bed. The pillow, the smell, the soft sound

3
00:00:17,359 --> 00:00:22,160
of snoring beside me, it was all very unfamiliar. I

4
00:00:22,239 --> 00:00:25,839
cautiously sat up and looked over at the sleeping man

5
00:00:25,960 --> 00:00:30,320
beside me. His blonde hair was sticking up in every direction,

6
00:00:31,320 --> 00:00:34,000
A new sentence starts here.
''';

const _wordJson = '''
{
  "segments": [
    {
      "body": "Hello there friends today",
      "startTime": 0.0,
      "endTime": 2.4,
      "words": [
        {"body": "Hello", "startTime": 0.0, "endTime": 0.3},
        {"body": "there", "startTime": 0.35, "endTime": 0.6},
        {"body": "friends", "startTime": 0.7, "endTime": 1.1},
        {"body": "today", "startTime": 1.2, "endTime": 1.5}
      ]
    },
    {
      "body": "we talk about English",
      "startTime": 1.6,
      "endTime": 3.2,
      "words": [
        {"body": "we", "startTime": 1.6, "endTime": 1.75},
        {"body": "talk", "startTime": 1.8, "endTime": 2.1},
        {"body": "about", "startTime": 2.15, "endTime": 2.4},
        {"body": "English", "startTime": 2.5, "endTime": 3.1}
      ]
    }
  ]
}
''';

const _copiedWordJson = '''
{
  "segments": [
    {
      "body": "Hello there friends today",
      "startTime": 0.0,
      "endTime": 2.0,
      "words": [
        {"body": "Hello", "startTime": 0.0, "endTime": 2.0},
        {"body": "there", "startTime": 0.0, "endTime": 2.0},
        {"body": "friends", "startTime": 0.0, "endTime": 2.0},
        {"body": "today", "startTime": 0.0, "endTime": 2.0}
      ]
    },
    {
      "body": "we talk about English",
      "startTime": 2.0,
      "endTime": 4.0,
      "words": [
        {"body": "we", "startTime": 2.0, "endTime": 4.0},
        {"body": "talk", "startTime": 2.0, "endTime": 4.0},
        {"body": "about", "startTime": 2.0, "endTime": 4.0},
        {"body": "English", "startTime": 2.0, "endTime": 4.0}
      ]
    }
  ]
}
''';

const _interpolatedJson = '''
{
  "segments": [
    {
      "body": "Hello there friends today",
      "startTime": 0.0,
      "endTime": 2.0,
      "words": [
        {"body": "Hello", "startTime": 0.0, "endTime": 0.5},
        {"body": "there", "startTime": 0.5, "endTime": 1.0},
        {"body": "friends", "startTime": 1.0, "endTime": 1.5},
        {"body": "today", "startTime": 1.5, "endTime": 2.0}
      ]
    }
  ]
}
''';
