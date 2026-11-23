import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/utils/stream_utils.dart';

void main() {
  test('combineLatest emits once both have, then on every change', () async {
    final a = StreamController<int>();
    final b = StreamController<String>();
    addTearDown(a.close);
    addTearDown(b.close);
    final seen = <String>[];
    final sub =
        combineLatest(a.stream, b.stream, (x, y) => '$x$y').listen(seen.add);
    a.add(1);
    await pumpEventQueue();
    expect(seen, isEmpty);
    b.add('a');
    a.add(2);
    b.add('b');
    await pumpEventQueue();
    expect(seen, ['1a', '2a', '2b']);
    await sub.cancel();
  });

  test('cancelling cancels both, even when one never finishes cancelling',
      () async {
    var bCancelled = false;
    // Its cancel never completes, so neither would its close().
    // ignore: close_sinks
    final a = StreamController<int>(onCancel: () => Completer<void>().future);
    final b = StreamController<int>(onCancel: () => bCancelled = true);
    addTearDown(b.close);
    final sub = combineLatest(a.stream, b.stream, (x, y) => x + y).listen(
      (_) {},
    );
    await pumpEventQueue();
    unawaited(sub.cancel());
    await pumpEventQueue();
    expect(a.hasListener, isFalse);
    expect(bCancelled, isTrue);
    expect(b.hasListener, isFalse);
  });
}
