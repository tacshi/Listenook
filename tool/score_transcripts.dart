import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Scores transcripts against human-reviewed references.
///
/// Prints word, character and mixed error rates. The mixed rate counts each
/// Han or kana character and each run of other letters or digits as one
/// token, so Chinese–English code-switching is scored fairly. Text is
/// compared after lowercasing, folding full-width ASCII and dropping
/// punctuation. Speaker turns and timing are not scored.
///
/// Files may be plain text, SRT, WebVTT, or the speech worker's JSON output.
/// Plain-text exports should leave out timestamps and speaker names.
Future<void> main(List<String> arguments) async {
  String? value(String name) {
    final index = arguments.indexOf(name);
    return index < 0 || index + 1 >= arguments.length
        ? null
        : arguments[index + 1];
  }

  final reference = value('--reference');
  final hypothesis = value('--hypothesis');
  final referenceDirectory = value('--reference-dir');
  final hypothesisDirectory = value('--hypothesis-dir');
  final List<(String, File, File)> pairs;
  if (reference != null && hypothesis != null) {
    pairs = [(p.basename(hypothesis), File(reference), File(hypothesis))];
  } else if (referenceDirectory != null && hypothesisDirectory != null) {
    pairs = _pairsInDirectories(
      Directory(referenceDirectory),
      Directory(hypothesisDirectory),
    );
  } else {
    stderr.writeln(
      'Usage: dart run tool/score_transcripts.dart '
      '--reference FILE --hypothesis FILE\n'
      '       dart run tool/score_transcripts.dart '
      '--reference-dir DIR --hypothesis-dir DIR',
    );
    exitCode = 64;
    return;
  }

  var total = TranscriptAccuracy.zero;
  var missing = 0;
  for (final (name, referenceFile, hypothesisFile) in pairs) {
    if (!hypothesisFile.existsSync()) {
      stderr.writeln('$name: no hypothesis at ${hypothesisFile.path}');
      missing++;
      continue;
    }
    final accuracy = scoreTranscript(
      transcriptTextFromFile(
        referenceFile.path,
        await referenceFile.readAsString(),
      ),
      transcriptTextFromFile(
        hypothesisFile.path,
        await hypothesisFile.readAsString(),
      ),
    );
    total += accuracy;
    stdout.writeln('file=$name ${accuracy.summary}');
  }
  if (pairs.length > 1) stdout.writeln('file=TOTAL ${total.summary}');
  if (missing > 0) exitCode = 1;
}

List<(String, File, File)> _pairsInDirectories(
  Directory references,
  Directory hypotheses,
) {
  final hypothesesByName = <String, File>{
    for (final file in hypotheses.listSync().whereType<File>())
      if (!p.basename(file.path).startsWith('.'))
        p.basenameWithoutExtension(file.path): file,
  };
  final files =
      references
          .listSync()
          .whereType<File>()
          .where((file) => !p.basename(file.path).startsWith('.'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final file in files)
      (
        p.basenameWithoutExtension(file.path),
        file,
        hypothesesByName[p.basenameWithoutExtension(file.path)] ??
            File(p.join(hypotheses.path, p.basename(file.path))),
      ),
  ];
}

/// Edit counts against a reference token sequence.
class EditScore {
  const EditScore({
    required this.referenceTokens,
    required this.substitutions,
    required this.deletions,
    required this.insertions,
  });

  static const zero = EditScore(
    referenceTokens: 0,
    substitutions: 0,
    deletions: 0,
    insertions: 0,
  );

  final int referenceTokens;
  final int substitutions;
  final int deletions;
  final int insertions;

  int get errors => substitutions + deletions + insertions;

  /// Errors per reference token; an empty reference scores 0 only when the
  /// hypothesis is empty too.
  double get rate =>
      referenceTokens == 0 ? (errors == 0 ? 0 : 1) : errors / referenceTokens;

  EditScore operator +(EditScore other) => EditScore(
    referenceTokens: referenceTokens + other.referenceTokens,
    substitutions: substitutions + other.substitutions,
    deletions: deletions + other.deletions,
    insertions: insertions + other.insertions,
  );
}

class TranscriptAccuracy {
  const TranscriptAccuracy({
    required this.words,
    required this.characters,
    required this.mixed,
  });

  static const zero = TranscriptAccuracy(
    words: EditScore.zero,
    characters: EditScore.zero,
    mixed: EditScore.zero,
  );

  final EditScore words;
  final EditScore characters;
  final EditScore mixed;

  String get summary =>
      'mer=${_fixed(mixed.rate)} wer=${_fixed(words.rate)} '
      'cer=${_fixed(characters.rate)} mixed_tokens=${mixed.referenceTokens} '
      'words=${words.referenceTokens} chars=${characters.referenceTokens}';

  TranscriptAccuracy operator +(TranscriptAccuracy other) => TranscriptAccuracy(
    words: words + other.words,
    characters: characters + other.characters,
    mixed: mixed + other.mixed,
  );
}

TranscriptAccuracy scoreTranscript(String reference, String hypothesis) {
  final normalizedReference = normalizeTranscriptText(reference);
  final normalizedHypothesis = normalizeTranscriptText(hypothesis);
  return TranscriptAccuracy(
    words: alignTokens(
      _words(normalizedReference),
      _words(normalizedHypothesis),
    ),
    characters: alignTokens(
      _characters(normalizedReference),
      _characters(normalizedHypothesis),
    ),
    mixed: alignTokens(
      mixedTokens(normalizedReference),
      mixedTokens(normalizedHypothesis),
    ),
  );
}

/// Reads the transcript text from plain text, SRT, WebVTT or worker JSON.
String transcriptTextFromFile(String path, String contents) =>
    switch (p.extension(path).toLowerCase()) {
      '.json' => _workerText(contents),
      '.srt' || '.vtt' => _cueText(contents),
      _ => contents,
    };

String _workerText(String contents) {
  final envelope = jsonDecode(contents);
  final result = envelope is Map ? envelope['result'] : null;
  final segments = result is Map ? result['segments'] : null;
  if (segments is! List) {
    throw const FormatException('Expected worker output with segments.');
  }
  return [
    for (final segment in segments)
      if (segment is Map && segment['text'] is String) segment['text'],
  ].join('\n');
}

final _cueTiming = RegExp(r'^\s*(\d+:)?\d+:\d+[.,]\d+\s*-->');
final _cueIndex = RegExp(r'^\s*\d+\s*$');
final _markup = RegExp(r'<[^>]*>|\{\\[^}]*\}');

String _cueText(String contents) {
  final lines = <String>[];
  var inNote = false;
  for (final line in const LineSplitter().convert(contents)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      inNote = false;
      continue;
    }
    if (inNote) continue;
    if (trimmed.startsWith('NOTE') || trimmed.startsWith('STYLE')) {
      inNote = true;
      continue;
    }
    if (trimmed.startsWith('WEBVTT') ||
        _cueIndex.hasMatch(trimmed) ||
        _cueTiming.hasMatch(trimmed)) {
      continue;
    }
    lines.add(trimmed.replaceAll(_markup, ' '));
  }
  return lines.join('\n');
}

final _nonText = RegExp(r'[^\p{L}\p{M}\p{N}\s]', unicode: true);
final _whitespace = RegExp(r'\s+');

/// Lowercases, folds full-width ASCII and replaces punctuation with spaces.
String normalizeTranscriptText(String text) {
  final folded = String.fromCharCodes(
    text.runes.map(
      (rune) => switch (rune) {
        >= 0xFF01 && <= 0xFF5E => rune - 0xFEE0,
        0x3000 => 0x20,
        _ => rune,
      },
    ),
  );
  return folded
      .toLowerCase()
      .replaceAll(_nonText, ' ')
      .replaceAll(_whitespace, ' ')
      .trim();
}

List<String> _words(String normalized) =>
    normalized.isEmpty ? const [] : normalized.split(' ');

List<String> _characters(String normalized) => [
  for (final rune in normalized.runes)
    if (rune != 0x20) String.fromCharCode(rune),
];

final _ideograph = RegExp(
  r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]',
  unicode: true,
);

/// Each Han or kana character is one token; other letters and digits group
/// into space-separated words.
List<String> mixedTokens(String normalized) {
  final tokens = <String>[];
  final word = StringBuffer();
  void flush() {
    if (word.isEmpty) return;
    tokens.add(word.toString());
    word.clear();
  }

  for (final rune in normalized.runes) {
    final character = String.fromCharCode(rune);
    if (rune == 0x20) {
      flush();
    } else if (_ideograph.hasMatch(character)) {
      flush();
      tokens.add(character);
    } else {
      word.write(character);
    }
  }
  flush();
  return tokens;
}

/// Levenshtein alignment that keeps one row of edit counts in memory.
EditScore alignTokens(List<String> reference, List<String> hypothesis) {
  final ids = <String, int>{};
  int id(String token) => ids.putIfAbsent(token, () => ids.length);
  final referenceIds = Int32List.fromList([for (final t in reference) id(t)]);
  final hypothesisIds = Int32List.fromList([for (final t in hypothesis) id(t)]);
  final width = hypothesisIds.length + 1;
  var cost = Int32List(width);
  var substitutions = Int32List(width);
  var deletions = Int32List(width);
  var insertions = Int32List(width);
  var nextCost = Int32List(width);
  var nextSubstitutions = Int32List(width);
  var nextDeletions = Int32List(width);
  var nextInsertions = Int32List(width);
  for (var column = 0; column < width; column++) {
    cost[column] = column;
    insertions[column] = column;
  }
  for (var row = 1; row <= referenceIds.length; row++) {
    nextCost[0] = row;
    nextSubstitutions[0] = 0;
    nextDeletions[0] = row;
    nextInsertions[0] = 0;
    final token = referenceIds[row - 1];
    for (var column = 1; column < width; column++) {
      final mismatch = token == hypothesisIds[column - 1] ? 0 : 1;
      var best = cost[column - 1] + mismatch;
      var s = substitutions[column - 1] + mismatch;
      var d = deletions[column - 1];
      var i = insertions[column - 1];
      if (cost[column] + 1 < best) {
        best = cost[column] + 1;
        s = substitutions[column];
        d = deletions[column] + 1;
        i = insertions[column];
      }
      if (nextCost[column - 1] + 1 < best) {
        best = nextCost[column - 1] + 1;
        s = nextSubstitutions[column - 1];
        d = nextDeletions[column - 1];
        i = nextInsertions[column - 1] + 1;
      }
      nextCost[column] = best;
      nextSubstitutions[column] = s;
      nextDeletions[column] = d;
      nextInsertions[column] = i;
    }
    (cost, nextCost) = (nextCost, cost);
    (substitutions, nextSubstitutions) = (nextSubstitutions, substitutions);
    (deletions, nextDeletions) = (nextDeletions, deletions);
    (insertions, nextInsertions) = (nextInsertions, insertions);
  }
  return EditScore(
    referenceTokens: referenceIds.length,
    substitutions: substitutions[width - 1],
    deletions: deletions[width - 1],
    insertions: insertions[width - 1],
  );
}

String _fixed(double value) => value.toStringAsFixed(4);
