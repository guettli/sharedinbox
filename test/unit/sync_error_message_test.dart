// Regression test for #609:
// A transient DNS failure inside the sync loop (`SocketException: Failed host
// lookup: 'imap.gmail.com' ... errno = 7`) was written verbatim into the Sync
// Entry's error field, which reads like a bug to users whose connection is
// fine. syncErrorMessage now maps transient network failures to a friendly
// hint while leaving other errors untouched.

import 'dart:async';
import 'dart:io';

import 'package:sharedinbox/core/sync/account_sync_manager.dart'
    show syncErrorMessage;
import 'package:test/test.dart';

void main() {
  group('syncErrorMessage', () {
    test('maps a Failed host lookup SocketException to a friendly hint', () {
      const error = SocketException(
        "Failed host lookup: 'imap.gmail.com'",
        osError: OSError('No address associated with hostname', 7),
      );
      final message = syncErrorMessage(error);
      expect(message, isNot(contains('SocketException')));
      expect(message, isNot(contains('errno')));
      expect(message.toLowerCase(), contains('network'));
    });

    test('maps a TimeoutException to the friendly hint', () {
      expect(
        syncErrorMessage(TimeoutException('too slow')),
        isNot(contains('TimeoutException')),
      );
    });

    test('leaves non-transient errors untouched', () {
      final error = Exception('invalid credentials');
      expect(syncErrorMessage(error), error.toString());
      expect(syncErrorMessage(StateError('bad state')), contains('bad state'));
    });
  });
}
