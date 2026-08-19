import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Future<void> _git(Directory repository, List<String> arguments) async {
  final result = await Process.run(
    'git',
    arguments,
    workingDirectory: repository.path,
  );
  expect(
    result.exitCode,
    0,
    reason: 'git ${arguments.join(' ')} failed:\n${result.stderr}',
  );
}

void main() {
  test('publisher validates provenance and publishes the manifest last', () {
    final source = File('scripts/release.sh').readAsStringSync();

    expect(source, contains('git rev-list --count HEAD'));
    expect(source, contains('Windows commit mismatch'));
    expect(source, contains('--reuse-artifacts'));
    expect(source, contains('--skip-windows'));
    expect(source, contains('--no-upload'));
    expect(source, contains(r'source "$ROOT/scripts/release-notes.sh"'));
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

  test('release notes expand squash-merge commit subjects', () async {
    final fixture = await Directory.systemTemp.createTemp(
      'meowstt_release_notes_',
    );
    addTearDown(() => fixture.delete(recursive: true));
    final repository = Directory('${fixture.path}/repository')..createSync();
    await _git(repository, ['init', '--quiet']);
    await _git(repository, ['config', 'user.name', 'MeowSTT Test']);
    await _git(repository, ['config', 'user.email', 'test@meowstt.invalid']);
    await _git(repository, ['config', 'commit.gpgsign', 'false']);
    await _git(repository, [
      'commit',
      '--quiet',
      '--allow-empty',
      '-m',
      'Previous release',
    ]);
    await _git(repository, ['tag', 'v1.0.0']);
    await _git(repository, [
      'commit',
      '--quiet',
      '--allow-empty',
      '-m',
      'Alignment (#24)',
      '-m',
      '* feat: improve podcast playback and requeue workflow\n\n'
          '* fix: render realistic waveform envelopes\n\n'
          '* Rename tray action to open main window\n\n'
          '* feat: add selectable alignment model variants',
    ]);

    final notes = File('${fixture.path}/notes.md');
    final helper = File('${Directory.current.path}/scripts/release-notes.sh');
    final result = await Process.run('bash', [
      '-c',
      r'''
source "$1"
cd -- "$2"
write_release_notes "$3" v1.0.0..HEAD
''',
      'release-notes-test',
      helper.path,
      repository.path,
      notes.path,
    ]);

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(
      notes.readAsStringSync(),
      '- improve podcast playback and requeue workflow\n'
      '- render realistic waveform envelopes\n'
      '- Rename tray action to open main window\n'
      '- add selectable alignment model variants\n',
    );
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
