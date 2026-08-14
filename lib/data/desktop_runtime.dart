import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:win32_registry/win32_registry.dart';

typedef DesktopNotificationCallback = Future<void> Function();

class DesktopRuntime {
  DesktopRuntime({FlutterLocalNotificationsPlugin? notifications})
    : _notifications = notifications ?? FlutterLocalNotificationsPlugin();

  static const _startupChannel = MethodChannel(
    'app.meowstt.desktop/launch_at_login',
  );
  static const _windowsRunKey =
      r'Software\Microsoft\Windows\CurrentVersion\Run';
  static const _windowsRunValue = 'MeowSTT';

  final FlutterLocalNotificationsPlugin _notifications;
  DesktopNotificationCallback? _onNotificationSelected;
  bool _notificationsReady = false;

  Future<void> initialize({
    required DesktopNotificationCallback onNotificationSelected,
  }) async {
    _onNotificationSelected = onNotificationSelected;
    if (!Platform.isMacOS && !Platform.isWindows) return;
    try {
      final initialized = await _notifications.initialize(
        settings: const InitializationSettings(
          macOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          windows: WindowsInitializationSettings(
            appName: 'MeowSTT',
            appUserModelId: 'MeowSTT.Desktop.Inbox',
            guid: '5ec4426e-335e-4b64-a21c-b87d5074702f',
          ),
        ),
        onDidReceiveNotificationResponse: (_) {
          _onNotificationSelected?.call();
        },
      );
      _notificationsReady = initialized ?? false;
    } on MissingPluginException {
      // Desktop plugins are intentionally unavailable in widget tests.
    } on Object catch (error) {
      debugPrint('Unable to initialize desktop notifications: $error');
    }
  }

  Future<bool> requestNotificationPermission() async {
    if (!Platform.isMacOS) return true;
    try {
      return await _notifications
              .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, badge: true, sound: true) ??
          false;
    } on MissingPluginException {
      return false;
    } on Object catch (error) {
      debugPrint('Unable to request notification permission: $error');
      return false;
    }
  }

  Future<void> showDiscoveryNotification({
    required String title,
    required String body,
  }) async {
    if (!_notificationsReady) return;
    try {
      await _notifications.show(
        id: 115,
        title: title,
        body: body,
        payload: 'inbox',
        notificationDetails: const NotificationDetails(
          macOS: DarwinNotificationDetails(
            threadIdentifier: 'meowstt-inbox-discovery',
          ),
          windows: WindowsNotificationDetails(
            header: WindowsHeader(
              id: 'meowstt-inbox-discovery',
              title: 'MeowSTT Inbox',
              arguments: 'inbox',
            ),
          ),
        ),
      );
    } on MissingPluginException {
      // Desktop plugins are intentionally unavailable in widget tests.
    } on Object catch (error) {
      debugPrint('Unable to show Inbox notification: $error');
    }
  }

  Future<void> setLaunchAtLogin(bool enabled) async {
    if (Platform.isWindows) {
      try {
        final key = CURRENT_USER.create(_windowsRunKey);
        try {
          if (enabled) {
            final command = '"${Platform.resolvedExecutable}" --background';
            key.setValue(_windowsRunValue, RegistryValue.string(command));
          } else if (key.getValue(_windowsRunValue) != null) {
            key.removeValue(_windowsRunValue);
          }
        } finally {
          key.close();
        }
      } on Object catch (error) {
        debugPrint('Unable to update Windows launch-at-login: $error');
      }
      return;
    }
    if (Platform.isMacOS) {
      try {
        await _startupChannel.invokeMethod<void>('setEnabled', enabled);
      } on MissingPluginException {
        // Desktop plugins are intentionally unavailable in widget tests.
      } on Object catch (error) {
        debugPrint('Unable to update macOS launch-at-login: $error');
      }
    }
  }
}
