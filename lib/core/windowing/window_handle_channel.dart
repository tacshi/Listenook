import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app_identity.dart';
import 'app_window.dart';

/// The native window operations the windowing API does not offer, keyed by
/// the window's native handle (NSWindow* / HWND). Implemented by each runner:
/// `macos/Runner/MainFlutterWindow.swift` and
/// `windows/runner/window_handle_channel.cpp`.
///
/// Every call is best effort: a window can be destroyed between the handle
/// being read and the call landing, and the runners ignore a stale handle.
class WindowHandleChannel {
  const WindowHandleChannel._();

  static const _channel = MethodChannel(AppIdentity.windowHandleChannel);
  static const _dropChannel = MethodChannel('desktop_drop');

  static Future<void> _call(
    String method,
    AppWindow window, [
    Map<String, Object?> extra = const {},
  ]) async {
    final handle = window.nativeHandle;
    if (handle == 0) return;
    try {
      await _channel.invokeMethod<void>(method, {'handle': handle, ...extra});
    } on MissingPluginException {
      // Widget tests and hosts without the runner channel.
    } on PlatformException catch (error) {
      debugPrint('WindowHandleChannel.$method: ${error.message}');
    }
  }

  /// Takes the window off screen without destroying it (close to the menu
  /// bar or tray), so its widget tree survives.
  static Future<void> hide(AppWindow window) => _call('hide', window);

  /// Puts a hidden window back on screen, restores it if minimized, and
  /// brings the app forward.
  static Future<void> show(AppWindow window) => _call('show', window);

  /// Locks resizing to [aspectRatio] (width / height), or unlocks with null.
  static Future<void> setAspectRatio(AppWindow window, double? aspectRatio) =>
      _call('setAspectRatio', window, {'aspectRatio': aspectRatio});

  /// Starts a native window move, as if the title bar were being dragged.
  /// Call while the primary button is still down — from a drag gesture's start.
  static Future<void> startDrag(AppWindow window) => _call('startDrag', window);

  /// Centers the window on its current screen.
  static Future<void> center(AppWindow window) => _call('center', window);

  /// Marks [window] as the app's main window: the target of the Dock, the
  /// menu-bar item and native full screen, drawn under a hidden title bar.
  /// With [startHidden] it stays off screen when its first frame appears
  /// (a login-item launch, or a launch only to play a video).
  static Future<void> registerMainWindow(
    AppWindow window, {
    required bool startHidden,
  }) => _call('registerMainWindow', window, {'startHidden': startHidden});

  /// Leaves the main window out of the taskbar while it is hidden (Windows).
  static Future<void> setSkipTaskbar(AppWindow window, bool skip) =>
      _call('setSkipTaskbar', window, {'skip': skip});

  /// Makes [window] accept dropped files (desktop_drop, patched in
  /// third_party/desktop_drop: plugins register before any Dart-created
  /// window exists, so the drop target is attached here instead).
  static Future<void> attachDropTarget(AppWindow window) async {
    final handle = window.nativeHandle;
    if (handle == 0) return;
    try {
      final attached = await _dropChannel.invokeMethod<bool>('attachToWindow', {
        'handle': handle,
      });
      if (attached != true) {
        debugPrint('WindowHandleChannel: file drop not attached to window');
      }
    } on MissingPluginException {
      // Widget tests and hosts without the plugin.
    } on PlatformException catch (error) {
      debugPrint('WindowHandleChannel.attachDropTarget: ${error.message}');
    }
  }

  /// Applies the player chrome: a transparent native title bar laid over the
  /// video on macOS, which fades with the player's controls. On Windows the
  /// native caption is removed and the player draws its own.
  static Future<void> stylePlayerWindow(AppWindow window) =>
      _call('stylePlayerWindow', window);

  /// Fades a player window's overlaid title bar in or out with the player's
  /// own controls.
  static Future<void> setTitlebarVisible(AppWindow window, bool visible) =>
      _call('setTitlebarVisible', window, {'visible': visible});
}
