import 'dart:convert';

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:http/http.dart' as http;

import '../models/account.dart';
import '../../data/imap/imap_client_factory.dart';

typedef ImapConnectForTestFn = Future<imap.ImapClient> Function(
    Account, String username, String password);

abstract class ConnectionTestService {
  /// Verifies credentials and returns the effective username used.
  /// Throws a descriptive [Exception] on failure.
  Future<String> testConnection(Account account, String password);
}

class ConnectionTestServiceImpl implements ConnectionTestService {
  ConnectionTestServiceImpl(
    this._httpClient, {
    ImapConnectForTestFn imapConnect = connectImap,
  }) : _imapConnect = imapConnect;

  final http.Client _httpClient;
  final ImapConnectForTestFn _imapConnect;

  @override
  Future<String> testConnection(Account account, String password) async {
    switch (account.type) {
      case AccountType.imap:
        return _testImap(account, password);
      case AccountType.jmap:
        return _testJmap(account, password);
    }
  }

  /// Returns the username candidates to try in order.
  /// If [account.username] is non-empty it's the only candidate.
  /// Otherwise: full email first, then the local part before '@'.
  List<String> _usernamesFor(Account account) {
    if (account.username.isNotEmpty) return [account.username];
    final email = account.email;
    final atIdx = email.indexOf('@');
    if (atIdx <= 0) return [email];
    final localPart = email.substring(0, atIdx);
    return [email, localPart];
  }

  Future<String> _testImap(Account account, String password) async {
    final candidates = _usernamesFor(account);
    Object? lastError;
    for (final username in candidates) {
      try {
        final client = await _imapConnect(account, username, password);
        await client.logout();
        return username;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError!;
  }

  Future<String> _testJmap(Account account, String password) async {
    final candidates = _usernamesFor(account);
    Object? lastError;
    for (final username in candidates) {
      try {
        final atIdx = account.email.indexOf('@');
        final domain =
            atIdx >= 0 ? account.email.substring(atIdx + 1) : account.email;
        final sessionUri = Uri.https(domain, '/.well-known/jmap');
        final credentials = base64.encode(utf8.encode('$username:$password'));
        final resp = await _httpClient
            .get(sessionUri, headers: {'Authorization': 'Basic $credentials'})
            .timeout(const Duration(seconds: 10));
        if (resp.statusCode == 401 || resp.statusCode == 403) {
          lastError = Exception('Authentication failed: wrong username or password');
          continue;
        }
        if (resp.statusCode != 200) {
          throw Exception('Connection failed (HTTP ${resp.statusCode})');
        }
        return username;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError!;
  }
}
