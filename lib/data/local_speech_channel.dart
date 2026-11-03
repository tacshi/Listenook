import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

import '../core/app_identity.dart';
import '../core/contracts.dart';
import '../core/local_speech.dart';

/// iOS: runs the speech engine inside the app (ios/Runner/SpeechEngine
/// Channel.swift) with the worker process's JSON protocol, since iOS apps
/// cannot start processes.
class ChannelLocalSpeechWorker implements LocalSpeechWorker {
  ChannelLocalSpeechWorker({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel(AppIdentity.speechEngineChannel) {
    _channel.setMethodCallHandler(_handle);
  }

  final MethodChannel _channel;
  final Map<String, ProgressCallback?> _progress = {};
  final _random = Random();

  /// How often a running command checks whether it was cancelled.
  static const cancelPollInterval = Duration(milliseconds: 100);

  Future<Object?> _handle(MethodCall call) async {
    if (call.method != 'progress') return null;
    final arguments = (call.arguments as Map).cast<String, Object?>();
    _progress[arguments['id']]?.call(
      (arguments['fraction'] as num?)?.toDouble(),
      arguments['detail'] as String?,
    );
    return null;
  }

  @override
  Future<Map<String, dynamic>> run(
    SpeechWorkerCommand command,
    Map<String, dynamic> request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    if (shouldCancel?.call() ?? false) {
      throw const OperationCancelledException();
    }
    final id =
        '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 30)}';
    _progress[id] = onProgress;
    var cancelled = false;
    final watcher = Timer.periodic(cancelPollInterval, (_) {
      if (cancelled || !(shouldCancel?.call() ?? false)) return;
      cancelled = true;
      unawaited(
        _channel.invokeMethod<void>('cancel', {'id': id}).catchError((_) {}),
      );
    });
    try {
      final result = await _channel.invokeMethod<String>('run', {
        'id': id,
        'command': switch (command) {
          SpeechWorkerCommand.transcribeMoss => 'transcribe-moss',
          SpeechWorkerCommand.transcribeQwen3 => 'transcribe-qwen3',
          SpeechWorkerCommand.alignQwen3 => 'align-qwen3',
        },
        'request': jsonEncode({...request, 'protocol': 1}),
      });
      if (cancelled) throw const OperationCancelledException();
      final decoded = result == null ? null : jsonDecode(result);
      if (decoded is! Map) {
        throw const LocalSpeechException('local_worker_invalid_output');
      }
      return decoded.cast<String, dynamic>();
    } on PlatformException catch (error) {
      if (cancelled || error.code == 'cancelled') {
        throw const OperationCancelledException();
      }
      throw LocalSpeechException(error.code, message: error.message);
    } on MissingPluginException {
      throw const LocalSpeechException('local_worker_unsupported');
    } finally {
      watcher.cancel();
      _progress.remove(id);
    }
  }

  /// Whether this device can run the local models: iOS 18 on real hardware
  /// with about 8 GB of memory (the models alone take 1–2.5 GB).
  static Future<bool> isDeviceSupported({MethodChannel? channel}) async {
    try {
      final capabilities =
          await (channel ??
                  const MethodChannel(AppIdentity.speechEngineChannel))
              .invokeMapMethod<String, Object?>('capabilities');
      if (capabilities == null) return false;
      return LocalSpeechRuntimeSupport.isMobileDeviceSupported(
        physicalMemoryBytes: (capabilities['physicalMemory'] as num?)?.toInt(),
        osMajorVersion: (capabilities['osMajor'] as num?)?.toInt(),
        simulator: capabilities['isSimulator'] == true,
      );
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Keeps large files (models, downloads) out of iCloud backups.
  static Future<void> excludeFromBackup(
    String path, {
    MethodChannel? channel,
  }) async {
    try {
      await (channel ?? const MethodChannel(AppIdentity.speechEngineChannel))
          .invokeMethod<void>('excludeFromBackup', {'path': path});
    } on MissingPluginException {
      // Desktop and tests have no backups to keep files out of.
    } on PlatformException {
      // The folder may not exist yet; it is excluded on the next launch.
    }
  }
}
