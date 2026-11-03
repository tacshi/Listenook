import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'platform_context.dart';

/// Fullscreen video without a window to enlarge (iOS): hides the status bar
/// and home indicator and, on phones, turns to landscape. Does nothing where
/// fullscreen is a window state.
abstract final class ImmersiveMode {
  static Future<void> enter(BuildContext context) async {
    if (!context.capabilities.immersiveFullscreen) return;
    // iPads keep their orientation: forcing one breaks Split View.
    final phone = MediaQuery.sizeOf(context).shortestSide < 600;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (phone) {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  static Future<void> exit(BuildContext context) async {
    if (!context.capabilities.immersiveFullscreen) return;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(const []);
  }
}
