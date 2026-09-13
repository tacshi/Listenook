import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS app detector matches the current executable', () async {
    final root = Directory.current;
    final helper = File('${root.path}/scripts/is-macos-app-running.sh');
    final currentProcess = await Process.run('ps', [
      '-p',
      '$pid',
      '-ww',
      '-o',
      'command=',
    ]);
    final executable = currentProcess.stdout.toString().trim().split(' ').first;
    final detection = await Process.run('bash', [helper.path, executable]);

    expect(
      detection.exitCode,
      0,
      reason: '${detection.stderr}\nprocess: ${currentProcess.stdout}',
    );
  }, skip: !Platform.isMacOS);

  test(
    'macOS metadata cleanup removes quarantine attributes',
    () async {
      final root = Directory.current;
      final metadataHelper = File(
        '${root.path}/scripts/strip-macos-download-metadata.sh',
      );
      final temporary = await Directory.systemTemp.createTemp(
        'listenook-gatekeeper-metadata-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final nestedFile = File('${temporary.path}/Contents/MacOS/Listenook');
      await nestedFile.create(recursive: true);
      final attributeWrite = await Process.run('xattr', [
        '-w',
        'com.apple.quarantine',
        'test-quarantine',
        nestedFile.path,
      ]);
      expect(attributeWrite.exitCode, 0, reason: '${attributeWrite.stderr}');

      final metadataCleanup = await Process.run('bash', [
        metadataHelper.path,
        temporary.path,
      ]);
      expect(metadataCleanup.exitCode, 0, reason: '${metadataCleanup.stderr}');
      final attributeRead = await Process.run('xattr', [
        '-p',
        'com.apple.quarantine',
        nestedFile.path,
      ]);
      expect(attributeRead.exitCode, isNot(0));
      expect(
        await metadataHelper.readAsString(),
        contains('com.apple.provenance'),
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'debug build stops the running app before replacing its bundle',
    () async {
      final buildScript = File(
        '${Directory.current.path}/scripts/build-macos.sh',
      );
      final source = await buildScript.readAsString();

      expect(source, contains('is-macos-app-running.sh'));
      expect(source, contains('stop-macos-app.sh'));
      expect(source, contains('strip-macos-download-metadata.sh'));
      expect(
        source,
        isNot(contains('Refusing to replace the running debug app')),
      );
    },
  );

  test(
    'macOS stop helper terminates the matching executable',
    () async {
      final root = Directory.current;
      final detector = File('${root.path}/scripts/is-macos-app-running.sh');
      final stopHelper = File('${root.path}/scripts/stop-macos-app.sh');
      final temporary = await Directory.systemTemp.createTemp(
        'listenook-stop-app-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final fakeExecutable = File(
        '${temporary.path}/Debug.app/Contents/MacOS/Listenook',
      );
      await fakeExecutable.parent.create(recursive: true);
      final copy = await Process.run('cp', ['/bin/sleep', fakeExecutable.path]);
      expect(copy.exitCode, 0, reason: '${copy.stderr}');
      final process = await Process.start(fakeExecutable.path, ['30']);
      addTearDown(() => process.kill(ProcessSignal.sigkill));

      ProcessResult? runningDetection;
      for (var attempt = 0; attempt < 20; attempt++) {
        runningDetection = await Process.run('bash', [
          detector.path,
          fakeExecutable.path,
        ]);
        if (runningDetection.exitCode == 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(
        runningDetection?.exitCode,
        0,
        reason: '${runningDetection?.stderr}',
      );

      final stop = await Process.run('bash', [
        stopHelper.path,
        fakeExecutable.path,
      ]);
      expect(stop.exitCode, 0, reason: '${stop.stderr}');
      expect(await process.exitCode, isNot(0));
      final stoppedDetection = await Process.run('bash', [
        detector.path,
        fakeExecutable.path,
      ]);
      expect(stoppedDetection.exitCode, isNot(0));
    },
    skip: !Platform.isMacOS,
  );
}
