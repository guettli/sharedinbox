// refreshThreadAggregate keys a thread `threadId ?? id`, as its callers do:
// a row without a thread id is the thread named by its own id (#1328).

import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/thread_aggregate.dart';

import 'db_test_helper.dart';

void main() {
  setUpAll(configureSqliteForTests);

  late AppDatabase db;
  setUp(() async {
    db = openTestDatabase();
    await seedAccountRow(db, 'acc');
  });
  tearDown(() => db.close());

  Future<void> insert(
    String id, {
    String? threadId,
    String mailboxPath = 'INBOX',
    required int day,
  }) =>
      db.into(db.emails).insert(
            EmailsCompanion.insert(
              id: id,
              accountId: 'acc',
              mailboxPath: mailboxPath,
              uid: day,
              receivedAt: DateTime.utc(2026, 1, day),
              threadId: Value(threadId),
              subject: Value('Mail $id'),
            ),
          );

  Future<ThreadRow?> thread(String id, {String mailboxPath = 'INBOX'}) =>
      (db.select(db.threads)
            ..where((t) => t.id.equals(id) & t.mailboxPath.equals(mailboxPath)))
          .getSingleOrNull();

  List<String> idsOf(ThreadRow row) =>
      List<String>.from(jsonDecode(row.emailIdsJson) as List);

  test('a row without a thread id is the thread of its own id', () async {
    await insert('acc:~a', day: 1);

    await refreshThreadAggregate(db, 'acc', 'INBOX', 'acc:~a');

    final row = (await thread('acc:~a'))!;
    expect(idsOf(row), ['acc:~a']);
    expect((row.latestEmailId, row.subject), ('acc:~a', 'Mail acc:~a'));
  });

  test('it sorts in with the rows that carry that thread id', () async {
    await insert('acc:~a', day: 2);
    await insert('acc:~b', threadId: 'acc:~a', day: 1);
    await insert('acc:~c', threadId: 'acc:~a', day: 3);

    await refreshThreadAggregate(db, 'acc', 'INBOX', 'acc:~a');

    final row = (await thread('acc:~a'))!;
    expect(idsOf(row), ['acc:~b', 'acc:~a', 'acc:~c']);
    expect(row.latestEmailId, 'acc:~c');
    expect(row.messageCount, 3);
  });

  test('only in the folder it shows in', () async {
    await insert('acc:~a', mailboxPath: 'Archive', day: 1);

    await refreshThreadAggregate(db, 'acc', 'INBOX', 'acc:~a');
    expect(await thread('acc:~a'), isNull);

    await refreshThreadAggregate(db, 'acc', 'Archive', 'acc:~a');
    expect(idsOf((await thread('acc:~a', mailboxPath: 'Archive'))!), [
      'acc:~a',
    ]);
  });

  test('a row with a thread id is not the thread of its own id', () async {
    await insert('acc:~a', threadId: 'subj:x', day: 1);
    await refreshThreadAggregate(db, 'acc', 'INBOX', 'acc:~a');
    expect(await thread('acc:~a'), isNull);
  });
}
