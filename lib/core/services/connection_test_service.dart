import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/account.dart';
import '../../data/imap/imap_client_factory.dart';

abstract class ConnectionTestService {
  /// Verifies credentials by opening and immediately closing a connection.
  /// Throws a descriptive [Exception] on failure.
  Future<void> testConnection(Account account, String password);
}

class ConnectionTestServiceImpl implements ConnectionTestService {
  ConnectionTestServiceImpl(this._httpClient);

  final http.Client _httpClient;

  @override
  Future<void> testConnection(Account account, String password) async {
    switch (account.type) {
      case AccountType.imap:
        final client = await connectImap(account, password);
        await client.logout();
      case AccountType.jmap:
        await _testJmap(account.jmapUrl!, account.email, password);
    }
  }

  Future<void> _testJmap(
    String apiUrl,
    String email,
    String password,
  ) async {
    // Derive the JMAP session URL from the email domain. According to RFC 8620,
    // a GET to /.well-known/jmap with Basic auth returns 200 on success and
    // 401 on bad credentials — a reliable login check without a POST.
    final atIdx = email.indexOf('@');
    final domain = atIdx >= 0 ? email.substring(atIdx + 1) : email;
    final sessionUri = Uri.https(domain, '/.well-known/jmap');
    final credentials = base64.encode(utf8.encode('$email:$password'));
    final resp = await _httpClient
        .get(sessionUri, headers: {'Authorization': 'Basic $credentials'})
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw Exception('Authentication failed: wrong email or password');
    }
    if (resp.statusCode != 200) {
      throw Exception('Connection failed (HTTP ${resp.statusCode})');
    }
  }
}
