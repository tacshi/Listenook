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

  test('macOS Quit is routed through Flutter and embeds the login helper', () {
    final menu = File(
      '${Directory.current.path}/macos/Runner/Base.lproj/MainMenu.xib',
    ).readAsStringSync();
    final project = File(
      '${Directory.current.path}/macos/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    final delegate = File(
      '${Directory.current.path}/macos/Runner/AppDelegate.swift',
    ).readAsStringSync();

    expect(menu, contains('selector="requestQuit:"'));
    expect(delegate, contains('SMAppService.mainApp'));
    expect(delegate, contains('SMLoginItemSetEnabled'));
    expect(delegate, contains('applicationShouldHandleReopen'));
    expect(delegate, contains('invokeNavigation("showInbox"'));
    expect(project, contains('Embed Login Items'));
    expect(project, contains('app.meowstt.desktop.Launcher'));
  }, skip: !Platform.isMacOS);
}
