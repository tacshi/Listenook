import 'package:flutter/widgets.dart';

/// Coordinates fullscreen and media teardown with mutations that can rebuild,
/// remove, or terminate the inline review video.
class ReviewFullscreenController {
  NavigatorState? _navigator;
  Future<void>? _pendingExit;
  final Map<Object, Future<void> Function()> _mediaShutdowns = {};
  final Map<Object, Future<void> Function()> _mediaResumes = {};
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

  void registerMediaShutdown(
    Object owner,
    Future<void> Function() shutdown, {
    Future<void> Function()? resume,
  }) {
    _mediaShutdowns[owner] = shutdown;
    if (resume != null) _mediaResumes[owner] = resume;
  }

  void unregisterMediaShutdown(Object owner) {
    _mediaShutdowns.remove(owner);
    _mediaResumes.remove(owner);
  }

  Future<void> shutdownMedia() async {
    for (final shutdown in List.of(_mediaShutdowns.values)) {
      await shutdown();
    }
  }

  Future<void> resumeMedia() async {
    for (final resume in List.of(_mediaResumes.values)) {
      await resume();
    }
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
