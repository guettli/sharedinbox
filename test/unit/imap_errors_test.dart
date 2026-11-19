import 'dart:async';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/data/imap/imap_errors.dart';

import 'fake_imap.dart';

/// A connection whose LIST fails.
class _ListFailsClient extends SelectingFakeImapClient {
  @override
  List<imap.Mailbox> get listedMailboxes => throw StateError('LIST failed');
}

void main() {
  group('isImapConnectionLost', () {
    for (final (name, error, expected) in <(String, Object, bool)>[
      (
        'socket abort',
        const SocketException('Software caused connection abort'),
        true,
      ),
      ('TLS error', const HandshakeException('bad record'), true),
      ('timeout exception', TimeoutException('no answer'), true),
      (
        'enough_mail timeout',
        imap.ImapException(imap.ImapClient(), 'timeout'),
        true
      ),
      (
        'write after close',
        StateError('Cannot add event after closing'),
        true,
      ),
      ('closed IOSink', StateError('StreamSink is closed'), true),
      (
        'server NO',
        imap.ImapException(imap.ImapClient(), 'NO [NONEXISTENT] no mailbox'),
        false,
      ),
      ('unrelated StateError', StateError('MOVE had no effect'), false),
      ('other error', Exception('boom'), false),
    ]) {
      test('$name → $expected', () {
        expect(isImapConnectionLost(error), expected);
      });
    }
  });

  group('isImapPermanentRefusal', () {
    for (final (name, error, expected) in <(String, Object, bool)>[
      (
        'NO [CANNOT]',
        imap.ImapException(imap.ImapClient(), 'NO [CANNOT] not allowed'),
        true,
      ),
      (
        'NO [NOPERM]',
        imap.ImapException(imap.ImapClient(), 'NO [NOPERM] access denied'),
        true,
      ),
      (
        'NO [READ-ONLY]',
        imap.ImapException(imap.ImapClient(), 'NO [READ-ONLY] mailbox'),
        true,
      ),
      (
        'plain NO',
        imap.ImapException(imap.ImapClient(), 'NO server busy'),
        false,
      ),
      (
        'NO [INUSE]',
        imap.ImapException(imap.ImapClient(), 'NO [INUSE] try later'),
        false,
      ),
      ('not an IMAP error', Exception('[CANNOT]'), false),
    ]) {
      test('$name → $expected', () {
        expect(isImapPermanentRefusal(error), expected);
      });
    }
  });

  group('confirmImapMailboxGone', () {
    imap.ImapException no(String text) =>
        imap.ImapException(imap.ImapClient(), text);

    test('NONEXISTENT is definite, without a LIST', () async {
      final client = SelectingFakeImapClient(listedPaths: ['INBOX', 'Work']);
      expect(
        await confirmImapMailboxGone(
          client,
          'Work',
          no('NO [NONEXISTENT] no mailbox'),
        ),
        isTrue,
      );
      expect(client.listCalls, 0);
    });

    test('INBOX is never gone, not even on NONEXISTENT', () async {
      final client = SelectingFakeImapClient(listedPaths: ['Work']);
      for (final path in ['INBOX', 'Inbox']) {
        expect(
          await confirmImapMailboxGone(
            client,
            path,
            no('NO [NONEXISTENT] no mailbox'),
          ),
          isFalse,
        );
        expect(
          await confirmImapMailboxGone(client, path, no('NO not found')),
          isFalse,
        );
      }
      expect(client.listCalls, 0);
    });

    test(
        'a vague error is confirmed by a LIST with INBOX and without the '
        'folder, listed once per connection and folder', () async {
      final client = SelectingFakeImapClient();
      expect(
        await confirmImapMailboxGone(client, 'Work', no('NO not found')),
        isTrue,
      );
      expect(
        await confirmImapMailboxGone(client, 'Work', no('NO not found')),
        isTrue,
      );
      expect(client.listCalls, 1);
    });

    test('a vague error for a listed folder is not confirmed', () async {
      final client = SelectingFakeImapClient(listedPaths: ['INBOX', 'Work']);
      expect(
        await confirmImapMailboxGone(client, 'Work', no('NO not found')),
        isFalse,
      );
    });

    test('a LIST without INBOX, or an empty one, confirms nothing', () async {
      for (final listed in [
        <String>[],
        <String>['Other'],
      ]) {
        final client = SelectingFakeImapClient(listedPaths: listed);
        expect(
          await confirmImapMailboxGone(client, 'Work', no('NO not found')),
          isFalse,
        );
      }
    });

    test('a failed LIST confirms nothing, and is asked again', () async {
      final client = _ListFailsClient();
      expect(
        await confirmImapMailboxGone(client, 'Work', no('NO not found')),
        isFalse,
      );
    });

    test('a lost connection confirms nothing', () async {
      final client = SelectingFakeImapClient();
      expect(
        await confirmImapMailboxGone(
          client,
          'Work',
          const SocketException('connection abort: not found'),
        ),
        isFalse,
      );
      client.fakeConnected = false;
      expect(
        await confirmImapMailboxGone(client, 'Work', no('NO not found')),
        isFalse,
      );
      expect(client.listCalls, 0);
    });

    test('an error that does not read like "no such folder" says nothing',
        () async {
      final client = SelectingFakeImapClient();
      expect(
        await confirmImapMailboxGone(client, 'Work', no('NO server busy')),
        isFalse,
      );
      expect(client.listCalls, 0);
    });
  });
}
