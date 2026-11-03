import 'package:flutter/foundation.dart';

/// What the platform the app runs on offers. UI and services branch on these
/// instead of on `Platform.isX`, so widget tests can exercise iOS behaviour on
/// the host (by theme platform or by providing a value).
@immutable
class PlatformCapabilities {
  const PlatformCapabilities._({
    required this.desktopShell,
    required this.folderMonitoring,
    required this.fileDialogs,
    required this.sandboxedFiles,
    required this.immersiveFullscreen,
    required this.nativeKeyCommandMenu,
    required this.nowPlaying,
    required this.touchByDefault,
    required this.shortcutModifierLabel,
  });

  static const desktop = PlatformCapabilities._(
    desktopShell: true,
    folderMonitoring: true,
    fileDialogs: true,
    sandboxedFiles: false,
    immersiveFullscreen: false,
    nativeKeyCommandMenu: false,
    nowPlaying: false,
    touchByDefault: false,
    shortcutModifierLabel: 'Ctrl+',
  );

  static const macOS = PlatformCapabilities._(
    desktopShell: true,
    folderMonitoring: true,
    fileDialogs: true,
    sandboxedFiles: false,
    immersiveFullscreen: false,
    nativeKeyCommandMenu: false,
    nowPlaying: false,
    touchByDefault: false,
    shortcutModifierLabel: '⌘',
  );

  static const iOS = PlatformCapabilities._(
    desktopShell: false,
    folderMonitoring: false,
    fileDialogs: false,
    sandboxedFiles: true,
    immersiveFullscreen: true,
    nativeKeyCommandMenu: true,
    nowPlaying: true,
    touchByDefault: true,
    shortcutModifierLabel: '⌘',
  );

  static PlatformCapabilities forPlatform(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.iOS => iOS,
        TargetPlatform.macOS => macOS,
        _ => desktop,
      };

  /// The running platform, for services created outside the widget tree.
  static PlatformCapabilities get current => forPlatform(defaultTargetPlatform);

  /// Window title bar, tray or menu-bar icon, launch at login, quitting with
  /// a confirmation, close-to-tray and in-app updates.
  final bool desktopShell;

  /// Inbox can watch a folder for new media. Not on iOS, where media comes
  /// in through the picker, other apps and drag and drop instead.
  final bool folderMonitoring;

  /// Folder pickers and save dialogs. Without them, folders are imported
  /// through the system document picker and exports go to the share sheet.
  final bool fileDialogs;

  /// Imported files are copied into the app container and saved paths are
  /// container-relative.
  final bool sandboxedFiles;

  /// Fullscreen video hides the system UI (and turns phones to landscape)
  /// rather than making a window fullscreen.
  final bool immersiveFullscreen;

  /// App-level shortcuts come from the system menu (the iPad menu bar and
  /// its ⌘-hold list), which forwards them over the navigation channel.
  final bool nativeKeyCommandMenu;

  /// Playback shows on the lock screen and responds to remote commands.
  final bool nowPlaying;

  /// Controls start in their touch layout until a mouse or trackpad is used.
  final bool touchByDefault;

  /// How the primary shortcut modifier is written in hints: "⌘" or "Ctrl+".
  final String shortcutModifierLabel;
}
