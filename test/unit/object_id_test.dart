import 'package:enough_mail/enough_mail.dart' as imap;
// ignore: implementation_imports
import 'package:enough_mail/src/private/util/client_base.dart'
    show ConnectionInfo;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/data/imap/object_id.dart';

imap.ImapServerInfo _serverInfo(List<String> capabilities) =>
    imap.ImapServerInfo(
      const ConnectionInfo('fake.host', 993, isSecure: true),
    )..capabilities = [for (final c in capabilities) imap.Capability(c)];

void main() {
  group('resolveObjectIdKind', () {
    test('prefers RFC 8474 OBJECTID EMAILID', () {
      expect(
        resolveObjectIdKind(_serverInfo(['OBJECTID', 'X-GM-EXT-1'])),
        ObjectIdKind.emailId,
      );
    });

    test('falls back to Gmail X-GM-MSGID when only X-GM-EXT-1 is advertised',
        () {
      expect(
        resolveObjectIdKind(_serverInfo(['X-GM-EXT-1'])),
        ObjectIdKind.gmailMsgId,
      );
    });

    test('returns null when neither extension is advertised', () {
      expect(resolveObjectIdKind(_serverInfo(['CONDSTORE'])), isNull);
    });
  });

  group('ObjectIdKind.fetchItem', () {
    test('maps to the FETCH data item names', () {
      expect(ObjectIdKind.emailId.fetchItem, 'EMAILID');
      expect(ObjectIdKind.gmailMsgId.fetchItem, 'X-GM-MSGID');
    });
  });

  group('parseObjectIdLine', () {
    test('parses an EMAILID FETCH line', () {
      final entry = parseObjectIdLine(
        '* 42 FETCH (UID 42 EMAILID (Mabc123))',
        ObjectIdKind.emailId,
      );
      expect(entry, isNotNull);
      expect(entry!.key, 42);
      expect(entry.value, 'Mabc123');
    });

    test('parses regardless of item order', () {
      final entry = parseObjectIdLine(
        '* 7 FETCH (EMAILID (Mzzz) UID 7)',
        ObjectIdKind.emailId,
      );
      expect(entry!.key, 7);
      expect(entry.value, 'Mzzz');
    });

    test('parses a Gmail X-GM-MSGID FETCH line', () {
      final entry = parseObjectIdLine(
        '* 3 FETCH (UID 3 X-GM-MSGID 1278455344230334865)',
        ObjectIdKind.gmailMsgId,
      );
      expect(entry!.key, 3);
      expect(entry.value, '1278455344230334865');
    });

    test('returns null when the requested id is absent', () {
      expect(
        parseObjectIdLine(
          '* 3 FETCH (UID 3 FLAGS (\\Seen))',
          ObjectIdKind.emailId,
        ),
        isNull,
      );
    });

    test('does not confuse EMAILID with the requested Gmail id', () {
      expect(
        parseObjectIdLine(
          '* 3 FETCH (UID 3 EMAILID (M1))',
          ObjectIdKind.gmailMsgId,
        ),
        isNull,
      );
    });

    test('returns null when there is no UID', () {
      expect(
        parseObjectIdLine('* 3 FETCH (EMAILID (M1))', ObjectIdKind.emailId),
        isNull,
      );
    });
  });
}
