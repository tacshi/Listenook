import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'macOS packaging detects an app executable before replacing its bundle',
    () async {
      final root = Directory.current;
      final helper = File('${root.path}/scripts/is-macos-app-running.sh');
      final metadataHelper = File(
        '${root.path}/scripts/strip-macos-download-metadata.sh',
      );
      final buildScript = File('${root.path}/scripts/build-macos.sh');
      final currentProcess = await Process.run('ps', [
        '-p',
        '$pid',
        '-ww',
        '-o',
        'command=',
      ]);
      final executable = currentProcess.stdout
          .toString()
          .trim()
          .split(' ')
          .first;
      final detection = await Process.run('bash', [helper.path, executable]);

      expect(
        detection.exitCode,
        0,
        reason: '${detection.stderr}\nprocess: ${currentProcess.stdout}',
      );
      final source = await buildScript.readAsString();
      expect(source, contains('is-macos-app-running.sh'));
      expect(source, contains('strip-macos-download-metadata.sh'));

      final temporary = await Directory.systemTemp.createTemp(
        'meowstt-gatekeeper-metadata-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final nestedFile = File('${temporary.path}/Contents/MacOS/MeowSTT');
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
}
