import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/platform_capabilities.dart';

extension PlatformContext on BuildContext {
  /// The provided capabilities, else those of the theme's platform (which
  /// follows `debugDefaultTargetPlatformOverride` and test themes).
  PlatformCapabilities get capabilities {
    try {
      final provided = Provider.of<PlatformCapabilities?>(this, listen: false);
      if (provided != null) return provided;
    } on ProviderNotFoundException {
      // Fall through to the theme's platform.
    }
    return PlatformCapabilities.forPlatform(Theme.of(this).platform);
  }

  /// Whether the last pointer was a finger, so hover-only controls must be
  /// shown and hit targets kept large. An iPad trackpad or mouse switches
  /// back to the pointer layout.
  bool get touchActive => InputModality.touchActiveOf(this);
}

/// Remembers which kind of pointer the user touched the app with last.
class InputModality extends StatefulWidget {
  const InputModality({super.key, required this.child, this.initialTouch});

  final Widget child;

  /// Defaults to touch on iOS (before any input arrives), pointer elsewhere.
  final bool? initialTouch;

  static bool touchActiveOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_InputModalityScope>()
          ?.touch ??
      context.capabilities.touchByDefault;

  @override
  State<InputModality> createState() => _InputModalityState();
}

class _InputModalityState extends State<InputModality> {
  bool? _touch;

  void _record(PointerEvent event) {
    final touch = switch (event.kind) {
      PointerDeviceKind.touch || PointerDeviceKind.stylus => true,
      PointerDeviceKind.mouse || PointerDeviceKind.trackpad => false,
      _ => null,
    };
    if (touch == null || touch == _touch) return;
    setState(() => _touch = touch);
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _record,
    onPointerHover: _record,
    onPointerPanZoomStart: _record,
    child: _InputModalityScope(
      touch:
          _touch ?? widget.initialTouch ?? context.capabilities.touchByDefault,
      child: widget.child,
    ),
  );
}

class _InputModalityScope extends InheritedWidget {
  const _InputModalityScope({required this.touch, required super.child});

  final bool touch;

  @override
  bool updateShouldNotify(_InputModalityScope oldWidget) =>
      touch != oldWidget.touch;
}
