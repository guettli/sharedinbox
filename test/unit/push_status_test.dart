import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/sync/push_status.dart';

void main() {
  test('every JmapPushStatus value has a stable wireName', () {
    // The `push_status` field written to the app_log is the string identity
    // that the sync-state view reads back — accidentally renaming any of
    // these enum wireNames would silently break that UI, so pin the values.
    expect(JmapPushStatus.connected.wireName, 'connected');
    expect(JmapPushStatus.unsupported.wireName, 'unsupported');
    expect(JmapPushStatus.connectFailed.wireName, 'connect_failed');
    expect(JmapPushStatus.sseFailed.wireName, 'sse_failed');
    expect(JmapPushStatus.sseStatusPrefix.wireName, 'sse_status_');
    expect(JmapPushStatus.closed.wireName, 'closed');
    expect(JmapPushStatus.errored.wireName, 'errored');
  });
}
