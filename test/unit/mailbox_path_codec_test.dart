import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/data/imap/mailbox_path_codec.dart';

import 'fake_imap.dart' show SnoozeSpyImapClient;

void main() {
  group('encodeImapMailboxPath', () {
    test('encodes umlauts to modified UTF-7 (RFC 3501 §5.1.3)', () {
      // ä = U+00E4 -> &AOQ-, ü = U+00FC -> &APw-  (#633)
      expect(
        encodeImapMailboxPath('Geschäftsführer', '/'),
        'Gesch&AOQ-ftsf&APw-hrer',
      );
    });

    test('leaves ASCII paths untouched', () {
      expect(encodeImapMailboxPath('INBOX', '/'), 'INBOX');
      expect(encodeImapMailboxPath('INBOX/Sent', '/'), 'INBOX/Sent');
    });

    test('encodes each segment, keeping separators literal', () {
      // A non-ASCII parent segment must also be encoded, while the '/'
      // separators stay as plain ASCII bytes.
      expect(
        encodeImapMailboxPath('Geschäftsführer/Sub', '/'),
        'Gesch&AOQ-ftsf&APw-hrer/Sub',
      );
      expect(
        encodeImapMailboxPath('Parent/Ordnüng', '/'),
        'Parent/Ordn&APw-ng',
      );
    });

    test('honours a dot hierarchy separator', () {
      expect(
        encodeImapMailboxPath('INBOX.Ordnüng', '.'),
        'INBOX.Ordn&APw-ng',
      );
    });

    test('round-trips back to the Unicode path via enough_mail', () {
      const path = 'Geschäftsführer/Ordnüng';
      final encoded = encodeImapMailboxPath(path, '/');
      final box = imap.Mailbox(
        encodedName: 'x',
        encodedPath: encoded,
        pathSeparator: '/',
        flags: const [],
      );
      expect(box.path, path);
    });
  });

  group('selectUnicodeMailboxByPath', () {
    test('sends the modified-UTF-7 wire path to SELECT', () async {
      final client = SnoozeSpyImapClient();
      await client.selectUnicodeMailboxByPath('Geschäftsführer');
      // Regression guard for #633: the raw Unicode name must never reach the
      // wire — the server rejects `SELECT "Geschäftsführer"` as a bad command.
      expect(client.selectedMailbox, 'Gesch&AOQ-ftsf&APw-hrer');
    });

    test('passes plain ASCII names through unchanged', () async {
      final client = SnoozeSpyImapClient();
      await client.selectUnicodeMailboxByPath('INBOX');
      expect(client.selectedMailbox, 'INBOX');
    });
  });
}
