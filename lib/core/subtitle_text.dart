String cleanSubtitleCaptionArtifacts(
  String value, {
  bool preserveLineBreaks = true,
}) {
  final withoutArtifacts = value
      .replaceAll(RegExp(r'\[[^\]\r\n]*\]'), '')
      .replaceAll(RegExp(r'>{2,}'), '');
  final lines = withoutArtifacts
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  return lines.join(preserveLineBreaks ? '\n' : ' ');
}
