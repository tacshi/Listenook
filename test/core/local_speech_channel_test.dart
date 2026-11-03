import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/contracts.dart';
import 'package:listenook/core/local_speech.dart';
import 'package:listenook/data/local_speech_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.listenook.test/speech_engine');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> sendProgress(String id, double fraction, String detail) =>
      messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          MethodCall('progress', {
            'id': id,
            'fraction': fraction,
            'detail': detail,
          }),
        ),
        (_) {},
      );

  test('runs a command in process and reports its progress', () async {
    final worker = ChannelLocalSpeechWorker(channel: channel);
    final progress = <(double?, String?)>[];
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      final id = (call.arguments as Map)['id'] as String;
      await sendProgress(id, .5, 'transcribing-coreml');
      return jsonEncode({
        'segments': [
          {'start_ms': 0, 'end_ms': 900, 'text': 'Hello'},
        ],
      });
    });

    final result = await worker.run(SpeechWorkerCommand.transcribeMoss, {
      'audio_path': '/tmp/a.wav',
    }, onProgress: (fraction, detail) => progress.add((fraction, detail)));

    expect(received?.method, 'run');
    final arguments = received!.arguments as Map;
    expect(arguments['command'], 'transcribe-moss');
    expect(jsonDecode(arguments['request'] as String), {
      'audio_path': '/tmp/a.wav',
      'protocol': 1,
    });
    expect(progress, [(.5, 'transcribing-coreml')]);
    expect((result['segments'] as List).single['text'], 'Hello');
  });

  test('engine failures keep their codes', () async {
    final worker = ChannelLocalSpeechWorker(channel: channel);
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
        code: 'local_stt_insufficient_memory',
        message: 'Not enough memory',
      );
    });

    expect(
      () => worker.run(SpeechWorkerCommand.transcribeQwen3, const {}),
      throwsA(
        isA<LocalSpeechException>().having(
          (error) => error.code,
          'code',
          'local_stt_insufficient_memory',
        ),
      ),
    );
  });

  test('cancelling asks the engine to stop', () async {
    final worker = ChannelLocalSpeechWorker(channel: channel);
    final finish = Completer<Object?>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'cancel') {
        finish.completeError(PlatformException(code: 'cancelled'));
        return null;
      }
      return finish.future;
    });
    var cancel = false;
    final run = worker.run(
      SpeechWorkerCommand.alignQwen3,
      const {},
      shouldCancel: () => cancel,
    );
    cancel = true;

    await expectLater(run, throwsA(isA<OperationCancelledException>()));
    expect(calls, ['run', 'cancel']);
  });

  test('only 8 GB devices on iOS 18 run the local models', () {
    const gib = 1024 * 1024 * 1024;
    bool supported(int memory, {int os = 18, bool simulator = false}) =>
        LocalSpeechRuntimeSupport.isMobileDeviceSupported(
          physicalMemoryBytes: memory,
          osMajorVersion: os,
          simulator: simulator,
        );
    // An 8 GB iPhone 15 Pro reports a little under 8 GiB.
    expect(supported((7.5 * gib).round()), isTrue);
    expect(supported(16 * gib), isTrue);
    expect(supported(6 * gib), isFalse);
    expect(supported(8 * gib, os: 17), isFalse);
    expect(supported(16 * gib, simulator: true), isFalse);
  });
}
