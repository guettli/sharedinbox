import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/entry_object.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/repositories/note_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/entry_projector.dart';
import 'package:sharedinbox/data/repositories/entry_repository_impl.dart';
import 'package:sharedinbox/data/repositories/legacy_note_migrator.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_imap.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';
import 'package:sharedinbox/data/repositories/note_repository_impl.dart';

import 'db_test_helper.dart';
import 'encrypted_objects/test_helpers.dart';
import 'helpers/fake_secure_storage.dart';
import 'helpers/stateful_fake_imap.dart';
import 'recording_app_log_repository.dart';

const _acc = 'acc-1';
const _notes = 'Notes';

const _account = Account(
  id: _acc,
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

/// One install: notes, the store with the entry projection and the
/// migrator, all on its own database and talking to the shared [server].
class _Device {
  _Device(this.server, {this.mode = NotesMode.entries});

  final StatefulFakeImapServer server;

  /// What the key lifecycle would say ([NotesMode]); [NotesMode.entries]
  /// holds the personal collection key.
  NotesMode mode;
  final db = openTestDatabase();
  final storage = FakeSecureStorage();
  final logs = RecordingAppLogRepository();
  late final accounts = AccountRepositoryImpl(db, storage);
  late final mailboxes = MailboxRepositoryImpl(
    db,
    accounts,
    imapConnect: (_, __, ___) async => server.connect(),
    namespace: _namespace,
  );
  late final store = MailObjectStoreImap(
    db,
    accounts,
    mailboxes,
    storage,
    imapConnect: (_, __, ___) async => server.connect(),
    namespace: _namespace,
    keyLookup: (_, keyId) => mode == NotesMode.entries &&
            constantTimeEquals(keyId, testPersonalKey.keyId)
        ? testPersonalKey
        : null,
    writeKey: (_, collectionId) =>
        mode == NotesMode.entries && collectionId == personalCollectionId
            ? testPersonalKey
            : null,
    projectors: [EntryProjector(db)],
  );
  late final notes = NoteRepositoryImpl(
    db,
    accounts,
    imapConnect: (_, __, ___) async => server.connect(),
    notesMode: (_) async => mode,
  );
  late final migrator = LegacyNoteMigrator(
    db,
    store,
    notes,
    notesMode: (_) async => mode,
    appLogger: AppLogger(logs),
  );
  late final entries = EntryRepositoryImpl(db, store);

  static Future<String> _namespace(Object client) =>
      (client as StatefulFakeImapClient).namespace();

  static Future<_Device> open(
    StatefulFakeImapServer server, {
    NotesMode mode = NotesMode.entries,
  }) async {
    final device = _Device(server, mode: mode);
    addTearDown(() async {
      await device.notes.waitForIdle();
      await device.store.waitForIdle();
      await device.db.close();
    });
    await device.accounts.addAccount(_account, 'pw');
    return device;
  }

  /// One foreground cycle as `AccountSyncManager` runs it: notes, then the
  /// object sync with the migration around it.
  Future<void> sync() async {
    await notes.syncAllNotes(_acc);
    await mailboxes.syncMailboxes(_acc);
    await migrator.beforeObjectSync(_acc);
    await store.sync(_acc);
    await store.waitForIdle();
    await migrator.afterObjectSync(_acc);
  }

  Future<List<Entry>> allEntries() => entries.observeEntries(_acc).first;

  Future<List<EmailNoteRow>> noteRows() => db.select(db.emailNotes).get();

  Future<int> awaiting() => migrator.watchAwaitingConfirmation(_acc).first;

  Future<void> confirm() => migrator.confirm(_acc);

  /// A note added on this device, not uploaded yet.
  Future<void> addLocalNote(String id, String messageId, String text) =>
      db.into(db.emailNotes).insert(
            EmailNotesCompanion.insert(
              id: id,
              accountId: _acc,
              messageId: messageId,
              noteText: text,
              serverId: '',
              createdAt: DateTime.utc(2024, 6, 2, 10, 15),
              pendingUpload: const Value(true),
            ),
          );
}

StatefulFakeImapServer _server({bool gmail = false}) => StatefulFakeImapServer(
      uidValidityByFolder: {'INBOX': 1, _notes: 7},
      gmail: gmail,
    );

/// A legacy note, as an older SharedInbox appended it.
void _putNote(
  StatefulFakeImapServer server,
  String noteId,
  String messageId,
  String text,
) {
  final builder = imap.MessageBuilder()
    ..subject = 'Note'
    ..text = text
    ..date = DateTime.utc(2024, 6, 2, 10, 15);
  builder
    ..addHeader('X-SharedInbox-Note-For', messageId)
    ..addHeader('X-SharedInbox-Note-Id', noteId);
  server.append(
    _notes,
    Uint8List.fromList(
      utf8.encode(builder.buildMimeMessage().renderMessage()),
    ),
  );
}

/// Another app's mail in `Notes` (e.g. Apple Notes): no note headers.
void _putForeign(StatefulFakeImapServer server) {
  final builder = imap.MessageBuilder()
    ..subject = 'Shopping list'
    ..text = 'not ours';
  server.append(
    _notes,
    Uint8List.fromList(
      utf8.encode(builder.buildMimeMessage().renderMessage()),
    ),
  );
}

/// The note ids in `Notes` on the server; null for a foreign mail.
List<String?> _noteIdsOn(StatefulFakeImapServer server, String path) => [
      for (final m in server.messagesIn(path))
        imap.MimeMessage.parseFromData(m.raw!)
            .getHeaderValue('X-SharedInbox-Note-Id')
            ?.trim(),
    ];

void main() {
  setUpAll(configureSqliteForTests);

  test('legacy mode: notes work as before, nothing is migrated', () async {
    final server = _server();
    _putNote(server, 'n1', '<m1@x>', 'old note');
    final a = await _Device.open(server, mode: NotesMode.legacy);
    await a.sync();
    await a.notes.addNote(_acc, '<m2@x>', 'new note');
    await a.notes.waitForIdle();
    await a.sync();

    expect(_noteIdsOn(server, _notes), hasLength(2));
    expect(await a.noteRows(), hasLength(2));
    expect(await a.allEntries(), isEmpty);
  });

  test('locked: no new note, a pending note is not uploaded', () async {
    final server = _server();
    final a = await _Device.open(server, mode: NotesMode.locked);
    await a.addLocalNote('n1', '<m1@x>', 'written before the key mail');

    await expectLater(
      a.notes.addNote(_acc, '<m1@x>', 'new'),
      throwsA(isA<NotesEncryptedException>()),
    );
    await a.sync();

    expect(server.messagesIn(_notes), isEmpty);
    expect(server.appendCount, 0);
    final row = (await a.noteRows()).single;
    expect(row.pendingUpload, isTrue);
    expect(await a.allEntries(), isEmpty);
  });

  test('A0: a note pending upload becomes an entry without confirmation',
      () async {
    final server = _server();
    final a = await _Device.open(server, mode: NotesMode.locked);
    await a.addLocalNote('n1', '<m1@x>', 'local only');
    await a.sync();

    a.mode = NotesMode.entries; // unlocked
    await a.sync();

    final entry = (await a.allEntries()).single;
    expect(entry.itemId, await legacyNoteItemId('n1'));
    expect(entry.body, 'local only');
    expect(entry.links, ['<m1@x>']);
    expect(entry.createdAt, DateTime.utc(2024, 6, 2, 10, 15));
    expect(await a.noteRows(), isEmpty);
    // The plaintext never reached the server.
    expect(server.messagesIn(_notes), isEmpty);
    // AppLogger writes unawaited.
    await Future<void>.delayed(Duration.zero);
    expect(
      a.logs.rows.where((e) => e.event == 'notes.migrate.local'),
      hasLength(1),
    );
    // Note text is never logged.
    expect(
      a.logs.rows.where((e) => (e.dataJson ?? '').contains('local only')),
      isEmpty,
    );
  });

  test(
      'synced notes wait for the confirmation, then move; foreign mail and '
      'the folder stay', () async {
    final server = _server();
    _putNote(server, 'n1', '<m1@x>', 'first');
    _putNote(server, 'n2', '<m2@x>', 'second');
    _putForeign(server);
    final a = await _Device.open(server);

    await a.sync();
    await a.sync();
    expect(await a.allEntries(), isEmpty);
    expect(await a.noteRows(), hasLength(2));
    expect(await a.awaiting(), 2);

    await a.confirm();
    expect(await a.awaiting(), 0);
    await a.sync();

    final entries = await a.allEntries();
    expect(
      {for (final e in entries) e.body: e.links},
      {
        'first': ['<m1@x>'],
        'second': ['<m2@x>'],
      },
    );
    expect(
      {for (final e in entries) e.createdAt},
      {DateTime.utc(2024, 6, 2, 10, 15)},
    );
    expect(await a.noteRows(), isEmpty);
    expect(_noteIdsOn(server, _notes), [null]);
    expect(server.folders, contains(_notes));

    // Further syncs change nothing.
    await Future<void>.delayed(Duration.zero);
    final logged = a.logs.rows.length;
    await a.sync();
    await Future<void>.delayed(Duration.zero);
    expect(await a.allEntries(), hasLength(2));
    expect(
      a.logs.rows
          .skip(logged)
          .where((e) => e.event.startsWith('notes.migrate.')),
      isEmpty,
    );
  });

  test('B deletes only notes whose entry is on the server', () async {
    final server = _server();
    _putNote(server, 'n1', '<m1@x>', 'first');
    final a = await _Device.open(server);
    await a.sync();
    await a.confirm();

    // Pass A only: the entry is written, not uploaded yet.
    await a.migrator.beforeObjectSync(_acc);
    expect(await a.allEntries(), hasLength(1));
    await a.migrator.afterObjectSync(_acc);
    expect((await a.noteRows()).single.pendingDelete, isFalse);
    expect(_noteIdsOn(server, _notes), ['n1']);

    // Interrupted after the upload, before the delete: resumes.
    await a.store.sync(_acc);
    await a.store.waitForIdle();
    final fresh = LegacyNoteMigrator(
      a.db,
      a.store,
      a.notes,
      notesMode: (_) async => NotesMode.entries,
    );
    await fresh.afterObjectSync(_acc);
    expect(await a.noteRows(), isEmpty);
    expect(server.messagesIn(_notes), isEmpty);
    expect(await a.allEntries(), hasLength(1));
  });

  test('an entry the user deleted is not recreated when its note returns',
      () async {
    final server = _server();
    _putNote(server, 'n1', '<m1@x>', 'first');
    final a = await _Device.open(server);
    await a.confirm();
    await a.sync();
    final entry = (await a.allEntries()).single;
    await a.entries.delete(_acc, entry.itemId);
    await a.store.waitForIdle();
    await a.sync();
    expect(await a.allEntries(), isEmpty);

    // An old client puts the plaintext note back.
    _putNote(server, 'n1', '<m1@x>', 'first');
    await a.sync();
    await a.sync();

    expect(await a.allEntries(), isEmpty);
    expect(server.messagesIn(_notes), isEmpty);
    expect(await a.noteRows(), isEmpty);
  });

  test('two devices migrating at once write one entry, no conflict', () async {
    final server = _server();
    _putNote(server, 'n1', '<m1@x>', 'shared note');
    final a = await _Device.open(server);
    final b = await _Device.open(server);
    for (final d in [a, b]) {
      await d.sync();
      await d.confirm();
    }
    // Both write the entry before either uploads.
    await a.migrator.beforeObjectSync(_acc);
    await b.migrator.beforeObjectSync(_acc);
    for (var round = 0; round < 2; round++) {
      await a.sync();
      await b.sync();
    }

    for (final d in [a, b]) {
      final entry = (await d.allEntries()).single;
      expect(entry.body, 'shared note');
      expect(entry.hasConflict, isFalse);
      expect(await d.store.observeConflicts(_acc).first, isEmpty);
      expect(await d.noteRows(), isEmpty);
    }
    expect(server.messagesIn(_notes), isEmpty);
  });

  test('a note added later by an old client is migrated on the next sync',
      () async {
    final server = _server();
    final a = await _Device.open(server);
    await a.confirm();
    await a.sync();
    _putNote(server, 'n9', '<m9@x>', 'from an old client');
    await a.sync();
    expect((await a.allEntries()).single.body, 'from an old client');
    expect(server.messagesIn(_notes), isEmpty);
  });

  test('on Gmail the plaintext copy goes through Trash', () async {
    final server = _server(gmail: true)..moveAnswersCopyUid = false;
    server.addTrash('[Gmail]/Trash');
    _putNote(server, 'n1', '<m1@x>', 'first');
    _putForeign(server);
    final a = await _Device.open(server);
    await a.confirm();
    await a.sync();

    expect((await a.allEntries()).single.body, 'first');
    expect(_noteIdsOn(server, _notes), [null]);
    expect(server.messagesIn('[Gmail]/Trash'), isEmpty);
    expect(
      _noteIdsOn(server, StatefulFakeImapServer.gmailAllMail),
      isNot(contains('n1')),
    );
  });

  test('without a key nothing runs', () async {
    final server = _server();
    _putNote(server, 'n1', '<m1@x>', 'first');
    final a = await _Device.open(server, mode: NotesMode.locked);
    await a.confirm();
    await a.sync();
    expect(await a.allEntries(), isEmpty);
    expect(_noteIdsOn(server, _notes), ['n1']);
    expect(await a.noteRows(), hasLength(1));
  });
}
