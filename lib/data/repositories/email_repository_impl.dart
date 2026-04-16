import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;

import '../../core/models/email.dart';
import '../../core/repositories/account_repository.dart';
import '../../core/repositories/email_repository.dart';
import '../db/database.dart';
import '../db/database.dart' as db show Email, EmailBody;
import '../imap/imap_client_factory.dart';

class EmailRepositoryImpl implements EmailRepository {
  EmailRepositoryImpl(this._db, this._accounts);

  final AppDatabase _db;
  final AccountRepository _accounts;

  // ── Observe ────────────────────────────────────────────────────────────────

  @override
  Stream<List<Email>> observeEmails(String accountId, String mailboxPath) {
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
  Future<Email?> getEmail(String emailId) async {
    final row = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(emailId)))
        .getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  // ── Body (on-demand) ───────────────────────────────────────────────────────

  @override
  Future<EmailBody> getEmailBody(String emailId) async {
    final cached = await (_db.select(_db.emailBodies)
          ..where((t) => t.emailId.equals(emailId)))
        .getSingleOrNull();
    if (cached != null) return _bodyRowToModel(cached);

    final emailRow = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(emailId)))
        .getSingle();
    final account = (await _accounts.getAccount(emailRow.accountId))!;
    final password = await _accounts.getPassword(account.id);
    final client = await connectImap(account, password);
    try {
      await client.selectMailboxByPath(emailRow.mailboxPath);
      final fetch = await client.fetchMessage(
        imap.MessageSequence.fromId(emailRow.uid, isUid: true),
        '(BODY[])',
        isUidSequence: true,
      );
      final msg = fetch.messages.first;
      final textBody = msg.decodeTextPlainPart();
      final htmlBody = msg.decodeTextHtmlPart();
      final contentInfos = msg.findContentInfo(
        disposition: imap.ContentDisposition.attachment,
      );

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
      return EmailBody(
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
    final client = await connectImap(account, password);
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
        final emailId = '${accountId}:$uid';

        await _db.into(_db.emails).insertOnConflictUpdate(
              EmailsCompanion.insert(
                id: emailId,
                accountId: accountId,
                mailboxPath: mailboxPath,
                uid: Value(uid),
                subject: Value(envelope.subject),
                sentAt: Value(envelope.date),
                receivedAt: Value(envelope.date ?? DateTime.now()),
                fromJson: Value(_encodeAddresses(envelope.from)),
                toJson: Value(_encodeAddresses(envelope.to)),
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
  Future<void> setFlag(String emailId, {bool? seen, bool? flagged}) async {
    final row = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(emailId)))
        .getSingle();
    final account = (await _accounts.getAccount(row.accountId))!;
    final password = await _accounts.getPassword(account.id);
    final client = await connectImap(account, password);
    try {
      await client.selectMailboxByPath(row.mailboxPath);
      final seq = imap.MessageSequence.fromId(row.uid, isUid: true);
      if (seen != null) {
        seen
            ? await client.markSeen(seq, isUidSequence: true)
            : await client.markUnseen(seq, isUidSequence: true);
      }
      if (flagged != null) {
        flagged
            ? await client.markFlagged(seq, isUidSequence: true)
            : await client.markUnflagged(seq, isUidSequence: true);
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
    final client = await connectImap(account, password);
    try {
      await client.selectMailboxByPath(row.mailboxPath);
      await client.move(
        imap.MessageSequence.fromId(row.uid, isUid: true),
        targetMailboxPath: destMailboxPath,
        isUidSequence: true,
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
    final client = await connectImap(account, password);
    try {
      await client.selectMailboxByPath(row.mailboxPath);
      await client.deleteMessages(
        imap.MessageSequence.fromId(row.uid, isUid: true),
        isUidSequence: true,
      );
      await (_db.delete(_db.emails)..where((t) => t.id.equals(emailId))).go();
    } finally {
      await client.logout();
    }
  }

  @override
  Future<void> sendEmail(String accountId, EmailDraft draft) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    final smtpClient = await connectSmtp(account, password);
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

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _encodeAddresses(List<imap.MailAddress>? addresses) =>
      jsonEncode(
        (addresses ?? const [])
            .map((a) => {'name': a.personalName, 'email': a.email})
            .toList(),
      );

  Email _toModel(db.Email row) {
    List<EmailAddress> parseAddresses(String json) {
      final list = jsonDecode(json) as List;
      return list
          .map(
            (e) => EmailAddress(
              name: e['name'] as String?,
              email: e['email'] as String,
            ),
          )
          .toList();
    }

    return Email(
      id: row.id,
      accountId: row.accountId,
      mailboxPath: row.mailboxPath,
      uid: row.uid,
      subject: row.subject,
      sentAt: row.sentAt,
      receivedAt: row.receivedAt,
      from: parseAddresses(row.fromJson),
      to: parseAddresses(row.toJson),
      cc: parseAddresses(row.ccJson),
      preview: row.preview,
      isSeen: row.isSeen,
      isFlagged: row.isFlagged,
      hasAttachment: row.hasAttachment,
    );
  }

  EmailBody _bodyRowToModel(db.EmailBody row) => EmailBody(
        emailId: row.emailId,
        textBody: row.textBody,
        htmlBody: row.htmlBody,
        attachments: _parseAttachments(row.attachmentsJson),
      );

  List<EmailAttachment> _parseAttachments(String json) {
    final list = jsonDecode(json) as List;
    return list
        .map(
          (e) => EmailAttachment(
            filename: e['filename'] as String,
            contentType: e['contentType'] as String,
            size: e['size'] as int,
          ),
        )
        .toList();
  }
}
