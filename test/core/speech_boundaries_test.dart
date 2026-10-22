import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/core/speech_boundaries.dart';
import 'package:listenook/ui/review/seek_helpers.dart';

const _speech = 140;
const _silence = 40;

/// Builds 10ms half-decibel frames from (duration, level) spans.
SpeechEnergy _energy(List<(int, int)> spans) => SpeechEnergy(
  Uint8List.fromList([
    for (final (durationMs, level) in spans)
      ...List<int>.filled(durationMs ~/ SpeechEnergy.frameMs, level),
  ]),
);

TranscriptSegment _segment(String id, int startMs, int endMs) =>
    TranscriptSegment(id: id, startMs: startMs, endMs: endMs, text: id);

void main() {
  test('a short pause splits sentences whose timestamps overlap a word', () {
    final speech = _energy([(1000, _speech), (80, _silence), (920, _speech)]);
    final previous = _segment('previous', 0, 1120);
    final current = _segment('current', 1100, 2000);

    final startMs = speech.sentenceStartMs(current, previous: previous);
    final endMs = speech.sentenceEndMs(previous, next: current);

    expect(startMs, 1040);
    expect(endMs, 1040);
    expect(
      sentenceRepeatStartMs(current, previousSegment: previous),
      1100,
      reason: 'Timestamps alone start after the onset of the first word.',
    );
  });

  test('a long silence keeps a short lead-in and tail', () {
    final speech = _energy([
      (1000, _speech),
      (1000, _silence),
      (1000, _speech),
    ]);
    final previous = _segment('previous', 0, 1100);
    final current = _segment('current', 1900, 3000);

    expect(speech.sentenceStartMs(current, previous: previous), 1870);
    expect(speech.sentenceEndMs(previous, next: current), 1210);
  });

  test('music between sentences stays out of both repeats', () {
    final speech = _energy([
      (1000, _speech),
      (500, _silence),
      (1500, 130),
      (400, _silence),
      (1000, _speech),
    ]);
    final previous = _segment('previous', 0, 1100);
    final current = _segment('current', 3300, 4400);

    expect(
      speech.sentenceStartMs(current, previous: previous),
      inInclusiveRange(3200, 3400),
    );
    expect(
      speech.sentenceEndMs(previous, next: current),
      inInclusiveRange(1000, 1500),
    );
  });

  test('rolling captions hand over where the next cue starts', () {
    final speech = _energy([(1000, _speech), (150, _silence), (1350, _speech)]);
    final previous = _segment('previous', 0, 2300);
    final current = _segment('current', 1100, 2500);

    expect(
      speech.sentenceStartMs(current, previous: previous),
      inInclusiveRange(1000, 1150),
    );
    expect(
      speech.sentenceEndMs(previous, next: current),
      inInclusiveRange(1000, 1150),
    );
  });

  test('the first sentence starts in the silence before it', () {
    final speech = _energy([(500, _silence), (1000, _speech)]);
    final first = _segment('first', 400, 1500);

    expect(speech.sentenceStartMs(first), 370);
    expect(sentenceRepeatStartMs(first, speech: speech), 370);
  });

  test('a consonant closure is not mistaken for the pause', () {
    final speech = _energy([
      (900, _speech),
      (40, _silence),
      (260, _speech),
      (150, _silence),
      (650, _speech),
    ]);
    final previous = _segment('previous', 0, 1000);
    final current = _segment('current', 1000, 2000);

    final startMs = speech.sentenceStartMs(current, previous: previous)!;

    expect(startMs, inInclusiveRange(1200, 1350));
  });

  test('speech over a music bed keeps the timestamp boundaries', () {
    final speech = _energy([(1000, _speech), (100, 125), (900, _speech)]);
    final previous = _segment('previous', 0, 1000);
    final current = _segment('current', 1100, 2000);

    expect(speech.sentenceStartMs(current, previous: previous), isNull);
    expect(speech.sentenceEndMs(previous, next: current), isNull);
    expect(
      sentenceRepeatStartMs(current, previousSegment: previous, speech: speech),
      sentenceRepeatStartMs(current, previousSegment: previous),
    );
    expect(
      sentenceRepeatEndMs(previous, nextSegment: current, speech: speech),
      sentenceRepeatEndMs(previous, nextSegment: current),
    );
  });

  test('repeat loops wrap at the pause instead of the timestamp', () {
    final speech = _energy([
      (1000, _speech),
      (1000, _silence),
      (1000, _speech),
    ]);
    final previous = _segment('previous', 0, 1100);
    final current = _segment('current', 1900, 3000);

    expect(
      sentenceRepeatRestartMs(previous, nextSegment: current, speech: speech),
      1210,
    );
    expect(
      isRepeatLoopEndCrossing(
        previous,
        previousMs: 1200,
        currentMs: 1215,
        nextSegment: current,
        speech: speech,
      ),
      isTrue,
    );
    expect(
      isRepeatLoopEndCrossing(
        previous,
        previousMs: 1200,
        currentMs: 1215,
        nextSegment: current,
      ),
      isFalse,
    );
    expect(
      shouldRestartRepeatedSentence(
        current,
        1880,
        previousSegment: previous,
        speech: speech,
      ),
      isFalse,
    );
  });
}
