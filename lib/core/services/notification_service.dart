import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:sharedinbox/core/services/notification_guard.dart';

const _kChannelId = 'new_mail';
const _kChannelName = 'New mail';

/// Bounds plugin initialization and the Linux daemon probe, which both run
/// before the first frame.
const _kInitTimeout = Duration(seconds: 3);

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

/// Whether a D-Bus session bus is reachable for the Linux notification backend.
///
/// `flutter_local_notifications` connects to the session bus when the Linux
/// backend is initialized. In a headless environment (CI, a login shell with no
/// desktop session) that connection fails asynchronously — the rejected future
/// escapes our synchronous try/catch and surfaces to `FlutterError.onError`,
/// crashing app boot. Only initialize the Linux backend when a bus is present.
bool _linuxSessionBusAvailable() {
  final env = Platform.environment;
  final addr = env['DBUS_SESSION_BUS_ADDRESS'];
  if (addr != null && addr.trim().isNotEmpty) return true;
  final runtimeDir = env['XDG_RUNTIME_DIR'];
  if (runtimeDir != null && runtimeDir.isNotEmpty) {
    return File('$runtimeDir/bus').existsSync();
  }
  return false;
}

Future<void> initNotifications() async {
  if (Platform.isLinux && !_linuxSessionBusAvailable()) {
    // No session bus: leave notifications disabled rather than let the D-Bus
    // connect fail on a detached future and take down startup.
    return;
  }
  try {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const linux = LinuxInitializationSettings(defaultActionName: 'Open');
    await _plugin
        .initialize(
          settings:
              const InitializationSettings(android: android, linux: linux),
          onDidReceiveNotificationResponse: (response) {
            final payload = response.payload;
            if (payload != null && payload.isNotEmpty) {
              onNotificationTap?.call(payload);
            }
          },
        )
        .timeout(_kInitTimeout);
    if (Platform.isLinux && !await _linuxNotificationDaemonAvailable()) return;
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    _initialized = true;
  } on MissingPluginException {
    // Plugin not registered on this device; notifications silently disabled.
  } catch (e) {
    debugPrint('Notifications disabled: initialization failed: $e');
  }
}

/// Whether a notification daemon owns `org.freedesktop.Notifications` on the
/// session bus. Minimal desktops (a bare i3/sway session without mako or
/// dunst, a headless Xvfb) have a session bus but no daemon; every `Notify`
/// call then fails with `ServiceUnknown` (#1107). Asks the daemon for its
/// capabilities, which D-Bus-activates a daemon that is installed but not
/// yet running, and treats an error or no reply as "no daemon".
Future<bool> _linuxNotificationDaemonAvailable() async {
  final linux = _plugin.resolvePlatformSpecificImplementation<
      LinuxFlutterLocalNotificationsPlugin>();
  if (linux == null) return false;
  try {
    await linux.getCapabilities().timeout(_kInitTimeout);
    return true;
  } catch (e) {
    debugPrint(
      'Notifications disabled: no notification daemon on the session bus '
      '(org.freedesktop.Notifications): $e',
    );
    return false;
  }
}

/// Shows a single new-mail notification. [title] is typically the sender and
/// [body] the subject line. [payload] travels back to [onNotificationTap] when
/// the user taps the notification. [id] keeps distinct messages from
/// collapsing into one slot. Never throws: a failing or hanging backend is
/// logged and skipped (see [guardNotificationShow]).
Future<void> showNewMailNotification({
  required String title,
  required String body,
  int? id,
  String? payload,
}) async {
  if (!notificationsSupported || !_initialized) return;
  await guardNotificationShow(
    () => _plugin.show(
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
    ),
  );
}
