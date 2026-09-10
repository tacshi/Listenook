/// Local, literal comparison against a transcript, not a spelling judgement.
enum DictationWordKind { matching, different, missing, extra }

class DictationWord {
  const DictationWord(this.kind, {this.expected, this.actual});
  final DictationWordKind kind;
  final String? expected;
  final String? actual;
}

class DictationResult {
  const DictationResult(this.words);
  final List<DictationWord> words;
  bool get matches =>
      words.every((word) => word.kind == DictationWordKind.matching);
}

final _words = RegExp(r"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*", unicode: true);

bool supportsEnglishDictation(String text, String? language) {
  if (language != null && language.trim().isNotEmpty) {
    return language.toLowerCase().split(RegExp('[-_]')).first == 'en';
  }
  return RegExp(r'[A-Za-z]+').hasMatch(text);
}

DictationResult compareDictation(String reference, String answer) {
  final expected = _words
      .allMatches(reference)
      .map((m) => m.group(0)!)
      .toList();
  final actual = _words.allMatches(answer).map((m) => m.group(0)!).toList();
  String normalize(String word) => word.toLowerCase().replaceAll('’', "'");
  final a = expected.map(normalize).toList();
  final b = actual.map(normalize).toList();
  final costs = List.generate(
    a.length + 1,
    (_) => List.filled(b.length + 1, 0),
  );
  for (var i = 0; i <= a.length; i++) {
    costs[i][0] = i;
  }
  for (var j = 0; j <= b.length; j++) {
    costs[0][j] = j;
  }
  for (var i = 1; i <= a.length; i++) {
    for (var j = 1; j <= b.length; j++) {
      final replacement = costs[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1);
      final removal = costs[i - 1][j] + 1;
      final insertion = costs[i][j - 1] + 1;
      costs[i][j] = [
        replacement,
        removal,
        insertion,
      ].reduce((x, y) => x < y ? x : y);
    }
  }
  var i = a.length;
  var j = b.length;
  final result = <DictationWord>[];
  while (i > 0 || j > 0) {
    if (i > 0 &&
        j > 0 &&
        a[i - 1] == b[j - 1] &&
        costs[i][j] == costs[i - 1][j - 1]) {
      result.add(
        DictationWord(
          DictationWordKind.matching,
          expected: expected[--i],
          actual: actual[--j],
        ),
      );
    } else if (i > 0 && costs[i][j] == costs[i - 1][j] + 1) {
      result.add(
        DictationWord(DictationWordKind.missing, expected: expected[--i]),
      );
    } else if (j > 0 && costs[i][j] == costs[i][j - 1] + 1) {
      result.add(DictationWord(DictationWordKind.extra, actual: actual[--j]));
    } else {
      result.add(
        DictationWord(
          DictationWordKind.different,
          expected: expected[--i],
          actual: actual[--j],
        ),
      );
    }
  }
  return DictationResult(List.unmodifiable(result.reversed));
}
