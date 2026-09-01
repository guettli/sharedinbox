import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:sharedinbox/core/utils/logger.dart';
import 'package:unifiedpush/unifiedpush.dart';

/// Instance identifier passed to `UnifiedPush.register`. We register a single
/// device-wide instance and treat every incoming push as "something happened,
/// re-sync all accounts" — the relay server doesn't need to know per-account
/// endpoints, which keeps deployment trivial.
const _kInstance = 'sharedinbox';

/// Callback invoked when a push wake-up arrives. The app uses this to kick
/// the [AccountSyncManager] so every account runs an immediate IMAP fetch.
typedef OnPushKick = void Function();

/// Thin wrapper around the [`unifiedpush`](https://unifiedpush.org) Flutter
/// connector.
///
/// Owns the lifecycle of a single instance registration and bridges
/// distributor events to the rest of the app:
///
/// * `onNewEndpoint` → stored on this object so the UI can show it / users
///   can copy it to their relay configuration.
/// * `onMessage` → fires [_onPushKick] (typically `AccountSyncManager.syncAll`)
///   and shows a local "new mail" notification immediately so the user gets
///   feedback even if the IMAP fetch is slow.
///
/// All public methods are safe to call on platforms where UnifiedPush has no
/// distributor (desktop) or where the plugin channel is absent (unit tests):
/// failures are caught and treated as "feature unavailable".
class UnifiedPushService {
  UnifiedPushService({OnPushKick? onPushKick}) : _onPushKick = onPushKick;

  final OnPushKick? _onPushKick;

  String? _endpoint;
  String? _lastError;
  bool _initialized = false;

  final _statusCtrl = StreamController<UnifiedPushStatus>.broadcast();

  /// Current push endpoint URL once the distributor has issued one.
  /// `null` before registration succeeds or when no distributor is available.
  String? get endpoint => _endpoint;

  /// Last registration error reported by the distributor, if any.
  String? get lastError => _lastError;

  /// Emits whenever the endpoint, distributor, or error state changes.
  Stream<UnifiedPushStatus> watch() => _statusCtrl.stream;

  /// Returns true on platforms where UnifiedPush can plausibly work.
  /// We only attempt initialization on Android — Linux requires a DBus name
  /// that's app-specific and out of scope for v1.
  bool get isSupported => Platform.isAndroid;

  /// Initialize the connector and, if a distributor is already saved, register
  /// to receive push events. Idempotent.
  Future<void> initialize() async {
    if (_initialized || !isSupported) return;
    try {
      await UnifiedPush.initialize(
        onNewEndpoint: _handleNewEndpoint,
        onRegistrationFailed: _handleRegistrationFailed,
        onUnregistered: _handleUnregistered,
        onMessage: _handleMessage,
      );
      _initialized = true;
      // If the user already chose a distributor in a previous session, the
      // plugin remembers it; re-registering returns the same endpoint.
      final hasSaved = await UnifiedPush.getDistributor();
      if (hasSaved != null && hasSaved.isNotEmpty) {
        await UnifiedPush.register(instance: _kInstance);
      }
    } on MissingPluginException {
      // Plugin not registered (running in a unit test or on an unsupported
      // platform). Silently disable; the UI shows "Unavailable".
    } on PlatformException catch (e) {
      _lastError = 'Initialize failed: ${e.message ?? e.code}';
      _emit();
    } catch (e) {
      _lastError = 'Initialize failed: $e';
      _emit();
    }
  }

  /// Returns the list of distributor app IDs installed on the device.
  /// Empty when no UnifiedPush distributor is installed or the plugin is not
  /// available.
  Future<List<String>> getDistributors() async {
    if (!isSupported) return const [];
    try {
      return await UnifiedPush.getDistributors();
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// Returns the currently-saved distributor app ID, or null.
  Future<String?> getDistributor() async {
    if (!isSupported) return null;
    try {
      return await UnifiedPush.getDistributor();
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Save [distributor] as the chosen one and request a new registration.
  /// The endpoint arrives asynchronously via [_handleNewEndpoint].
  Future<void> pickDistributor(String distributor) async {
    if (!isSupported) return;
    try {
      await UnifiedPush.saveDistributor(distributor);
      await UnifiedPush.register(instance: _kInstance);
      _lastError = null;
      _emit();
    } on MissingPluginException {
      _lastError = 'UnifiedPush plugin unavailable on this device';
      _emit();
    } on PlatformException catch (e) {
      _lastError = 'Register failed: ${e.message ?? e.code}';
      _emit();
    }
  }

  /// Cancel the current registration. The distributor is forgotten and the
  /// endpoint cleared.
  Future<void> unregister() async {
    if (!isSupported) return;
    try {
      await UnifiedPush.unregister(_kInstance);
      _endpoint = null;
      _lastError = null;
      _emit();
    } on MissingPluginException {
      // Same defensive behaviour as initialize().
    } on PlatformException catch (e) {
      _lastError = 'Unregister failed: ${e.message ?? e.code}';
      _emit();
    }
  }

  /// Tear down the broadcast controller. Call from `Provider.onDispose`.
  void dispose() {
    unawaited(_statusCtrl.close());
  }

  // Internal: called from `UnifiedPush.initialize` callbacks.
  void _handleNewEndpoint(PushEndpoint endpoint, String instance) {
    _endpoint = endpoint.url;
    _lastError = null;
    _emit();
  }

  void _handleRegistrationFailed(FailedReason reason, String instance) {
    _lastError = 'Registration failed: ${reason.name}';
    _emit();
  }

  void _handleUnregistered(String instance) {
    _endpoint = null;
    _emit();
  }

  void _handleMessage(PushMessage message, String instance) {
    // Empty / opaque wake-up — the relay does not send mail content. The kick
    // triggers a sync; any resulting popups come from the notification
    // dispatcher (gated by the account's rules), so the wake-up itself is
    // silent instead of firing a generic "Push wake-up" notification.
    log('UnifiedPush message received for $instance');
    _onPushKick?.call();
  }

  void _emit() {
    if (_statusCtrl.isClosed) return;
    _statusCtrl.add(
      UnifiedPushStatus(endpoint: _endpoint, error: _lastError),
    );
  }
}

/// Immutable snapshot of the current UnifiedPush registration state, emitted
/// by [UnifiedPushService.watch].
class UnifiedPushStatus {
  const UnifiedPushStatus({this.endpoint, this.error});
  final String? endpoint;
  final String? error;
}
