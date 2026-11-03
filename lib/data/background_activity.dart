import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/app_identity.dart';

/// iOS: asks for time to finish work the user started (uploads, local
/// transcription, translation, downloads) after the app leaves the
/// foreground. The system grants a few minutes at its discretion; work that
/// runs out is suspended with the app and continues, or reports an error,
/// when the app returns.
class BackgroundActivity {
  BackgroundActivity({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel(AppIdentity.backgroundActivityChannel);

  final MethodChannel _channel;
  bool _busy = false;

  /// Keeps the app running in the background while [busy].
  Future<void> setBusy(bool busy) async {
    if (busy == _busy) return;
    _busy = busy;
    try {
      await _channel.invokeMethod<void>(busy ? 'begin' : 'end');
    } on MissingPluginException {
      // Desktop apps keep running in the background anyway.
    } on PlatformException catch (error) {
      debugPrint('Background time request failed: $error');
    }
  }
}
