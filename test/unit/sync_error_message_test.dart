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

import 'package:enough_mail/enough_mail.dart' show ImapClient, ImapException;
import 'package:sharedinbox/core/net/connection_lost_exception.dart';
import 'package:sharedinbox/core/sync/account_sync_manager.dart'
    show syncErrorDetail, syncErrorMessage, syncErrorKey;
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

    // enough_mail reports its own response timeout as ImapException('timeout'),
    // e.g. LOGIN or SELECT on a blackholed connection. It is the same
    // transient "server did not answer" case, not a raw error to show.
    test("maps enough_mail's ImapException('timeout') like a timeout", () {
      final client = ImapClient();
      expect(
        syncErrorMessage(ImapException(client, 'timeout')),
        syncErrorMessage(TimeoutException('too slow')),
      );
      expect(
        syncErrorMessage(ImapException(client, 'NO [AUTHENTICATIONFAILED]')),
        'NO [AUTHENTICATIONFAILED]',
        reason: 'a NO/BAD reply stays as the server sent it',
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

    // #1224: a connection the phone dropped mid-sync is neither a slow
    // server nor an unreachable one.
    test('reports a lost connection as such', () {
      const lost = ConnectionLostException(
        'Connection to the mail server lost',
        osError: OSError('Software caused connection abort', 103),
      );
      final message = syncErrorMessage(lost);
      expect(message, contains('Lost the connection'));
      expect(message, isNot(contains('did not answer in time')));
      expect(message, isNot(contains('Could not reach')));
      expect(message.length, lessThan(120));
      expect(syncErrorKey(message), 'connection-lost');
    });

    test('leaves non-transient errors untouched', () {
      final error = Exception('invalid credentials');
      expect(syncErrorMessage(error), error.toString());
      expect(syncErrorMessage(StateError('bad state')), contains('bad state'));
    });
  });

  group('syncErrorKey', () {
    // The bug this key exists for: a partial cycle's message embeds the
    // failing folder names and count, so dismissing the banner by raw text
    // meant it re-appeared the moment a different folder failed. All partial
    // messages must share one key regardless of which folders are named.
    test('partial-failure messages are folder-name invariant per cause', () {
      // Same cause, different folder sets -> same key, so dismissing one does
      // not re-pop when the failing folders shift. This is the bug the key
      // exists to fix.
      const a = '2 of 7 folders failed (Archive, Sent): '
          'Could not reach the mail server — temporary network or DNS '
          'problem. Will retry automatically.';
      const b = '3 of 7 folders failed (Archive, Drafts, Spam): '
          'Could not reach the mail server — temporary network or DNS '
          'problem. Will retry automatically.';
      expect(syncErrorKey(a), 'partial:unreachable');
      expect(syncErrorKey(a), syncErrorKey(b));
    });

    test('a partial folds in its cause, so transient and persistent differ',
        () {
      const transient = '2 of 7 folders failed (Archive): Could not reach the '
          'mail server — temporary network or DNS problem. Will retry '
          'automatically.';
      const persistent = '1 of 7 folders failed (Archive): '
          'Authentication failed (HTTP 403)';
      expect(syncErrorKey(transient), 'partial:unreachable');
      expect(syncErrorKey(persistent), 'partial:other');
      expect(
        syncErrorKey(transient),
        isNot(syncErrorKey(persistent)),
        reason: 'dismissing a transient partial must not suppress a serious '
            'one, which never recovers to clear the dismissal',
      );
    });

    test('maps the transient hints to stable keys', () {
      expect(
        syncErrorKey(syncErrorMessage(TimeoutException('x'))),
        'timeout',
      );
      expect(
        syncErrorKey(
          syncErrorMessage(const SocketException('Connection refused')),
        ),
        'unreachable',
      );
    });

    test('keeps a one-off error distinct by its full text', () {
      final a = syncErrorMessage(Exception('mailbox locked'));
      final b = syncErrorMessage(Exception('quota exceeded'));
      expect(syncErrorKey(a), isNot(syncErrorKey(b)));
      expect(syncErrorKey(a), a);
    });

    // Drift guard: if syncErrorMessage is reworded without updating
    // syncErrorKey, the transient hints would fall through to their full text
    // and the banner-dismiss grouping would silently break.
    test('the transient hints do not fall through to full-text keys', () {
      for (final e in <Object>[
        TimeoutException('x'),
        const SocketException('Failed host lookup'),
        const HandshakeException('tls'),
      ]) {
        final message = syncErrorMessage(e);
        expect(
          syncErrorKey(message),
          isNot(message),
          reason: 'a transient error must map to a short class, not its text',
        );
      }
    });
  });

  group('syncErrorDetail', () {
    test('keeps the raw exception the friendly hint hides', () {
      const error = SocketException(
        "Failed host lookup: 'imap.gmail.com'",
        osError: OSError('No address associated with hostname', 7),
      );
      final trace = StackTrace.fromString('#0 connect (x.dart:1)');
      final detail = syncErrorDetail(error, trace);
      expect(detail, startsWith('SocketException: Failed host lookup'));
      expect(detail, contains('errno = 7'));
      expect(detail, endsWith('#0 connect (x.dart:1)'));
    });

    test('keeps the raw exception behind the timeout hint', () {
      final trace = StackTrace.fromString('#0 fetch (x.dart:1)');
      final detail = syncErrorDetail(
        TimeoutException('no answer', const Duration(seconds: 20)),
        trace,
      );
      expect(detail, startsWith('TimeoutException after 0:00:20.000000'));
      expect(detail, endsWith('#0 fetch (x.dart:1)'));
    });

    test('strips credentials embedded in a URL', () {
      final detail = syncErrorDetail(
        HttpException(
          'Connection closed',
          uri: Uri.parse('https://alice:s3cret@jmap.example.com/session'),
        ),
        StackTrace.empty,
      );
      expect(detail, contains('https://jmap.example.com/session'));
      expect(detail, isNot(contains('s3cret')));
      expect(detail, isNot(contains('alice')));
    });

    test('does not repeat an error already shown verbatim', () {
      final trace = StackTrace.fromString('#0 sync (x.dart:1)');
      expect(syncErrorDetail(StateError('boom'), trace), '#0 sync (x.dart:1)');
    });
  });
}
