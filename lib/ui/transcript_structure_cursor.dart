import '../core/app_identity.dart';
import 'dart:async';

import 'package:flutter/services.dart';

enum TranscriptStructureCursorKind { split, merge }

abstract final class TranscriptStructureCursors {
  static MouseCursor _split = TranscriptStructureMouseCursor._(
    TranscriptStructureCursorKind.split,
    SystemMouseCursors.precise,
  );
  static MouseCursor _merge = TranscriptStructureMouseCursor._(
    TranscriptStructureCursorKind.merge,
    SystemMouseCursors.resizeRow,
  );

  static MouseCursor get split => _split;
  static MouseCursor get merge => _merge;

  static void beginNewGeneration() {
    _split = TranscriptStructureMouseCursor._(
      TranscriptStructureCursorKind.split,
      SystemMouseCursors.precise,
    );
    _merge = TranscriptStructureMouseCursor._(
      TranscriptStructureCursorKind.merge,
      SystemMouseCursors.resizeRow,
    );
  }

  static Future<void> deactivateAll() async {
    try {
      await TranscriptStructureMouseCursor._channel.invokeMethod<void>(
        'deactivateAll',
      );
    } on MissingPluginException {
      // Non-desktop and test hosts use Flutter's fallback cursor ownership.
    } on PlatformException {
      // A platform adapter failure must not make transcript editing unusable.
    }
  }
}

class TranscriptStructureMouseCursor extends MouseCursor {
  const TranscriptStructureMouseCursor._(this.kind, this.fallback);

  static const _channel = MethodChannel(
    AppIdentity.cursorChannel,
  );
  static int _nextSessionId = 1;

  final TranscriptStructureCursorKind kind;
  final SystemMouseCursor fallback;

  @override
  MouseCursorSession createSession(int device) =>
      _TranscriptStructureMouseCursorSession(this, device, _nextSessionId++);

  @override
  String get debugDescription => 'transcript-${kind.name}';
}

class _TranscriptStructureMouseCursorSession extends MouseCursorSession {
  _TranscriptStructureMouseCursorSession(
    TranscriptStructureMouseCursor super.cursor,
    super.device,
    this.sessionId,
  );

  final int sessionId;

  TranscriptStructureMouseCursor get _cursor =>
      cursor as TranscriptStructureMouseCursor;

  @override
  Future<void> activate() async {
    try {
      await TranscriptStructureMouseCursor._channel.invokeMethod<void>(
        'activate',
        {'kind': _cursor.kind.name, 'session': sessionId, 'device': device},
      );
    } on MissingPluginException {
      await _activateFallback();
    } on PlatformException {
      await _activateFallback();
    }
  }

  Future<void> _activateFallback() =>
      SystemChannels.mouseCursor.invokeMethod<void>('activateSystemCursor', {
        'device': device,
        'kind': _cursor.fallback.kind,
      });

  @override
  void dispose() {
    unawaited(_deactivate());
  }

  Future<void> _deactivate() async {
    try {
      await TranscriptStructureMouseCursor._channel.invokeMethod<void>(
        'deactivate',
        {'session': sessionId},
      );
    } on MissingPluginException {
      // The next Flutter cursor session owns the fallback transition.
    } on PlatformException {
      // The next Flutter cursor session owns the fallback transition.
    }
  }
}
