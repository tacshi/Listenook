import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../../core/windowing/app_window.dart';
import '../../core/windowing/app_windows.dart';
import '../../core/windowing/desktop_windows.dart';
import '../../core/windowing/window_handle_channel.dart';
import 'video_player_controller.dart';
import 'video_player_page.dart';

/// Gives every video its own OS window: another view of the app's one
/// engine, created from Dart, so the main window can stay hidden.
class VideoPlayerWindows {
  VideoPlayerWindows._(this._windows);

  /// Null in widget tests and on SDKs built without windowing.
  static VideoPlayerWindows? get instance {
    final windows = DesktopWindows.instance;
    if (windows == null) return null;
    return _instance ??= VideoPlayerWindows._(windows);
  }

  static VideoPlayerWindows? _instance;

  static const _initialSize = Size(1280, 720);
  static const _minimumSize = Size(480, 270);

  final DesktopWindows _windows;
  final Map<String, _PlayerWindow> _open = {};

  bool get hasOpenWindows => _open.isNotEmpty;

  /// Runs before a new player window opens, so other playback in the app
  /// (review, podcasts) can pause. Installed by the app shell.
  Future<void> Function()? beforeOpen;

  /// Runs once the last player window has closed.
  VoidCallback? afterAllClosed;

  /// Opens [path] in its own window, or brings its window forward when it is
  /// already playing.
  ///
  /// [wrap] supplies the app context the page needs (theme, localization,
  /// providers).
  Future<void> open(
    String path, {
    required VideoPlayerController Function(String path) createController,
    required Widget Function(BuildContext context, Widget player) wrap,
  }) async {
    final key = p.normalize(p.absolute(path));
    final existing = _open[key];
    if (existing != null) {
      await WindowHandleChannel.show(existing.window);
      existing.window.activate();
      return;
    }
    try {
      await beforeOpen?.call();
    } on Object catch (error) {
      debugPrint('VideoPlayerWindows: pausing other playback ($error)');
    }
    if (_open.containsKey(key)) return;
    final window = AppWindow.create(
      size: _initialSize,
      constraints: BoxConstraints(
        minWidth: _minimumSize.width,
        minHeight: _minimumSize.height,
      ),
      title: p.basename(path),
    );
    final entry = _PlayerWindow(
      key: key,
      window: window,
      controller: createController(key),
    );
    entry.registryEntry = AppWindowEntry(
      window: window,
      builder: (context) => entry.unmounted
          ? const ColoredBox(color: Colors.black)
          : wrap(
              context,
              VideoPlayerPage(
                path: key,
                controller: entry.controller,
                onClose: () => unawaited(close(key)),
                onVideoSize: (size) => unawaited(_fitToVideo(entry, size)),
                onControlsVisibilityChanged: (visible) => unawaited(
                  WindowHandleChannel.setTitlebarVisible(window, visible),
                ),
              ),
            ),
    );
    window
      ..onCloseRequested = (() => unawaited(close(key)))
      ..onDestroyed = (() => _onDestroyed(entry));
    _open[key] = entry;
    _windows.registry.add(entry.registryEntry);
    unawaited(_styleWhenShown(entry));
  }

  Future<void> _styleWhenShown(_PlayerWindow entry) async {
    await WidgetsBinding.instance.endOfFrame;
    if (entry.window.isDestroyed) return;
    await WindowHandleChannel.stylePlayerWindow(entry.window);
    await WindowHandleChannel.center(entry.window);
    await WindowHandleChannel.show(entry.window);
    entry.window.activate();
  }

  /// Sizes the window to the video's aspect ratio, within most of the screen,
  /// and keeps that ratio while resizing.
  Future<void> _fitToVideo(_PlayerWindow entry, Size video) async {
    final aspect = video.width / video.height;
    if (!aspect.isFinite || aspect <= 0) return;
    final applied = entry.appliedAspect;
    if (applied != null && (applied - aspect).abs() < .001) return;
    entry.appliedAspect = aspect;
    final window = entry.window;
    await WindowHandleChannel.setAspectRatio(window, aspect);
    if (window.isFullscreen || window.isMaximized) return;
    window.setSize(_fittedSize(video));
    await WindowHandleChannel.center(window);
  }

  static Size _fittedSize(Size video) {
    final displays = WidgetsBinding.instance.platformDispatcher.displays;
    var limit = const Size(1600, 1000);
    if (displays.isNotEmpty) {
      final display = displays.first;
      final logical = display.size / display.devicePixelRatio;
      limit = Size(logical.width * .8, logical.height * .8);
    }
    final scale = math.min(
      1.0,
      math.min(limit.width / video.width, limit.height / video.height),
    );
    final width = math.max(_minimumSize.width, video.width * scale);
    return Size(width, width * video.height / video.width);
  }

  /// Closes [path]'s window: the title bar's close button, Esc, ⌘W and
  /// quitting all come through here.
  ///
  /// The player is unmounted and its controller closed first — that stops
  /// libmpv and saves the resume point — and only then is the native window
  /// destroyed, so audio never outlives its window.
  Future<void> close(String path) {
    final entry = _open[p.normalize(p.absolute(path))];
    if (entry == null) return Future<void>.value();
    return entry.closing ??= _close(entry);
  }

  Future<void> _close(_PlayerWindow entry) async {
    entry.unmounted = true;
    _windows.registry.refresh();
    await WidgetsBinding.instance.endOfFrame;
    try {
      await entry.controller.close().timeout(const Duration(seconds: 5));
    } on Object catch (error) {
      debugPrint('VideoPlayerWindows: player shutdown ($error)');
    }
    if (entry.window.isFullscreen) entry.window.setFullscreen(false);
    entry.window.destroy();
    // Destroying fires onDestroyed synchronously on some platforms and not at
    // all in tests' fake windowing owner; either way the entry goes now.
    _onDestroyed(entry);
  }

  void _onDestroyed(_PlayerWindow entry) {
    if (entry.destroyed) return;
    entry.destroyed = true;
    _windows.registry.remove(entry.registryEntry);
    if (identical(_open[entry.key], entry)) _open.remove(entry.key);
    entry.controller.dispose();
    if (_open.isEmpty) afterAllClosed?.call();
  }

  /// Closes every player window and waits for each to finish tearing down.
  Future<void> shutdown() =>
      Future.wait([for (final key in List.of(_open.keys)) close(key)]);
}

class _PlayerWindow {
  _PlayerWindow({
    required this.key,
    required this.window,
    required this.controller,
  });

  final String key;
  final AppWindow window;
  final VideoPlayerController controller;
  late final AppWindowEntry registryEntry;
  Future<void>? closing;
  bool unmounted = false;
  bool destroyed = false;
  double? appliedAspect;
}
