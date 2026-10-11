import 'package:flutter/foundation.dart';

import 'desktop_windows.dart';

/// What the app shell needs from its main window: show and hide (close to the
/// menu bar or tray), quitting, full-screen state and the close button.
///
/// [DesktopWindows] implements it over Flutter's windowing API; widget tests
/// install a fake through [debugOverride].
abstract interface class MainWindowHost {
  /// Null in widget tests without an override.
  static MainWindowHost? get instance =>
      debugOverride ?? DesktopWindows.instance;

  @visibleForTesting
  static MainWindowHost? debugOverride;

  bool get mainVisible;
  bool get mainFullscreen;

  /// Notifies when the main window's state (full screen, focus) changes.
  Listenable get mainListenable;

  /// Replaces what the main window's close button does.
  set mainCloseHandler(Future<void> Function()? handler);

  void setMainTitle(String title);
  Future<void> showMain();
  Future<void> hideMain();
  Future<void> quit();
}
