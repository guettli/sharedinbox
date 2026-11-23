import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_router.dart';

import 'encrypted_objects/test_helpers.dart';
import 'helpers/fake_account_repository.dart';

class _NotAnswered implements Exception {}

/// Records the member each call reached; answers nothing useful.
class _Recording implements MailObjectStore {
  final calls = <String>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    calls.add(name.substring(8, name.length - 2));
    if (invocation.memberName == #observe) {
      return const Stream<List<MailObject>>.empty();
    }
    return Future<Never>.error(_NotAnswered());
  }
}

const _object = MailObject(
  accountId: 'j',
  folder: MailObjectFolder.data,
  messageId: '<m@x>',
);

void main() {
  test('every call goes to the store of the account transport', () async {
    final accounts = FakeAccountRepository(const [
      Account(
        id: 'i',
        displayName: 'I',
        email: 'i@example.com',
        imapHost: 'imap.example.com',
        smtpHost: 'smtp.example.com',
      ),
      Account(
        id: 'j',
        displayName: 'J',
        email: 'j@example.com',
        type: AccountType.jmap,
        jmapUrl: 'https://jmap.example.com',
      ),
    ]);
    final imap = _Recording();
    final jmap = _Recording();
    final router = MailObjectStoreRouter(accounts, imap: imap, jmap: jmap);

    Future<void> swallow(Future<Object?> Function() call) async {
      try {
        await call();
      } on _NotAnswered {
        // The fakes answer nothing.
      }
    }

    for (final id in ['i', 'j', 'gone']) {
      await swallow(() => router.sync(id));
      await swallow(() => router.reopen(id));
      await swallow(() => router.item(id, 'h'));
      await swallow(() => router.clockFor(id));
      await swallow(() => router.delete(id, 'h'));
      await swallow(() => router.appendRaw(id, Uint8List(0)));
      await swallow(() => router.deleteRaw(id, '<m@x>'));
    }
    await swallow(() => router.open(_object));
    await swallow(() => router.fetchBody(_object));
    await swallow(() => router.put('j', testObject()));
    router.observe('j', MailObjectFolder.data);

    const perAccount = [
      'sync',
      'reopen',
      'item',
      'clockFor',
      'delete',
      'appendRaw',
      'deleteRaw',
    ];
    expect(imap.calls, [...perAccount, ...perAccount, 'observe']);
    expect(jmap.calls, [...perAccount, 'open', 'fetchBody', 'put']);
  });
}
