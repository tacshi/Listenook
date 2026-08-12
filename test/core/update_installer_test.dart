import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/update_models.dart';
import 'package:meow_stt/data/update_installer.dart';

void main() {
  test(
    'Windows launches Inno Setup detached with manifest arguments',
    () async {
      String? executable;
      List<String>? arguments;
      ProcessStartMode? mode;
      final installer = WindowsUpdateInstaller(
        start: (path, args, startMode) async {
          executable = path;
          arguments = args;
          mode = startMode;
          return _FakeProcess();
        },
      );
      final asset = _asset(
        kind: UpdateInstallKind.innoSetup,
        silentArgs: const ['/SILENT', '/relaunch=1'],
      );

      await installer.launch(File('setup.exe'), asset);

      expect(executable, 'setup.exe');
      expect(arguments, ['/SILENT', '/relaunch=1']);
      expect(mode, ProcessStartMode.detached);
    },
  );

  test('Windows falls back to non-cancellable relaunch arguments', () async {
    List<String>? arguments;
    final installer = WindowsUpdateInstaller(
      start: (_, args, _) async {
        arguments = args;
        return _FakeProcess();
      },
    );

    await installer.launch(
      File('setup.exe'),
      _asset(kind: UpdateInstallKind.innoSetup),
    );

    expect(
      arguments,
      containsAll(['/NOCANCEL', '/CLOSEAPPLICATIONS', '/relaunch=1']),
    );
  });

  test('macOS locates only a writable installed MeowSTT bundle', () async {
    final root = await Directory.systemTemp.createTemp('meowstt-installer-');
    addTearDown(() => root.delete(recursive: true));
    final executable = '${root.path}/MeowSTT.app/Contents/MacOS/MeowSTT';
    await Directory(File(executable).parent.path).create(recursive: true);

    expect(
      MacosUpdateInstaller(executablePath: executable).installedBundlePath(),
      '${root.path}/MeowSTT.app',
    );
    expect(
      MacosUpdateInstaller(
        executablePath: '${root.path}/NotAnApp/Contents/MacOS/MeowSTT',
      ).installedBundlePath(),
      isNull,
    );
  });

  test('macOS verifies and starts the rollback-capable swap helper', () async {
    final root = await Directory.systemTemp.createTemp('meowstt-installer-');
    addTearDown(() => root.delete(recursive: true));
    final executable = '${root.path}/MeowSTT.app/Contents/MacOS/MeowSTT';
    await Directory(File(executable).parent.path).create(recursive: true);
    final archive = File('${root.path}/update/MeowSTT.zip');
    await archive.parent.create(recursive: true);
    await archive.writeAsBytes([1]);
    final commands = <String>[];
    List<String>? helperArguments;
    final installer = MacosUpdateInstaller(
      executablePath: executable,
      processId: 123,
      run: (command, arguments) async {
        commands.add(command);
        if (command == '/usr/bin/ditto') {
          await Directory(
            '${arguments.last}/MeowSTT.app',
          ).create(recursive: true);
        }
        return ProcessResult(1, 0, '', '');
      },
      start: (_, arguments, mode) async {
        expect(mode, ProcessStartMode.detached);
        helperArguments = arguments;
        return _FakeProcess();
      },
    );

    await installer.launch(archive, _asset(kind: UpdateInstallKind.appZip));

    expect(
      commands,
      containsAll(['/usr/bin/ditto', '/usr/bin/codesign', '/usr/sbin/spctl']),
    );
    expect(helperArguments, containsAll(['123', '${root.path}/MeowSTT.app']));
    expect(MacosUpdateInstaller.helperScript, contains('update-backup'));
    expect(
      MacosUpdateInstaller.helperScript,
      contains(r'mv "$backup_app" "$target_app"'),
    );
  });

  test('macOS refuses an archive whose signature fails', () async {
    final root = await Directory.systemTemp.createTemp('meowstt-installer-');
    addTearDown(() => root.delete(recursive: true));
    final executable = '${root.path}/MeowSTT.app/Contents/MacOS/MeowSTT';
    await Directory(File(executable).parent.path).create(recursive: true);
    final archive = File('${root.path}/update/MeowSTT.zip');
    await archive.parent.create(recursive: true);
    await archive.writeAsBytes([1]);
    final installer = MacosUpdateInstaller(
      executablePath: executable,
      run: (command, arguments) async {
        if (command == '/usr/bin/ditto') {
          await Directory(
            '${arguments.last}/MeowSTT.app',
          ).create(recursive: true);
        }
        return ProcessResult(
          1,
          command == '/usr/bin/codesign' ? 1 : 0,
          '',
          'bad',
        );
      },
    );

    await expectLater(
      installer.launch(archive, _asset(kind: UpdateInstallKind.appZip)),
      throwsA(isA<UpdateInstallException>()),
    );
  });
}

UpdateAsset _asset({
  required UpdateInstallKind kind,
  List<String> silentArgs = const [],
}) => UpdateAsset(
  kind: kind,
  fileName: kind == UpdateInstallKind.appZip ? 'MeowSTT.zip' : 'setup.exe',
  size: 1,
  sha256: List.filled(64, '0').join(),
  url: Uri.parse('https://example.com/update'),
  silentArgs: silentArgs,
);

class _FakeProcess implements Process {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
