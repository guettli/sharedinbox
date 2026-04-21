import 'package:enough_mail/enough_mail.dart' as imap;
// ignore: implementation_imports
import 'package:enough_mail/src/private/util/client_base.dart'
    show ConnectionInfo;

/// Minimal fake IMAP client used by connection_test_service_test.dart.
/// Only overrides what is strictly needed to avoid real network calls.
class FakeImapClient extends imap.ImapClient {
  FakeImapClient() : super();

  @override
  final imap.ImapServerInfo serverInfo = imap.ImapServerInfo(
    const ConnectionInfo('fake.host', 993, isSecure: true),
  )..capabilities = [];

  @override
  Future<dynamic> logout() async {}
}
