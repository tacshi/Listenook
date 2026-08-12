import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/make_update_manifest.dart';

void main() {
  test('builds checksummed entries for all supported targets', () async {
    final directory = await Directory.systemTemp.createTemp('manifest-test-');
    addTearDown(() => directory.delete(recursive: true));
    final files = <String, List<int>>{
      'MeowSTT-2.0.0-macos-arm64-release.zip': [1],
      'MeowSTT-2.0.0-macos-x64-release.zip': [2, 3],
      'MeowSTT-2.0.0-windows-x64-release-setup.exe': [4, 5, 6],
    };
    for (final entry in files.entries) {
      await File('${directory.path}/${entry.key}').writeAsBytes(entry.value);
    }

    final manifest = await buildUpdateManifest(
      version: '2.0.0',
      build: 42,
      artifactDirectory: directory,
      releasedAt: DateTime.utc(2026, 8, 12),
    );
    final platforms = manifest['platforms'] as Map<String, Object?>;

    expect(
      platforms.keys,
      containsAll(['macos-arm64', 'macos-x64', 'windows-x64']),
    );
    for (final entry in platforms.entries) {
      final platform = entry.value as Map<String, Object?>;
      final bytes = files[platform['fileName']]!;
      expect(platform['version'], '2.0.0');
      expect(platform['build'], 42);
      expect(platform['size'], bytes.length);
      expect(platform['sha256'], sha256.convert(bytes).toString());
    }
    expect(
      (platforms['windows-x64'] as Map)['silentArgs'],
      contains('/relaunch=1'),
    );
  });

  test('retains a previous platform when its artifact is skipped', () async {
    final directory = await Directory.systemTemp.createTemp('manifest-test-');
    addTearDown(() => directory.delete(recursive: true));
    await File(
      '${directory.path}/MeowSTT-2.0.0-macos-arm64-release.zip',
    ).writeAsBytes([1]);
    final oldWindows = <String, Object?>{
      'version': '1.9.0',
      'build': 40,
      'kind': 'innoSetup',
    };

    final manifest = await buildUpdateManifest(
      version: '2.0.0',
      build: 42,
      artifactDirectory: directory,
      previousManifest: {
        'schema': 1,
        'platforms': {'windows-x64': oldWindows},
      },
    );

    expect((manifest['platforms'] as Map)['windows-x64'], same(oldWindows));
  });

  test('rejects multiple artifacts for one target', () async {
    final directory = await Directory.systemTemp.createTemp('manifest-test-');
    addTearDown(() => directory.delete(recursive: true));
    for (final prefix in ['one', 'two']) {
      await File(
        '${directory.path}/$prefix-macos-arm64-release.zip',
      ).writeAsBytes([1]);
    }

    await expectLater(
      buildUpdateManifest(
        version: '2.0.0',
        build: 42,
        artifactDirectory: directory,
      ),
      throwsStateError,
    );
  });
}
