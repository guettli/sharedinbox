import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/sieve_script.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/data/imap/managesieve_client.dart';
import 'package:sharedinbox/data/jmap/jmap_client.dart';

typedef ManageSieveConnectFn = Future<ManageSieveClient> Function({
  required String host,
  required int port,
  required bool useTls,
});

Future<ManageSieveClient> _defaultManageSieveConnect({
  required String host,
  required int port,
  required bool useTls,
}) =>
    ManageSieveClient.connect(host: host, port: port, useTls: useTls);

class SieveRepository {
  SieveRepository(
    this._accounts,
    this._httpClient, {
    ManageSieveConnectFn manageSieveConnect = _defaultManageSieveConnect,
  }) : _manageSieveConnect = manageSieveConnect;

  final AccountRepository _accounts;
  final http.Client _httpClient;
  final ManageSieveConnectFn _manageSieveConnect;

  Future<List<SieveScript>> listScripts(String accountId) async {
    final account = await _requireAccount(accountId);
    if (account.type == AccountType.imap) {
      return _withManageSieve(
        account,
        (c) async {
          final scripts = await c.listScripts();
          return scripts
              .map(
                (s) => SieveScript(
                  id: s.name,
                  name: s.name,
                  blobId: s.name,
                  isActive: s.isActive,
                ),
              )
              .toList();
        },
      );
    }
    return _withJmap(account, (jmap) async {
      final responses = await jmap.call(
        [
          [
            'SieveScript/get',
            {'accountId': jmap.accountId, 'ids': null},
            '0',
          ],
        ],
        withSieve: true,
      );
      final result = _responseArgs(responses, 0, 'SieveScript/get');
      final list = result['list'] as List<dynamic>;
      return list.map((e) {
        final m = e as Map<String, dynamic>;
        return SieveScript(
          id: m['id'] as String,
          name: m['name'] as String,
          blobId: m['blobId'] as String,
          isActive: m['isActive'] as bool? ?? false,
        );
      }).toList();
    });
  }

  Future<String> getScriptContent(String accountId, String blobId) async {
    final account = await _requireAccount(accountId);
    if (account.type == AccountType.imap) {
      // For ManageSieve, blobId is the script name (see listScripts above).
      return _withManageSieve(account, (c) => c.getScript(blobId));
    }
    return _withJmap(account, (jmap) async {
      final bytes = await jmap.downloadBlob(
        blobId,
        name: 'script.sieve',
        type: 'application/sieve',
      );
      return utf8.decode(bytes);
    });
  }

  Future<SieveScript> saveScript(
    String accountId, {
    String? id,
    required String name,
    required String content,
  }) async {
    final account = await _requireAccount(accountId);
    if (account.type == AccountType.imap) {
      return _withManageSieve(account, (c) async {
        await c.putScript(name, content);
        // Renamed: drop the old script.
        if (id != null && id != name) {
          await c.deleteScript(id);
        }
        return SieveScript(
          id: name,
          name: name,
          blobId: name,
          isActive: false,
        );
      });
    }
    return _withJmap(account, (jmap) async {
      final blobId = await jmap.uploadBlob(
        Uint8List.fromList(utf8.encode(content)),
        'application/sieve',
      );
      final Map<String, dynamic> setArgs = id == null
          ? {
              'accountId': jmap.accountId,
              'create': {
                'new': {'name': name, 'blobId': blobId},
              },
            }
          : {
              'accountId': jmap.accountId,
              'update': {
                id: {'name': name, 'blobId': blobId},
              },
            };
      final responses = await jmap.call(
        [
          ['SieveScript/set', setArgs, '0'],
        ],
        withSieve: true,
      );
      final result = _responseArgs(responses, 0, 'SieveScript/set');
      if (id == null) {
        final created = result['created'] as Map<String, dynamic>?;
        final newScript = created?['new'] as Map<String, dynamic>?;
        if (newScript == null) {
          final notCreated = result['notCreated'] as Map<String, dynamic>?;
          final err = notCreated?['new'] as Map<String, dynamic>?;
          throw JmapException(
            'Failed to create script: ${err?['type']} — ${err?['description']}',
          );
        }
        return SieveScript(
          id: newScript['id'] as String? ?? '',
          name: name,
          blobId: blobId,
          isActive: false,
        );
      }
      final notUpdated = result['notUpdated'] as Map<String, dynamic>?;
      if (notUpdated != null && notUpdated.containsKey(id)) {
        final err = notUpdated[id] as Map<String, dynamic>?;
        throw JmapException(
          'Failed to update script: ${err?['type']} — ${err?['description']}',
        );
      }
      return SieveScript(id: id, name: name, blobId: blobId, isActive: false);
    });
  }

  Future<void> deleteScript(String accountId, String scriptId) async {
    final account = await _requireAccount(accountId);
    if (account.type == AccountType.imap) {
      await _withManageSieve(account, (c) async {
        await c.deleteScript(scriptId);
      });
      return;
    }
    await _withJmap(account, (jmap) async {
      final responses = await jmap.call(
        [
          [
            'SieveScript/set',
            {
              'accountId': jmap.accountId,
              'destroy': [scriptId],
            },
            '0',
          ],
        ],
        withSieve: true,
      );
      final result = _responseArgs(responses, 0, 'SieveScript/set');
      final notDestroyed = result['notDestroyed'] as Map<String, dynamic>?;
      if (notDestroyed != null && notDestroyed.containsKey(scriptId)) {
        final err = notDestroyed[scriptId] as Map<String, dynamic>?;
        throw JmapException('Failed to delete script: ${err?['type']}');
      }
    });
  }

  Future<void> activateScript(String accountId, String scriptId) async {
    final account = await _requireAccount(accountId);
    if (account.type == AccountType.imap) {
      await _withManageSieve(account, (c) async {
        await c.setActive(scriptId);
      });
      return;
    }
    await _withJmap(account, (jmap) async {
      await jmap.call(
        [
          [
            'SieveScript/activate',
            {'accountId': jmap.accountId, 'id': scriptId},
            '0',
          ],
        ],
        withSieve: true,
      );
    });
  }

  // ── helpers ───────────────────────────────────────────────────────────────

  Future<Account> _requireAccount(String accountId) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) throw Exception('Account not found');
    return account;
  }

  Future<T> _withJmap<T>(
    Account account,
    Future<T> Function(JmapClient) body,
  ) async {
    final jmapUrl = account.jmapUrl;
    if (jmapUrl == null || jmapUrl.isEmpty) {
      throw Exception('Account has no JMAP URL');
    }
    final password = await _accounts.getPassword(account.id);
    final username =
        account.username.isNotEmpty ? account.username : account.email;
    final jmap = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: username,
      password: password,
    );
    if (!jmap.supportsSieve) {
      throw Exception(
        'Server does not support Sieve (urn:ietf:params:jmap:sieve)',
      );
    }
    return body(jmap);
  }

  Future<T> _withManageSieve<T>(
    Account account,
    Future<T> Function(ManageSieveClient) body,
  ) async {
    final host = account.manageSieveHost.isNotEmpty
        ? account.manageSieveHost
        : account.imapHost;
    if (host.isEmpty) {
      throw Exception('Account has no ManageSieve host configured');
    }
    final password = await _accounts.getPassword(account.id);
    final username =
        account.username.isNotEmpty ? account.username : account.email;
    final client = await _manageSieveConnect(
      host: host,
      port: account.manageSievePort,
      useTls: account.manageSieveSsl,
    );
    try {
      await client.authenticatePlain(username, password);
      return await body(client);
    } finally {
      await client.logout();
    }
  }
}

Map<String, dynamic> _responseArgs(
  List<dynamic> responses,
  int index,
  String expectedMethod,
) {
  final triple = responses[index] as List<dynamic>;
  final method = triple[0] as String;
  if (method == 'error') {
    final err = triple[1] as Map<String, dynamic>;
    throw JmapException('$expectedMethod error: ${err['type']}');
  }
  return triple[1] as Map<String, dynamic>;
}
