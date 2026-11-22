import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart' show SyncEmailsResult;
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';
import 'package:sharedinbox/data/repositories/sync_state_repository_impl.dart';

import 'account_repository_impl_test.dart' show MapSecureStorage;
import 'db_test_helper.dart';
import 'fake_imap.dart' show SnoozeSpyImapClient;
import 'helpers/test_accounts.dart';

// The app's own data folders (`SharedInbox`, `SharedInbox/Keys`,
// `SharedInbox/Data`) are recorded by the folder listing, hidden everywhere
// and never mail-synced (#1364).

const _jmapAccount = Account(
  id: 'jmap-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  type: AccountType.jmap,
  jmapUrl: 'https://jmap.example.com/.well-known/jmap',
);

/// [SnoozeSpyImapClient] whose LIST answers [paths] with [separator].
class _Listing extends SnoozeSpyImapClient {
  _Listing(this.paths, {this.separator = '/'});

  final List<String> paths;
  final String separator;

  @override
  List<imap.Mailbox> get listedMailboxes => [
        for (final p in paths)
          imap.Mailbox(
            encodedName: p.split(separator).last,
            encodedPath: p,
            pathSeparator: separator,
            flags: [],
          ),
      ];
}

Future<imap.ImapClient> _noImap(Account a, String u, String p) =>
    Future.error(StateError('no IMAP connection expected'));

http.Client _jmapServing(List<Map<String, dynamic>> list) =>
    MockClient((req) async {
      if (req.url.path.contains('well-known')) {
        return http.Response(
          jsonEncode({
            'apiUrl': 'https://jmap.example.com/api/',
            'accounts': {
              'acct1': {'name': 'alice@example.com', 'isPersonal': true},
            },
            'primaryAccounts': {
              'urn:ietf:params:jmap:core': 'acct1',
              'urn:ietf:params:jmap:mail': 'acct1',
            },
            'capabilities': {},
            'username': 'alice@example.com',
            'state': 'sess1',
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'sessionState': 'sess1',
          'methodResponses': [
            [
              'Mailbox/get',
              {'accountId': 'acct1', 'state': 'st1', 'list': list},
              '0',
            ],
          ],
        }),
        200,
      );
    });

Map<String, dynamic> _jmapBox(
  String id,
  String name, {
  String? parentId,
  String? role,
}) =>
    {
      'id': id,
      'name': name,
      'parentId': parentId,
      'role': role,
      'unreadEmails': 0,
      'totalEmails': 0,
    };

Future<void> _seedEmail(
  AppDatabase db,
  String accountId,
  String id,
  String path,
  String subject,
) =>
    db.into(db.emails).insert(
          EmailsCompanion.insert(
            id: id,
            accountId: accountId,
            mailboxPath: path,
            srvMailboxPath: Value(path),
            uid: 1,
            subject: Value(subject),
            receivedAt: DateTime(2026),
          ),
        );

void main() {
  setUpAll(configureSqliteForTests);

  group('IMAP', () {
    late AppDatabase db;
    late AccountRepositoryImpl accounts;

    setUp(() async {
      db = openTestDatabase();
      accounts = AccountRepositoryImpl(db, MapSecureStorage());
      await accounts.addAccount(testImapAccount, 'pw');
    });
    tearDown(() => db.close());

    MailboxRepositoryImpl repo(imap.ImapClient client) => MailboxRepositoryImpl(
          db,
          accounts,
          imapConnect: (_, __, ___) async => client,
        );

    test(
        'the listing records SharedInbox, Keys and Data by path: hidden, '
        'while Work/SharedInbox and SharedInbox/Foo stay visible', () async {
      final mailboxes = repo(
        _Listing([
          'INBOX',
          'SharedInbox',
          'SharedInbox/Keys',
          'SharedInbox/Data',
          'SharedInbox/Foo',
          'Work',
          'Work/SharedInbox',
        ]),
      );
      await mailboxes.syncMailboxes('acc-1');

      final shown = await mailboxes.observeMailboxes('acc-1').first;
      expect(shown.map((m) => m.path).toSet(), {
        'INBOX',
        'SharedInbox/Foo',
        'Work',
        'Work/SharedInbox',
      });
      expect(shown.where((m) => m.isAppData), isEmpty);
      // Not in the all-accounts list either.
      expect(
        (await mailboxes.observeMailboxes(null).first).map((m) => m.path),
        isNot(contains('SharedInbox/Data')),
      );

      final app = await mailboxes.observeAppDataFolders('acc-1').first;
      expect(app.map((m) => m.path).toSet(), {
        'SharedInbox',
        'SharedInbox/Keys',
        'SharedInbox/Data',
      });
      expect(app.every((m) => m.isAppData), isTrue);
    });

    test('paths go by the server hierarchy separator', () async {
      final mailboxes = repo(
        _Listing(
          ['INBOX', 'SharedInbox', 'SharedInbox.Keys', 'SharedInbox.Data'],
          separator: '.',
        ),
      );
      await mailboxes.syncMailboxes('acc-1');

      expect(
        (await mailboxes.observeAppDataFolders('acc-1').first)
            .map((m) => m.path)
            .toSet(),
        {'SharedInbox', 'SharedInbox.Keys', 'SharedInbox.Data'},
      );
      expect(
        (await mailboxes.observeMailboxes('acc-1').first).map((m) => m.path),
        ['INBOX'],
      );
    });

    test(
        'mail synced into a folder before it was recorded is dropped, with '
        'its sync checkpoint', () async {
      await db.into(db.mailboxes).insert(
            MailboxesCompanion.insert(
              id: 'acc-1:SharedInbox/Data',
              accountId: 'acc-1',
              path: 'SharedInbox/Data',
              name: 'Data',
              srvName: const Value('Data'),
            ),
          );
      await _seedEmail(db, 'acc-1', 'acc-1:~d1', 'SharedInbox/Data', 'blob');
      await _seedEmail(db, 'acc-1', 'acc-1:~w1', 'Work', 'kept');
      await db.into(db.syncStates).insert(
            SyncStatesCompanion.insert(
              accountId: 'acc-1',
              resourceType: 'IMAP:SharedInbox/Data',
              state: jsonEncode({'uidValidity': 1, 'lastUid': 1}),
              syncedAt: DateTime(2026),
            ),
          );

      await repo(_Listing(['INBOX', 'Work', 'SharedInbox', 'SharedInbox/Data']))
          .syncMailboxes('acc-1');

      final ids = (await db.select(db.emails).get()).map((e) => e.id);
      expect(ids, ['acc-1:~w1']);
      expect(
        (await db.select(db.syncStates).get())
            .where((s) => s.resourceType == 'IMAP:SharedInbox/Data'),
        isEmpty,
      );
    });

    test('syncEmails of an app data folder does nothing', () async {
      final mailboxes = MailboxRepositoryImpl(db, accounts);
      await mailboxes.registerAppDataFolders('acc-1', ['SharedInbox/Data']);
      final emails = EmailRepositoryImpl(db, accounts, imapConnect: _noImap);

      expect(
        await emails.syncEmails('acc-1', 'SharedInbox/Data'),
        SyncEmailsResult.zero,
      );
      // An ordinary folder does connect (and fails here, no server).
      await expectLater(emails.syncEmails('acc-1', 'Work'), throwsStateError);
    });

    test('mail in an app data folder shows in no search and no folder state',
        () async {
      await repo(_Listing(['INBOX', 'Work', 'SharedInbox', 'SharedInbox/Keys']))
          .syncMailboxes('acc-1');
      await _seedEmail(db, 'acc-1', 'acc-1:~k1', 'SharedInbox/Keys', 'secret');
      await _seedEmail(db, 'acc-1', 'acc-1:~w1', 'Work', 'secret');

      final emails = EmailRepositoryImpl(db, accounts, imapConnect: _noImap);
      final found = await emails.searchEmailsGlobal(null, 'secret');
      expect(found.map((e) => e.id), ['acc-1:~w1']);

      final states =
          await SyncStateRepositoryImpl(db).statesForAccount('acc-1');
      expect(
        states.map((s) => s.mailboxPath),
        isNot(contains('SharedInbox/Keys')),
      );
    });
  });

  group('JMAP', () {
    test(
        'the root SharedInbox mailbox and its Keys and Data children are '
        'recorded by id; Work/SharedInbox and SharedInbox/Foo are not',
        () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final accounts = AccountRepositoryImpl(db, MapSecureStorage());
      await accounts.addAccount(_jmapAccount, 'pw');
      final mailboxes = MailboxRepositoryImpl(
        db,
        accounts,
        httpClient: _jmapServing([
          _jmapBox('in', 'Inbox', role: 'inbox'),
          _jmapBox('si', 'SharedInbox'),
          _jmapBox('k', 'Keys', parentId: 'si'),
          _jmapBox('d', 'Data', parentId: 'si'),
          _jmapBox('f', 'Foo', parentId: 'si'),
          _jmapBox('w', 'Work'),
          _jmapBox('ws', 'SharedInbox', parentId: 'w'),
          _jmapBox('wk', 'Keys', parentId: 'ws'),
          // A root with a role is no app folder, nor are its children.
          _jmapBox('ar', 'SharedInbox', role: 'archive'),
          _jmapBox('ark', 'Keys', parentId: 'ar'),
        ]),
      );

      await mailboxes.syncMailboxes('jmap-1');

      expect(
        (await mailboxes.observeMailboxes('jmap-1').first)
            .map((m) => m.path)
            .toSet(),
        {'in', 'f', 'w', 'ws', 'wk', 'ar', 'ark'},
      );
      expect(
        (await mailboxes.observeAppDataFolders('jmap-1').first)
            .map((m) => m.path)
            .toSet(),
        {'si', 'k', 'd'},
      );
    });
  });
}
