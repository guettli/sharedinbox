import 'package:drift/drift.dart';

import 'package:sharedinbox/core/models/account.dart' as model;
import 'package:sharedinbox/core/utils/mailbox_role_label.dart';
import 'package:sharedinbox/core/utils/message_id_utils.dart';
import 'package:sharedinbox/core/utils/text_diff.dart';
import 'package:sharedinbox/data/db/database.dart';

// [Email] and [MailboxRow] are already part of this file's public API (they
// appear as the row fields of [EmailDiff], [MailboxDiff], [BodyDiff] and
// [UnmatchableEmail]). Re-exporting them lets the UI layer name them without
// importing the data-layer package directly, which the layer check forbids.
export 'package:sharedinbox/data/db/database.dart' show Email, MailboxRow;

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

    // Sort by newest date first — otherwise entries would be grouped by
    // "missing in A" then "missing in B" (the order the compare loops
    // produce), which is unhelpful when scanning a long diff.
    emailDiffs
        .sort((x, y) => _dateOfEmailDiff(y).compareTo(_dateOfEmailDiff(x)));
    bodyDiffs.sort((x, y) => _dateOfEmail(y.a).compareTo(_dateOfEmail(x.a)));
    unmatchable.sort(
      (x, y) => _dateOfEmail(y.email).compareTo(_dateOfEmail(x.email)),
    );

    return AccountComparisonResult(
      accountIdA: accountIdA,
      accountIdB: accountIdB,
      mailboxes: mailboxDiffs,
      emails: emailDiffs,
      bodies: bodyDiffs,
      unmatchable: unmatchable,
    );
  }

  static DateTime _dateOfEmail(Email e) => e.sentAt ?? e.receivedAt;

  static DateTime _dateOfEmailDiff(EmailDiff d) {
    final e = d.a ?? d.b;
    if (e == null) return DateTime.fromMillisecondsSinceEpoch(0);
    return _dateOfEmail(e);
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

  /// A human-readable folder name — the role label (e.g. "Trash") when the
  /// mailbox has a known role, otherwise the folder's own name. JMAP folder
  /// `path`s are opaque ids (e.g. "b"), so never surface those to the user.
  String _folderLabel(MailboxRow row) => mailboxRoleLabel(row.role) ?? row.name;

  Future<void> _compareMailboxEmails(
    String mailboxKey,
    MailboxRow a,
    MailboxRow b,
    List<EmailDiff> emailDiffs,
    List<BodyDiff> bodyDiffs,
    List<UnmatchableEmail> unmatchable,
  ) async {
    // Both sides are the same logical folder, so a single friendly label is
    // enough; prefer side A's (role labels are identical across the pair).
    final folderName = _folderLabel(a);
    final emailsA = await _emailsIn(a.accountId, a.path);
    final emailsB = await _emailsIn(b.accountId, b.path);

    // Normalise the Message-ID before keying: legacy IMAP rows written prior
    // to the `_cleanMessageId` fix (#143) still carry the RFC 5322 `<...>`
    // brackets in the DB, whereas JMAP rows have always stored them without.
    // Without this join, the same message shows up as two separate diffs.
    final byMessageIdA = <String, Email>{};
    for (final e in emailsA) {
      final mid = normaliseMessageId(e.messageId);
      if (mid == null) {
        unmatchable.add(
          UnmatchableEmail(
            side: ComparisonSide.a,
            mailboxKey: mailboxKey,
            folderName: _folderLabel(a),
            email: e,
          ),
        );
        continue;
      }
      byMessageIdA[mid] = e;
    }

    final byMessageIdB = <String, Email>{};
    for (final e in emailsB) {
      final mid = normaliseMessageId(e.messageId);
      if (mid == null) {
        unmatchable.add(
          UnmatchableEmail(
            side: ComparisonSide.b,
            mailboxKey: mailboxKey,
            folderName: _folderLabel(b),
            email: e,
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
      // Surface the raw stored id so callers see whatever's actually in the
      // DB; the v49 migration eventually rewrites legacy IMAP rows to the
      // canonical bracket-less form, at which point both sides match here.
      if (eb == null) {
        emailDiffs.add(
          EmailDiff(
            kind: EmailDiffKind.missingInB,
            mailboxKey: mailboxKey,
            folderName: folderName,
            messageId: ea.messageId!,
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
            folderName: folderName,
            messageId: ea.messageId!,
            a: ea,
            b: eb,
            fields: mismatches,
          ),
        );
      }

      final body = await _diffBodies(ea.messageId!, folderName, ea, eb);
      if (body != null) bodyDiffs.add(body);
    }
    for (final eb in remainingB.values) {
      emailDiffs.add(
        EmailDiff(
          kind: EmailDiffKind.missingInA,
          mailboxKey: mailboxKey,
          folderName: folderName,
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

  Future<BodyDiff?> _diffBodies(
    String messageId,
    String folderName,
    Email ea,
    Email eb,
  ) async {
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
    // Equality is decided on the whitespace-normalised text, but the shown
    // diff runs on the raw bodies so the reader sees the actual lines.
    final diffLines = computeContextDiff(ba.textBody ?? '', bb.textBody ?? '');
    return BodyDiff(
      messageId: messageId,
      folderName: folderName,
      a: ea,
      b: eb,
      diffLines: diffLines,
    );
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
    required this.folderName,
    required this.messageId,
    required this.a,
    required this.b,
    this.fields = const [],
  });

  final EmailDiffKind kind;
  final String mailboxKey;

  /// Human-readable folder name (never the opaque JMAP mailbox id).
  final String folderName;
  final String messageId;
  final Email? a;
  final Email? b;
  final List<EmailFieldMismatch> fields;
}

class BodyDiff {
  const BodyDiff({
    required this.messageId,
    required this.folderName,
    required this.a,
    required this.b,
    this.diffLines = const [],
  });

  final String messageId;

  /// Human-readable folder name (never the opaque JMAP mailbox id).
  final String folderName;
  final Email a;
  final Email b;

  /// Short context diff between the two cached text bodies.
  final List<DiffLine> diffLines;
}

class UnmatchableEmail {
  const UnmatchableEmail({
    required this.side,
    required this.mailboxKey,
    required this.folderName,
    required this.email,
  });

  final ComparisonSide side;
  final String mailboxKey;

  /// Human-readable folder name (never the opaque JMAP mailbox id).
  final String folderName;
  final Email email;

  String get emailId => email.id;
  String? get subject => email.subject;
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
