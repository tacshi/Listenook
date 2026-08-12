import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'macOS Window menu binds Command-W to the standard close action',
    () async {
      final menu = await File(
        '${Directory.current.path}/macos/Runner/Base.lproj/MainMenu.xib',
      ).readAsString();

      expect(menu, contains('<menuItem title="Close" keyEquivalent="w"'));
      expect(menu, contains('<action selector="performClose:" target="-1"'));
    },
    skip: !Platform.isMacOS,
  );
}
