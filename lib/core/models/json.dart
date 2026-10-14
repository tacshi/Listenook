/// JSON parsing helpers shared by the model files. Not exported by
/// `models.dart`.
library;

import 'job.dart';

List<T> mapJsonList<T>(
  dynamic value,
  T Function(Map<String, dynamic>) parser,
) => value is List
    ? value
          .whereType<Map>()
          .map((item) => parser(item.cast<String, dynamic>()))
          .toList()
    : <T>[];

List<String> jsonStrings(dynamic value) =>
    value is List ? value.whereType<String>().toList() : const [];

Set<T> enumSetFromJson<T extends Enum>(
  List<T> values,
  dynamic names, {
  required Set<T> fallback,
}) {
  if (names is! List) return Set<T>.of(fallback);
  final result = <T>{};
  for (final name in names) {
    final value = enumByName(values, name);
    if (value != null) result.add(value);
  }
  return result;
}

DateTime? dateFromJson(dynamic value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

T? enumByName<T extends Enum>(List<T> values, dynamic name) {
  if (name is! String) return null;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

TranscriptAcquisitionMode transcriptAcquisitionModeFromJson(dynamic name) {
  if (name == 'publisherWordTimed') {
    return TranscriptAcquisitionMode.publisherCaptions;
  }
  return enumByName(TranscriptAcquisitionMode.values, name) ??
      TranscriptAcquisitionMode.soniox;
}

TranscriptionProvider transcriptionProviderFromJson(
  dynamic provider,
  dynamic acquisitionMode,
) =>
    enumByName(TranscriptionProvider.values, provider) ??
    switch (acquisitionMode) {
      'mossPro' => TranscriptionProvider.mossPro,
      'mossLocal' => TranscriptionProvider.mossLocal,
      'qwen3Local' => TranscriptionProvider.qwen3Local,
      _ => TranscriptionProvider.soniox,
    };
