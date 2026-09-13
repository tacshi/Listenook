import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'modern macOS DMG packaging uses diskutil without hdiutil warnings',
    () async {
      final invocation = await _runPackagingFixture('27.0');

      expect(invocation.exitCode, 0, reason: invocation.stderr.toString());
      expect(invocation.command, [
        'diskutil',
        'image',
        'create',
        'from',
        '--volumeName',
        'Listenook',
        '--format',
        'UDZO',
        invocation.stagePath,
        invocation.dmgPath,
      ]);
      expect(invocation.stderr, isNot(contains('deprecated')));
    },
    skip: !Platform.isMacOS,
  );

  test(
    'older macOS DMG packaging retains the compatible hdiutil fallback',
    () async {
      final invocation = await _runPackagingFixture('13.6');

      expect(invocation.exitCode, 0, reason: invocation.stderr.toString());
      expect(invocation.command, [
        'hdiutil',
        'create',
        '-volname',
        'Listenook',
        '-srcfolder',
        invocation.stagePath,
        '-ov',
        '-format',
        'UDZO',
        invocation.dmgPath,
      ]);
    },
    skip: !Platform.isMacOS,
  );
}

Future<_PackagingInvocation> _runPackagingFixture(String macOSVersion) async {
  final temporary = await Directory.systemTemp.createTemp(
    'listenook-dmg-packaging-',
  );
  addTearDown(() => temporary.delete(recursive: true));
  final bin = await Directory('${temporary.path}/bin').create();
  final stage = await Directory('${temporary.path}/stage').create();
  final dmg = File('${temporary.path}/Listenook.dmg');
  final log = File('${temporary.path}/command.log');
  await _writeExecutable(
    '${bin.path}/sw_vers',
    '#!/usr/bin/env bash\nprintf \'%s\\n\' \'$macOSVersion\'\n',
  );
  await _writeCommandRecorder('${bin.path}/diskutil', 'diskutil');
  await _writeCommandRecorder('${bin.path}/hdiutil', 'hdiutil');

  final helper = File('${Directory.current.path}/scripts/create-macos-dmg.sh');
  final result = await Process.run(
    'bash',
    [helper.path, stage.path, dmg.path],
    environment: {
      ...Platform.environment,
      'PATH': '${bin.path}:${Platform.environment['PATH'] ?? ''}',
      'LISTENOOK_DMG_TEST_LOG': log.path,
    },
  );
  final buildSource = await File(
    '${Directory.current.path}/scripts/build-macos.sh',
  ).readAsString();
  expect(buildSource, contains('create-macos-dmg.sh'));

  return _PackagingInvocation(
    exitCode: result.exitCode,
    stderr: result.stderr.toString(),
    command: await log.exists() ? await log.readAsLines() : const [],
    stagePath: stage.path,
    dmgPath: dmg.path,
  );
}

Future<void> _writeCommandRecorder(String path, String command) =>
    _writeExecutable(path, '''#!/usr/bin/env bash
printf '%s\\n' '$command' "\$@" > "\$LISTENOOK_DMG_TEST_LOG"
''');

Future<void> _writeExecutable(String path, String contents) async {
  await File(path).writeAsString(contents);
  final chmod = await Process.run('chmod', ['+x', path]);
  expect(chmod.exitCode, 0, reason: chmod.stderr.toString());
}

class _PackagingInvocation {
  const _PackagingInvocation({
    required this.exitCode,
    required this.stderr,
    required this.command,
    required this.stagePath,
    required this.dmgPath,
  });

  final int exitCode;
  final String stderr;
  final List<String> command;
  final String stagePath;
  final String dmgPath;
}
