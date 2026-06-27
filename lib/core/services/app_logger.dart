import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show kDebugMode;

import 'package:sharedinbox/core/repositories/app_log_repository.dart';

/// Application-wide structured logger.
///
/// Each call writes a row to [AppLogRepository] (best-effort — failures are
/// swallowed) and, in debug builds, mirrors to `dart:developer` so entries
/// show up in `flutter logs`.
///
/// Extra fields can be attached via [data]; the map is JSON-encoded with
/// unencodable values fall back to `value.toString()` so the call never throws.
class AppLogger {
  AppLogger(this._repo);

  final AppLogRepository _repo;

  /// Returns a copy of [data] (merged with the optional [error]/[stack]) as a
  /// JSON string, or `null` when nothing extra was supplied. Unencodable
  /// values are converted via `toString()` so callers never have to think
  /// about serialisability.
  static String? encodeData(
    Map<String, Object?>? data, {
    Object? error,
    StackTrace? stack,
  }) {
    if ((data == null || data.isEmpty) && error == null && stack == null) {
      return null;
    }
    final out = <String, Object?>{};
    if (data != null) out.addAll(data);
    if (error != null) out['error'] = error.toString();
    if (stack != null) out['stack'] = stack.toString();
    return jsonEncode(out, toEncodable: (v) => v.toString());
  }

  Future<int?> log({
    required AppLogLevel level,
    required String event,
    required String message,
    Map<String, Object?>? data,
    String? screen,
    String? accountId,
    String? mailboxPath,
    String? emailId,
    int? syncLogId,
    Object? error,
    StackTrace? stack,
  }) async {
    if (kDebugMode) {
      developer.log(
        '[${level.wireName}] $event: $message',
        name: 'sharedinbox',
        error: error,
        stackTrace: stack,
      );
    }
    final encoded = encodeData(data, error: error, stack: stack);
    try {
      return await _repo.insert(
        level: level,
        event: event,
        message: message,
        dataJson: encoded,
        screen: screen,
        accountId: accountId,
        mailboxPath: mailboxPath,
        emailId: emailId,
        syncLogId: syncLogId,
      );
    } catch (_) {
      // Logging is best-effort — a buggy or unavailable repo must never
      // propagate back into the caller.
      return null;
    }
  }

  Future<int?> debug(
    String event,
    String message, {
    Map<String, Object?>? data,
    String? screen,
    String? accountId,
    String? mailboxPath,
    String? emailId,
    int? syncLogId,
  }) =>
      log(
        level: AppLogLevel.debug,
        event: event,
        message: message,
        data: data,
        screen: screen,
        accountId: accountId,
        mailboxPath: mailboxPath,
        emailId: emailId,
        syncLogId: syncLogId,
      );

  Future<int?> info(
    String event,
    String message, {
    Map<String, Object?>? data,
    String? screen,
    String? accountId,
    String? mailboxPath,
    String? emailId,
    int? syncLogId,
  }) =>
      log(
        level: AppLogLevel.info,
        event: event,
        message: message,
        data: data,
        screen: screen,
        accountId: accountId,
        mailboxPath: mailboxPath,
        emailId: emailId,
        syncLogId: syncLogId,
      );

  Future<int?> warn(
    String event,
    String message, {
    Map<String, Object?>? data,
    String? screen,
    String? accountId,
    String? mailboxPath,
    String? emailId,
    int? syncLogId,
    Object? error,
    StackTrace? stack,
  }) =>
      log(
        level: AppLogLevel.warn,
        event: event,
        message: message,
        data: data,
        screen: screen,
        accountId: accountId,
        mailboxPath: mailboxPath,
        emailId: emailId,
        syncLogId: syncLogId,
        error: error,
        stack: stack,
      );

  Future<int?> error(
    String event,
    String message, {
    Map<String, Object?>? data,
    String? screen,
    String? accountId,
    String? mailboxPath,
    String? emailId,
    int? syncLogId,
    Object? error,
    StackTrace? stack,
  }) =>
      log(
        level: AppLogLevel.error,
        event: event,
        message: message,
        data: data,
        screen: screen,
        accountId: accountId,
        mailboxPath: mailboxPath,
        emailId: emailId,
        syncLogId: syncLogId,
        error: error,
        stack: stack,
      );
}
