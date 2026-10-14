import 'dart:async';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:tray_manager/tray_manager.dart';

/// An entry in the tray icon's menu.
class DesktopTrayMenuItem {
  const DesktopTrayMenuItem({
    required this.key,
    required this.label,
    this.enabled = true,
  });

  final String key;
  final String label;
  final bool enabled;
}

abstract mixin class DesktopTrayListener {
  /// A primary click that did not open the menu.
  void onTrayIconClicked() {}

  void onTrayMenuItemSelected(String key) {}
}

/// The menu-bar (macOS) or notification-area (Windows) icon.
///
/// On macOS a primary click opens the menu. On Windows a secondary click
/// opens it and primary clicks are reported to the listener.
abstract interface class DesktopTray {
  set listener(DesktopTrayListener? value);

  /// Shows the icon, or updates its tooltip and menu when already shown.
  /// A null menu entry is a separator.
  void show({
    required String tooltip,
    required List<DesktopTrayMenuItem?> menu,
  });

  /// Removes the icon; [show] adds it again.
  void remove();
}

class NativeDesktopTray implements DesktopTray {
  @override
  DesktopTrayListener? listener;

  TrayIcon? _icon;
  Image? _image;
  _NativeTrayMenu? _menu;

  // macOS needs the 2x template; Windows picks a size from the ICO.
  static String get _iconAsset => Platform.isWindows
      ? 'assets/branding/tray/listenook-tray.ico'
      : Platform.isMacOS
      ? 'assets/branding/tray/listenook-tray-template@2x.png'
      : 'assets/branding/tray/listenook-tray-template.png';

  static ContextMenuTrigger get _menuTrigger => Platform.isMacOS
      ? ContextMenuTrigger.clicked
      : ContextMenuTrigger.rightClicked;

  @override
  void show({
    required String tooltip,
    required List<DesktopTrayMenuItem?> menu,
  }) {
    final icon = _icon ?? _createIcon();
    icon.setTooltip(tooltip);
    final previous = _menu;
    final next = _NativeTrayMenu(
      menu,
      onSelected: (key) => listener?.onTrayMenuItemSelected(key),
    );
    icon.setContextMenu(next.menu);
    _menu = next;
    _disposeLater(previous);
  }

  @override
  void remove() {
    _icon?.dispose();
    _icon = null;
    _image?.dispose();
    _image = null;
    _disposeLater(_menu);
    _menu = null;
  }

  TrayIcon _createIcon() {
    final icon = TrayIcon.create();
    if (icon == null) throw StateError('Unable to create the tray icon');
    final image = ImageAsset.fromAsset(_iconAsset);
    if (image == null) {
      icon.dispose();
      throw StateError('Unable to load $_iconAsset');
    }
    icon
      ..isIconTemplate = Platform.isMacOS
      ..iconSize = const Size.square(18)
      ..icon = image
      ..setContextMenuTrigger(_menuTrigger)
      // Clicks are only reported, and the trigger only fires, once the
      // icon has a listener.
      ..addListener(_handleEvent)
      ..setVisible(true);
    _icon = icon;
    _image = image;
    return icon;
  }

  void _handleEvent(TrayIconEvent event) {
    if (event is TrayIconClickedEvent &&
        _menuTrigger != ContextMenuTrigger.clicked) {
      listener?.onTrayIconClicked();
    }
  }

  // The selected item's own callback may be what replaces or removes the
  // menu, so the old one has to outlive it.
  void _disposeLater(_NativeTrayMenu? menu) {
    if (menu != null) Timer.run(menu.dispose);
  }
}

class _NativeTrayMenu {
  _NativeTrayMenu(
    List<DesktopTrayMenuItem?> items, {
    required void Function(String key) onSelected,
  }) : menu = Menu.create() ?? (throw StateError('Unable to create a menu')) {
    for (final item in items) {
      if (item == null) {
        menu.addSeparator();
        continue;
      }
      final nativeItem =
          MenuItem.createWithLabelAndType(item.label, MenuItemType.normal) ??
          (throw StateError('Unable to create the menu item ${item.key}'));
      nativeItem.isEnabled = item.enabled;
      final listenerId = nativeItem.addListener((event) {
        if (event is MenuItemClickedEvent) onSelected(item.key);
      });
      _items.add((nativeItem, listenerId));
      menu.addItem(nativeItem);
    }
  }

  final Menu menu;
  final List<(MenuItem, ListenerId)> _items = [];

  void dispose() {
    for (final (item, listenerId) in _items) {
      item
        ..removeListener(listenerId)
        ..dispose();
    }
    _items.clear();
    menu.dispose();
  }
}
