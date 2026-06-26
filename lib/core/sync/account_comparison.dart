import 'package:drift/drift.dart';

import 'package:sharedinbox/core/models/account.dart' as model;
import 'package:sharedinbox/data/db/database.dart';

/// Compares the local-DB state of two accounts that should mirror the same
/// mailbox on the server (one IMAP, one JMAP). Both sides are read from the
/// local Drift database, so this measures whether the two protocol-specific
/// sync paths arrive at the same picture — it does not talk to a server.
///
/// Matching cannot use protocol IDs (IMAP UIDs vs JMAP opaque ids), so:
///   - mailboxes are matched by `role` first, then by lower-cased `name`;
///   - emails are matched by RFC 2822 Message-ID inside a matched mailbox;
///   - bodies are compared only when both sides cached one.
class AccountComparison {
  AccountComparison(this._db);

  final AppDatabase _db;

  /// Two accounts qualify as a comparable IMAP/JMAP pair when they target the
  /// same host and use the same effective username, and one is IMAP while the
  /// other is JMAP.
  static bool isComparablePair(model.Account a, model.Account b) {
    if (a.id == b.id) return false;
    if (a.type == b.type) return false;
    final hostA = _hostFor(a);
    final hostB = _hostFor(b);
    if (hostA.isEmpty || hostB.isEmpty) return false;
    if (hostA != hostB) return false;
    return _effectiveUsername(a) == _effectiveUsername(b);
  }

  /// Returns every other account that forms a comparable pair with [account].
  static List<model.Account> counterpartsOf(
    model.Account account,
    Iterable<model.Account> all,
  ) {
    return [
      for (final other in all)
        if (isComparablePair(account, other)) other,
    ];
  }

  static String _hostFor(model.Account a) {
    switch (a.type) {
      case model.AccountType.imap:
        return a.imapHost.trim().toLowerCase();
      case model.AccountType.jmap:
        final url = a.jmapUrl;
        if (url == null || url.isEmpty) return '';
        final parsed = Uri.tryParse(url);
        return (parsed?.host ?? '').toLowerCase();
    }
  }

  static String _effectiveUsername(model.Account a) {
    final u = a.username.trim();
    if (u.isNotEmpty) return u.toLowerCase();
    return a.email.trim().toLowerCase();
  }

  /// Reads both accounts' rows and produces an [AccountComparisonResult].
  Future<AccountComparisonResult> compare(
    String accountIdA,
    String accountIdB,
  ) async {
    final mailboxesA = await _mailboxesFor(accountIdA);
    final mailboxesB = await _mailboxesFor(accountIdB);
    final mailboxDiffs = <MailboxDiff>[];

    final unmatchedA = [...mailboxesA];
    final unmatchedB = [...mailboxesB];
    final paired = <(MailboxRow, MailboxRow)>[];

    // 1. Match by exact (role, name) case-insensitive
    for (int i = unmatchedA.length - 1; i >= 0; i--) {
      final a = unmatchedA[i];
      final bIdx = unmatchedB.indexWhere(
        (b) => a.role == b.role && a.name.toLowerCase() == b.name.toLowerCase(),
      );
      if (bIdx != -1) {
        paired.add((a, unmatchedB.removeAt(bIdx)));
        unmatchedA.removeAt(i);
      }
    }

    // 2. Match by role (when both have the same non-null role)
    for (int i = unmatchedA.length - 1; i >= 0; i--) {
      final a = unmatchedA[i];
      if (a.role == null || a.role!.isEmpty) continue;
      final bIdx = unmatchedB.indexWhere((b) => b.role == a.role);
      if (bIdx != -1) {
        paired.add((a, unmatchedB.removeAt(bIdx)));
        unmatchedA.removeAt(i);
      }
    }

    // 3. Match by name case-insensitive
    for (int i = unmatchedA.length - 1; i >= 0; i--) {
      final a = unmatchedA[i];
      final bIdx = unmatchedB
          .indexWhere((b) => a.name.toLowerCase() == b.name.toLowerCase());
      if (bIdx != -1) {
        paired.add((a, unmatchedB.removeAt(bIdx)));
        unmatchedA.removeAt(i);
      }
    }

    // Process matched pairs
    for (final (a, b) in paired) {
      final key = _mailboxKey(a);
      if (a.unreadCount != b.unreadCount || a.totalCount != b.totalCount) {
        mailboxDiffs.add(
          MailboxDiff(
            kind: MailboxDiffKind.countMismatch,
            key: key,
            a: a,
            b: b,
          ),
        );
      }
    }

    // Unmatched remaining
    for (final a in unmatchedA) {
      mailboxDiffs.add(
        MailboxDiff(
          kind: MailboxDiffKind.missingInB,
          key: _mailboxKey(a),
          a: a,
          b: null,
        ),
      );
    }
    for (final b in unmatchedB) {
      mailboxDiffs.add(
        MailboxDiff(
          kind: MailboxDiffKind.missingInA,
          key: _mailboxKey(b),
          a: null,
          b: b,
        ),
      );
    }

    final emailDiffs = <EmailDiff>[];
    final bodyDiffs = <BodyDiff>[];
    final unmatchable = <UnmatchableEmail>[];

    for (final (a, b) in paired) {
      final key = _mailboxKey(a);
      await _compareMailboxEmails(
        key,
        a,
        b,
        emailDiffs,
        bodyDiffs,
        unmatchable,
      );
    }

    return AccountComparisonResult(
      accountIdA: accountIdA,
      accountIdB: accountIdB,
      mailboxes: mailboxDiffs,
      emails: emailDiffs,
      bodies: bodyDiffs,
      unmatchable: unmatchable,
    );
  }

  Future<List<MailboxRow>> _mailboxesFor(String accountId) {
    return (_db.select(_db.mailboxes)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
  }

  String _mailboxKey(MailboxRow row) {
    final role = row.role;
    if (role != null && role.isNotEmpty) return 'role:${role.toLowerCase()}';
    return 'name:${row.name.toLowerCase()}';
  }

  Future<void> _compareMailboxEmails(
    String mailboxKey,
    MailboxRow a,
    MailboxRow b,
    List<EmailDiff> emailDiffs,
    List<BodyDiff> bodyDiffs,
    List<UnmatchableEmail> unmatchable,
  ) async {
    final emailsA = await _emailsIn(a.accountId, a.path);
    final emailsB = await _emailsIn(b.accountId, b.path);

    final byMessageIdA = <String, Email>{};
    for (final e in emailsA) {
      final mid = e.messageId;
      if (mid == null || mid.isEmpty) {
        unmatchable.add(
          UnmatchableEmail(
            side: ComparisonSide.a,
            mailboxKey: mailboxKey,
            emailId: e.id,
            subject: e.subject,
          ),
        );
        continue;
      }
      byMessageIdA[mid] = e;
    }

    final byMessageIdB = <String, Email>{};
    for (final e in emailsB) {
      final mid = e.messageId;
      if (mid == null || mid.isEmpty) {
        unmatchable.add(
          UnmatchableEmail(
            side: ComparisonSide.b,
            mailboxKey: mailboxKey,
            emailId: e.id,
            subject: e.subject,
          ),
        );
        continue;
      }
      byMessageIdB[mid] = e;
    }

    final remainingB = Map<String, Email>.from(byMessageIdB);
    for (final entry in byMessageIdA.entries) {
      final mid = entry.key;
      final ea = entry.value;
      final eb = remainingB.remove(mid);
      if (eb == null) {
        emailDiffs.add(
          EmailDiff(
            kind: EmailDiffKind.missingInB,
            mailboxKey: mailboxKey,
            messageId: mid,
            a: ea,
            b: null,
          ),
        );
        continue;
      }
      final mismatches = <EmailFieldMismatch>[];
      if (ea.isSeen != eb.isSeen) {
        mismatches.add(EmailFieldMismatch.seen);
      }
      if (ea.isFlagged != eb.isFlagged) {
        mismatches.add(EmailFieldMismatch.flagged);
      }
      if ((ea.subject ?? '') != (eb.subject ?? '')) {
        mismatches.add(EmailFieldMismatch.subject);
      }
      if (!_sentAtClose(ea.sentAt, eb.sentAt)) {
        mismatches.add(EmailFieldMismatch.sentAt);
      }
      if (mismatches.isNotEmpty) {
        emailDiffs.add(
          EmailDiff(
            kind: EmailDiffKind.fieldMismatch,
            mailboxKey: mailboxKey,
            messageId: mid,
            a: ea,
            b: eb,
            fields: mismatches,
          ),
        );
      }

      final body = await _diffBodies(mid, ea, eb);
      if (body != null) bodyDiffs.add(body);
    }
    for (final eb in remainingB.values) {
      emailDiffs.add(
        EmailDiff(
          kind: EmailDiffKind.missingInA,
          mailboxKey: mailboxKey,
          messageId: eb.messageId!,
          a: null,
          b: eb,
        ),
      );
    }
  }

  Future<List<Email>> _emailsIn(String accountId, String mailboxPath) {
    return (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath),
          ))
        .get();
  }

  bool _sentAtClose(DateTime? a, DateTime? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return a.difference(b).abs() <= const Duration(seconds: 1);
  }

  Future<BodyDiff?> _diffBodies(String messageId, Email ea, Email eb) async {
    final ba = await (_db.select(_db.emailBodies)
          ..where((t) => t.emailId.equals(ea.id)))
        .getSingleOrNull();
    final bb = await (_db.select(_db.emailBodies)
          ..where((t) => t.emailId.equals(eb.id)))
        .getSingleOrNull();
    if (ba == null || bb == null) return null;
    final textA = _normalise(ba.textBody);
    final textB = _normalise(bb.textBody);
    if (textA == null && textB == null) return null;
    if (textA == textB) return null;
    return BodyDiff(messageId: messageId, a: ea, b: eb);
  }

  String? _normalise(String? body) {
    if (body == null) return null;
    return body.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}

enum ComparisonSide { a, b }

enum MailboxDiffKind { missingInA, missingInB, countMismatch }

enum EmailDiffKind { missingInA, missingInB, fieldMismatch }

enum EmailFieldMismatch { seen, flagged, subject, sentAt }

class MailboxDiff {
  const MailboxDiff({
    required this.kind,
    required this.key,
    required this.a,
    required this.b,
  });

  final MailboxDiffKind kind;
  final String key;
  final MailboxRow? a;
  final MailboxRow? b;
}

class EmailDiff {
  const EmailDiff({
    required this.kind,
    required this.mailboxKey,
    required this.messageId,
    required this.a,
    required this.b,
    this.fields = const [],
  });

  final EmailDiffKind kind;
  final String mailboxKey;
  final String messageId;
  final Email? a;
  final Email? b;
  final List<EmailFieldMismatch> fields;
}

class BodyDiff {
  const BodyDiff({
    required this.messageId,
    required this.a,
    required this.b,
  });

  final String messageId;
  final Email a;
  final Email b;
}

class UnmatchableEmail {
  const UnmatchableEmail({
    required this.side,
    required this.mailboxKey,
    required this.emailId,
    required this.subject,
  });

  final ComparisonSide side;
  final String mailboxKey;
  final String emailId;
  final String? subject;
}

class AccountComparisonResult {
  const AccountComparisonResult({
    required this.accountIdA,
    required this.accountIdB,
    required this.mailboxes,
    required this.emails,
    required this.bodies,
    required this.unmatchable,
  });

  final String accountIdA;
  final String accountIdB;
  final List<MailboxDiff> mailboxes;
  final List<EmailDiff> emails;
  final List<BodyDiff> bodies;
  final List<UnmatchableEmail> unmatchable;

  bool get isIdentical => mailboxes.isEmpty && emails.isEmpty && bodies.isEmpty;

  int get diffCount => mailboxes.length + emails.length + bodies.length;
}
