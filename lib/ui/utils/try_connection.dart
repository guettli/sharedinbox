import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/di.dart';

/// "Try connection" state shared by the add- and edit-account forms, rendered
/// by `TryConnectionButton` from [tryTesting], [tryOk] and [tryErr].
mixin TryConnectionState<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  bool tryTesting = false;
  String? tryOk;
  String? tryErr;

  /// Clears the result without calling `setState`.
  void resetTryConnection() {
    tryTesting = false;
    tryOk = null;
    tryErr = null;
  }

  /// Tests [buildAccount]'s connection with [password] and stores the message
  /// to show. A failure is logged as `account.test_connection_failed` with the
  /// raw exception; [tryErr] gets the readable [userErrorMessage].
  Future<void> runTryConnection({
    required Account Function() buildAccount,
    required String password,
    required String screen,
    String? accountId,
  }) async {
    setState(() {
      resetTryConnection();
      tryTesting = true;
    });
    String? ok;
    String? err;
    try {
      final result = await ref
          .read(connectionTestServiceProvider)
          .testConnection(buildAccount(), password);
      final warning = result.identityWarning;
      ok = warning != null
          ? 'Connected as ${result.username}\n⚠ $warning'
          : 'Connected as ${result.username}';
    } catch (e, stack) {
      unawaited(
        ref.read(appLoggerProvider).warn(
              'account.test_connection_failed',
              'Connection test failed',
              screen: screen,
              accountId: accountId,
              error: e,
              stack: stack,
            ),
      );
      err = userErrorMessage(e);
    }
    if (mounted) {
      setState(() {
        tryTesting = false;
        tryOk = ok;
        tryErr = err;
      });
    }
  }
}
