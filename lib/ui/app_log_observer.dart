import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:sharedinbox/core/services/app_logger.dart';

/// NavigatorObserver that emits a `ui.screen.enter` debug log every time a
/// route is pushed. The logger is set after [ProviderScope] has been built
/// (see `main.dart`); until then events are silently dropped — never logging
/// during early startup avoids needing a container before `runApp()`.
class AppLogNavigatorObserver extends NavigatorObserver {
  AppLogger? logger;

  void _log(String event, Route<dynamic>? route) {
    final l = logger;
    if (l == null || route == null) return;
    final name = route.settings.name ?? route.runtimeType.toString();
    unawaited(
      l.debug('ui.$event', name, screen: name),
    );
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _log('screen.enter', route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _log('screen.enter', newRoute);
  }
}
