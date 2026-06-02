import 'dart:convert';

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:http/http.dart' as http;
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/imap/managesieve_client.dart';

typedef ImapConnectForTestFn =
    Future<imap.ImapClient> Function(Account, String username, String password);

typedef SmtpConnectForTestFn =
    Future<imap.SmtpClient> Function(Account, String username, String password);

typedef ManageSieveConnectForTestFn =
    Future<ManageSieveClient> Function({
      required String host,
      required int port,
      required bool useTls,
    });

Future<ManageSieveClient> _defaultManageSieveConnect({
  required String host,
  required int port,
  required bool useTls,
}) => ManageSieveClient.connect(host: host, port: port, useTls: useTls);

abstract class ConnectionTestService {
  /// Verifies credentials and returns the effective username used.
  /// Throws a descriptive [Exception] on failure.
  Future<String> testConnection(Account account, String password);
}

class ConnectionTestServiceImpl implements ConnectionTestService {
  ConnectionTestServiceImpl(
    this._httpClient, {
    ImapConnectForTestFn imapConnect = connectImap,
    SmtpConnectForTestFn smtpConnect = connectSmtp,
    ManageSieveConnectForTestFn manageSieveConnect = _defaultManageSieveConnect,
  }) : _imapConnect = imapConnect,
       _smtpConnect = smtpConnect,
       _manageSieveConnect = manageSieveConnect;

  final http.Client _httpClient;
  final ImapConnectForTestFn _imapConnect;
  final SmtpConnectForTestFn _smtpConnect;
  final ManageSieveConnectForTestFn _manageSieveConnect;

  @override
  Future<String> testConnection(Account account, String password) async {
    switch (account.type) {
      case AccountType.imap:
        final username = await _testImap(account, password);
        // Also verify SMTP — without this, send-mail would fail later with
        // no warning at account-edit time.
        await _testSmtp(account, username, password);
        // ManageSieve is opt-in: only test it if the user has explicitly
        // filled in the host (the section is collapsed by default).
        if (account.manageSieveHost.trim().isNotEmpty) {
          await _testManageSieve(account, username, password);
        }
        return username;
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

  Future<void> _testSmtp(
    Account account,
    String username,
    String password,
  ) async {
    final imap.SmtpClient client;
    try {
      client = await _smtpConnect(account, username, password);
    } catch (e) {
      throw Exception('SMTP: $e');
    }
    try {
      await client.quit();
    } catch (_) {
      /* best-effort */
    }
  }

  Future<void> _testManageSieve(
    Account account,
    String username,
    String password,
  ) async {
    final host = account.manageSieveHost.trim().isNotEmpty
        ? account.manageSieveHost.trim()
        : account.imapHost;
    final ManageSieveClient client;
    try {
      client = await _manageSieveConnect(
        host: host,
        port: account.manageSievePort,
        useTls: account.manageSieveSsl,
      );
    } catch (e) {
      throw Exception('ManageSieve: $e');
    }
    try {
      await client.authenticatePlain(username, password);
    } catch (e) {
      try {
        await client.logout();
      } catch (_) {
        /* best-effort */
      }
      throw Exception('ManageSieve: $e');
    }
    try {
      await client.logout();
    } catch (_) {
      /* best-effort */
    }
  }

  Future<String> _testJmap(Account account, String password) async {
    final jmapUrl = account.jmapUrl;
    if (jmapUrl == null || jmapUrl.isEmpty) {
      throw Exception('No JMAP URL configured for this account');
    }
    final sessionUri = Uri.parse(jmapUrl);
    final candidates = _usernamesFor(account);
    Object? lastError;
    for (final username in candidates) {
      try {
        final credentials = base64.encode(utf8.encode('$username:$password'));
        final resp = await _httpClient
            .get(sessionUri, headers: {'Authorization': 'Basic $credentials'})
            .timeout(const Duration(seconds: 10));
        if (resp.statusCode == 401 || resp.statusCode == 403) {
          lastError = Exception(
            'Authentication failed: wrong username or password',
          );
          continue;
        }
        if (resp.statusCode != 200) {
          throw Exception('Connection failed (HTTP ${resp.statusCode})');
        }
        final Map<String, dynamic> session;
        try {
          session = jsonDecode(resp.body) as Map<String, dynamic>;
        } on FormatException {
          throw Exception(
            'Not a JMAP server — unexpected response from $jmapUrl',
          );
        }
        final caps = session['capabilities'];
        if (caps is! Map || !caps.containsKey('urn:ietf:params:jmap:core')) {
          throw Exception(
            'Not a JMAP server — missing core capability at $jmapUrl',
          );
        }
        return username;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError!;
  }
}
