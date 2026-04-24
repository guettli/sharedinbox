import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/models/account.dart';
import '../../core/models/sieve_script.dart';
import '../../core/repositories/account_repository.dart';
import 'jmap_client.dart';

class SieveRepository {
  SieveRepository(this._accounts, this._httpClient);

  final AccountRepository _accounts;
  final http.Client _httpClient;

  Future<JmapClient> _connect(String accountId) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) throw Exception('Account not found');
    if (account.type != AccountType.jmap) {
      throw Exception('Sieve is only supported on JMAP accounts');
    }
    final jmapUrl = account.jmapUrl;
    if (jmapUrl == null || jmapUrl.isEmpty) {
      throw Exception('Account has no JMAP URL');
    }
    final password = await _accounts.getPassword(accountId);
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
    return jmap;
  }

  Future<List<SieveScript>> listScripts(String accountId) async {
    final jmap = await _connect(accountId);
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
  }

  Future<String> getScriptContent(String accountId, String blobId) async {
    final jmap = await _connect(accountId);
    final bytes = await jmap.downloadBlob(
      blobId,
      name: 'script.sieve',
      type: 'application/sieve',
    );
    return utf8.decode(bytes);
  }

  Future<SieveScript> saveScript(
    String accountId, {
    String? id,
    required String name,
    required String content,
  }) async {
    final jmap = await _connect(accountId);
    final blobId = await jmap.uploadBlob(
      Uint8List.fromList(utf8.encode(content)),
      'application/sieve',
    );

    final Map<String, dynamic> setArgs;
    if (id == null) {
      setArgs = {
        'accountId': jmap.accountId,
        'create': {
          'new': {'name': name, 'blobId': blobId},
        },
      };
    } else {
      setArgs = {
        'accountId': jmap.accountId,
        'update': {
          id: {'name': name, 'blobId': blobId},
        },
      };
    }

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
      final newId = newScript['id'] as String? ?? '';
      return SieveScript(
        id: newId,
        name: name,
        blobId: blobId,
        isActive: false,
      );
    } else {
      final notUpdated = result['notUpdated'] as Map<String, dynamic>?;
      if (notUpdated != null && notUpdated.containsKey(id)) {
        final err = notUpdated[id] as Map<String, dynamic>?;
        throw JmapException(
          'Failed to update script: ${err?['type']} — ${err?['description']}',
        );
      }
      return SieveScript(id: id, name: name, blobId: blobId, isActive: false);
    }
  }

  Future<void> deleteScript(String accountId, String scriptId) async {
    final jmap = await _connect(accountId);
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
  }

  Future<void> activateScript(String accountId, String scriptId) async {
    final jmap = await _connect(accountId);
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
