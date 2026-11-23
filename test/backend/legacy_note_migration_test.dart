// Backend tests of the legacy-note migration (#1375) against a real
// Stalwart, over IMAP and JMAP: plaintext notes in `Notes` move into
// encrypted entries once confirmed, a foreign mail and the folder stay, an
// interrupted migration resumes, two devices migrating at once write one
// entry, and a note pending upload on a locked device never reaches the
// server. The devices hold the personal key of the unit tests; the key
// lifecycle itself is covered by encrypted_key_service_test.dart.
// Run via: task test-backend

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/repositories/note_repository.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/entry_projector.dart';
import 'package:sharedinbox/data/repositories/entry_repository_impl.dart';
import 'package:sharedinbox/data/repositories/legacy_note_migrator.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_base.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_imap.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_jmap.dart';
import 'package:sharedinbox/data/repositories/note_repository_impl.dart';
import 'package:test/test.dart';

import '../unit/db_test_helper.dart';
import '../unit/encrypted_objects/test_helpers.dart';
import 'mail_object_store_scenarios.dart';
import 'stalwart_harness.dart';

const _notes = 'Notes';

void main() {
  late PoolImapAccount pool;

  setUpAll(() {
    configureSqliteForTests();
    pool = PoolImapAccount();
  });
  setUp(
    () => pool.deleteFolders(
      [objectDataPath, 'SharedInbox/Keys', 'SharedInbox', _notes],
    ),
  );

  for (final jmap in [false, true]) {
    group(jmap ? 'JMAP' : 'IMAP', () {
      Account account() => jmap
          ? pool.user.jmapAccount(id: 'test-jmap', env: pool.env)
          : pool.account;

      Future<_Device> device({NotesMode mode = NotesMode.entries}) async {
        final d = _Device(account(), jmap: jmap, mode: mode);
        addTearDown(() async {
          await d.notes.waitForIdle();
          await d.objects.store.waitForIdle();
          await d.objects.db.close();
        });
        await d.objects.accounts.addAccount(account(), pool.user.password);
        return d;
      }

      /// The note ids in `Notes` (none without the folder); null for a
      /// foreign mail.
      Future<List<String?>> notesOnServer() => pool.withClient((c) async {
            try {
              await c.selectMailboxByPath(_notes);
            } on imap.ImapException {
              return const <String?>[];
            }
            final uids = (await c.uidSearchMessages(searchCriteria: 'ALL'))
                    .matchingSequence
                    ?.toList() ??
                const <int>[];
            if (uids.isEmpty) return const <String?>[];
            final fetched = await c.uidFetchMessages(
              imap.MessageSequence.fromIds(uids, isUid: true),
              '(UID BODY.PEEK[])',
            );
            return [
              for (final m in fetched.messages)
                m.getHeaderValue('X-SharedInbox-Note-Id')?.trim(),
            ];
          });

      /// Appends [raw] to `Notes`, creating it.
      Future<void> append(imap.MimeMessage raw) => pool.withClient((c) async {
            try {
              await c.createMailbox(_notes);
            } catch (_) {
              // Already there.
            }
            await c.appendMessage(raw, targetMailboxPath: _notes);
          });

      /// A legacy note, as an older SharedInbox appended it.
      Future<void> putNote(String noteId, String messageId, String text) {
        final b = imap.MessageBuilder()
          ..subject = 'Note'
          ..text = text;
        b
          ..addHeader('X-SharedInbox-Note-For', messageId)
          ..addHeader('X-SharedInbox-Note-Id', noteId);
        return append(b.buildMimeMessage());
      }

      /// Another app's mail in `Notes` (e.g. Apple Notes).
      Future<void> putForeign() => append(
            (imap.MessageBuilder()
                  ..subject = 'Shopping list'
                  ..text = 'not ours')
                .buildMimeMessage(),
          );

      test('notes move after the confirmation; foreign mail and folder stay',
          () async {
        await putNote('n1-$jmap', '<m1@x>', 'first');
        await putNote('n2-$jmap', '<m2@x>', 'second');
        await putForeign();
        final a = await device();

        await a.sync();
        expect(await a.entries(), isEmpty);
        expect(await a.migrator.watchAwaitingConfirmation(a.id).first, 2);

        await a.migrator.confirm(a.id);
        await a.sync();

        final entries = await a.entries();
        expect(
          {for (final e in entries) e.body: e.links},
          {
            'first': ['<m1@x>'],
            'second': ['<m2@x>'],
          },
        );
        expect(entries.every((e) => e.createdAt != null), isTrue);
        expect(await notesOnServer(), [null]);
        expect(await a.noteRows(), isEmpty);
      });

      test('an interrupted migration resumes; no duplicate entries', () async {
        await putNote('n1-$jmap', '<m1@x>', 'first');
        final a = await device();
        await a.sync();
        await a.migrator.confirm(a.id);

        // Stopped after pass A, before the upload.
        await a.migrator.beforeObjectSync(a.id);
        // Stopped after the upload, before the delete.
        await a.objects.sync();
        expect(await notesOnServer(), ['n1-$jmap']);

        final fresh = a.newMigrator();
        await fresh.beforeObjectSync(a.id);
        await fresh.afterObjectSync(a.id);
        expect(await notesOnServer(), isEmpty);
        expect((await a.entries()).single.body, 'first');
        await a.sync();
        expect(await a.entries(), hasLength(1));
      });

      test('two devices migrating at once: one entry, no conflict', () async {
        await putNote('n1-$jmap', '<m1@x>', 'shared');
        final a = await device();
        final b = await device();
        for (final d in [a, b]) {
          await d.sync();
          await d.migrator.confirm(d.id);
        }
        await a.migrator.beforeObjectSync(a.id);
        await b.migrator.beforeObjectSync(b.id);
        for (var round = 0; round < 2; round++) {
          await a.sync();
          await b.sync();
        }
        for (final d in [a, b]) {
          final entry = (await d.entries()).single;
          expect(entry.body, 'shared');
          expect(entry.hasConflict, isFalse);
        }
        expect(await notesOnServer(), isEmpty);
      });

      test(
          'a later note is migrated; a deleted entry is not recreated; a '
          'note pending on a locked device never reaches the server', () async {
        final a = await device(mode: NotesMode.locked);
        await a.notes.syncAllNotes(a.id);
        await a.objects.db.into(a.objects.db.emailNotes).insert(
              EmailNotesCompanion.insert(
                id: 'local-$jmap',
                accountId: a.id,
                messageId: '<m0@x>',
                noteText: 'local only',
                serverId: '',
                createdAt: DateTime.utc(2024),
                pendingUpload: const Value(true),
              ),
            );
        await a.sync();
        expect(await notesOnServer(), isEmpty);

        a.mode = NotesMode.entries;
        await a.migrator.confirm(a.id);
        await a.sync();
        expect((await a.entries()).single.body, 'local only');

        await putNote('n9-$jmap', '<m9@x>', 'from an old client');
        await a.sync();
        final later = (await a.entries())
            .firstWhere((e) => e.body == 'from an old client');
        expect(await notesOnServer(), isEmpty);

        await a.repo.delete(a.id, later.itemId);
        await a.objects.store.waitForIdle();
        await a.sync();
        await putNote('n9-$jmap', '<m9@x>', 'from an old client');
        await a.sync();
        await a.sync();
        expect(
          [for (final e in await a.entries()) e.body],
          ['local only'],
        );
        expect(await notesOnServer(), isEmpty);
      });
    });
  }
}

/// One install: the store with the entry projection over IMAP or JMAP,
/// notes and the migrator, on its own database.
class _Device {
  _Device(Account account, {required bool jmap, required this.mode}) {
    objects = BackendObjectDevice(account, jmap ? _jmapStore : _imapStore);
    notes = NoteRepositoryImpl(
      objects.db,
      objects.accounts,
      imapConnect: testImapConnect,
      httpClient: objects.httpClient,
      notesMode: (_) async => mode,
    );
    migrator = newMigrator();
  }

  NotesMode mode;
  late final BackendObjectDevice objects;
  late final NoteRepositoryImpl notes;
  late final LegacyNoteMigrator migrator;
  late final repo = EntryRepositoryImpl(objects.db, objects.store);

  String get id => objects.accountId;

  LegacyNoteMigrator newMigrator() => LegacyNoteMigrator(
        objects.db,
        objects.store,
        notes,
        notesMode: (_) async => mode,
      );

  CollectionKey? _key(String _, Uint8List keyId) => mode == NotesMode.entries &&
          constantTimeEquals(keyId, testPersonalKey.keyId)
      ? testPersonalKey
      : null;

  CollectionKey? _writeKey(String _, String collectionId) =>
      mode == NotesMode.entries && collectionId == personalCollectionId
          ? testPersonalKey
          : null;

  MailObjectStoreBase _imapStore(BackendObjectDevice d) => MailObjectStoreImap(
        d.db,
        d.accounts,
        d.mailboxes,
        d.storage,
        imapConnect: (a, u, p) => d.offline
            ? Future.error(const SocketException('offline'))
            : testImapConnect(a, u, p),
        keyLookup: _key,
        writeKey: _writeKey,
        projectors: [EntryProjector(d.db)],
      );

  MailObjectStoreBase _jmapStore(BackendObjectDevice d) => MailObjectStoreJmap(
        d.db,
        d.accounts,
        d.mailboxes,
        d.storage,
        httpClient: d.httpClient,
        keyLookup: _key,
        writeKey: _writeKey,
        projectors: [EntryProjector(d.db)],
      );

  /// One foreground cycle as `AccountSyncManager` runs it.
  Future<void> sync() async {
    await notes.syncAllNotes(id);
    await objects.mailboxes.syncMailboxes(id);
    await migrator.beforeObjectSync(id);
    await objects.sync();
    await migrator.afterObjectSync(id);
  }

  Future<List<Entry>> entries() => repo.observeEntries(id).first;

  Future<List<EmailNoteRow>> noteRows() =>
      objects.db.select(objects.db.emailNotes).get();
}
