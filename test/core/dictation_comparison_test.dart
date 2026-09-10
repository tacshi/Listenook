import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/dictation_comparison.dart';

void main() {
  test('ignores case, whitespace, punctuation and apostrophe style', () {
    expect(compareDictation("Don't stop!", '  DON’T\nstop. ').matches, isTrue);
  });
  test('aligns an omission without shifting later words', () {
    final result = compareDictation('one two three four', 'one three four');
    expect(result.words.map((w) => w.kind), [
      DictationWordKind.matching,
      DictationWordKind.missing,
      DictationWordKind.matching,
      DictationWordKind.matching,
    ]);
    expect(result.words[1].expected, 'two');
  });
  test('reports extra and different words', () {
    expect(
      compareDictation('a cat', 'a small cat').words[1].kind,
      DictationWordKind.extra,
    );
    final change = compareDictation('a cat', 'a dog').words.last;
    expect(change.kind, DictationWordKind.different);
    expect(change.expected, 'cat');
    expect(change.actual, 'dog');
  });
  test('preserves contractions, word forms and numeric spelling', () {
    for (final pair in [
      ["don't", 'do not'],
      ['cats', 'cat'],
      ['2', 'two'],
    ]) {
      expect(compareDictation(pair[0], pair[1]).matches, isFalse);
    }
  });
  test(
    'repeated words align deterministically and empty input is supported',
    () {
      expect(
        compareDictation('go go home', 'go home').words.map((w) => w.kind),
        [
          DictationWordKind.missing,
          DictationWordKind.matching,
          DictationWordKind.matching,
        ],
      );
      expect(
        compareDictation(
          'one two',
          '',
        ).words.every((w) => w.kind == DictationWordKind.missing),
        isTrue,
      );
      expect(
        compareDictation('', 'one').words.single.kind,
        DictationWordKind.extra,
      );
      expect(compareDictation('', '').matches, isTrue);
    },
  );
  test('language eligibility respects explicit tags and missing metadata', () {
    expect(supportsEnglishDictation('Hello', 'en-US'), isTrue);
    expect(supportsEnglishDictation('Hello', null), isTrue);
    expect(supportsEnglishDictation('Hello', 'fr'), isFalse);
    expect(supportsEnglishDictation('你好', null), isFalse);
  });
}
