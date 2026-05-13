import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/draft.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/draft_repository.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';

class DraftRepositoryImpl implements DraftRepository {
  DraftRepositoryImpl(
    this._db,
    this._accounts, {
    ImapConnectFn? imapConnect,
  }) : _imapConnect = imapConnect;

  final AppDatabase _db;
  final AccountRepository _accounts;
  final ImapConnectFn? _imapConnect;

  @override
  Future<SavedDraft> saveDraft({
    int? id,
    String? accountId,
    String? replyToEmailId,
    required String toText,
    required String ccText,
    required String subjectText,
    required String bodyText,
  }) async {
    final now = DateTime.now();
    if (id != null) {
      await (_db.update(_db.drafts)..where((t) => t.id.equals(id))).write(
        DraftsCompanion(
          accountId: Value(accountId),
          replyToEmailId: Value(replyToEmailId),
          toText: Value(toText),
          ccText: Value(ccText),
          subjectText: Value(subjectText),
          bodyText: Value(bodyText),
          updatedAt: Value(now),
        ),
      );
      return SavedDraft(
        id: id,
        accountId: accountId,
        replyToEmailId: replyToEmailId,
        toText: toText,
        ccText: ccText,
        subjectText: subjectText,
        bodyText: bodyText,
        updatedAt: now,
      );
    }

    final newId = await _db.into(_db.drafts).insert(
          DraftsCompanion.insert(
            accountId: Value(accountId),
            replyToEmailId: Value(replyToEmailId),
            toText: Value(toText),
            ccText: Value(ccText),
            subjectText: Value(subjectText),
            bodyText: Value(bodyText),
            updatedAt: now,
          ),
        );
    return SavedDraft(
      id: newId,
      accountId: accountId,
      replyToEmailId: replyToEmailId,
      toText: toText,
      ccText: ccText,
      subjectText: subjectText,
      bodyText: bodyText,
      updatedAt: now,
    );
  }

  @override
  Future<SavedDraft?> findDraft({String? replyToEmailId}) async {
    final query = _db.select(_db.drafts);
    if (replyToEmailId == null) {
      query.where((t) => t.replyToEmailId.isNull());
    } else {
      query.where((t) => t.replyToEmailId.equals(replyToEmailId));
    }
    query.orderBy([(t) => OrderingTerm.desc(t.id)]);
    query.limit(1);
    final row = await query.getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  @override
  Future<SavedDraft?> getDraft(int id) async {
    final row = await (_db.select(
      _db.drafts,
    )..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  @override
  Future<void> deleteDraft(int id) async {
    await (_db.delete(_db.drafts)..where((t) => t.id.equals(id))).go();
  }

  @override
  Future<void> syncDrafts(String accountId, String password) async {
    final connect = _imapConnect;
    if (connect == null) return;

    final account = await _accounts.getAccount(accountId);
    if (account == null || account.type != AccountType.imap) return;

    final username =
        account.username.isNotEmpty ? account.username : account.email;
    imap.ImapClient? client;
    try {
      client = await connect(account, username, password);
      await _syncWithServer(client, accountId);
    } finally {
      await client?.logout();
    }
  }

  Future<void> _syncWithServer(
    imap.ImapClient client,
    String accountId,
  ) async {
    // Create/select the Drafts folder.
    try {
      await client.createMailbox('Drafts');
    } catch (_) {
      // Already exists.
    }
    final selectResult = await client.selectMailboxByPath('Drafts');
    final messageCount = selectResult.messagesExists;

    // Upload local drafts that have no server counterpart.
    final localDrafts = await (_db.select(_db.drafts)
          ..where(
            (t) => t.accountId.equals(accountId) & t.imapServerId.isNull(),
          ))
        .get();

    for (final row in localDrafts) {
      final builder = imap.MessageBuilder()
        ..to = _parseAddresses(row.toText)
        ..cc = _parseAddresses(row.ccText)
        ..subject = row.subjectText
        ..text = row.bodyText;
      final mime = builder.buildMimeMessage();
      final appendResult = await client.appendMessage(
        mime,
        targetMailboxPath: 'Drafts',
        flags: [r'\Draft'],
      );
      final uidList =
          appendResult.responseCodeAppendUid?.targetSequence.toList();
      final uid = (uidList != null && uidList.isNotEmpty)
          ? uidList.first.toString()
          : null;
      if (uid != null) {
        await (_db.update(_db.drafts)..where((t) => t.id.equals(row.id)))
            .write(DraftsCompanion(imapServerId: Value(uid)));
      }
    }

    // Download server drafts not tracked locally.
    if (messageCount > 0) {
      final knownServerIds = await (_db.select(_db.drafts)
            ..where(
              (t) => t.accountId.equals(accountId) & t.imapServerId.isNotNull(),
            ))
          .get();
      final knownIds = knownServerIds.map((r) => r.imapServerId!).toSet();

      final seq = imap.MessageSequence.fromAll();
      final fetch = await client.uidFetchMessages(seq, '(UID FLAGS ENVELOPE)');
      for (final msg in fetch.messages) {
        final uid = msg.uid?.toString();
        if (uid == null || knownIds.contains(uid)) continue;
        if (msg.flags?.contains(r'\Deleted') ?? false) continue;
        final env = msg.envelope;
        final now = DateTime.now();
        await _db.into(_db.drafts).insert(
              DraftsCompanion.insert(
                accountId: Value(accountId),
                toText: Value(_addressListToText(env?.to)),
                ccText: Value(_addressListToText(env?.cc)),
                subjectText: Value(env?.subject ?? ''),
                bodyText: const Value(''),
                updatedAt: now,
                imapServerId: Value(uid),
              ),
            );
      }
    }
  }

  List<imap.MailAddress> _parseAddresses(String text) {
    if (text.trim().isEmpty) return [];
    return text.split(',').map((s) => imap.MailAddress('', s.trim())).toList();
  }

  String _addressListToText(List<imap.MailAddress>? addresses) {
    if (addresses == null || addresses.isEmpty) return '';
    return addresses.map((a) => a.email).join(', ');
  }

  SavedDraft _toModel(Draft row) => SavedDraft(
        id: row.id,
        accountId: row.accountId,
        replyToEmailId: row.replyToEmailId,
        toText: row.toText,
        ccText: row.ccText,
        subjectText: row.subjectText,
        bodyText: row.bodyText,
        updatedAt: row.updatedAt,
        imapServerId: row.imapServerId,
      );
}
