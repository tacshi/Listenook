import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/app_identity.dart';
import 'package:listenook/data/update_service.dart';
import 'package:listenook/l10n/strings.dart';
import 'package:flutter/widgets.dart';

void main() {
  test('localized names and owned bundle namespace are consistent', () {
    expect(const AppStrings(Locale('en')).appName, 'Listenook');
    expect(const AppStrings(Locale('zh', 'CN')).appName, '聆页');
    expect(const AppStrings(Locale('zh', 'CN')).t('tray_quit'), '退出聆页');
    expect(AppIdentity.bundleId, 'app.capyvibe.listenook');
    expect(
      UpdateService.defaultManifestUrl,
      'https://raw.githubusercontent.com/tacshi/Listenook-Release/main/listenook-latest.json',
    );
    final native = [
      'macos/Runner/AppDelegate.swift',
      'native/apple/AudioEncoder.swift',
    ].map((path) => File(path).readAsStringSync()).join('\n');
    final cursor = File(
      'macos/Runner/MainFlutterWindow.swift',
    ).readAsStringSync();
    final windows = File(
      'windows/runner/flutter_window.cpp',
    ).readAsStringSync();
    for (final channel in [
      AppIdentity.navigationChannel,
      AppIdentity.startupChannel,
      AppIdentity.encoderChannel,
    ]) {
      expect(native, contains(channel));
    }
    expect(cursor, contains(AppIdentity.cursorChannel));
    expect(windows, contains(AppIdentity.cursorChannel));
  });

  test('new environment values win and legacy variables remain fallbacks', () {
    expect(
      AppIdentity.environment(
        'LISTENOOK_SPEECH_WORKER',
        values: {
          'MEOWSTT_SPEECH_WORKER': 'old',
          'LISTENOOK_SPEECH_WORKER': 'new',
        },
      ),
      'new',
    );
    expect(
      AppIdentity.environment(
        'LISTENOOK_SPEECH_WORKER',
        values: {'MEOWSTT_SPEECH_WORKER': 'old'},
      ),
      'old',
    );
    expect(
      AppIdentity.environment(
        'LISTENOOK_SPEECH_WORKER',
        values: {'MEOWSTT_SPEECH_WORKER': 'old', 'LISTENOOK_SPEECH_WORKER': ''},
      ),
      '',
    );
  });

  test('publisher cannot overwrite the legacy update manifest', () {
    final publisher = File('scripts/publish.sh').readAsStringSync();
    expect(
      publisher,
      contains(r'git -C "$RELEASE_REPO_DIR" add listenook-latest.json'),
    );
    expect(
      publisher,
      isNot(contains(r'git -C "$RELEASE_REPO_DIR" add latest.json')),
    );
    expect(publisher, isNot(contains(r'"$RELEASE_REPO_DIR/latest.json"')));
  });
}
