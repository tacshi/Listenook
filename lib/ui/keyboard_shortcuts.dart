import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

bool primaryFocusIsEditable() {
  final focusContext = FocusManager.instance.primaryFocus?.context;
  if (focusContext == null) return false;
  return focusContext.widget is EditableText ||
      focusContext.findAncestorWidgetOfExactType<EditableText>() != null;
}

bool shortcutModifierPressed() {
  final keyboard = HardwareKeyboard.instance;
  return keyboard.isControlPressed ||
      keyboard.isMetaPressed ||
      keyboard.isAltPressed ||
      keyboard.isShiftPressed;
}

/// ⌘. — the iPad keyboard's Escape: the Magic Keyboard has no Esc key.
const commandPeriod = SingleActivator(LogicalKeyboardKey.period, meta: true);

/// Whether [event] is Escape or ⌘.
bool isEscapeEvent(KeyEvent event) =>
    event.logicalKey == LogicalKeyboardKey.escape ||
    (event.logicalKey == LogicalKeyboardKey.period &&
        HardwareKeyboard.instance.isMetaPressed &&
        !HardwareKeyboard.instance.isShiftPressed);
