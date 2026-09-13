import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:win32_registry/win32_registry.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_identity.dart';

typedef DesktopNotificationCallback = Future<void> Function();

class DesktopRuntime {
  DesktopRuntime({
    FlutterLocalNotificationsPlugin? notifications,
    this.migrationMarker,
  }) : _notifications = notifications ?? FlutterLocalNotificationsPlugin();

  static const _startupChannel = MethodChannel(AppIdentity.startupChannel);
  static const _windowsRunKey =
      r'Software\Microsoft\Windows\CurrentVersion\Run';
  static const _windowsRunValue = AppIdentity.name;

  final FlutterLocalNotificationsPlugin _notifications;
  final File? migrationMarker;
  String _displayName = AppIdentity.name;
  DesktopNotificationCallback? _onNotificationSelected;
  bool _notificationsReady = false;

  Future<void> initialize({
    required DesktopNotificationCallback onNotificationSelected,
  }) async {
    _onNotificationSelected = onNotificationSelected;
    if (!Platform.isMacOS && !Platform.isWindows) return;
    try {
      final initialized = await _notifications.initialize(
        settings: InitializationSettings(
          macOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          windows: WindowsInitializationSettings(
            appName: _displayName,
            appUserModelId: AppIdentity.bundleId,
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
        notificationDetails: NotificationDetails(
          macOS: DarwinNotificationDetails(
            threadIdentifier: 'listenook-inbox-discovery',
          ),
          windows: WindowsNotificationDetails(
            header: WindowsHeader(
              id: 'listenook-inbox-discovery',
              title: _displayName,
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
          if (key.getValue('MeowSTT') != null) key.removeValue('MeowSTT');
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

  Future<void> setDisplayName(String name, String languageCode) async {
    _displayName = name;
    if (Platform.isMacOS) {
      try {
        await _startupChannel.invokeMethod<void>('setDisplayName', {
          'name': name,
          'languageCode': languageCode,
        });
      } on MissingPluginException {
        // Not present in widget tests.
      }
    }
    if (Platform.isWindows &&
        _notificationsReady &&
        _onNotificationSelected != null) {
      await initialize(onNotificationSelected: _onNotificationSelected!);
    }
  }

  Future<bool> needsLegacyLoginNotice() async {
    final file = migrationMarker;
    if (!Platform.isMacOS || file == null || !await file.exists()) return false;
    final marker = jsonDecode(await file.readAsString()) as Map;
    return marker['migrated'] == true &&
        marker['legacy_login_notice_dismissed'] != true;
  }

  Future<void> dismissLegacyLoginNotice({bool openSettings = false}) async {
    if (openSettings) {
      final opened = await launchUrl(
        Uri.parse(
          'x-apple.systempreferences:com.apple.LoginItems-Settings.extension',
        ),
      );
      if (!opened) return;
    }
    final file = migrationMarker;
    if (file == null || !await file.exists()) return;
    final marker = jsonDecode(await file.readAsString()) as Map;
    marker['legacy_login_notice_dismissed'] = true;
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(marker), flush: true);
    await temporary.rename(file.path);
  }
}
