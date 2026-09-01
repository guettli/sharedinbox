import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/filter/filter_json.dart';
import 'package:sharedinbox/core/models/email.dart' as model;
import 'package:sharedinbox/core/models/notification_rule.dart';
import 'package:sharedinbox/core/repositories/notification_rule_repository.dart';
import 'package:sharedinbox/data/db/database.dart';

class NotificationRuleRepositoryImpl implements NotificationRuleRepository {
  NotificationRuleRepositoryImpl(this._db);

  final AppDatabase _db;

  NotificationRule _toModel(NotificationRuleRow row) => NotificationRule(
        id: row.id,
        accountId: row.accountId,
        name: row.name,
        filter: filterGroupFromJson(row.expressionJson),
        createdAt: row.createdAt,
      );

  @override
  Stream<List<NotificationRule>> watchRules(String accountId) {
    final query = _db.select(_db.notificationRules)
      ..where((t) => t.accountId.equals(accountId))
      ..orderBy([(t) => OrderingTerm.desc(t.id)]);
    return query.watch().map((rows) => rows.map(_toModel).toList());
  }

  @override
  Future<List<NotificationRule>> listRules(String accountId) async {
    final rows = await (_db.select(_db.notificationRules)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([(t) => OrderingTerm.desc(t.id)]))
        .get();
    return rows.map(_toModel).toList();
  }

  @override
  Future<int> addRule(String accountId, FilterGroup filter, {String? name}) {
    return _db.into(_db.notificationRules).insert(
          NotificationRulesCompanion.insert(
            accountId: accountId,
            name: Value(name),
            expressionJson: filterGroupToJson(filter),
            createdAt: DateTime.now(),
          ),
        );
  }

  @override
  Future<void> updateRule(int id, FilterGroup filter, {String? name}) async {
    await (_db.update(_db.notificationRules)..where((t) => t.id.equals(id)))
        .write(
      NotificationRulesCompanion(
        name: Value(name),
        expressionJson: Value(filterGroupToJson(filter)),
      ),
    );
  }

  @override
  Future<void> deleteRule(int id) async {
    await (_db.delete(_db.notificationRules)..where((t) => t.id.equals(id)))
        .go();
  }

  /// The set of mailbox paths that count as "inbox" for [accountId]. IMAP uses
  /// the literal path `INBOX`; JMAP tags its inbox with role `inbox`.
  Future<Set<String>> _inboxPaths(String accountId) async {
    final rows = await (_db.select(_db.mailboxes)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                (t.role.equals('inbox') | t.path.equals('INBOX')),
          ))
        .get();
    return rows.map((r) => r.path).toSet();
  }

  @override
  Future<List<model.Email>> unnotifiedInboxEmails(String accountId) async {
    final paths = await _inboxPaths(accountId);
    if (paths.isEmpty) return const [];
    final rows = await (_db.select(_db.emails)
          ..where(
            (t) => t.accountId.equals(accountId) & t.mailboxPath.isIn(paths),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.receivedAt)]))
        .get();
    final notified = await (_db.select(_db.notifiedEmails)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    final notifiedIds = notified.map((r) => r.emailId).toSet();
    return [
      for (final row in rows)
        if (!notifiedIds.contains(row.id)) _emailToModel(row),
    ];
  }

  @override
  Future<void> markNotified(String accountId, List<String> emailIds) async {
    if (emailIds.isEmpty) return;
    final now = DateTime.now();
    await _db.batch((b) {
      b.insertAll(
        _db.notifiedEmails,
        [
          for (final id in emailIds)
            NotifiedEmailsCompanion.insert(
              accountId: accountId,
              emailId: id,
              notifiedAt: now,
            ),
        ],
        mode: InsertMode.insertOrIgnore,
      );
    });
  }

  @override
  Future<void> markBaseline(String accountId) async {
    final paths = await _inboxPaths(accountId);
    if (paths.isEmpty) return;
    final rows = await (_db.select(_db.emails)
          ..where(
            (t) => t.accountId.equals(accountId) & t.mailboxPath.isIn(paths),
          ))
        .get();
    await markNotified(accountId, [for (final row in rows) row.id]);
  }

  model.Email _emailToModel(Email row) {
    List<model.EmailAddress> parse(String json) {
      final list = jsonDecode(json) as List<dynamic>;
      return [
        for (final e in list)
          model.EmailAddress(
            name: (e as Map<String, dynamic>)['name'] as String?,
            email: e['email'] as String,
          ),
      ];
    }

    return model.Email(
      id: row.id,
      accountId: row.accountId,
      mailboxPath: row.mailboxPath,
      uid: row.uid,
      subject: row.subject,
      sentAt: row.sentAt,
      receivedAt: row.receivedAt,
      from: parse(row.fromJson),
      to: parse(row.toAddresses),
      cc: parse(row.ccJson),
      preview: row.preview,
      isSeen: row.isSeen,
      isFlagged: row.isFlagged,
      hasAttachment: row.hasAttachment,
      threadId: row.threadId,
      messageId: row.messageId,
      inReplyTo: row.inReplyTo,
      references: row.references,
      snoozedUntil: row.snoozedUntil,
      snoozedFromMailboxPath: row.snoozedFromMailboxPath,
      listUnsubscribeHeader: row.listUnsubscribeHeader,
      isLocal: row.isLocal,
    );
  }
}
