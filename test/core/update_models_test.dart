import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/update_models.dart';

void main() {
  group('AppVersion', () {
    test('orders semantic components before the build number', () {
      expect(
        AppVersion.tryParse('1.2.0+2'),
        greaterThan(AppVersion.tryParse('1.2.0+1')!),
      );
      expect(
        AppVersion.tryParse('1.2.1+0'),
        greaterThan(AppVersion.tryParse('1.2.0+999')!),
      );
      expect(AppVersion.tryParse('1.2'), isNull);
      expect(AppVersion.tryParse('v1.2.3'), isNull);
    });

    test('an explicit package build overrides an inline build', () {
      expect(AppVersion.tryParse('1.2.3+4', build: 9)?.label, '1.2.3+9');
    });
  });

  test('selects the three supported architecture keys', () {
    expect(updatePlatformKeyForAbi(Abi.macosArm64), 'macos-arm64');
    expect(updatePlatformKeyForAbi(Abi.macosX64), 'macos-x64');
    expect(updatePlatformKeyForAbi(Abi.windowsX64), 'windows-x64');
    expect(updatePlatformKeyForAbi(Abi.linuxX64), isNull);
  });

  group('UpdateManifest', () {
    test('parses a valid platform entry', () {
      final release = UpdateManifest.parse(
        _manifest(),
      ).forPlatform('macos-arm64');

      expect(release?.version, const AppVersion(2, 0, 0, build: 42));
      expect(release?.asset.kind, UpdateInstallKind.appZip);
      expect(release?.asset.size, 3);
      expect(release?.asset.silentArgs, isEmpty);
    });

    test('ignores unsupported entries for other platforms', () {
      final raw = _manifest();
      (raw['platforms'] as Map<String, Object?>)['future-os'] = {
        'kind': 'futureInstaller',
      };

      expect(UpdateManifest.parse(raw).forPlatform('macos-arm64'), isNotNull);
    });

    test('rejects unsupported schema and malformed selected assets', () {
      expect(
        () => UpdateManifest.parse({..._manifest(), 'schema': 2}),
        throwsA(isA<UpdateManifestException>()),
      );

      final badDigest = _manifest();
      ((badDigest['platforms'] as Map)['macos-arm64'] as Map)['sha256'] = 'bad';
      expect(
        () => UpdateManifest.parse(badDigest).forPlatform('macos-arm64'),
        throwsA(isA<UpdateManifestException>()),
      );

      final badUrl = _manifest();
      ((badUrl['platforms'] as Map)['macos-arm64'] as Map)['url'] =
          'http://example.com/update.zip';
      expect(
        () => UpdateManifest.parse(badUrl).forPlatform('macos-arm64'),
        throwsA(isA<UpdateManifestException>()),
      );
    });
  });
}

Map<String, Object?> _manifest() => {
  'schema': 1,
  'platforms': <String, Object?>{
    'macos-arm64': <String, Object?>{
      'version': '2.0.0',
      'build': 42,
      'kind': 'appZip',
      'fileName': 'Listenook.zip',
      'size': 3,
      'sha256': List.filled(64, '0').join(),
      'url': 'https://example.com/Listenook.zip',
      'releasedAt': '2026-08-12T00:00:00Z',
      'notesUrl': 'https://example.com/releases/v2.0.0',
    },
  },
};
