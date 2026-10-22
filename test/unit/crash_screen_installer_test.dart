import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/services/crash_logger.dart';

void main() {
  // #1107: an async error reached FlutterError.onError from the parent zone;
  // runApp there reported a "Zone mismatch" error straight back into onError,
  // which called runApp again, forever.
  test('installs once, in the app zone, even if installing re-reports',
      () async {
    final appZone = Zone.current.fork();
    final installer = CrashScreenInstaller(appZone);
    var calls = 0;
    Zone? ranIn;

    // Stands in for FlutterError.onError: escalates to the crash screen, and
    // the substitute runApp reports a new error back into the handler, as
    // the debug zone check did.
    void onError() {
      installer.install(() {
        calls++;
        ranIn = Zone.current;
        onError();
      });
    }

    Zone.root.run(onError);

    expect(calls, 1);
    expect(ranIn, same(appZone));

    // The guard only blocks re-entry: a later error escalates again.
    Zone.root.run(onError);
    expect(calls, 2);
  });
}
