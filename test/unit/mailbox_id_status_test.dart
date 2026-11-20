// The raw `STATUS … (MAILBOXID)` command and its parser (#1315):
// enough_mail 2.1.7 can neither ask for nor parse RFC 8474 MAILBOXID, so
// lib/data/imap/mailbox_id_status.dart does both. Run against a scripted
// IMAP server over a real socket, through the app's own connectImap.

import 'dart:convert';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/imap/mailbox_id_status.dart';
import 'package:test/test.dart';

Account _account(int port) => Account(
      id: 'status-acc',
      displayName: 'Status Test',
      email: 'user@example.com',
      imapHost: '127.0.0.1',
      imapPort: port,
      imapSsl: false,
      smtpHost: 'smtp.example.com',
    );

/// A server that greets, accepts LOGIN and answers each STATUS with
/// [answer] (untagged lines, `\r\n`-terminated, then the tagged reply with
/// [tagged]).
Future<ServerSocket> _server(String answer, {String tagged = 'OK done'}) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) {
    socket.write('* OK [CAPABILITY IMAP4rev1 OBJECTID] ready\r\n');
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final tag = line.split(' ').first;
      if (line.contains('LOGIN')) {
        socket.write('$tag OK LOGIN completed\r\n');
      } else if (line.contains('STATUS')) {
        socket.write('$answer$tag $tagged\r\n');
      } else {
        socket.write('$tag OK\r\n');
      }
    });
  });
  return server;
}

Future<ImapFolderStatus> _ask(
  String answer, {
  String tagged = 'OK done',
}) async {
  final server = await _server(answer, tagged: tagged);
  addTearDown(server.close);
  final client = await connectImap(_account(server.port), 'user', 'secret');
  addTearDown(() => client.disconnect());
  return statusWithMailboxIdFromServer(
    client,
    imap.Mailbox(
      encodedName: 'Work',
      encodedPath: 'Work',
      pathSeparator: '/',
      flags: [],
    ),
    [imap.StatusFlags.messages, imap.StatusFlags.unseen],
  );
}

void main() {
  group('parseStatusLine', () {
    test('reads the counts, the MAILBOXID and the folder name', () {
      expect(
        parseStatusLine(
          'STATUS "Work" (MESSAGES 3 UNSEEN 1 UIDVALIDITY 77 '
          'MAILBOXID (eaaaaah))',
        ),
        (
          mailbox: 'Work',
          status: (
            messages: 3,
            unseen: 1,
            uidValidity: 77,
            mailboxId: 'eaaaaah',
          ),
        ),
      );
    });

    test('items in any case (RFC 3501: case-insensitive)', () {
      expect(
        parseStatusLine('status Work (messages 4 unseen 2 mailboxid (F7))'),
        (
          mailbox: 'Work',
          status: (messages: 4, unseen: 2, uidValidity: null, mailboxId: 'F7'),
        ),
      );
    });

    test('a quoted name with escapes; a name that looks like items', () {
      expect(
        parseStatusLine(r'STATUS "a \"b\" \\c" (MESSAGES 1)')?.mailbox,
        r'a "b" \c',
      );
      expect(
        parseStatusLine('STATUS "MESSAGES 9 (x)" (MAILBOXID (F1))')?.status,
        (messages: 0, unseen: 0, uidValidity: null, mailboxId: 'F1'),
      );
    });

    test('no MAILBOXID, a literal name, or no STATUS response', () {
      expect(
        parseStatusLine('STATUS INBOX (MESSAGES 2)')?.status.mailboxId,
        isNull,
      );
      expect(parseStatusLine('STATUS {4} (MESSAGES 2)')?.mailbox, isNull);
      expect(parseStatusLine('LIST () "/" "INBOX"'), isNull);
    });
  });

  group('statusWithMailboxIdFromServer', () {
    test('sends STATUS with MAILBOXID and reads the answer', () async {
      expect(
        await _ask('* STATUS "Work" (MESSAGES 2 UNSEEN 1 MAILBOXID (F9))\r\n'),
        (messages: 2, unseen: 1, uidValidity: null, mailboxId: 'F9'),
      );
    });

    test('lowercase items', () async {
      expect(
        await _ask('* status "Work" (messages 5 unseen 0 mailboxid (F2))\r\n'),
        (messages: 5, unseen: 0, uidValidity: null, mailboxId: 'F2'),
      );
    });

    test('a literal folder name', () async {
      expect(
        await _ask('* STATUS {4}\r\nWork (MESSAGES 3 MAILBOXID (F4))\r\n'),
        (messages: 3, unseen: 0, uidValidity: null, mailboxId: 'F4'),
      );
    });

    test('other untagged lines around it, another folder\'s STATUS too',
        () async {
      expect(
        await _ask(
          '* STATUS "Other" (MESSAGES 9 MAILBOXID (F0))\r\n'
          '* 4 EXISTS\r\n'
          '* STATUS "Work" (MESSAGES 1 MAILBOXID (F5))\r\n'
          '* STATUS "Work" (MESSAGES 7 MAILBOXID (F6))\r\n',
        ),
        (messages: 1, unseen: 0, uidValidity: null, mailboxId: 'F5'),
      );
    });

    test('OK without a STATUS answer fails: not an empty folder', () async {
      await expectLater(
        _ask('* 4 EXISTS\r\n'),
        throwsA(
          isA<imap.ImapException>().having(
            (e) => '$e',
            'message',
            contains('without a STATUS response'),
          ),
        ),
      );
    });

    test('a NO or BAD answer fails', () async {
      await expectLater(
        _ask('', tagged: 'NO [NONEXISTENT] Mailbox does not exist'),
        throwsA(isA<imap.ImapException>()),
      );
      await expectLater(
        _ask('', tagged: 'BAD Unknown STATUS item'),
        throwsA(isA<imap.ImapException>()),
      );
    });
  });
}
