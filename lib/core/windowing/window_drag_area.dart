import 'dart:async';

import 'package:flutter/widgets.dart';

import 'app_window.dart';
import 'window_handle_channel.dart';

/// Moves the surrounding window when dragged, like a native title bar, and
/// toggles maximize on double-click.
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final window = AppWindow.maybeOf(context);
    if (window == null) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => unawaited(WindowHandleChannel.startDrag(window)),
      onDoubleTap: () {
        if (!window.isFullscreen) window.setMaximized(!window.isMaximized);
      },
      child: child,
    );
  }
}
