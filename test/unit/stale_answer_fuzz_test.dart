// Stale-answer fuzz for the IMAP sync engine (SYNC.md §9, SYNC-REDESIGN.md
// §8 phase 0).
//
// Drives the real [EmailRepositoryImpl] against [StatefulFakeImapServer] and
// interleaves random user actions with sync reads whose answers reach the
// app *after* a local change: the fake runs the user's action once it has
// fixed an answer and before it returns it. Another client changes the
// server now and then. Once the queue drains and sync settles, every
// message must look the same locally and on the server, and match what the
// user last asked for.
//
// Runs a fixed list of seeds by default. Longer runs:
//   STALE_FUZZ_SEEDS=500 flutter test test/unit/stale_answer_fuzz_test.dart
// Some seeds (as printed on failure): STALE_FUZZ_SEED=17 or =17,42; with
// STALE_FUZZ_VERBOSE=1 the trace shows the local rows, queue and server after
// every step. Steps per seed: STALE_FUZZ_STEPS (default 25).

import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_state_writer.dart';

import 'db_test_helper.dart';
import 'helpers/fake_secure_storage.dart';
import 'helpers/stateful_fake_imap.dart';

const _account = Account(
  id: 'acc-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

const _folders = ['INBOX', 'Archive', 'Trash'];
const _roles = {'INBOX': 'inbox', 'Archive': 'archive', 'Trash': 'trash'};

/// [_Intent.location] of a message the user deleted for good.
const _expunged = '(expunged)';

/// STALE_FUZZ_VERBOSE=1 adds the local rows and the queue to the trace
/// after every flush, sync and user action.
final _verbose = Platform.environment['STALE_FUZZ_VERBOSE'] == '1';

int _envInt(String name, int fallback) =>
    int.tryParse(Platform.environment[name] ?? '') ?? fallback;

void main() {
  setUpAll(configureSqliteForTests);

  final only = Platform.environment['STALE_FUZZ_SEED'];
  final seeds = only != null
      ? [for (final s in only.split(',')) int.parse(s.trim())]
      : [for (var s = 1; s <= _envInt('STALE_FUZZ_SEEDS', 30); s++) s];
  final steps = _envInt('STALE_FUZZ_STEPS', 25);

  group('stale-answer fuzz (IMAP)', () {
    for (final seed in seeds) {
      test('seed $seed', () => _FuzzRun(seed, steps).run());
    }
  });

  _knownBugs();
}

/// STALE_FUZZ_KNOWN_BUGS=1 runs the skipped regression tests below. Kept
/// while no known bug is open, for the next one the fuzz finds.
// ignore: unused_element
String? _knownBug(String reason) =>
    Platform.environment['STALE_FUZZ_KNOWN_BUGS'] == '1' ? null : reason;

/// Bugs the fuzz found, reduced to one deterministic case each. The fuzz
/// driver avoids exactly their triggers (see "known bug" in [_FuzzRun]), so
/// it keeps checking everything else. Fixing one: drop its `skip:` and its
/// exclusion in the driver.
void _knownBugs() {
  group('found by the stale-answer fuzz', () {
    late StatefulFakeImapServer server;
    late AppDatabase db;
    late EmailRepositoryImpl emails;

    /// Opens the app on [server] (filled by the test) and syncs it once.
    Future<void> open() async {
      final app = await _openApp(server);
      db = app.db;
      emails = app.emails;
      addTearDown(db.close);
      await _syncCycle(emails);
    }

    Future<Email> row(String messageId) async =>
        (await _rowsOf(db, messageId)).single;

    setUp(() => server = _newServer());

    test(
      'a delete for good of a mail whose move to Trash is still queued '
      'expunges the Trash mail with its old UID',
      () async {
        server
          ..deliver('INBOX', 'a@test')
          ..deliver('Trash', 'b@test');
        await open();
        final a = await row('a@test');

        // Offline: delete (to Trash), then delete it from Trash for good.
        expect(await emails.deleteEmail(a.id), 'Trash');
        expect(await emails.deleteEmail(a.id), isNull);
        await _syncCycle(emails);

        expect(server.find('b@test'), isNotNull, reason: 'b was not touched');
        expect(server.find('a@test'), isNull);
      },
    );

    test(
      "a move queued while the mail's earlier move is still queued does not "
      'hide the mail with that UID in the destination',
      () async {
        server
          ..deliver('INBOX', 'a@test')
          ..deliver('Trash', 'b@test');
        final app = await _openApp(server);
        db = app.db;
        emails = app.emails;
        addTearDown(db.close);
        await emails.syncEmails(_account.id, 'INBOX');
        final a = await row('a@test');

        // To Trash and back before either move is sent; Trash has not been
        // synced yet.
        await emails.moveEmail(a.id, 'Trash');
        await emails.moveEmail(a.id, 'INBOX');
        await emails.syncEmails(_account.id, 'Trash');
        await _syncCycle(emails);
        await _syncCycle(emails);

        expect(server.find('b@test')?.folder.path, 'Trash');
        expect(server.find('a@test')?.folder.path, 'INBOX');
        expect(await _rowsOf(db, 'b@test'), hasLength(1));
      },
    );

    test(
      'a mark-read queued behind a move that Undo cancelled acts on the '
      'mail where it stayed',
      () async {
        server
          ..deliver('INBOX', 'a@test')
          ..deliver('Trash', 'b@test');
        await open();
        final a = await row('a@test');

        await emails.moveEmail(a.id, 'Trash');
        await emails.setFlag(a.id, seen: true);
        // Undo before any flush: the move is cancelled, the mail stays.
        expect(await emails.cancelPendingChange(a.id, 'move'), isTrue);
        await _syncCycle(emails);

        expect(server.find('a@test')!.folder.path, 'INBOX');
        expect(server.find('a@test')!.message.seen, isTrue);
        expect(server.find('b@test')!.message.seen, isFalse);
      },
    );

    test(
      'without COPYUID, a delete for good behind a move does not pick one '
      'of two copies with the same Message-ID',
      () async {
        server = StatefulFakeImapServer(
          uidValidityByFolder: {'INBOX': 11, 'Archive': 22, 'Trash': 33},
          uidPlus: false,
        )
          ..deliver('INBOX', 'a@test')
          ..deliver('Trash', 'a@test');
        await open();
        final a = (await _rowsOf(db, 'a@test'))
            .singleWhere((r) => r.mailboxPath == 'INBOX');

        expect(await emails.deleteEmail(a.id), 'Trash');
        expect(await emails.deleteEmail(a.id), isNull);
        await _syncCycle(emails);

        final copies = server.folders['Trash']!.messages.values
            .where((m) => m.messageId == 'a@test');
        expect(copies, hasLength(2), reason: 'which copy is ours is unknown');
        final failed = await (db.select(db.pendingChanges)
              ..where((t) => t.state.equals('failed')))
            .get();
        expect(failed.map((c) => c.changeType), ['delete']);
      },
    );

    test(
      'a star queued behind a move that failed does not star the mail with '
      'the old UID in the destination',
      () async {
        server
          ..deliver('INBOX', 'a@test')
          ..deliver('Archive', 'b@test');
        await open();
        final a = await row('a@test');

        server.expungeElsewhere('a@test');
        await emails.moveEmail(a.id, 'Archive');
        await emails.setFlag(a.id, flagged: true);
        await _syncCycle(emails);

        expect(server.find('b@test')!.message.flagged, isFalse);
      },
    );

    test(
      'a move that fails because another client removed the mail does not '
      'leave a row that acts on another mail',
      () async {
        server
          ..deliver('INBOX', 'a@test')
          ..deliver('Archive', 'b@test');
        await open();
        final a = await row('a@test');

        server.expungeElsewhere('a@test');
        // The app has not noticed yet: the user files and stars a.
        await emails.moveEmail(a.id, 'Archive');
        await emails.setFlag(a.id, flagged: true);
        await _syncCycle(emails);
        await _syncCycle(emails);

        expect(
          server.find('b@test')!.message.flagged,
          isFalse,
          reason: 'only a was starred',
        );
        expect(await _rowsOf(db, 'a@test'), isEmpty, reason: 'a is gone');
      },
    );

    test(
      'a stale FETCH answer does not bring back a mail whose move was sent '
      'meanwhile',
      () async {
        server.deliver('Archive', 'a@test');
        await open();
        await emails.moveEmail((await row('a@test')).id, 'INBOX');
        await emails.flushPendingChanges(_account.id, 'pw');
        final inInbox = (await row('a@test')).id;

        List<String>? rowsBeforeReconcile;
        server.beforeAnswer = (command) async {
          if (command == 'FETCH headers (INBOX)') {
            // The INBOX answer still lists a. Meanwhile the user files it
            // again and another flush sends that.
            await emails.moveEmail(inInbox, 'Archive');
            await emails.flushPendingChanges(_account.id, 'pw');
          }
          if (command == 'SEARCH ALL (INBOX)') {
            rowsBeforeReconcile = [
              for (final r in await _rowsOf(db, 'a@test')) r.id,
            ];
          }
        };
        await emails.syncEmails(_account.id, 'INBOX');

        expect(
          rowsBeforeReconcile,
          isNotNull,
          reason: 'race not exercised: no SEARCH ALL after the FETCH',
        );
        expect(server.find('a@test')?.folder.path, 'Archive');
        // One row, and it is still the mail's own: moves keep the id.
        expect(rowsBeforeReconcile, [inInbox]);
      },
    );

    test(
      'a stale FETCH answer does not bring back a mail whose queued move was '
      'sent while the answer was on its way',
      () async {
        server.deliver('Archive', 'a@test');
        await open();
        await emails.moveEmail((await row('a@test')).id, 'INBOX');
        await emails.flushPendingChanges(_account.id, 'pw');
        // Queued before the sync starts, sent while its answer is held.
        final id = (await row('a@test')).id;
        await emails.moveEmail(id, 'Archive');

        List<String>? rowsBeforeReconcile;
        server.beforeAnswer = (command) async {
          if (command == 'FETCH headers (INBOX)') {
            await emails.flushPendingChanges(_account.id, 'pw');
          }
          if (command == 'SEARCH ALL (INBOX)') {
            rowsBeforeReconcile = [
              for (final r in await _rowsOf(db, 'a@test')) r.id,
            ];
          }
        };
        await emails.syncEmails(_account.id, 'INBOX');

        expect(
          rowsBeforeReconcile,
          isNotNull,
          reason: 'race not exercised: no SEARCH ALL after the FETCH',
        );
        expect(server.find('a@test')?.folder.path, 'Archive');
        expect(rowsBeforeReconcile, [id]);
      },
    );

    test(
      'a stale FETCH answer does not bring back a mail deleted for good '
      'while it was on its way',
      () async {
        server.deliver('Archive', 'a@test');
        await open();
        await emails.moveEmail((await row('a@test')).id, 'Trash');
        await emails.flushPendingChanges(_account.id, 'pw');
        // Queued before the sync starts, sent while its answer is held: the
        // row is gone by then, so only where it was can tell (#1269).
        await emails.deleteEmail((await row('a@test')).id);

        List<String>? rowsBeforeReconcile;
        server.beforeAnswer = (command) async {
          if (command == 'FETCH headers (Trash)') {
            await emails.flushPendingChanges(_account.id, 'pw');
          }
          if (command == 'SEARCH ALL (Trash)') {
            rowsBeforeReconcile = [
              for (final r in await _rowsOf(db, 'a@test')) r.id,
            ];
          }
        };
        await emails.syncEmails(_account.id, 'Trash');

        expect(
          server.find('a@test'),
          isNull,
          reason: 'race not exercised: the delete was not sent meanwhile',
        );
        expect(
          rowsBeforeReconcile,
          isNotNull,
          reason: 'race not exercised: no SEARCH ALL after the FETCH',
        );
        expect(rowsBeforeReconcile, isEmpty);
      },
    );

    test(
      'a mail whose delete fails while a FETCH answer is on its way is shown '
      'again',
      () async {
        server.deliver('Archive', 'a@test');
        await open();
        await emails.moveEmail((await row('a@test')).id, 'Trash');
        await emails.flushPendingChanges(_account.id, 'pw');
        // Queued before the sync starts; the server refuses it while the
        // answer is held, until the app gives up.
        await emails.deleteEmail((await row('a@test')).id);
        server.refuses = (messageId) => messageId == 'a@test';

        server.beforeAnswer = (command) async {
          if (command == 'FETCH headers (Trash)') {
            for (var i = 0; i < 6; i++) {
              await emails.flushPendingChanges(_account.id, 'pw');
            }
          }
        };
        await emails.syncEmails(_account.id, 'Trash');

        final failed = await (db.select(db.pendingChanges)
              ..where((t) => t.state.equals('failed')))
            .get();
        expect(
          failed.map((c) => c.changeType),
          ['delete'],
          reason: 'race not exercised: the delete did not fail meanwhile',
        );
        expect(server.find('a@test')?.folder.path, 'Trash');
        expect(
          [for (final r in await _rowsOf(db, 'a@test')) r.mailboxPath],
          ['Trash'],
        );
      },
    );

    test(
      'a mail moved twice stays where the second move put it while that one '
      'is sent',
      () async {
        server.deliver('INBOX', 'a@test');
        await open();
        await emails.moveEmail((await row('a@test')).id, 'Archive');
        await emails.moveEmail((await row('a@test')).id, 'Trash');

        List<String>? shownWhileSecondMoveRuns;
        server.beforeAnswer = (command) async {
          if (command == 'MOVE (Archive)') {
            shownWhileSecondMoveRuns = [
              for (final r in await _rowsOf(db, 'a@test')) r.mailboxPath,
            ];
          }
        };
        await emails.flushPendingChanges(_account.id, 'pw');

        expect(
          shownWhileSecondMoveRuns,
          ['Trash'],
          reason: 'the first move landing must not show the mail in Archive',
        );
        expect(server.find('a@test')?.folder.path, 'Trash');
        expect(
          [for (final r in await _rowsOf(db, 'a@test')) r.mailboxPath],
          ['Trash'],
        );
        expect(await db.select(db.pendingChanges).get(), isEmpty);
      },
    );

    test(
      'when the second of two moves fails, a star queued behind it lands on '
      'the mail',
      () async {
        // b has UID 1 in Archive, the UID a has in INBOX.
        server
          ..deliver('Archive', 'b@test')
          ..deliver('INBOX', 'a@test');
        await open();
        await emails.moveEmail((await row('a@test')).id, 'Archive');
        await emails.moveEmail((await row('a@test')).id, 'Trash');
        await emails.setFlag((await row('a@test')).id, flagged: true);

        // The first move lands; the server then refuses a's second move
        // (once: the star is allowed).
        server.beforeAnswer = (command) async {
          if (command == 'MOVE (INBOX)') {
            var once = true;
            server.refuses = (messageId) {
              if (messageId != 'a@test' || !once) return false;
              once = false;
              return true;
            };
          }
        };
        for (var i = 0; i < 3; i++) {
          await emails.flushPendingChanges(_account.id, 'pw');
        }

        expect(server.find('a@test')?.folder.path, 'Archive');
        expect(server.find('a@test')!.message.flagged, isTrue);
        expect(
          server.find('b@test')!.message.flagged,
          isFalse,
          reason: 'only a was starred',
        );
        // The star reached the server; it is acked and shows until a read
        // confirms it (SYNC-REDESIGN.md §4.5).
        final left = await db.select(db.pendingChanges).get();
        expect(
          [for (final c in left) '${c.changeType} ${c.state}'],
          ['move failed', 'flag_flagged acked'],
        );
      },
    );

    test(
      'moving a mail another client already moved there leaves one row',
      () async {
        server.deliver('Trash', 'a@test');
        await open();
        final inTrash = (await row('a@test')).id;
        // Another client files it; this app sees it arrive in Archive before
        // it notices it left Trash.
        server.moveElsewhere('a@test', 'Archive');
        await emails.syncEmails(_account.id, 'Archive');
        expect(await _rowsOf(db, 'a@test'), hasLength(2));
        // The user files the Trash copy too.
        await emails.moveEmail(inTrash, 'Archive');

        await _syncCycle(emails);

        expect(server.find('a@test')?.folder.path, 'Archive');
        expect(
          [for (final r in await _rowsOf(db, 'a@test')) r.mailboxPath],
          ['Archive'],
        );
        expect(await db.select(db.pendingChanges).get(), isEmpty);
      },
    );

    test(
      'a delete for good works on a server without UIDPLUS',
      () async {
        server = StatefulFakeImapServer(
          uidValidityByFolder: {'INBOX': 11, 'Archive': 22, 'Trash': 33},
          uidPlus: false,
        )..deliver('Trash', 'a@test');
        await open();

        expect(await emails.deleteEmail((await row('a@test')).id), isNull);
        await _syncCycle(emails);

        expect(server.find('a@test'), isNull);
        final failed = await (db.select(db.pendingChanges)
              ..where((t) => t.state.equals('failed')))
            .get();
        expect(failed, isEmpty);
      },
    );

    test(
      'a failed IMAP flag change shows server truth again at the next sync',
      () async {
        server.deliver('INBOX', 'a@test');
        server.refuses = (messageId) => messageId == 'a@test';
        await open();

        await emails.setFlag((await row('a@test')).id, seen: true);
        for (var i = 0; i < 6; i++) {
          await _syncCycle(emails);
        }

        final failed = await (db.select(db.pendingChanges)
              ..where((t) => t.state.equals('failed')))
            .get();
        expect(failed, hasLength(1));
        expect((await row('a@test')).isSeen, isFalse);
      },
    );

    test(
      'a failed IMAP flag change is undone as soon as it fails',
      () async {
        server.deliver('INBOX', 'a@test');
        server.refuses = (messageId) => messageId == 'a@test';
        await open();

        await emails.setFlag((await row('a@test')).id, seen: true);
        // Flushes only: no sync reads the server meanwhile.
        for (var i = 0; i < 6; i++) {
          await emails.flushPendingChanges(_account.id, 'pw');
        }

        final failed = await (db.select(db.pendingChanges)
              ..where((t) => t.state.equals('failed')))
            .get();
        expect(failed, hasLength(1));
        expect((await row('a@test')).isSeen, isFalse);
      },
    );

    test(
      'two failed changes of one flag do not guess the value before them',
      () async {
        server.deliver('INBOX', 'a@test');
        server.refuses = (messageId) => messageId == 'a@test';
        await open();
        final id = (await row('a@test')).id;

        // Star, then unstar: both refused. Undoing the unstar must not star
        // the mail, since the star never reached the server either.
        await emails.setFlag(id, flagged: true);
        await emails.setFlag(id, flagged: false);
        for (var i = 0; i < 6; i++) {
          await emails.flushPendingChanges(_account.id, 'pw');
        }

        // The unstar superseded the star while both were queued
        // (SYNC-REDESIGN.md §3): one failed change.
        final failed = await (db.select(db.pendingChanges)
              ..where((t) => t.state.equals('failed')))
            .get();
        expect(failed, hasLength(1));
        expect((await row('a@test')).isFlagged, isFalse);
        await _syncCycle(emails);
        expect((await row('a@test')).isFlagged, isFalse);
      },
    );

    test(
      'when failed flag changes cannot be undone, the next sync reads the '
      'server',
      () async {
        server.deliver('INBOX', 'a@test');
        server.refuses = (messageId) => messageId == 'a@test';
        await open();
        final id = (await row('a@test')).id;

        // Star, unstar, star: all refused. The last one fails after an
        // earlier one, so the value before it is not known locally.
        await emails.setFlag(id, flagged: true);
        await emails.setFlag(id, flagged: false);
        await emails.setFlag(id, flagged: true);
        for (var i = 0; i < 6; i++) {
          await emails.flushPendingChanges(_account.id, 'pw');
        }
        expect(
          await (db.select(db.pendingChanges)
                ..where((t) => t.state.equals('pending')))
              .get(),
          isEmpty,
        );

        // One sync, well within the 15-minute reconcile interval.
        await emails.syncEmails(_account.id, 'INBOX');
        expect((await row('a@test')).isFlagged, isFalse);
      },
    );
  });
}

/// A repository on an in-memory database that talks to [server], with the
/// account and its INBOX, Archive and Trash folders set up.
Future<({AppDatabase db, EmailRepositoryImpl emails})> _openApp(
  StatefulFakeImapServer server,
) async {
  final db = openTestDatabase();
  final accounts = AccountRepositoryImpl(db, FakeSecureStorage());
  final emails = EmailRepositoryImpl(
    db,
    accounts,
    imapConnect: (_, __, ___) async => server.connect(),
    smtpConnect: (_, __, ___) =>
        Future.error(UnsupportedError('no SMTP in this test')),
    fetchObjectIds: (_, __, ___) async => const {},
    fetchPreviewSnippets: (_, __, ___) async => const {},
  );
  await accounts.addAccount(_account, 'pw');
  for (final path in _folders) {
    await db.into(db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: '${_account.id}:$path',
            accountId: _account.id,
            path: path,
            name: path,
            role: Value(_roles[path]),
          ),
        );
  }
  return (db: db, emails: emails);
}

StatefulFakeImapServer _newServer() => StatefulFakeImapServer(
      uidValidityByFolder: {'INBOX': 11, 'Archive': 22, 'Trash': 33},
    );

/// As if the 15-minute flag reconcile of [folder] were due.
Future<void> _expireFlagReconcile(AppDatabase db, String folder) =>
    (db.delete(db.syncStates)
          ..where(
            (t) => t.resourceType.equals('IMAP:FlagReconcile:$folder'),
          ))
        .go();

/// One sync cycle, as the account sync manager runs it: flush, then sync
/// every folder.
Future<void> _syncCycle(EmailRepositoryImpl emails) async {
  await emails.flushPendingChanges(_account.id, 'pw');
  for (final folder in _folders) {
    await emails.syncEmails(_account.id, folder);
  }
}

/// [messageId]'s local rows.
Future<List<Email>> _rowsOf(AppDatabase db, String messageId) =>
    (db.select(db.emails)..where((t) => t.messageId.equals(messageId))).get();

/// What the user last asked for, per field, since the last change another
/// client made to that field. Null: the user has not touched the field since,
/// so server truth is expected.
class _Intent {
  bool? seen;
  bool? flagged;

  /// A folder, or [_expunged].
  String? location;

  // Whether the user ever acted on the field: a server change by the app on
  // a field the user never touched is a bug.
  bool touchedSeen = false;
  bool touchedFlagged = false;
  bool touchedLocation = false;
  bool touchedExpunge = false;

  /// Another client moved or expunged the message. Changes the user queued
  /// against the old location may then be moot ("message gone"), so neither
  /// a failed change nor an unmet intent is a bug for this message; local and
  /// server must still agree.
  bool conflicted = false;
}

class _FuzzRun {
  _FuzzRun(this.seed, this.steps) : _rnd = Random(seed);

  final int seed;
  final int steps;
  final Random _rnd;
  final _trace = <String>[];
  final _intents = <String, _Intent>{};

  late final StatefulFakeImapServer _server;
  late final AppDatabase _db;
  late final EmailRepositoryImpl _emails;

  /// The Message-ID whose STORE/MOVE the server refuses, if any.
  String? _refused;

  /// Chance that an answer is held back for a stale-answer event.
  late final double _staleRate;

  /// What the app is doing, for the trace: `flush` or `sync <folder>`.
  String _phase = 'idle';
  bool _hooksOn = true;
  int _nextMessage = 1;

  /// Errors thrown by what [_onAnswer] ran. They must not reach the app: it
  /// would take them for an IMAP error (and e.g. read "no match").
  final _hookErrors = <String>[];

  /// Failed changes of a mail from before its [_Intent.conflicted] was
  /// cleared: those were moot, not bugs.
  final _excusedFailures = <int>{};

  Future<void> run() async {
    await _setUp();
    try {
      await _cycle().timeout(const Duration(seconds: 10));
      for (var i = 0; i < steps; i++) {
        await _step(i).timeout(const Duration(seconds: 10));
      }
      final problems = await _settle();
      if (problems.isNotEmpty) fail(await _report(problems));
    } on TestFailure {
      rethrow;
    } catch (e, st) {
      fail(await _report(['threw $e\n$st']));
    } finally {
      await _db.close();
    }
  }

  Future<void> _setUp() async {
    final uidPlus = _rnd.nextDouble() < 0.75;
    _server = StatefulFakeImapServer(
      uidValidityByFolder: {
        for (var i = 0; i < _folders.length; i++)
          _folders[i]: 100 * (i + 1) + _rnd.nextInt(50),
      },
      uidPlus: uidPlus,
    );
    final count = 5 + _rnd.nextInt(5);
    for (var i = 0; i < count; i++) {
      final folder = _rnd.nextDouble() < 0.6 ? 'INBOX' : _pick(_folders);
      _deliver(
        folder,
        flags: [
          if (_rnd.nextBool()) r'\Seen',
          if (_rnd.nextDouble() < 0.3) r'\Flagged',
        ],
      );
    }
    if (_rnd.nextDouble() < 0.15) {
      final refused = _pick(_intents.keys.toList());
      _refused = refused;
      _server.refuses = (messageId) => messageId == refused;
    }
    _staleRate = 0.1 + _rnd.nextDouble() * 0.5;
    _trace.add(
      'setup: $count messages, UIDPLUS=$uidPlus, '
      'staleRate=${_staleRate.toStringAsFixed(2)}, '
      'refused=${_refused ?? 'none'}; server: ${_serverDump()}',
    );

    final app = await _openApp(_server);
    _db = app.db;
    _emails = app.emails;
    _server.beforeAnswer = _onAnswer;
  }

  T _pick<T>(List<T> items) => items[_rnd.nextInt(items.length)];

  void _deliver(String folder, {List<String> flags = const []}) {
    final messageId = 'm${_nextMessage++}@fuzz';
    final message = _server.deliver(folder, messageId, flags: flags);
    _intents[messageId] = _Intent();
    _trace.add('  server: $messageId arrives in $folder/${message.uid} $flags');
  }

  Future<void> _step(int i) async {
    final r = _rnd.nextDouble();
    _trace.add('step $i');
    if (r < 0.35) return _userAction();
    if (r < 0.45) return _otherClient();
    if (r < 0.5) return _flush();
    if (r < 0.55) return _sync(_pick(_folders));
    return _cycle();
  }

  /// One sync cycle, as the account sync manager runs it.
  Future<void> _cycle() async {
    await _flush();
    for (final folder in _folders) {
      await _sync(folder);
    }
  }

  Future<void> _flush() async {
    final outer = _phase;
    _phase = 'flush';
    _trace.add('  flush');
    try {
      await _emails.flushPendingChanges(_account.id, 'pw');
    } finally {
      _phase = outer;
    }
    await _traceState('after flush');
  }

  Future<void> _sync(String folder) async {
    final outer = _phase;
    _phase = 'sync $folder';
    // As if the 15-minute flag reconcile were due.
    final reconcile = _hooksOn && _rnd.nextDouble() < 0.15;
    _trace.add('  sync $folder${reconcile ? ' (flag reconcile due)' : ''}');
    if (reconcile) await _expireFlagReconcile(_db, folder);
    try {
      await _emails.syncEmails(_account.id, folder);
    } finally {
      _phase = outer;
    }
    await _traceState('after sync $folder');
  }

  Future<void> _traceState(String when) async {
    if (!_verbose) return;
    final queue = await _db.select(_db.pendingChanges).get();
    _trace.addAll([
      '    $when: local ${[
        for (final r in await _localRows())
          '${r.id}${r.mailboxPath == r.id.split(':')[1] ? '' : '@${r.mailboxPath}'}'
              '=${r.messageId}${r.isSeen ? ' seen' : ''}'
              '${r.isFlagged ? ' starred' : ''}',
      ].join(', ')}',
      '      queue ${[
        for (final c in queue)
          '#${c.id} ${c.state} ${c.changeType} ${c.payload}',
      ].join(', ')}',
      '      server ${_serverDump()}',
    ]);
  }

  /// The stale-answer hook: the server has fixed the answer to [command];
  /// the user (or the app's own flush, or another client) acts before the
  /// app reads it.
  Future<void> _onAnswer(String command) async {
    if (!_hooksOn || _rnd.nextDouble() >= _staleRate) return;
    _trace.add('  [$_phase: answer to $command held back]');
    final events = 1 + _rnd.nextInt(2);
    for (var i = 0; i < events; i++) {
      try {
        await _heldBackEvent(command);
      } catch (e, st) {
        _trace.add('    (threw $e)');
        _hookErrors.add('while the answer to $command was held back: $e\n$st');
      }
    }
  }

  Future<void> _heldBackEvent(String command) async {
    final r = _rnd.nextDouble();
    if (r < 0.7) return _userAction();
    if (r >= 0.85 || _phase.startsWith('flush')) return _otherClient();
    // The queued change reaches the server while the read's answer is in
    // flight (another flush, e.g. the background isolate's).
    return _flush();
  }

  Future<List<Email>> _localRows() async {
    final rows = await (_db.select(_db.emails)
          ..where(
            (t) => t.accountId.equals(_account.id) & t.isLocal.equals(false),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();
    return rows;
  }

  /// The user acts on a mail as the app shows it.
  Future<void> _userAction() async {
    await _userActionNow();
    await _traceState('after user action');
  }

  Future<void> _userActionNow() async {
    final rows = await _localRows();
    if (rows.isEmpty) return;
    final row = _pick(rows);
    final messageId = row.messageId!;
    final intent = _intents[messageId]!;
    final r = _rnd.nextDouble();
    final what = '${row.id} ($messageId)';
    final onServer = _server.find(messageId);
    final current = onServer != null &&
        row.id ==
            '${_account.id}:${onServer.folder.path}:${onServer.message.uid}';
    if (intent.conflicted &&
        current &&
        rows.where((r) => r.messageId == messageId).length == 1 &&
        (await _queued(messageId)).isEmpty) {
      // The app caught up with the other client's move (one row, where the
      // server has it, nothing queued): check it again from here on. What the user did meanwhile acted on the old location.
      intent
        ..conflicted = false
        ..seen = null
        ..flagged = null
        ..location = null;
      _excusedFailures.addAll(
        [for (final c in await _queued(messageId, failed: true)) c.id],
      );
      _trace.add('  ($messageId is in sync again)');
    }
    if (r < 0.35) {
      final seen = !row.isSeen;
      _trace.add('  user: mark $what ${seen ? 'read' : 'unread'}');
      await _emails.setFlag(row.id, seen: seen);
      intent
        ..seen = seen
        ..touchedSeen = true;
      return;
    }
    if (r < 0.65) {
      final flagged = !row.isFlagged;
      _trace.add('  user: ${flagged ? 'star' : 'unstar'} $what');
      await _emails.setFlag(row.id, flagged: flagged);
      intent
        ..flagged = flagged
        ..touchedFlagged = true;
      return;
    }
    if (r < 0.9) {
      final dest = _pick(_folders.where((f) => f != row.mailboxPath).toList());
      _trace.add('  user: move $what to $dest');
      await _emails.moveEmail(row.id, dest);
      intent
        ..location = dest
        ..touchedLocation = true;
      return;
    }
    _trace.add('  user: delete $what');
    final dest = await _emails.deleteEmail(row.id);
    _trace.add('    -> ${dest ?? 'deleted for good'}');
    intent
      ..location = dest ?? _expunged
      ..touchedExpunge |= dest == null
      ..touchedLocation |= dest != null;
  }

  /// The pending (or [failed]) changes of the mail [messageId].
  Future<List<PendingChangeRow>> _queued(
    String messageId, {
    bool failed = false,
  }) async =>
      [
        for (final change in await _pendingRows(failed: failed))
          if (await _messageIdOf(change) == messageId) change,
      ];

  /// Another client changes the server (or new mail arrives).
  Future<void> _otherClient() async {
    final all = [
      for (final folder in _server.folders.values)
        for (final message in folder.messages.values)
          (folder: folder.path, message: message),
    ];
    final r = _rnd.nextDouble();
    if (all.isEmpty || r >= 0.95) {
      _deliver('INBOX');
      return;
    }
    final (:folder, :message) = _pick(all);
    final messageId = message.messageId;
    final intent = _intents[messageId]!;
    final where = '$messageId in $folder/${message.uid}';
    if (r < 0.4) {
      _trace.add('  other client: ${message.seen ? 'unread' : 'read'} $where');
      _server.setFlagElsewhere(messageId, r'\Seen', on: !message.seen);
      intent.seen = null;
      return;
    }
    if (r < 0.8) {
      _trace.add(
        '  other client: ${message.flagged ? 'unstar' : 'star'} $where',
      );
      _server.setFlagElsewhere(messageId, r'\Flagged', on: !message.flagged);
      intent.flagged = null;
      return;
    }
    intent
      ..seen = null
      ..flagged = null
      ..location = null
      ..conflicted = true;
    if (r < 0.9) {
      final dest = _pick(_folders.where((f) => f != folder).toList());
      _server.moveElsewhere(messageId, dest);
      _trace.add(
        '  other client: move $where to $dest/${message.uid}',
      );
      return;
    }
    _trace.add('  other client: expunge $where');
    _server.expungeElsewhere(messageId);
  }

  /// Runs cycles without user actions until the queue is empty and two
  /// cycles in a row change nothing, then checks the property.
  Future<List<String>> _settle() async {
    _hooksOn = false;
    _trace.add('settle');
    String? last;
    var stable = 0;
    for (var i = 0; i < 15 && stable < 2; i++) {
      await _cycle().timeout(const Duration(seconds: 10));
      final now = await _snapshot();
      final pending = await _pendingRows();
      stable = now == last && pending.isEmpty ? stable + 1 : 0;
      last = now;
    }
    if (stable < 2) return ['sync did not settle within 15 cycles'];

    // A due flag reconcile re-reads every flag: it must find nothing to fix.
    for (final folder in _folders) {
      await _expireFlagReconcile(_db, folder);
    }
    await _cycle();
    final before = last!.split('\n').toSet();
    final changed = [
      for (final line in (await _snapshot()).split('\n'))
        if (!before.contains(line)) line,
    ];
    final problems = await _check();
    if (changed.isNotEmpty) {
      problems.add(
        'a flag reconcile after settling changed: ${changed.join('; ')}',
      );
    }
    return problems;
  }

  Future<List<PendingChangeRow>> _pendingRows({bool failed = false}) =>
      (_db.select(_db.pendingChanges)
            ..where(
              (t) => failed
                  ? t.state.equals('failed')
                  : t.state.isIn(const ['pending', 'inflight']),
            ))
          .get();

  Future<String> _snapshot() async => [
        for (final row in await _localRows())
          '${row.id} ${row.messageId} ${row.isSeen} ${row.isFlagged}',
        _serverDump(),
      ].join('\n');

  String _serverDump() => [
        for (final folder in _server.folders.values)
          '${folder.path}: ${[
            for (final m in folder.messages.values)
              '${m.uid}=${m.messageId}'
                  '${m.seen ? ' seen' : ''}${m.flagged ? ' starred' : ''}',
          ].join(', ')}',
      ].join('; ');

  /// The Message-ID a queued change is about.
  Future<String?> _messageIdOf(PendingChangeRow change) async {
    final payload = jsonDecode(change.payload) as Map<String, dynamic>;
    if (payload['messageId'] case final String id) return id;
    final row = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(change.resourceId)))
        .getSingleOrNull();
    return row?.messageId;
  }

  Future<List<String>> _check() async {
    final problems = <String>[
      // Every row's read/star/snooze state is COALESCE(local_, srv_), and a
      // local_ value has an op behind it (SYNC-REDESIGN.md §8 phase 3).
      for (final p in await EmailStateWriter(_db).consistencyProblems())
        'overlay inconsistent: $p',
    ];

    final noIntentCheck = <String>{
      if (_refused case final refused?) refused,
      for (final MapEntry(:key, :value) in _intents.entries)
        if (value.conflicted) key,
    };
    // SYNC.md §6, known gap: a failed delete is not undone locally, and
    // the deleted row is not fetched back until a force resync.
    final failedDeletes = <String?>{};
    for (final change in await _pendingRows(failed: true)) {
      final messageId = await _messageIdOf(change);
      if (change.changeType == 'delete') failedDeletes.add(messageId);
      if (noIntentCheck.contains(messageId)) continue;
      if (_excusedFailures.contains(change.id)) continue;
      problems.add(
        'change #${change.id} ${change.changeType} ${change.payload} of '
        '$messageId failed: ${change.lastError}',
      );
    }

    final local = <String, List<Email>>{};
    for (final row in await _localRows()) {
      (local[row.messageId!] ??= []).add(row);
    }
    for (final MapEntry(key: messageId, value: intent) in _intents.entries) {
      final rows = local[messageId] ?? const <Email>[];
      // The known gap above.
      if (rows.isEmpty && failedDeletes.contains(messageId)) continue;
      final found = _server.find(messageId);
      problems.addAll(_checkRows(messageId, rows, found));
      if (noIntentCheck.contains(messageId)) continue;
      problems.addAll(_checkIntent(messageId, intent, found));
    }

    for (final error in _hookErrors) {
      problems.add('the stale-answer hook threw $error');
    }
    for (final hit in _server.hits) {
      final intent = _intents[hit.messageId]!;
      final touched = switch (hit.command) {
        r'STORE +\Seen' || r'STORE -\Seen' => intent.touchedSeen,
        r'STORE +\Flagged' || r'STORE -\Flagged' => intent.touchedFlagged,
        r'STORE +\Deleted' || 'EXPUNGE' => intent.touchedExpunge,
        final c when c.startsWith('MOVE ') => intent.touchedLocation,
        _ => false,
      };
      if (!touched) {
        problems.add(
          '${hit.command} hit ${hit.messageId}, which the user never asked '
          'for',
        );
      }
    }
    return problems;
  }

  /// [messageId]'s local [rows] against where the server has it ([found]).
  List<String> _checkRows(
    String messageId,
    List<Email> rows,
    ({FakeServerFolder folder, FakeServerMessage message})? found,
  ) {
    final ids = rows.map((r) => r.id).join(', ');
    if (found == null) {
      if (rows.isEmpty) return const [];
      return ['$messageId is gone on the server but shown locally as $ids'];
    }
    final (:folder, :message) = found;
    if (rows.length != 1) {
      return [
        '$messageId is in ${folder.path}/${message.uid} on the server but has '
            '${rows.length} local rows ($ids)',
      ];
    }
    final row = rows.single;
    return [
      if (row.srvMailboxPath != folder.path ||
          row.srvUid != message.uid ||
          row.mailboxPath != folder.path ||
          row.uid != message.uid)
        '$messageId is ${folder.path}/${message.uid} on the server but '
            '${row.srvMailboxPath}/${row.srvUid} (mailboxPath '
            '${row.mailboxPath}, uid ${row.uid}) locally',
      if (row.isSeen != message.seen)
        '$messageId: read is ${row.isSeen} locally, ${message.seen} on the '
            'server',
      if (row.isFlagged != message.flagged)
        '$messageId: starred is ${row.isFlagged} locally, ${message.flagged} '
            'on the server',
    ];
  }

  /// The server ([found]) against what the user last asked for.
  List<String> _checkIntent(
    String messageId,
    _Intent intent,
    ({FakeServerFolder folder, FakeServerMessage message})? found,
  ) {
    final location = found?.folder.path ?? _expunged;
    final seen = found?.message.seen;
    final flagged = found?.message.flagged;
    return [
      if (intent.location case final wanted? when wanted != location)
        '$messageId: user moved it to $wanted, it is $location',
      if (intent.seen case final wanted? when found != null && wanted != seen)
        '$messageId: user set read=$wanted, server has $seen',
      if (intent.flagged case final wanted?
          when found != null && wanted != flagged)
        '$messageId: user set starred=$wanted, server has $flagged',
    ];
  }

  Future<String> _report(List<String> problems) async {
    final pending = await _db.select(_db.pendingChanges).get();
    return [
      'stale-answer fuzz, seed $seed (rerun: STALE_FUZZ_SEED=$seed):',
      for (final p in problems) '  - $p',
      'server: ${_serverDump()}',
      'local:',
      for (final row in await _localRows())
        '  ${row.id} ${row.messageId} seen=${row.isSeen} '
            'starred=${row.isFlagged}',
      'queue:',
      for (final c in pending)
        '  #${c.id} ${c.state} ${c.changeType} ${c.payload} '
            'attempts=${c.attempts} ${c.lastError ?? ''}',
      'server changes by the app: '
          '${_server.hits.map((h) => '${h.command} ${h.messageId}').join(', ')}',
      'trace:',
      ..._trace,
    ].join('\n');
  }
}
