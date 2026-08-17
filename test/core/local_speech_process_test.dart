import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/contracts.dart';
import 'package:meow_stt/core/local_speech.dart';
import 'package:meow_stt/data/local_speech_process.dart';

void main() {
  test(
    'speech worker exchanges private JSON files and forwards progress',
    () async {
      final root = await Directory.systemTemp.createTemp('meow-worker-test-');
      addTearDown(() => root.delete(recursive: true));
      final executable = File('${root.path}/worker.sh');
      final stale = File('${root.path}/speech-999-stale-request.json');
      await stale.writeAsString('private stale text');
      await stale.setLastModified(
        DateTime.now().subtract(const Duration(hours: 2)),
      );
      await executable.writeAsString(r'''#!/bin/sh
command="$1"
request="$3"
output="$5"
request_mode=$(stat -f '%Lp' "$request")
output_mode=$(stat -f '%Lp' "$output")
printf '{"protocol":1,"event":"progress","fraction":0.5,"detail":"native"}\n'
printf '{"protocol":1,"ok":true,"result":{"command":"%s","request_mode":"%s","output_mode":"%s"}}' "$command" "$request_mode" "$output_mode" > "$output"
''');
      await Process.run('/bin/chmod', ['700', executable.path]);

      double? progress;
      final result =
          await ProcessLocalSpeechWorker(
            temporaryDirectory: root,
            executablePath: executable.path,
          ).run(SpeechWorkerCommand.transcribeMoss, const {
            'protocol': 1,
            'hotwords': ['private phrase'],
          }, onProgress: (fraction, detail) => progress = fraction);

      expect(result['command'], 'transcribe-moss');
      expect(result['request_mode'], '600');
      expect(result['output_mode'], '600');
      expect(progress, 0.5);
      expect(root.listSync().whereType<File>().map((file) => file.path), [
        executable.path,
      ]);
    },
    skip: !Platform.isMacOS,
  );

  test('speech worker terminates a cancelled helper', () async {
    final root = await Directory.systemTemp.createTemp('meow-worker-cancel-');
    addTearDown(() => root.delete(recursive: true));
    final executable = File('${root.path}/worker.sh');
    await executable.writeAsString(r'''#!/bin/sh
trap '' TERM
while true; do sleep 1; done
''');
    await Process.run('/bin/chmod', ['700', executable.path]);
    var cancelled = false;
    Future<void>.delayed(
      const Duration(milliseconds: 80),
      () => cancelled = true,
    );

    await expectLater(
      ProcessLocalSpeechWorker(
        temporaryDirectory: root,
        executablePath: executable.path,
        terminationGrace: const Duration(milliseconds: 100),
      ).run(SpeechWorkerCommand.alignQwen3, const {
        'protocol': 1,
      }, shouldCancel: () => cancelled),
      throwsA(isA<OperationCancelledException>()),
    );
  }, skip: !Platform.isMacOS);
}
