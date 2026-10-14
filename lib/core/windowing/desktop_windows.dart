import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitType;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_window.dart';
import 'app_windows.dart';
import 'main_window_host.dart';
import 'window_handle_channel.dart';

/// The desktop app's windows: the main window plus any video player windows.
///
/// The native runners are headless — every window is created here, from Dart,
/// as a view of the one engine, so a player window shares the main window's
/// isolate and services.
class DesktopWindows implements MainWindowHost {
  DesktopWindows._(this.main, {required bool visible}) : _mainVisible = visible;

  /// Null in widget tests and on SDKs built without windowing.
  static DesktopWindows? get instance => _instance;
  static DesktopWindows? _instance;

  static const _preferredMainSize = Size(1240, 820);
  static const _minMainSize = Size(920, 640);

  final AppWindow main;
  final AppWindowRegistry registry = AppWindowRegistry();
  late final AppWindowEntry _mainEntry;
  Future<void> Function()? _mainCloseHandler;
  bool _mainVisible;

  /// Creates the main window showing [content] and mounts the window tree.
  /// Call once, from `main()`, after `WidgetsFlutterBinding.ensureInitialized`.
  ///
  /// With [startHidden] the main window stays off screen until [showMain]:
  /// a login-item launch, or a launch only to play a video.
  static DesktopWindows start({
    required Widget content,
    required bool startHidden,
  }) {
    assert(_instance == null, 'DesktopWindows.start called twice');
    final size = _fitToScreen(_preferredMainSize);
    final window = AppWindow.create(
      size: size,
      constraints: BoxConstraints(
        minWidth: _minMainSize.width.clamp(0, size.width),
        minHeight: _minMainSize.height.clamp(0, size.height),
      ),
      title: '',
    );
    final windows = DesktopWindows._(window, visible: !startHidden);
    _instance = windows;
    window
      ..onCloseRequested = windows._onMainCloseRequested
      ..onDestroyed = windows._onMainDestroyed;
    windows._mainEntry = AppWindowEntry(
      window: window,
      builder: (_) => content,
    );
    windows.registry.add(windows._mainEntry);
    unawaited(
      WindowHandleChannel.registerMainWindow(window, startHidden: startHidden),
    );
    unawaited(WindowHandleChannel.attachDropTarget(window));
    if (startHidden && Platform.isWindows) {
      unawaited(WindowHandleChannel.setSkipTaskbar(window, true));
    }
    runWidget(AppWindowsHost(registry: windows.registry));
    return windows;
  }

  @override
  bool get mainVisible => _mainVisible;

  @override
  bool get mainFullscreen => main.isFullscreen;

  @override
  Listenable get mainListenable => main.listenable;

  @override
  void setMainTitle(String title) => main.setTitle(title);

  /// Replaces what the main window's close button does. Without a handler the
  /// window hides, as closing it always has.
  @override
  set mainCloseHandler(Future<void> Function()? handler) =>
      _mainCloseHandler = handler;

  /// Runs the main window's close behaviour, as its close button does
  /// (Windows draws that button itself).
  Future<void> requestMainClose() async => _onMainCloseRequested();

  void _onMainCloseRequested() {
    final handler = _mainCloseHandler;
    if (handler != null) {
      unawaited(handler());
    } else {
      unawaited(hideMain());
    }
  }

  void _onMainDestroyed() => registry.remove(_mainEntry);

  @override
  Future<void> hideMain() async {
    _mainVisible = false;
    if (Platform.isWindows) {
      await WindowHandleChannel.setSkipTaskbar(main, true);
    }
    await WindowHandleChannel.hide(main);
  }

  /// Brings the main window back (from hidden or minimized) and focuses it.
  @override
  Future<void> showMain() async {
    _mainVisible = true;
    if (Platform.isWindows) {
      await WindowHandleChannel.setSkipTaskbar(main, false);
    }
    await WindowHandleChannel.show(main);
    main.activate();
  }

  /// Ends the process once the app has cleaned up, as closing the last window
  /// used to: the runners no longer quit when a window goes away.
  @override
  Future<void> quit() async {
    await ServicesBinding.instance.exitApplication(AppExitType.required);
  }

  static Size _fitToScreen(Size preferred) {
    final displays = WidgetsBinding.instance.platformDispatcher.displays;
    if (displays.isEmpty) return preferred;
    final display = displays.first;
    final logical = display.size / display.devicePixelRatio;
    // Leave room for the menu bar / taskbar and a margin.
    final available = Size(logical.width - 32, logical.height - 96);
    if (available.isEmpty) return preferred;
    return Size(
      preferred.width.clamp(0, available.width).toDouble(),
      preferred.height.clamp(0, available.height).toDouble(),
    );
  }
}
