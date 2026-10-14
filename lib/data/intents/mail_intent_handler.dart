import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
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

  /// Field-by-field summary for the App Log. Only the *shape* of the intent is
  /// recorded (which fields arrived and how long they are) — never the
  /// addresses or the body, so a bug report cannot leak the message.
  Map<String, Object?> get logFields => <String, Object?>{
        'to': to?.length ?? 0,
        'cc': cc?.length ?? 0,
        'bcc': bcc?.length ?? 0,
        'subject': subject?.length ?? 0,
        'body': body?.length ?? 0,
        'attachments': attachmentPaths.length,
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
  MailIntentHandler({GoRouter? router, AppLogger? logger})
      : _router = router,
        _logger = logger;

  GoRouter? _router;
  final AppLogger? _logger;
  StreamSubscription<dynamic>? _eventSub;
  bool _disposed = false;

  void attach(GoRouter router) {
    _router = router;
  }

  /// Initialise the bridge: process a cold-start intent (if any) and listen
  /// for warm-start intents on the event channel. Safe to call from `main`
  /// on platforms without the plugin (no-op on non-Android, and any channel
  /// failure is swallowed so a missing bridge never crashes startup).
  Future<void> initialize() async {
    if (!_isAndroid()) {
      _log('mail_intent.skipped', 'not Android — bridge not started');
      return;
    }
    // Subscribe *before* asking for the cold-start intent: `onNewIntent` can
    // fire while that round-trip is still in flight, and an intent arriving
    // with no listener attached would otherwise be dropped (#862).
    _listen();
    try {
      final initial = await methodChannel
          .invokeMapMethod<dynamic, dynamic>('getInitialIntent');
      final parsed = MailIntent.fromMap(initial);
      _log(
        'mail_intent.cold_start',
        parsed == null
            ? 'no compose intent on the launch intent'
            : 'compose intent on the launch intent',
        data: parsed?.logFields,
      );
      if (parsed != null) _dispatch(parsed, 'cold');
    } on MissingPluginException {
      // Plugin not registered (unit/widget tests, older Flutter engines).
      _log('mail_intent.missing_plugin', 'mail intent bridge not registered');
      return;
    } catch (e, st) {
      log('mail-intent: getInitialIntent failed', error: e, stackTrace: st);
      _log(
        'mail_intent.error',
        'getInitialIntent failed',
        error: e,
        stack: st,
        level: AppLogLevel.warn,
      );
    }
  }

  void _listen() {
    _eventSub ??= eventChannel.receiveBroadcastStream().listen(
      (event) {
        final parsed = MailIntent.fromMap(event as Map?);
        _log(
          'mail_intent.warm_start',
          parsed == null
              ? 'onNewIntent carried no compose fields'
              : 'compose intent via onNewIntent',
          data: parsed?.logFields,
        );
        if (parsed != null) _dispatch(parsed, 'warm');
      },
      onError: (Object e, StackTrace st) {
        log('mail-intent: event channel error', error: e, stackTrace: st);
        _log(
          'mail_intent.error',
          'event channel error',
          error: e,
          stack: st,
          level: AppLogLevel.warn,
        );
      },
    );
  }

  void dispose() {
    _disposed = true;
    unawaited(_eventSub?.cancel());
    _eventSub = null;
  }

  void _dispatch(MailIntent intent, String source) {
    final router = _router;
    if (router == null) {
      _log(
        'mail_intent.dropped',
        'no router attached — cannot open compose',
        level: AppLogLevel.warn,
        data: {'source': source},
      );
      return;
    }
    // Push only once the current frame is done. `initialize()` runs from
    // `initState`, so on a cold start the intent can resolve while the
    // `Router` is still settling its initial route — and that initial route
    // then replaces the imperative push, leaving the user on the inbox
    // instead of the compose screen (#862).
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      if (_disposed) return;
      _log(
        'mail_intent.compose',
        'opening /compose from a $source-start intent',
        data: intent.logFields,
      );
      unawaited(router.push('/compose', extra: intent.toComposeExtra()));
    });
    // A post-frame callback only runs when a frame is actually produced; ask
    // for one in case the app is sitting idle.
    binding.ensureVisualUpdate();
  }

  void _log(
    String event,
    String message, {
    Map<String, Object?>? data,
    Object? error,
    StackTrace? stack,
    AppLogLevel level = AppLogLevel.info,
  }) {
    final logger = _logger;
    if (logger == null) return;
    unawaited(
      logger.log(
        level: level,
        event: event,
        message: message,
        data: data,
        error: error,
        stack: stack,
      ),
    );
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
