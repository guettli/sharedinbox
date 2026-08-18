import 'dart:async';

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:http/http.dart' as http;

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/jmap/jmap_client.dart';

typedef ImapConnectForCapabilitiesFn = Future<imap.ImapClient> Function(
  Account,
  String username,
  String password,
);

/// The capabilities a mail server advertises for one account.
class ServerCapabilities {
  const ServerCapabilities({required this.type, required this.capabilities});

  final AccountType type;

  /// Capability tokens, sorted. For IMAP these are the `CAPABILITY` response
  /// tokens (e.g. `IDLE`, `MOVE`, `UIDPLUS`); for JMAP the Session capability
  /// URNs (e.g. `urn:ietf:params:jmap:core`).
  final List<String> capabilities;
}

/// Fetches the capabilities advertised by an account's mail server.
///
/// Live probe — connects, reads what the server supports, disconnects. Nothing
/// is persisted; callers re-fetch whenever the view is opened.
abstract class ServerCapabilitiesService {
  Future<ServerCapabilities> fetch(Account account, String password);
}

class ServerCapabilitiesServiceImpl implements ServerCapabilitiesService {
  ServerCapabilitiesServiceImpl(
    this._httpClient, {
    ImapConnectForCapabilitiesFn imapConnect = connectImap,
  }) : _imapConnect = imapConnect;

  final http.Client _httpClient;
  final ImapConnectForCapabilitiesFn _imapConnect;

  @override
  Future<ServerCapabilities> fetch(Account account, String password) async {
    switch (account.type) {
      case AccountType.imap:
        return _fetchImap(account, password);
      case AccountType.jmap:
        return _fetchJmap(account, password);
    }
  }

  /// The effective login username, mirroring the sync manager: the configured
  /// [Account.username] when set, otherwise the account [Account.email].
  String _username(Account account) =>
      account.username.isNotEmpty ? account.username : account.email;

  Future<ServerCapabilities> _fetchImap(
    Account account,
    String password,
  ) async {
    final client = await _imapConnect(account, _username(account), password);
    try {
      // LOGIN already populates serverInfo.capabilities, but re-issue an
      // explicit CAPABILITY so any post-authentication-only tokens are shown.
      var caps = await client.capability();
      if (caps.isEmpty) {
        caps = client.serverInfo.capabilities ?? const [];
      }
      final names = caps.map((c) => c.name).toSet().toList()..sort();
      return ServerCapabilities(type: AccountType.imap, capabilities: names);
    } finally {
      try {
        await client.logout();
      } catch (_) {
        // best-effort — the probe already has what it needs.
      }
    }
  }

  Future<ServerCapabilities> _fetchJmap(
    Account account,
    String password,
  ) async {
    final jmapUrl = account.jmapUrl;
    if (jmapUrl == null || jmapUrl.isEmpty) {
      throw Exception('No JMAP URL configured for this account');
    }
    final client = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: _username(account),
      password: password,
    );
    final names = client.capabilities.toList()..sort();
    return ServerCapabilities(type: AccountType.jmap, capabilities: names);
  }
}

/// A short, human-readable description for a well-known IMAP capability token
/// or JMAP capability URN, or null when the token is unknown (shown raw only).
String? capabilityDescription(String token) {
  final exact = _capabilityDescriptions[token];
  if (exact != null) return exact;
  if (token.startsWith('AUTH=')) {
    return 'Supported login mechanism (${token.substring('AUTH='.length)}).';
  }
  if (token.startsWith('THREAD=')) {
    return 'Server-side message threading.';
  }
  if (token.startsWith('UTF8=')) {
    return 'Accepts UTF-8 in commands and mailbox names.';
  }
  if (token.startsWith('COMPRESS=')) {
    return 'Connection compression.';
  }
  return null;
}

const _capabilityDescriptions = <String, String>{
  // IMAP
  'IMAP4rev1': 'Core IMAP protocol (RFC 3501).',
  'IMAP4rev2': 'Core IMAP protocol, revision 2 (RFC 9051).',
  'IDLE': 'Push updates — the server notifies of new mail without polling.',
  'MOVE': 'Atomic message move between mailboxes.',
  'UIDPLUS': 'Reports assigned UIDs on copy/move/append.',
  'CONDSTORE': 'Conditional store — track per-message change sequences.',
  'QRESYNC': 'Quick resynchronisation of mailbox changes.',
  'STARTTLS': 'Upgrade a plaintext connection to TLS.',
  'NAMESPACE': 'Advertises personal/shared/other-user namespaces.',
  'ID': 'Exchange client/server identification.',
  'ENABLE': 'Enable optional server extensions.',
  'LITERAL+': 'Non-synchronising literals (faster uploads).',
  'LITERAL-': 'Non-synchronising literals, size-limited.',
  'SORT': 'Server-side sorting of search results.',
  'ESEARCH': 'Extended SEARCH results.',
  'SEARCHRES': 'Reuse the last SEARCH result set.',
  'WITHIN': 'Relative date search (YOUNGER/OLDER).',
  'ACL': 'Per-mailbox access control lists.',
  'QUOTA': 'Report and enforce mailbox quotas.',
  'SPECIAL-USE': 'Advertises special-use mailboxes (Sent, Trash, …).',
  'LIST-EXTENDED': 'Extended LIST command options.',
  'LIST-STATUS': 'Return STATUS data inline with LIST.',
  'BINARY': 'Fetch and append message parts in binary.',
  'CATENATE': 'Build messages server-side from multiple parts.',
  'MULTIAPPEND': 'Append multiple messages in one command.',
  'UNSELECT': 'Close a mailbox without expunging.',
  'CHILDREN': 'Report whether a mailbox has child mailboxes.',
  'SASL-IR': 'Send the initial SASL response with AUTHENTICATE.',
  'LOGINDISABLED': 'Plaintext LOGIN is disabled until TLS is negotiated.',
  // JMAP
  'urn:ietf:params:jmap:core': 'Core JMAP protocol (RFC 8620).',
  'urn:ietf:params:jmap:mail': 'Mailboxes, emails and threads (RFC 8621).',
  'urn:ietf:params:jmap:submission': 'Sending mail (RFC 8621 §7).',
  'urn:ietf:params:jmap:vacationresponse': 'Vacation auto-responder.',
  'urn:ietf:params:jmap:sieve': 'Sieve script management (RFC 9661).',
  'urn:ietf:params:jmap:websocket': 'Push and requests over WebSocket.',
  'urn:ietf:params:jmap:quota': 'Report account quotas.',
  'urn:ietf:params:jmap:contacts': 'Address book / contacts.',
  'urn:ietf:params:jmap:calendars': 'Calendars and events.',
};
