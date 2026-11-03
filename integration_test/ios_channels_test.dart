import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:listenook/core/app_identity.dart';
import 'package:listenook/data/local_speech_channel.dart';

import 'support/results_file.dart';

/// Every channel the iOS runner registers answers (ios/Runner/*.swift). The
/// Dart wrappers swallow missing plugins, so these call the channels raw.
void main() {
  saveResultsWhenDone(IntegrationTestWidgetsFlutterBinding.ensureInitialized());
  final skip = !Platform.isIOS;

  testWidgets('files, open-in, menu and background channels answer', (
    tester,
  ) async {
    const files = MethodChannel(AppIdentity.filesChannel);
    // Nothing to share: answers without showing the sheet.
    expect(
      await files.invokeMethod<bool>('share', {'paths': <String>[]}),
      isFalse,
    );

    const openFiles = MethodChannel(AppIdentity.openFilesChannel);
    expect(await openFiles.invokeMethod<bool>('launchedForFiles'), isFalse);
    expect(
      await openFiles.invokeListMethod<String>('takePendingOpenFiles'),
      isEmpty,
    );

    const navigation = MethodChannel(AppIdentity.navigationChannel);
    await navigation.invokeMethod<void>('setMenuTitles', {'go': 'Go'});

    const background = MethodChannel(AppIdentity.backgroundActivityChannel);
    await background.invokeMethod<void>('begin');
    await background.invokeMethod<void>('end');
  }, skip: skip);

  testWidgets('Now Playing accepts an item and clears it', (tester) async {
    const nowPlaying = MethodChannel(AppIdentity.nowPlayingChannel);
    await nowPlaying.invokeMethod<void>('update', {
      'title': 'Integration test',
      'durationMs': 60000,
      'positionMs': 1000,
      'playing': false,
      'rate': 1.0,
    });
    await nowPlaying.invokeMethod<void>('clear');
  }, skip: skip);

  testWidgets('the speech engine reports the device and its gate', (
    tester,
  ) async {
    const engine = MethodChannel(AppIdentity.speechEngineChannel);
    final capabilities = await engine.invokeMapMethod<String, Object?>(
      'capabilities',
    );
    expect(capabilities?['isSimulator'], isFalse);
    expect(capabilities?['osMajor'] as int, greaterThanOrEqualTo(18));
    final memory = capabilities?['physicalMemory'] as int;
    expect(memory, greaterThan(0));
    expect(
      await ChannelLocalSpeechWorker.isDeviceSupported(),
      memory >= 7 * 1024 * 1024 * 1024,
    );

    final folder = await Directory.systemTemp.createTemp('listenook-backup-');
    addTearDown(() => folder.delete(recursive: true));
    expect(
      await engine.invokeMethod<bool>('excludeFromBackup', {
        'path': folder.path,
      }),
      isTrue,
    );
  }, skip: skip);
}
