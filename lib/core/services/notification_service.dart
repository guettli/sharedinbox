import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const _kChannelId = 'new_mail';
const _kChannelName = 'New mail';

final _plugin = FlutterLocalNotificationsPlugin();
bool _initialized = false;

/// Invoked with a notification's payload when the user taps it. Wired up by
/// `main.dart` so the tap can drive navigation without this platform-glue file
/// depending on the UI layer.
void Function(String payload)? onNotificationTap;

/// New-mail notifications are only wired up on the platforms whose
/// `flutter_local_notifications` backend this app initializes. macOS, Windows
/// and iOS fall through to a no-op until their backends are added.
bool get notificationsSupported => Platform.isAndroid || Platform.isLinux;

Future<void> initNotifications() async {
  try {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const linux = LinuxInitializationSettings(defaultActionName: 'Open');
    await _plugin.initialize(
      settings: const InitializationSettings(android: android, linux: linux),
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload != null && payload.isNotEmpty) {
          onNotificationTap?.call(payload);
        }
      },
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

/// Shows a single new-mail notification. [title] is typically the sender and
/// [body] the subject line. [payload] travels back to [onNotificationTap] when
/// the user taps the notification. [id] keeps distinct messages from
/// collapsing into one slot.
Future<void> showNewMailNotification({
  required String title,
  required String body,
  int? id,
  String? payload,
}) async {
  if (!notificationsSupported || !_initialized) return;
  await _plugin.show(
    id: id ?? (title + body).hashCode & 0x7FFFFFFF,
    title: title,
    body: body,
    payload: payload,
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        _kChannelId,
        _kChannelName,
        channelDescription: 'Notifications for new incoming mail',
        importance: Importance.high,
        priority: Priority.high,
      ),
      linux: LinuxNotificationDetails(),
    ),
  );
}
