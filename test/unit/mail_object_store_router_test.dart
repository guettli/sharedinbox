import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
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
    if (invocation.memberName == #observeConflicts) {
      return const Stream<List<ConflictItem>>.empty();
    }
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
      await swallow(() => router.recordHighWater(id));
      await swallow(() => router.delete(id, 'h'));
      await swallow(() => router.appendRaw(id, Uint8List(0)));
      await swallow(() => router.deleteRaw(id, '<m@x>'));
      await swallow(() => router.itemHmacOf(id, 'c', 'i'));
      await swallow(() => router.resolve(id, 'h', keep: Hlc(1, 0, 'd')));
      await swallow(() => router.keepAll(id, 'h', keep: Hlc(1, 0, 'd')));
    }
    await swallow(() => router.open(_object));
    await swallow(() => router.fetchBody(_object));
    await swallow(() => router.put('j', testObject()));
    await swallow(
      () => router.putCovering('j', testObject(), covered: const []),
    );
    router.observe('j', MailObjectFolder.data);
    router.observeConflicts('j');
    await swallow(() => router.rowsOfKind('j', 'blob'));

    const perAccount = [
      'sync',
      'reopen',
      'item',
      'clockFor',
      'recordHighWater',
      'delete',
      'appendRaw',
      'deleteRaw',
      'itemHmacOf',
      'resolve',
      'keepAll',
    ];
    expect(
      imap.calls,
      [
        ...perAccount,
        ...perAccount,
        'observe',
        'observeConflicts',
        'rowsOfKind',
      ],
    );
    expect(
      jmap.calls,
      [...perAccount, 'open', 'fetchBody', 'put', 'putCovering'],
    );
  });
}
