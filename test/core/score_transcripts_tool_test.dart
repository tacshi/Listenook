import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/score_transcripts.dart';

void main() {
  test('normalization ignores case, punctuation and full-width forms', () {
    expect(normalizeTranscriptText('Ｈｅｌｌｏ，　World!  “Yes.”'), 'hello world yes');
    expect(normalizeTranscriptText('我们，开始吧。'), '我们 开始吧');
  });

  test('word alignment counts substitutions, deletions and insertions', () {
    final score = scoreTranscript(
      'the cat sat on the mat',
      'cat sit on the mat today',
    ).words;

    expect(score.referenceTokens, 6);
    expect(score.substitutions, 1);
    expect(score.deletions, 1);
    expect(score.insertions, 1);
    expect(score.rate, 0.5);
  });

  test('mixed tokens score Han characters and Latin words separately', () {
    expect(mixedTokens(normalizeTranscriptText('我们用 Flutter 开发 v2')), [
      '我',
      '们',
      '用',
      'flutter',
      '开',
      '发',
      'v2',
    ]);

    final accuracy = scoreTranscript('我们用Flutter开发', '我们用 flutter 开发了');
    expect(accuracy.mixed.referenceTokens, 6);
    expect(accuracy.mixed.insertions, 1);
    expect(accuracy.mixed.rate, closeTo(1 / 6, 1e-9));
    expect(accuracy.characters.referenceTokens, 12);
  });

  test('empty transcripts score zero only when both are empty', () {
    expect(scoreTranscript('', '').mixed.rate, 0);
    expect(scoreTranscript('', 'extra').mixed.rate, 1);
    expect(scoreTranscript('missing', '').mixed.rate, 1);
  });

  test('subtitle files contribute only their cue text', () {
    const srt =
        '1\n00:00:00,000 --> 00:00:01,500\nHello, <i>world</i>!\n\n'
        '2\n00:00:01,500 --> 00:00:03,000\n{\\an8}Second line\n';
    const vtt =
        'WEBVTT\n\nNOTE reviewed by hand\nsecond note line\n\n'
        '00:00.000 --> 00:01.500\n<v Speaker 1>Hello, world!\n\n'
        '00:01.500 --> 00:03.000\nSecond line\n';

    for (final (path, contents) in [('ref.srt', srt), ('ref.vtt', vtt)]) {
      final text = transcriptTextFromFile(path, contents);
      expect(
        scoreTranscript(text, 'hello world second line').mixed.errors,
        0,
        reason: path,
      );
    }
  });

  test('worker output contributes its segment text', () {
    final output = jsonEncode({
      'ok': true,
      'result': {
        'segments': [
          {'start_ms': 0, 'end_ms': 900, 'text': '你好'},
          {'start_ms': 900, 'end_ms': 2000, 'text': 'Listenook'},
        ],
      },
    });

    expect(
      scoreTranscript(
        '你好 Listenook',
        transcriptTextFromFile('run.json', output),
      ).mixed.errors,
      0,
    );
  });
}
