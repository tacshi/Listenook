import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('visible UI text is routed through localization', () {
    final violations = <String>[];
    final patterns = <RegExp>[
      RegExp(
        r'''\b(?:Text|SelectableText)\(\s*(?:const\s+)?["'][A-Za-z]''',
        multiLine: true,
      ),
      RegExp(
        r'''\b(?:tooltip|hintText|labelText|message|confirmButtonText)\s*:\s*["'][A-Za-z]''',
        multiLine: true,
      ),
      RegExp(
        r'''\b(?:title|content|subtitle)\s*:\s*(?:const\s+)?Text\(\s*["'][A-Za-z]''',
        multiLine: true,
      ),
    ];

    for (final file
        in Directory('lib/ui')
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))) {
      final source = file
          .readAsStringSync()
          .replaceAll("'Listenook'", "context.strings.t('product_name')")
          .replaceAll('"Listenook"', 'context.strings.t("product_name")');
      for (final pattern in patterns) {
        for (final match in pattern.allMatches(source)) {
          final line =
              '\n'.allMatches(source.substring(0, match.start)).length + 1;
          violations.add('${file.path}:$line: ${match.group(0)}');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'User-visible strings must use context.strings so every locale stays complete.',
    );
  });
}
