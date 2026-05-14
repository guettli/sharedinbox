import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const _kChannelId = 'new_mail';
const _kChannelName = 'New mail';

final _plugin = FlutterLocalNotificationsPlugin();

Future<void> initNotifications() async {
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  await _plugin.initialize(
    const InitializationSettings(android: android),
    onDidReceiveNotificationResponse: (_) {},
  );
  await _plugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
}

Future<void> showNewMailNotification(String accountEmail) async {
  if (!Platform.isAndroid) return;
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
