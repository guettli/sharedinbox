import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';

/// Sends every call to the [MailObjectStore] of the account's transport:
/// [imap] for IMAP accounts, [jmap] for JMAP accounts (#1371). An account
/// is only ever served by one of them, so each store's per-account state
/// (clock, running sync) stays its own.
class MailObjectStoreRouter implements MailObjectStore {
  MailObjectStoreRouter(
    this._accounts, {
    required MailObjectStore imap,
    required MailObjectStore jmap,
  })  : _imap = imap,
        _jmap = jmap;

  final AccountRepository _accounts;
  final MailObjectStore _imap;
  final MailObjectStore _jmap;

  /// The transport of each account seen; it never changes.
  final Map<String, AccountType> _types = {};

  Future<MailObjectStore> _for(String accountId) async {
    var type = _types[accountId];
    if (type == null) {
      final account = await _accounts.getAccount(accountId);
      // An unknown account: both stores do nothing for it.
      if (account == null) return _imap;
      type = _types[accountId] = account.type;
    }
    return type == AccountType.jmap ? _jmap : _imap;
  }

  /// Reads the local rows only, the same for both stores.
  @override
  Stream<List<MailObject>> observe(String accountId, MailObjectFolder folder) =>
      _imap.observe(accountId, folder);

  @override
  Future<void> sync(String accountId) async =>
      (await _for(accountId)).sync(accountId);

  @override
  Future<InnerObject?> open(MailObject object) async =>
      (await _for(object.accountId)).open(object);

  @override
  Future<void> reopen(String accountId) async =>
      (await _for(accountId)).reopen(accountId);

  @override
  Future<MailObjectItem?> item(String accountId, String itemHmac) async =>
      (await _for(accountId)).item(accountId, itemHmac);

  @override
  Future<HlcClock> clockFor(String accountId) async =>
      (await _for(accountId)).clockFor(accountId);

  @override
  Future<MailObject> put(String accountId, InnerObject object) async =>
      (await _for(accountId)).put(accountId, object);

  @override
  Future<MailObject> delete(String accountId, String itemHmac) async =>
      (await _for(accountId)).delete(accountId, itemHmac);

  @override
  Future<MailObject> appendRaw(String accountId, Uint8List mail) async =>
      (await _for(accountId)).appendRaw(accountId, mail);

  @override
  Future<void> deleteRaw(String accountId, String messageId) async =>
      (await _for(accountId)).deleteRaw(accountId, messageId);

  @override
  Future<MailObject?> fetchBody(MailObject object) async =>
      (await _for(object.accountId)).fetchBody(object);
}
