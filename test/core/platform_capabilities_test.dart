import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/platform_capabilities.dart';

void main() {
  test('iOS has no desktop shell and keeps files in the sandbox', () {
    final ios = PlatformCapabilities.forPlatform(TargetPlatform.iOS);
    expect(ios.desktopShell, isFalse);
    expect(ios.fileDialogs, isFalse);
    expect(ios.sandboxedFiles, isTrue);
    expect(ios.immersiveFullscreen, isTrue);
    expect(ios.nativeKeyCommandMenu, isTrue);
    expect(ios.nowPlaying, isTrue);
    expect(ios.touchByDefault, isTrue);
    expect(ios.shortcutModifierLabel, '⌘');
  });

  test('desktop platforms keep windows, dialogs and Ctrl or ⌘ hints', () {
    final macOS = PlatformCapabilities.forPlatform(TargetPlatform.macOS);
    final windows = PlatformCapabilities.forPlatform(TargetPlatform.windows);
    for (final desktop in [macOS, windows]) {
      expect(desktop.desktopShell, isTrue);
      expect(desktop.fileDialogs, isTrue);
      expect(desktop.sandboxedFiles, isFalse);
      expect(desktop.touchByDefault, isFalse);
    }
    expect(macOS.shortcutModifierLabel, '⌘');
    expect(windows.shortcutModifierLabel, 'Ctrl+');
    // Widget tests run as Android: they keep the desktop behaviour.
    expect(
      PlatformCapabilities.forPlatform(TargetPlatform.android),
      same(PlatformCapabilities.desktop),
    );
  });
}
