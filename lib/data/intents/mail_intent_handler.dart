import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/utils/logger.dart';
import 'package:sharedinbox/core/utils/mailto_parser.dart';

/// Compose-screen fields extracted from an incoming Android intent.
///
/// File-path attachments (already copied to the app cache by the Kotlin
/// bridge) ride along on [attachmentPaths] so the compose screen can attach
/// them without any further platform work.
@immutable
class MailIntent {
  const MailIntent({
    this.to,
    this.cc,
    this.bcc,
    this.subject,
    this.body,
    this.attachmentPaths = const [],
  });

  final String? to;
  final String? cc;
  final String? bcc;
  final String? subject;
  final String? body;
  final List<String> attachmentPaths;

  bool get isEmpty =>
      (to == null || to!.isEmpty) &&
      (cc == null || cc!.isEmpty) &&
      (bcc == null || bcc!.isEmpty) &&
      (subject == null || subject!.isEmpty) &&
      (body == null || body!.isEmpty) &&
      attachmentPaths.isEmpty;

  Map<String, dynamic> toComposeExtra() => <String, dynamic>{
        if (to != null) 'prefillTo': to,
        if (cc != null) 'prefillCc': cc,
        if (subject != null) 'prefillSubject': subject,
        if (body != null) 'prefillBody': body,
      };

  static MailIntent? fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) return null;
    final attachments = (map['attachmentPaths'] as List?)
            ?.cast<Object?>()
            .map((e) => e?.toString())
            .whereType<String>()
            .toList() ??
        const <String>[];
    final intent = MailIntent(
      to: map['to'] as String?,
      cc: map['cc'] as String?,
      bcc: map['bcc'] as String?,
      subject: map['subject'] as String?,
      body: map['body'] as String?,
      attachmentPaths: attachments,
    );
    return intent.isEmpty ? null : intent;
  }
}

/// Bridge between Android's mail-handling intents and the Flutter app.
///
/// Wires up two platform channels and pushes any incoming compose intent
/// onto the running [GoRouter] so the user lands directly on `/compose`
/// with the prefilled fields.
class MailIntentHandler {
  MailIntentHandler({GoRouter? router}) : _router = router;

  GoRouter? _router;
  StreamSubscription<dynamic>? _eventSub;

  void attach(GoRouter router) {
    _router = router;
  }

  /// Initialise the bridge: process a cold-start intent (if any) and listen
  /// for warm-start intents on the event channel. Safe to call from `main`
  /// on platforms without the plugin (no-op on non-Android, and any channel
  /// failure is swallowed so a missing bridge never crashes startup).
  Future<void> initialize() async {
    if (!_isAndroid()) return;
    try {
      final initial = await methodChannel
          .invokeMapMethod<dynamic, dynamic>('getInitialIntent');
      final parsed = MailIntent.fromMap(initial);
      if (parsed != null) _dispatch(parsed);
    } on MissingPluginException {
      // Plugin not registered (unit/widget tests, older Flutter engines).
      return;
    } catch (e, st) {
      log('mail-intent: getInitialIntent failed', error: e, stackTrace: st);
    }

    _eventSub ??= eventChannel.receiveBroadcastStream().listen(
      (event) {
        final parsed = MailIntent.fromMap(event as Map?);
        if (parsed != null) _dispatch(parsed);
      },
      onError: (Object e, StackTrace st) {
        log('mail-intent: event channel error', error: e, stackTrace: st);
      },
    );
  }

  void dispose() {
    unawaited(_eventSub?.cancel());
    _eventSub = null;
  }

  void _dispatch(MailIntent intent) {
    final router = _router;
    if (router == null) return;
    unawaited(router.push('/compose', extra: intent.toComposeExtra()));
  }

  /// Whether the Android platform channel should be used. Tests override
  /// this to exercise the Android branch on non-Android hosts.
  @visibleForTesting
  static bool Function() isAndroidForTest = () => !kIsWeb && Platform.isAndroid;

  static bool _isAndroid() => isAndroidForTest();

  /// Method channel for the cold-start intent. Exposed for tests so they
  /// can install a mock handler.
  @visibleForTesting
  static const MethodChannel methodChannel = MethodChannel(
    'sharedinbox/mail_intent',
  );

  /// Event channel for warm-start intents (delivered via `onNewIntent`).
  @visibleForTesting
  static const EventChannel eventChannel = EventChannel(
    'sharedinbox/mail_intent_events',
  );
}

/// Builds a [MailIntent] from a raw `mailto:` URI string. Used by tests and
/// by any caller that wants to drive the compose screen from a `mailto:`
/// link without going through the platform bridge (e.g. desktop in the
/// future).
MailIntent? mailIntentFromMailtoString(String mailto) {
  final uri = Uri.tryParse(mailto);
  if (uri == null) return null;
  final fields = parseMailto(uri);
  if (fields == null) return null;
  return MailIntent(
    to: fields.to,
    cc: fields.cc,
    bcc: fields.bcc,
    subject: fields.subject,
    body: fields.body,
  );
}
