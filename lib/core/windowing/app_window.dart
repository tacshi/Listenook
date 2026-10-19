// The only file in the app that touches Flutter's experimental windowing API.
// It is `@internal` and lives under `src/`, and upstream makes breaking changes
// to it even in patch releases — keep every use behind this wrapper so an SDK
// bump is a one-file fix. See flutter/flutter#30701.
//
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/src/foundation/_features.dart' show isWindowingEnabled;
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_linux.dart'
    show BaseWindowControllerLinux;
import 'package:flutter/src/widgets/_window_macos.dart'
    show BaseWindowControllerMacOS;
import 'package:flutter/src/widgets/_window_win32.dart'
    show BaseWindowControllerWin32;
import 'package:flutter/widgets.dart';

/// Whether desktop windows are created from Dart through the windowing API.
///
/// True on macOS, Windows and Linux when the SDK was built with the
/// `enable-windowing` feature (pubspec `flutter: config:`). The native runners
/// are headless on those platforms, so there is no other way to get a window.
bool get appWindowingAvailable =>
    isWindowingEnabled &&
    !kIsWeb &&
    (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

/// One top-level OS window: a view of the app's single engine.
///
/// A thin wrapper over the SDK's `WindowController`, adding the native handle
/// (for the window-handle channel — hide/show and aspect ratio, which the API
/// does not offer) and routing the close button through [onCloseRequested].
class AppWindow {
  AppWindow._(this._controller, this._delegate);

  /// Creates the native window. It becomes visible once a [AppWindowView]
  /// for it renders its first frame.
  ///
  /// [onCloseRequested] replaces the default "destroy on close" — the caller
  /// decides whether to hide, tear down first, or ignore. [onDestroyed] runs
  /// once the native window is gone, whoever destroyed it.
  factory AppWindow.create({
    required Size size,
    BoxConstraints? constraints,
    String? title,
    VoidCallback? onCloseRequested,
    VoidCallback? onDestroyed,
  }) {
    final delegate = _AppWindowDelegate(onCloseRequested, onDestroyed);
    final controller = WindowController(
      size: constraints?.constrain(size) ?? size,
      constraints: constraints,
      title: title,
      delegate: delegate,
    );
    return AppWindow._(controller, delegate);
  }

  final WindowController _controller;
  final _AppWindowDelegate _delegate;

  /// Notifies on every state change the platform reports (size, title,
  /// activation, fullscreen, destruction).
  Listenable get listenable => _controller;

  /// Replaces the close-button handler after creation (the owner of a window
  /// is often built after the window itself).
  set onCloseRequested(VoidCallback? handler) =>
      _delegate.onCloseRequested = handler;

  set onDestroyed(VoidCallback? handler) => _delegate.onDestroyed = handler;

  /// The engine view id this window renders.
  int get viewId => _controller.rootView.viewId;

  /// NSWindow* / HWND / GtkWindow* as an integer, or 0 where there is none
  /// (tests' fake windowing owner, or once destroyed).
  int get nativeHandle {
    if (_controller.isDestroyed) return 0;
    return switch (_controller) {
      final BaseWindowControllerMacOS mac => mac.windowHandle.address,
      final BaseWindowControllerWin32 win => win.windowHandle.address,
      final BaseWindowControllerLinux linux => linux.windowHandle.address,
      _ => 0,
    };
  }

  bool get isDestroyed => _controller.isDestroyed;
  bool get isActivated => !isDestroyed && _controller.isActivated;
  bool get isFullscreen => !isDestroyed && _controller.isFullscreen;
  bool get isMaximized => !isDestroyed && _controller.isMaximized;
  bool get isMinimized => !isDestroyed && _controller.isMinimized;
  Size get contentSize => _controller.contentSize;
  String get title => _controller.title;

  void setTitle(String title) {
    if (!isDestroyed) _controller.setTitle(title);
  }

  void setSize(Size size) {
    if (!isDestroyed) _controller.setSize(size);
  }

  void setConstraints(BoxConstraints constraints) {
    if (!isDestroyed) _controller.setConstraints(constraints);
  }

  void setFullscreen(bool fullscreen) {
    if (!isDestroyed) _controller.setFullscreen(fullscreen);
  }

  void setMaximized(bool maximized) {
    if (!isDestroyed) _controller.setMaximized(maximized);
  }

  void setMinimized(bool minimized) {
    if (!isDestroyed) _controller.setMinimized(minimized);
  }

  /// Brings the window to the front and gives it focus.
  void activate() {
    if (!isDestroyed) _controller.activate();
  }

  /// Destroys the native window. Safe to call more than once.
  void destroy() {
    if (!isDestroyed) _controller.destroy();
  }

  /// The window whose view [context] is rendered in, or null outside one
  /// (mobile, web, widget tests without a window).
  static AppWindow? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_AppWindowScope>()?.window;
}

class _AppWindowDelegate with WindowControllerDelegate {
  _AppWindowDelegate(this.onCloseRequested, this.onDestroyed);

  VoidCallback? onCloseRequested;
  VoidCallback? onDestroyed;

  @override
  void onWindowCloseRequested(WindowController controller) {
    final handler = onCloseRequested;
    if (handler == null) {
      super.onWindowCloseRequested(controller);
    } else {
      handler();
    }
  }

  @override
  void onWindowDestroyed() {
    super.onWindowDestroyed();
    onDestroyed?.call();
  }
}

/// Renders [child] into [window]'s OS window.
class AppWindowView extends StatelessWidget {
  const AppWindowView({super.key, required this.window, required this.child});

  final AppWindow window;
  final Widget child;

  @override
  Widget build(BuildContext context) => Window(
    controller: window._controller,
    child: _AppWindowScope(window: window, child: child),
  );
}

class _AppWindowScope extends InheritedWidget {
  const _AppWindowScope({required this.window, required super.child});

  final AppWindow window;

  @override
  bool updateShouldNotify(_AppWindowScope oldWidget) =>
      window != oldWidget.window;
}
