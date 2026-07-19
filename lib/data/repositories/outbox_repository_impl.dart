import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;

import 'package:sharedinbox/core/models/email.dart' as model;
import 'package:sharedinbox/core/models/outbox_message.dart';
import 'package:sharedinbox/core/repositories/outbox_repository.dart';
import 'package:sharedinbox/data/db/database.dart';

/// Backoff schedule (in seconds). Capped at the last entry — once `attempts`
/// exceeds the table length we wait this long between every further retry.
/// Short first retry so a brief network blip recovers fast, then back off so
/// a server outage doesn't generate noise.
const _backoffSeconds = [30, 120, 600, 3600];

class OutboxRepositoryImpl implements OutboxRepository {
  OutboxRepositoryImpl(this._db);

  final AppDatabase _db;

  @override
  Future<int> enqueue(String accountId, model.EmailDraft draft) async {
    final builder = _buildMime(draft);
    final mime = builder.buildMimeMessage().renderMessage();
    final mimeBase64 = base64.encode(utf8.encode(mime));
    final envelope = jsonEncode({
      'from': draft.from.toJson(),
      'to': draft.to.map((a) => a.toJson()).toList(),
      'cc': draft.cc.map((a) => a.toJson()).toList(),
      'subject': draft.subject,
      'body': draft.body,
    });
    final attachmentsJson = jsonEncode(draft.attachmentFilePaths);
    return _db.into(_db.outbox).insert(
          OutboxCompanion.insert(
            accountId: accountId,
            mimeBase64: mimeBase64,
            envelopeJson: envelope,
            attachmentsJson: Value(attachmentsJson),
            createdAt: DateTime.now(),
          ),
        );
  }

  @override
  Future<int> flush(
    String accountId,
    Future<void> Function(OutboxJob job) sender, {
    DateTime? now,
    OutboxFlushObserver? observer,
  }) async {
    final at = now ?? DateTime.now();
    // Pending rows whose next attempt time is null or has already passed.
    final rows = await (_db.select(_db.outbox)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.status.equals('pending') &
                (t.nextAttemptAt.isNull() |
                    t.nextAttemptAt.isSmallerOrEqualValue(at)),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
    if (rows.isEmpty) return 0;

    var sent = 0;
    for (final row in rows) {
      final draft = _decodeEnvelope(row.envelopeJson, row.attachmentsJson);
      final mimeBytes = base64.decode(row.mimeBase64);
      final job = OutboxJob(
        id: row.id,
        accountId: row.accountId,
        draft: draft,
        mimeBytes: mimeBytes,
        attempts: row.attempts,
      );
      _safeNotify(() => observer?.onAttempt?.call(job));
      try {
        await sender(job);
        await (_db.delete(_db.outbox)..where((t) => t.id.equals(row.id))).go();
        sent++;
        _safeNotify(() => observer?.onOk?.call(job));
      } on PermanentSendException catch (e) {
        await (_db.update(_db.outbox)..where((t) => t.id.equals(row.id))).write(
          OutboxCompanion(
            status: const Value('failed'),
            lastError: Value(e.message),
            attempts: Value(row.attempts + 1),
          ),
        );
        _safeNotify(() => observer?.onPermanent?.call(job, e));
      } catch (e, stack) {
        final attempts = row.attempts + 1;
        final delaySec = _backoffSeconds[
            (attempts - 1).clamp(0, _backoffSeconds.length - 1)];
        final nextAttemptAt = at.add(Duration(seconds: delaySec));
        await (_db.update(_db.outbox)..where((t) => t.id.equals(row.id))).write(
          OutboxCompanion(
            attempts: Value(attempts),
            lastError: Value(e.toString()),
            nextAttemptAt: Value(nextAttemptAt),
          ),
        );
        _safeNotify(
          () => observer?.onTransient?.call(job, e, stack, nextAttemptAt),
        );
      }
    }
    return sent;
  }

  // Observer hooks are best-effort — a buggy callback (e.g. a logger that
  // fell over) must never turn a successful send into a stuck queue row.
  void _safeNotify(void Function() fn) {
    try {
      fn();
    } catch (_) {}
  }

  @override
  Stream<List<OutboxMessage>> observeOutbox(String accountId) {
    return (_db.select(_db.outbox)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch()
        .map((rows) => rows.map(_rowToMessage).toList());
  }

  @override
  Stream<List<OutboxMessage>> observeAllOutbox() {
    return (_db.select(_db.outbox)
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch()
        .map((rows) => rows.map(_rowToMessage).toList());
  }

  @override
  Future<void> retry(int id) async {
    await (_db.update(_db.outbox)..where((t) => t.id.equals(id))).write(
      const OutboxCompanion(
        attempts: Value(0),
        lastError: Value(null),
        nextAttemptAt: Value(null),
        status: Value('pending'),
      ),
    );
  }

  @override
  Future<void> discard(int id) async {
    await (_db.delete(_db.outbox)..where((t) => t.id.equals(id))).go();
  }
}

model.EmailDraft _decodeEnvelope(String envelopeJson, String attachmentsJson) {
  final env = jsonDecode(envelopeJson) as Map<String, dynamic>;
  final atts = jsonDecode(attachmentsJson) as List<dynamic>;
  return model.EmailDraft(
    from: model.EmailAddress.fromJson(env['from'] as Map<String, dynamic>),
    to: (env['to'] as List<dynamic>)
        .map((e) => model.EmailAddress.fromJson(e as Map<String, dynamic>))
        .toList(),
    cc: (env['cc'] as List<dynamic>)
        .map((e) => model.EmailAddress.fromJson(e as Map<String, dynamic>))
        .toList(),
    subject: env['subject'] as String? ?? '',
    body: env['body'] as String? ?? '',
    attachmentFilePaths: atts.cast<String>(),
  );
}

OutboxMessage _rowToMessage(OutboxRow row) {
  final env = jsonDecode(row.envelopeJson) as Map<String, dynamic>;
  return OutboxMessage(
    id: row.id,
    accountId: row.accountId,
    subject: env['subject'] as String? ?? '',
    to: (env['to'] as List<dynamic>?)
            ?.map((e) => (e as Map<String, dynamic>)['email'] as String)
            .toList() ??
        const [],
    cc: (env['cc'] as List<dynamic>?)
            ?.map((e) => (e as Map<String, dynamic>)['email'] as String)
            .toList() ??
        const [],
    createdAt: row.createdAt,
    attempts: row.attempts,
    lastError: row.lastError,
    nextAttemptAt: row.nextAttemptAt,
    status: row.status,
  );
}

imap.MessageBuilder _buildMime(model.EmailDraft draft) {
  return imap.MessageBuilder()
    ..from = [imap.MailAddress(draft.from.name, draft.from.email)]
    ..to = draft.to.map((a) => imap.MailAddress(a.name, a.email)).toList()
    ..cc = draft.cc.map((a) => imap.MailAddress(a.name, a.email)).toList()
    ..subject = draft.subject
    ..text = draft.body;
}
