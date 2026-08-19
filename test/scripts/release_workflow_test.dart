import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('publisher validates provenance and publishes the manifest last', () {
    final source = File('scripts/release.sh').readAsStringSync();

    expect(source, contains('git rev-list --count HEAD'));
    expect(source, contains('Windows commit mismatch'));
    expect(source, contains('--reuse-artifacts'));
    expect(source, contains('--skip-windows'));
    expect(source, contains('--no-upload'));
    expect(source, contains('gh auth login -h github.com'));
    expect(source, contains('must be public for anonymous app updates'));
    expect(source, contains('initialized the empty release repository'));
    expect(source, contains('[y]es / [e]dit / [N]o'));
    expect(source, contains(r'${EDITOR:-${VISUAL:-vi}}'));
    expect(source, contains('release notes are empty after editing'));

    final assets = source.indexOf('publishing GitHub release assets');
    final manifest = source.indexOf('publishing manifest last');
    final tag = source.indexOf('tagging source');
    expect(assets, greaterThanOrEqualTo(0));
    expect(manifest, greaterThan(assets));
    expect(tag, greaterThan(manifest));
  });

  test('platform packages contain updater artifacts and relaunch support', () {
    final macos = File('scripts/build-macos.sh').readAsStringSync();
    final windows = File('packaging/windows/MeowSTT.iss').readAsStringSync();
    final windowsRelease = File('scripts/win-release.ps1').readAsStringSync();

    expect(macos, contains(r'ditto -c -k --keepParent "$APP" "$APP_ZIP"'));
    expect(macos, contains('--build-name'));
    expect(macos, contains('--build-number'));
    expect(windows, contains("{param:relaunch|0}"));
    expect(windows, contains('ShouldRelaunch'));
    expect(windowsRelease, contains(r'commit = $Commit'));
    expect(windowsRelease, contains(r'architecture = $Arch'));
  });

  test('Windows build entry points share the common build implementation', () {
    final debug = File('scripts/win-debug.ps1').readAsStringSync();
    final release = File('scripts/win-release.ps1').readAsStringSync();

    expect(debug, contains('build-windows.ps1'));
    expect(debug, contains('-Mode debug'));
    expect(release, contains('build-windows.ps1'));
    expect(File('scripts/build-debug.ps1').existsSync(), isFalse);
    expect(File('scripts/build-release.ps1').existsSync(), isFalse);
  });
}
