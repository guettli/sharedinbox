import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const _kChannelId = 'new_mail';
const _kChannelName = 'New mail';

final _plugin = FlutterLocalNotificationsPlugin();
bool _initialized = false;

Future<void> initNotifications() async {
  try {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      const InitializationSettings(android: android),
      onDidReceiveNotificationResponse: (_) {},
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    _initialized = true;
  } on MissingPluginException {
    // Plugin not registered on this device; notifications silently disabled.
  } catch (_) {
    // Unexpected initialization failure; notifications silently disabled.
  }
}

Future<void> showNewMailNotification(String accountEmail) async {
  if (!Platform.isAndroid || !_initialized) return;
  await _plugin.show(
    accountEmail.hashCode & 0x7FFFFFFF,
    'New mail',
    accountEmail,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        _kChannelId,
        _kChannelName,
        channelDescription: 'Notifications for new incoming mail',
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
  );
}
