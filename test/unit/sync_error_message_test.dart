// Regression test for #609:
// A transient DNS failure inside the sync loop (`SocketException: Failed host
// lookup: 'imap.gmail.com' ... errno = 7`) was written verbatim into the Sync
// Entry's error field, which reads like a bug to users whose connection is
// fine. syncErrorMessage now maps transient network failures to a friendly
// hint while leaving other errors untouched.
//
// And for #967: a TimeoutException shared that hint, so a server that was
// reached but answered too slowly was reported as unreachable — "temporary
// network or DNS problem". That wording sent a real investigation at DNS
// while the cause was a request the client had made too large to answer in
// time. The two now read differently.

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

    test('maps a TimeoutException to a friendly hint of its own', () {
      final message = syncErrorMessage(TimeoutException('too slow'));
      expect(message, isNot(contains('TimeoutException')));
      expect(
        message.toLowerCase(),
        contains('did not answer in time'),
        reason: 'a slow server must be reported as slow',
      );
    });

    test('does not blame the network for a timeout', () {
      final timeout =
          syncErrorMessage(TimeoutException('too slow')).toLowerCase();
      expect(
        timeout,
        isNot(contains('could not reach')),
        reason: 'the server was reached — saying otherwise misdirects '
            'the next investigation (#967)',
      );
      expect(
        timeout,
        isNot(contains('dns')),
        reason: 'not even to deny it: the words are what readers remember',
      );
      expect(timeout, isNot(contains('network')));
    });

    test('stays short enough for the two-line sync banner', () {
      expect(
        syncErrorMessage(TimeoutException('too slow')).length,
        lessThan(120),
        reason: 'EmailListScreen ellipses the banner after two lines, and '
            'the actionable half is at the end',
      );
    });

    test('a timeout and an unreachable host read differently', () {
      const unreachable = SocketException(
        "Failed host lookup: 'imap.gmail.com'",
        osError: OSError('No address associated with hostname', 7),
      );
      expect(
        syncErrorMessage(TimeoutException('too slow')),
        isNot(syncErrorMessage(unreachable)),
      );
    });

    test('still keeps an unreachable host on the original hint', () {
      const unreachable = SocketException('Connection refused');
      expect(syncErrorMessage(unreachable), contains('Could not reach'));
    });

    test('leaves non-transient errors untouched', () {
      final error = Exception('invalid credentials');
      expect(syncErrorMessage(error), error.toString());
      expect(syncErrorMessage(StateError('bad state')), contains('bad state'));
    });
  });
}
