import 'dart:convert';
import 'dart:math';

import '../core/contracts.dart';
import '../core/models.dart';

class LlmTranslationService implements TranslationService {
  const LlmTranslationService(this._llm);

  static const _maxSegmentsPerBatch = 20;
  static const _maxCharactersPerBatch = 8000;
  static const _systemPrompt =
      'You are a professional subtitle translator. Translate faithfully and '
      'naturally. Preserve meaning, tone, names, and speaker intent. Return '
      'only the requested numbered lines without explanations.';

  final LlmClient _llm;

  @override
  Future<List<String>> listModels(
    TranslationSettings settings, {
    String? candidateApiKey,
  }) async {
    final validation = settings.validationError(requireModel: false);
    if (validation != null) throw TranslationException(validation);
    return _translatingErrors(
      () => _llm.listModels(
        settings.providerSettings,
        candidateApiKey: candidateApiKey,
      ),
    );
  }

  @override
  Future<void> translate({
    required TranslationSettings settings,
    required String targetLanguage,
    required List<TranscriptSegment> segments,
    required Future<void> Function(
      Map<String, String> translatedBySegmentId,
      int completedSegments,
      int totalSegments,
    )
    onBatch,
    CancelCheck? shouldCancel,
  }) async {
    final validation = settings.validationError();
    if (validation != null) throw TranslationException(validation);
    if (!supportedTranslationLanguageCodes.contains(targetLanguage)) {
      throw const TranslationException('translation_invalid_language');
    }
    final batches = _batches(segments);
    final cache = <String, String>{};
    var processed = 0;

    for (final batch in batches) {
      _checkCancelled(shouldCancel);
      final updates = <String, String>{};
      if (batch.length == 1 &&
          batch.single.text.length > _maxCharactersPerBatch) {
        final segment = batch.single;
        final translated = await _translateLongSegment(
          segment,
          settings: settings,
          targetLanguage: targetLanguage,
          shouldCancel: shouldCancel,
        );
        if (translated != null) updates[segment.id] = translated;
        processed++;
        await onBatch(updates, processed, segments.length);
        continue;
      }
      final representatives = <TranscriptSegment>[];
      final pendingByText = <String, List<TranscriptSegment>>{};

      for (final segment in batch) {
        final normalized = segment.text.trim();
        if (_isPunctuationOnly(normalized)) {
          updates[segment.id] = segment.text;
        } else if (cache[normalized] case final cached?) {
          updates[segment.id] = cached;
        } else {
          final duplicates = pendingByText.putIfAbsent(normalized, () {
            representatives.add(segment);
            return <TranscriptSegment>[];
          });
          duplicates.add(segment);
        }
      }

      if (representatives.isNotEmpty) {
        final response = await _complete(
          settings: settings,
          prompt: _translationPrompt(representatives, targetLanguage),
          shouldCancel: shouldCancel,
        );
        final translations = _parseLines(response, representatives.length);
        for (var index = 0; index < representatives.length; index++) {
          final source = representatives[index].text.trim();
          final translated = translations[index]?.trim();
          if (translated == null ||
              translated.isEmpty ||
              _isRefusal(translated)) {
            continue;
          }
          cache[source] = translated;
          for (final segment in pendingByText[source]!) {
            updates[segment.id] = translated;
          }
        }
      }

      processed += batch.length;
      await onBatch(updates, processed, segments.length);
    }
  }

  Future<String?> _translateLongSegment(
    TranscriptSegment segment, {
    required TranslationSettings settings,
    required String targetLanguage,
    CancelCheck? shouldCancel,
  }) async {
    final translations = <String>[];
    for (var start = 0; start < segment.text.length;) {
      var end = min(start + _maxCharactersPerBatch, segment.text.length);
      if (end < segment.text.length &&
          _isHighSurrogate(segment.text.codeUnitAt(end - 1))) {
        end--;
      }
      final part = segment.text.substring(start, end);
      final response = await _complete(
        settings: settings,
        prompt: _translationPrompt([
          TranscriptSegment(
            id: segment.id,
            startMs: segment.startMs,
            endMs: segment.endMs,
            text: part,
          ),
        ], targetLanguage),
        shouldCancel: shouldCancel,
      );
      final translated = _parseLines(response, 1).single?.trim();
      if (translated == null || translated.isEmpty || _isRefusal(translated)) {
        return null;
      }
      translations.add(translated);
      start = end;
    }
    return translations.join(' ');
  }

  bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

  Future<String> _complete({
    required TranslationSettings settings,
    required String prompt,
    CancelCheck? shouldCancel,
  }) => _translatingErrors(
    () => _llm.complete(
      settings: settings.providerSettings,
      systemPrompt: _systemPrompt,
      userPrompt: prompt,
      shouldCancel: shouldCancel,
    ),
  );

  /// Reports client failures under the translation error codes the UI shows.
  Future<T> _translatingErrors<T>(Future<T> Function() request) async {
    try {
      return await request();
    } on LlmException catch (error) {
      final code = error.code.startsWith('llm_')
          ? 'translation_${error.code.substring('llm_'.length)}'
          : error.code;
      throw TranslationException(
        code,
        message: error.message,
        retryable: error.retryable,
      );
    }
  }

  List<List<TranscriptSegment>> _batches(List<TranscriptSegment> segments) {
    final result = <List<TranscriptSegment>>[];
    var current = <TranscriptSegment>[];
    var characters = 0;
    for (final segment in segments) {
      final nextCharacters = characters + segment.text.length;
      if (current.isNotEmpty &&
          (current.length >= _maxSegmentsPerBatch ||
              nextCharacters > _maxCharactersPerBatch)) {
        result.add(current);
        current = <TranscriptSegment>[];
        characters = 0;
      }
      current.add(segment);
      characters += segment.text.length;
    }
    if (current.isNotEmpty) result.add(current);
    return result;
  }

  String _translationPrompt(
    List<TranscriptSegment> segments,
    String targetLanguage,
  ) {
    final lines = <String>[
      for (var index = 0; index < segments.length; index++)
        '${index + 1}. ${segments[index].text}',
    ];
    return '''
Translate each subtitle line into ${_languageName(targetLanguage)}.
Keep every line concise and natural. Do not merge, split, omit, censor, or explain lines.
If a line is already in the target language or is non-linguistic, keep it unchanged.

Input:
${lines.join('\n')}

Output exactly ${segments.length} numbered lines in the form "N. translation".
''';
  }

  List<String?> _parseLines(String response, int count) {
    final lines = const LineSplitter()
        .convert(response)
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    final result = List<String?>.filled(count, null);
    final numbered = RegExp(r'^(\d+)[.)]\s*(.*)$');
    for (final line in lines) {
      final match = numbered.firstMatch(line);
      if (match == null) continue;
      final number = int.tryParse(match.group(1)!);
      if (number == null || number < 1 || number > count) continue;
      result[number - 1] = match.group(2)?.trim();
    }
    return result;
  }

  bool _isPunctuationOnly(String text) =>
      text.isEmpty ||
      !RegExp(
        r'[A-Za-z0-9\u00C0-\u02AF\u0370-\u1FFF\u3040-\u30FF'
        r'\u3400-\u9FFF\uAC00-\uD7AF]',
      ).hasMatch(text);

  bool _isRefusal(String text) {
    final value = text.toLowerCase();
    return value.contains("i can't translate") ||
        value.contains('i cannot translate') ||
        value.contains('unable to translate') ||
        value.contains('抱歉，我无法') ||
        value.contains('对不起，我不能');
  }

  String _languageName(String code) => const {
    'en': 'English',
    'zh-Hans': 'Simplified Chinese',
    'zh-Hant': 'Traditional Chinese',
    'ja': 'Japanese',
    'ko': 'Korean',
    'es': 'Spanish',
    'fr': 'French',
    'de': 'German',
    'it': 'Italian',
    'pt': 'Portuguese',
    'ru': 'Russian',
    'ar': 'Arabic',
    'hi': 'Hindi',
    'vi': 'Vietnamese',
    'th': 'Thai',
    'yue': 'Cantonese',
    'nl': 'Dutch',
    'pl': 'Polish',
    'tr': 'Turkish',
    'uk': 'Ukrainian',
    'cs': 'Czech',
    'sv': 'Swedish',
    'da': 'Danish',
    'fi': 'Finnish',
    'el': 'Greek',
    'he': 'Hebrew',
    'id': 'Indonesian',
    'ms': 'Malay',
  }[code]!;

  void _checkCancelled(CancelCheck? shouldCancel) {
    if (shouldCancel?.call() ?? false) {
      throw const OperationCancelledException();
    }
  }
}

class TranslationException implements Exception {
  const TranslationException(this.code, {this.message, this.retryable = false});

  final String code;
  final String? message;
  final bool retryable;

  @override
  String toString() => 'TranslationException($code)';
}
