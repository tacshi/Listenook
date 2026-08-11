import 'package:flutter/widgets.dart';

/// Coordinates the fullscreen video route with mutations that can rebuild or
/// remove the inline review video.
class ReviewFullscreenController {
  NavigatorState? _navigator;
  Future<void>? _pendingExit;
  bool _active = false;

  bool get isActive => _active;

  void markEntered(NavigatorState navigator) {
    _navigator = navigator;
    _active = true;
  }

  void markExited() {
    _active = false;
    _navigator = null;
  }

  Future<void> exit() {
    final pending = _pendingExit;
    if (pending != null) return pending;
    if (!_active) return Future.value();

    final navigator = _navigator;
    if (navigator == null || !navigator.mounted) {
      _active = false;
      return Future.value();
    }

    final operation = _popFullscreen(navigator);
    _pendingExit = operation;
    return operation;
  }

  Future<void> _popFullscreen(NavigatorState navigator) async {
    try {
      await navigator.maybePop();
      await WidgetsBinding.instance.endOfFrame;
    } finally {
      _active = false;
      _navigator = null;
      _pendingExit = null;
    }
  }
}
