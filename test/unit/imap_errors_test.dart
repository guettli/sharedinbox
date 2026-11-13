import 'dart:async';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/data/imap/imap_errors.dart';

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
}
