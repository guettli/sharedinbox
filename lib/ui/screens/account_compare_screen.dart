import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/sync/account_comparison.dart';
import 'package:sharedinbox/core/sync/account_comparison_provider.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

final _dateFmt = DateFormat('yyyy-MM-dd HH:mm:ss');

class AccountCompareScreen extends ConsumerWidget {
  const AccountCompareScreen({
    super.key,
    required this.accountIdA,
    required this.accountIdB,
  });

  final String accountIdA;
  final String accountIdB;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result =
        ref.watch(accountComparisonProvider((accountIdA, accountIdB)));
    final accountA = ref.watch(accountByIdProvider(accountIdA)).value;
    final accountB = ref.watch(accountByIdProvider(accountIdB)).value;
    final labelA = accountA == null
        ? accountIdA
        : '${accountA.displayName} '
            '(${accountA.type.name.toUpperCase()})';
    final labelB = accountB == null
        ? accountIdB
        : '${accountB.displayName} '
            '(${accountB.type.name.toUpperCase()})';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Compare accounts'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Re-run comparison',
            onPressed: () => ref.invalidate(
              accountComparisonProvider((accountIdA, accountIdB)),
            ),
          ),
        ],
      ),
      body: result.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Comparison failed: $e')),
        data: (data) => _CompareBody(
          result: data,
          labelA: labelA,
          labelB: labelB,
        ),
      ),
    );
  }
}

class _CompareBody extends StatelessWidget {
  const _CompareBody({
    required this.result,
    required this.labelA,
    required this.labelB,
  });

  final AccountComparisonResult result;
  final String labelA;
  final String labelB;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('A: $labelA', style: theme.textTheme.bodyMedium),
            Text('B: $labelB', style: theme.textTheme.bodyMedium),
            const SizedBox(height: AppSpacing.sm),
            if (result.isIdentical)
              Row(
                children: [
                  const Icon(Icons.verified, color: Colors.green),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    'Local DBs are identical',
                    style: theme.textTheme.titleMedium,
                  ),
                ],
              )
            else
              Text(
                '${result.diffCount} difference(s) found',
                style: theme.textTheme.titleMedium
                    ?.copyWith(color: theme.colorScheme.error),
              ),
          ],
        ),
      ),
      const Divider(height: 1),
    ];

    if (result.mailboxes.isNotEmpty) {
      children.add(_section('Mailboxes', context));
      children.addAll(
        result.mailboxes.map((d) => _MailboxDiffTile(diff: d)),
      );
    }
    if (result.emails.isNotEmpty) {
      children.add(_section('Emails', context));
      children.addAll(result.emails.map((d) => _EmailDiffTile(diff: d)));
    }
    if (result.bodies.isNotEmpty) {
      children.add(_section('Bodies', context));
      children.addAll(result.bodies.map((d) => _BodyDiffTile(diff: d)));
    }
    if (result.unmatchable.isNotEmpty) {
      children.add(_section('Skipped (no Message-ID)', context));
      children
          .addAll(result.unmatchable.map((u) => _UnmatchableTile(entry: u)));
    }

    return ListView(children: children);
  }

  Widget _section(String title, BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall,
      ),
    );
  }
}

class _MailboxDiffTile extends StatelessWidget {
  const _MailboxDiffTile({required this.diff});

  final MailboxDiff diff;

  @override
  Widget build(BuildContext context) {
    final String title;
    final String subtitle;
    switch (diff.kind) {
      case MailboxDiffKind.missingInA:
        title = 'Missing in A: ${diff.b?.name ?? diff.key}';
        subtitle =
            'Present in B only (unread ${diff.b?.unreadCount}, total ${diff.b?.totalCount})';
        break;
      case MailboxDiffKind.missingInB:
        title = 'Missing in B: ${diff.a?.name ?? diff.key}';
        subtitle =
            'Present in A only (unread ${diff.a?.unreadCount}, total ${diff.a?.totalCount})';
        break;
      case MailboxDiffKind.countMismatch:
        title = 'Count mismatch: ${diff.a?.name ?? diff.key}';
        subtitle =
            'A unread=${diff.a?.unreadCount} total=${diff.a?.totalCount} · '
            'B unread=${diff.b?.unreadCount} total=${diff.b?.totalCount}';
        break;
    }
    return ExpansionTile(
      dense: true,
      leading: const Icon(Icons.folder_outlined),
      title: Text(title),
      subtitle: Text(subtitle),
      childrenPadding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        0,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      children: [
        _DetailRow(label: 'Key', value: diff.key),
        if (diff.a != null) ..._mailboxSideDetails('A', diff.a!),
        if (diff.b != null) ..._mailboxSideDetails('B', diff.b!),
      ],
    );
  }

  List<Widget> _mailboxSideDetails(String side, MailboxRow row) {
    return [
      _DetailRow(label: '$side · name', value: row.name),
      _DetailRow(label: '$side · path', value: row.path),
      _DetailRow(label: '$side · role', value: row.role ?? '(none)'),
      _DetailRow(
        label: '$side · counts',
        value: 'unread ${row.unreadCount}, total ${row.totalCount}',
      ),
    ];
  }
}

class _EmailDiffTile extends StatelessWidget {
  const _EmailDiffTile({required this.diff});

  final EmailDiff diff;

  @override
  Widget build(BuildContext context) {
    final String title;
    final String subtitle;
    switch (diff.kind) {
      case EmailDiffKind.missingInA:
        title = 'Missing in A: ${diff.b?.subject ?? '(no subject)'}';
        subtitle = _subtitleFor(diff.b);
        break;
      case EmailDiffKind.missingInB:
        title = 'Missing in B: ${diff.a?.subject ?? '(no subject)'}';
        subtitle = _subtitleFor(diff.a);
        break;
      case EmailDiffKind.fieldMismatch:
        final fields = diff.fields.map((f) => f.name).join(', ');
        title =
            'Fields differ ($fields): ${diff.a?.subject ?? diff.b?.subject ?? '(no subject)'}';
        subtitle = _subtitleFor(diff.a ?? diff.b);
        break;
    }
    return ExpansionTile(
      dense: true,
      leading: const Icon(Icons.email_outlined),
      title: Text(title),
      subtitle: Text(subtitle),
      childrenPadding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        0,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      children: _emailDetails(diff),
    );
  }

  String _subtitleFor(Email? e) {
    final date = e == null ? '' : '${_dateFmt.format(_dateOf(e))} · ';
    return '$date${diff.mailboxKey} · ${diff.messageId}';
  }

  List<Widget> _emailDetails(EmailDiff diff) {
    final rows = <Widget>[
      _DetailRow(label: 'Message-ID', value: diff.messageId),
      _DetailRow(label: 'Folder', value: diff.mailboxKey),
    ];
    if (diff.fields.isNotEmpty) {
      rows.add(
        _DetailRow(
          label: 'Fields differ',
          value: diff.fields.map((f) => f.name).join(', '),
        ),
      );
    }
    if (diff.a != null) {
      rows.add(const Divider(height: AppSpacing.lg));
      rows.addAll(_emailSideDetails('A', diff.a!));
    }
    if (diff.b != null) {
      rows.add(const Divider(height: AppSpacing.lg));
      rows.addAll(_emailSideDetails('B', diff.b!));
    }
    return rows;
  }
}

class _BodyDiffTile extends StatelessWidget {
  const _BodyDiffTile({required this.diff});

  final BodyDiff diff;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      dense: true,
      leading: const Icon(Icons.description_outlined),
      title: Text('Body differs: ${diff.a.subject ?? '(no subject)'}'),
      subtitle: Text('${_dateFmt.format(_dateOf(diff.a))} · ${diff.messageId}'),
      childrenPadding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        0,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      children: [
        _DetailRow(label: 'Message-ID', value: diff.messageId),
        const Divider(height: AppSpacing.lg),
        ..._emailSideDetails('A', diff.a),
        const Divider(height: AppSpacing.lg),
        ..._emailSideDetails('B', diff.b),
      ],
    );
  }
}

class _UnmatchableTile extends StatelessWidget {
  const _UnmatchableTile({required this.entry});

  final UnmatchableEmail entry;

  @override
  Widget build(BuildContext context) {
    final side = entry.side == ComparisonSide.a ? 'A' : 'B';
    return ExpansionTile(
      dense: true,
      leading: const Icon(Icons.help_outline),
      title: Text('$side · ${entry.subject ?? '(no subject)'}'),
      subtitle: Text(
        '${_dateFmt.format(_dateOf(entry.email))} · ${entry.mailboxKey}',
      ),
      childrenPadding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        0,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      children: [
        _DetailRow(label: 'Side', value: side),
        _DetailRow(label: 'Folder', value: entry.mailboxKey),
        ..._emailSideDetails(side, entry.email),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

List<Widget> _emailSideDetails(String side, Email e) {
  return [
    _DetailRow(label: '$side · date', value: _dateFmt.format(_dateOf(e))),
    _DetailRow(label: '$side · from', value: _formatAddresses(e.fromJson)),
    _DetailRow(label: '$side · to', value: _formatAddresses(e.toAddresses)),
    _DetailRow(label: '$side · subject', value: e.subject ?? '(none)'),
    _DetailRow(label: '$side · message-id', value: e.messageId ?? '(none)'),
    _DetailRow(label: '$side · account', value: e.accountId),
    _DetailRow(label: '$side · folder', value: e.mailboxPath),
    _DetailRow(
      label: '$side · flags',
      value: 'seen=${e.isSeen} flagged=${e.isFlagged}',
    ),
  ];
}

DateTime _dateOf(Email e) => e.sentAt ?? e.receivedAt;

String _formatAddresses(String json) {
  try {
    final list = jsonDecode(json) as List<dynamic>;
    if (list.isEmpty) return '(none)';
    return list.map((e) {
      final m = e as Map<String, dynamic>;
      final name = m['name'] as String? ?? '';
      final email = m['email'] as String? ?? '';
      return name.isEmpty ? email : '$name <$email>';
    }).join(', ');
  } catch (_) {
    return json;
  }
}
