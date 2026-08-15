String stripHtml(String raw) {
  var value = raw.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  value = value.replaceAll(RegExp(r'</p>', caseSensitive: false), '\n');
  value = value.replaceAll(RegExp(r'<[^>]+>'), '');
  return decodeHtmlEntities(value)
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

/// Produces safe, structured HTML for a podcast description.
///
/// Publishers commonly put rich HTML in `content:encoded`, but older cached
/// episodes and some feeds only contain plain text. Plain text is escaped,
/// split into paragraphs, and linkified so both forms render consistently.
String podcastDescriptionHtml(String raw) {
  final value = raw
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\u2060', '')
      .replaceAll('\ufeff', '')
      .trim();
  if (value.isEmpty) return '';

  if (!_containsHtmlElement(value)) {
    return _plainTextDescriptionHtml(_decodeRepeatedEntities(value));
  }

  return value
      .replaceAll(
        RegExp(r'<p\b[^>]*>\s*-\s*</p>', caseSensitive: false),
        '<hr>',
      )
      // Whitespace between block tags is formatting in the source, not copy.
      .replaceAll(RegExp(r'>[ \t]*\n[ \t]*<'), '><')
      // Newlines inside a paragraph (notably timestamp lists) are meaningful.
      .replaceAll('\n', '<br>');
}

String _decodeRepeatedEntities(String value) {
  var decoded = value;
  for (var pass = 0; pass < 3; pass += 1) {
    final next = decodeHtmlEntities(decoded);
    if (next == decoded) break;
    decoded = next;
  }
  return decoded;
}

bool _containsHtmlElement(String value) =>
    RegExp(r'<\/?[a-zA-Z][^>]*>').hasMatch(value);

String _plainTextDescriptionHtml(String value) {
  final paragraphs = value.split(RegExp(r'\n{2,}'));
  return paragraphs.map((paragraph) {
    final trimmed = paragraph.trim();
    if (trimmed == '-') return '<hr>';
    final content = trimmed.split('\n').map(_linkifyPlainText).join('<br>');
    final isHeading =
        !trimmed.contains('\n') &&
        trimmed.length <= 80 &&
        trimmed.endsWith(':');
    return isHeading ? '<p><strong>$content</strong></p>' : '<p>$content</p>';
  }).join();
}

String _linkifyPlainText(String value) {
  final matches = RegExp(
    r'https?://[^\s<>]+|www\.[^\s<>]+|(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}/[^\s<>]+',
  ).allMatches(value);
  if (matches.isEmpty) return _escapeHtml(value);

  final result = StringBuffer();
  var cursor = 0;
  for (final match in matches) {
    result.write(_escapeHtml(value.substring(cursor, match.start)));
    var label = match.group(0)!;
    var suffix = '';
    while (label.isNotEmpty && RegExp(r'[.,;!?]$').hasMatch(label)) {
      suffix = '${label.substring(label.length - 1)}$suffix';
      label = label.substring(0, label.length - 1);
    }
    final href = label.startsWith('http') ? label : 'https://$label';
    result
      ..write('<a href="${_escapeHtml(href)}">${_escapeHtml(label)}</a>')
      ..write(_escapeHtml(suffix));
    cursor = match.end;
  }
  result.write(_escapeHtml(value.substring(cursor)));
  return result.toString();
}

String _escapeHtml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

String decodeHtmlEntities(String raw) {
  return raw.replaceAllMapped(RegExp(r'&(#x?[0-9a-fA-F]+|[a-zA-Z]+);'), (
    match,
  ) {
    final entity = match.group(1)!;
    if (entity.startsWith('#x') || entity.startsWith('#X')) {
      final code = int.tryParse(entity.substring(2), radix: 16);
      return code == null ? match.group(0)! : String.fromCharCode(code);
    }
    if (entity.startsWith('#')) {
      final code = int.tryParse(entity.substring(1));
      return code == null ? match.group(0)! : String.fromCharCode(code);
    }
    return switch (entity) {
      'amp' => '&',
      'lt' => '<',
      'gt' => '>',
      'quot' => '"',
      'apos' => "'",
      'nbsp' => ' ',
      _ => match.group(0)!,
    };
  });
}
