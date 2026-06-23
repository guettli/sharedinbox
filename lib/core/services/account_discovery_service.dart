import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:sharedinbox/core/models/discovery_result.dart';

abstract class AccountDiscoveryService {
  Future<DiscoveryResult> discover(String email);
}

class AccountDiscoveryServiceImpl implements AccountDiscoveryService {
  AccountDiscoveryServiceImpl(this._client);

  final http.Client _client;

  @override
  Future<DiscoveryResult> discover(String email) async {
    final atIdx = email.indexOf('@');
    if (atIdx < 0) return UnknownDiscovery();
    final domain = email.substring(atIdx + 1).toLowerCase();

    final jmap = await _tryJmap(domain);
    if (jmap != null) return jmap;

    final imap = await _tryImapAutoconfig(domain);
    if (imap != null) return imap;

    final mx = await _tryMxFallback(domain);
    if (mx != null) return mx;

    return UnknownDiscovery();
  }

  Future<JmapDiscovery?> _tryJmap(String domain) async {
    try {
      final url = Uri.https(domain, '/.well-known/jmap');
      final request = http.Request('GET', url)..followRedirects = false;
      final streamed =
          await _client.send(request).timeout(const Duration(seconds: 5));

      String sessionUrl;
      if (streamed.statusCode >= 300 && streamed.statusCode < 400) {
        final location = streamed.headers['location'];
        if (location == null) return null;
        sessionUrl = url.resolve(location).toString();
      } else if (streamed.statusCode == 200) {
        sessionUrl = url.toString();
      } else {
        return null;
      }

      return JmapDiscovery(sessionUrl: sessionUrl);
    } catch (_) {
      return null;
    }
  }

  Future<ImapSmtpDiscovery?> _tryImapAutoconfig(String domain) async {
    final urls = [
      Uri.https('autoconfig.$domain', '/mail/config-v1.1.xml'),
      Uri.https(domain, '/.well-known/autoconfig/mail/config-v1.1.xml'),
    ];
    for (final url in urls) {
      try {
        final resp = await _client.get(url).timeout(const Duration(seconds: 5));
        if (resp.statusCode != 200) continue;
        final result = _parseAutoconfig(resp.body);
        if (result != null) return result;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  ImapSmtpDiscovery? _parseAutoconfig(String xml) {
    final imapBlock = RegExp(
      r'<incomingServer\s+type="imap"[^>]*>([\s\S]*?)</incomingServer>',
    ).firstMatch(xml)?.group(1);

    final smtpBlock = RegExp(
      r'<outgoingServer\s+type="smtp"[^>]*>([\s\S]*?)</outgoingServer>',
    ).firstMatch(xml)?.group(1);

    if (imapBlock == null || smtpBlock == null) return null;

    final imapHost = _tag(imapBlock, 'hostname');
    final imapPort = int.tryParse(_tag(imapBlock, 'port') ?? '') ?? 993;
    final imapSsl = _tag(imapBlock, 'socketType')?.toUpperCase() == 'SSL';

    final smtpHost = _tag(smtpBlock, 'hostname');
    final smtpPort = int.tryParse(_tag(smtpBlock, 'port') ?? '') ?? 587;
    final smtpSsl = _tag(smtpBlock, 'socketType')?.toUpperCase() == 'SSL';

    if (imapHost == null || smtpHost == null) return null;

    return ImapSmtpDiscovery(
      imapHost: imapHost,
      imapPort: imapPort,
      imapSsl: imapSsl,
      smtpHost: smtpHost,
      smtpPort: smtpPort,
      smtpSsl: smtpSsl,
    );
  }

  String? _tag(String block, String tag) =>
      RegExp('<$tag>([^<]+)</$tag>').firstMatch(block)?.group(1)?.trim();

  /// Queries DNS-over-HTTPS for MX records and returns an [ImapSmtpDiscovery]
  /// using the highest-priority MX host with standard ports (IMAP 993/SSL,
  /// SMTP 465/SSL). Used as a last-resort fallback when neither the JMAP
  /// well-known endpoint nor the autoconfig XML was found.
  Future<ImapSmtpDiscovery?> _tryMxFallback(String domain) async {
    try {
      final url = Uri.https('dns.google', '/resolve', {
        'name': domain,
        'type': 'MX',
      });
      final resp = await _client.get(url).timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return null;

      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      if (body['Status'] != 0) return null;

      final answers = (body['Answer'] as List?)?.cast<Map<String, dynamic>>();
      if (answers == null || answers.isEmpty) return null;

      final entries = <MapEntry<int, String>>[];
      for (final a in answers.where((a) => a['type'] == 15)) {
        final parts = (a['data'] as String).trim().split(RegExp(r'\s+'));
        if (parts.length < 2) continue;
        final priority = int.tryParse(parts[0]);
        if (priority == null) continue;
        final host = parts[1].replaceAll(RegExp(r'\.$'), '');
        if (host.isNotEmpty) entries.add(MapEntry(priority, host));
      }
      if (entries.isEmpty) return null;
      entries.sort((a, b) => a.key.compareTo(b.key));
      final host = entries.first.value;

      return ImapSmtpDiscovery(
        imapHost: host,
        imapPort: 993,
        imapSsl: true,
        smtpHost: host,
        smtpPort: 465,
        smtpSsl: true,
      );
    } catch (_) {
      return null;
    }
  }
}
