import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;

import '../../core/models/account.dart' as account_model;
import '../../core/models/email.dart' as model;
import '../../core/repositories/account_repository.dart';
import '../../core/repositories/email_repository.dart';
import '../db/database.dart';
import '../imap/imap_client_factory.dart';

typedef ImapConnectFn = Future<imap.ImapClient> Function(
    account_model.Account account, String password);
typedef SmtpConnectFn = Future<imap.SmtpClient> Function(
    account_model.Account account, String password);

class EmailRepositoryImpl implements EmailRepository {
  EmailRepositoryImpl(
    this._db,
    this._accounts, {
    ImapConnectFn imapConnect = connectImap,
    SmtpConnectFn smtpConnect = connectSmtp,
  })  : _imapConnect = imapConnect,
        _smtpConnect = smtpConnect;

  final AppDatabase _db;
  final AccountRepository _accounts;
  final ImapConnectFn _imapConnect;
  final SmtpConnectFn _smtpConnect;

  // ── Observe ────────────────────────────────────────────────────────────────

  @override
  Stream<List<model.Email>> observeEmails(
    String accountId,
    String mailboxPath,
  ) {
    return (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath),
          )
          ..orderBy([(t) => OrderingTerm.desc(t.receivedAt)]))
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }

  @override
  Future<model.Email?> getEmail(String emailId) async {
    final row = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(emailId)))
        .getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  // ── Body (on-demand) ───────────────────────────────────────────────────────

  @override
  Future<model.EmailBody> getEmailBody(String emailId) async {
    final cached = await (_db.select(_db.emailBodies)
          ..where((t) => t.emailId.equals(emailId)))
        .getSingleOrNull();
    if (cached != null) return _bodyRowToModel(cached);

    final emailRow = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(emailId)))
        .getSingle();
    final account = (await _accounts.getAccount(emailRow.accountId))!;
    final password = await _accounts.getPassword(account.id);
    final client = await _imapConnect(account, password);
    try {
      await client.selectMailboxByPath(emailRow.mailboxPath);
      final fetch = await client.uidFetchMessage(emailRow.uid, '(BODY[])');
      final msg = fetch.messages.first;
      final textBody = msg.decodeTextPlainPart();
      final htmlBody = msg.decodeTextHtmlPart();
      final contentInfos = msg.findContentInfo();

      final attachmentsJson = jsonEncode(
        contentInfos
            .map(
              (a) => {
                'filename': a.fileName ?? '',
                'contentType': a.contentType?.mediaType.text ?? '',
                'size': a.size ?? 0,
              },
            )
            .toList(),
      );

      await _db.into(_db.emailBodies).insertOnConflictUpdate(
            EmailBodiesCompanion.insert(
              emailId: emailId,
              textBody: Value(textBody),
              htmlBody: Value(htmlBody),
              attachmentsJson: Value(attachmentsJson),
            ),
          );
      return model.EmailBody(
        emailId: emailId,
        textBody: textBody,
        htmlBody: htmlBody,
        attachments: _parseAttachments(attachmentsJson),
      );
    } finally {
      await client.logout();
    }
  }

  // ── Sync ───────────────────────────────────────────────────────────────────

  @override
  Future<void> syncEmails(String accountId, String mailboxPath) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    final client = await _imapConnect(account, password);
    try {
      await client.selectMailboxByPath(mailboxPath);
      final fetch = await client.fetchMessages(
        imap.MessageSequence.fromAll(),
        '(UID FLAGS ENVELOPE BODYSTRUCTURE)',
      );
      for (final msg in fetch.messages) {
        final envelope = msg.envelope;
        if (envelope == null) continue;
        final uid = msg.uid;
        if (uid == null) continue;
        final emailId = '$accountId:$uid';

        await _db.into(_db.emails).insertOnConflictUpdate(
              EmailsCompanion.insert(
                id: emailId,
                accountId: accountId,
                mailboxPath: mailboxPath,
                uid: uid,
                subject: Value(envelope.subject),
                sentAt: Value(envelope.date),
                receivedAt: envelope.date ?? DateTime.now(),
                fromJson: Value(_encodeAddresses(envelope.from)),
                toAddresses: Value(_encodeAddresses(envelope.to)),
                ccJson: Value(_encodeAddresses(envelope.cc)),
                isSeen: Value(msg.flags?.contains(r'\Seen') ?? false),
                isFlagged: Value(msg.flags?.contains(r'\Flagged') ?? false),
                hasAttachment: Value(msg.hasAttachments()),
              ),
            );
      }
    } finally {
      await client.logout();
    }
  }

  // ── Mutations ──────────────────────────────────────────────────────────────

  @override
  Future<void> setFlag(
    String emailId, {
    bool? seen,
    bool? flagged,
  }) async {
    final row = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(emailId)))
        .getSingle();
    final account = (await _accounts.getAccount(row.accountId))!;
    final password = await _accounts.getPassword(account.id);
    final client = await _imapConnect(account, password);
    try {
      await client.selectMailboxByPath(row.mailboxPath);
      final seq = imap.MessageSequence.fromId(row.uid, isUid: true);
      if (seen != null) {
        seen
            ? await client.uidMarkSeen(seq)
            : await client.uidMarkUnseen(seq);
      }
      if (flagged != null) {
        flagged
            ? await client.uidMarkFlagged(seq)
            : await client.uidMarkUnflagged(seq);
      }
      await (_db.update(_db.emails)..where((t) => t.id.equals(emailId)))
          .write(
        EmailsCompanion(
          isSeen: seen != null ? Value(seen) : const Value.absent(),
          isFlagged: flagged != null ? Value(flagged) : const Value.absent(),
        ),
      );
    } finally {
      await client.logout();
    }
  }

  @override
  Future<void> moveEmail(String emailId, String destMailboxPath) async {
    final row = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(emailId)))
        .getSingle();
    final account = (await _accounts.getAccount(row.accountId))!;
    final password = await _accounts.getPassword(account.id);
    final client = await _imapConnect(account, password);
    try {
      await client.selectMailboxByPath(row.mailboxPath);
      await client.uidMove(
        imap.MessageSequence.fromId(row.uid, isUid: true),
        targetMailboxPath: destMailboxPath,
      );
      await (_db.delete(_db.emails)..where((t) => t.id.equals(emailId))).go();
    } finally {
      await client.logout();
    }
  }

  @override
  Future<void> deleteEmail(String emailId) async {
    final row = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(emailId)))
        .getSingle();
    final account = (await _accounts.getAccount(row.accountId))!;
    final password = await _accounts.getPassword(account.id);
    final client = await _imapConnect(account, password);
    try {
      await client.selectMailboxByPath(row.mailboxPath);
      final seq = imap.MessageSequence.fromId(row.uid, isUid: true);
      await client.uidMarkDeleted(seq);
      await client.uidExpunge(seq);
      await (_db.delete(_db.emails)..where((t) => t.id.equals(emailId))).go();
    } finally {
      await client.logout();
    }
  }

  @override
  Future<void> sendEmail(String accountId, model.EmailDraft draft) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    final smtpClient = await _smtpConnect(account, password);
    try {
      final builder = imap.MessageBuilder()
        ..from = [imap.MailAddress(draft.from.name, draft.from.email)]
        ..to = draft.to
            .map((a) => imap.MailAddress(a.name, a.email))
            .toList()
        ..cc = draft.cc
            .map((a) => imap.MailAddress(a.name, a.email))
            .toList()
        ..subject = draft.subject
        ..text = draft.body;
      await smtpClient.sendMessage(builder.buildMimeMessage());
    } finally {
      await smtpClient.quit();
    }
  }

  @override
  Future<List<model.Email>> searchEmails(
    String accountId,
    String mailboxPath,
    String query,
  ) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    final client = await _imapConnect(account, password);
    try {
      await client.selectMailboxByPath(mailboxPath);
      final escaped = query.replaceAll('"', '\\"');
      final result = await client.uidSearchMessages(
        searchCriteria: 'OR SUBJECT "$escaped" TEXT "$escaped"',
      );
      final uids = result.matchingSequence?.toList() ?? [];
      if (uids.isEmpty) return [];

      final fetch = await client.fetchMessages(
        imap.MessageSequence.fromIds(uids, isUid: true),
        '(UID FLAGS ENVELOPE)',
      );
      return fetch.messages
          .where((msg) => msg.uid != null && msg.envelope != null)
          .map((msg) {
        final envelope = msg.envelope!;
        final uid = msg.uid!;
        final emailId = '$accountId:$uid';
        return model.Email(
          id: emailId,
          accountId: accountId,
          mailboxPath: mailboxPath,
          uid: uid,
          subject: envelope.subject,
          sentAt: envelope.date,
          receivedAt: envelope.date ?? DateTime.now(),
          from: _toAddressList(envelope.from),
          to: _toAddressList(envelope.to),
          cc: _toAddressList(envelope.cc),
          isSeen: msg.flags?.contains(r'\Seen') ?? false,
          isFlagged: msg.flags?.contains(r'\Flagged') ?? false,
          hasAttachment: msg.hasAttachments(),
        );
      }).toList();
    } finally {
      await client.logout();
    }
  }

  List<model.EmailAddress> _toAddressList(List<imap.MailAddress>? addresses) =>
      (addresses ?? const [])
          .map(
            (a) => model.EmailAddress(
              name: a.personalName,
              email: a.email,
            ),
          )
          .toList();

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _encodeAddresses(List<imap.MailAddress>? addresses) => jsonEncode(
        (addresses ?? const [])
            .map((a) => {'name': a.personalName, 'email': a.email})
            .toList(),
      );

  model.Email _toModel(Email row) {
    List<model.EmailAddress> parseAddresses(String json) {
      final list = jsonDecode(json) as List<dynamic>;
      return list
          .map(
            (e) => model.EmailAddress(
              name: (e as Map<String, dynamic>)['name'] as String?,
              email: e['email'] as String,
            ),
          )
          .toList();
    }

    return model.Email(
      id: row.id,
      accountId: row.accountId,
      mailboxPath: row.mailboxPath,
      uid: row.uid,
      subject: row.subject,
      sentAt: row.sentAt,
      receivedAt: row.receivedAt,
      from: parseAddresses(row.fromJson),
      to: parseAddresses(row.toAddresses),
      cc: parseAddresses(row.ccJson),
      preview: row.preview,
      isSeen: row.isSeen,
      isFlagged: row.isFlagged,
      hasAttachment: row.hasAttachment,
    );
  }

  model.EmailBody _bodyRowToModel(EmailBody row) => model.EmailBody(
        emailId: row.emailId,
        textBody: row.textBody,
        htmlBody: row.htmlBody,
        attachments: _parseAttachments(row.attachmentsJson),
      );

  List<model.EmailAttachment> _parseAttachments(String json) {
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map(
          (e) => model.EmailAttachment(
            filename: (e as Map<String, dynamic>)['filename'] as String,
            contentType: e['contentType'] as String,
            size: e['size'] as int,
          ),
        )
        .toList();
  }
}
