import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/sync/account_comparison.dart';
import 'package:sharedinbox/core/sync/account_comparison_provider.dart';
import 'package:sharedinbox/core/utils/text_diff.dart';
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
      childrenPadding: _childrenPadding,
      children: [
        _DetailRow(label: 'Key', value: diff.key),
        if (diff.a != null) ..._mailboxSideRows('A', diff.a!),
        if (diff.b != null) ..._mailboxSideRows('B', diff.b!),
      ],
    );
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

    final rows = <Widget>[
      _DetailRow(label: 'Message-ID', value: diff.messageId),
      _DetailRow(label: 'Folder', value: diff.folderName),
    ];
    if (diff.fields.isNotEmpty) {
      rows.add(
        _DetailRow(
          label: 'Fields differ',
          value: diff.fields.map((f) => f.name).join(', '),
        ),
      );
    }
    // When both sides are present, collapse equal fields to a single "(equal)"
    // row so the eye only has to scan the values that actually differ.
    if (diff.a != null && diff.b != null) {
      rows.add(const Divider(height: AppSpacing.lg));
      rows.addAll(_comparisonRows(diff.a!, diff.b!, diff.folderName));
    } else if (diff.a != null) {
      rows.add(const Divider(height: AppSpacing.lg));
      rows.addAll(_emailSideRows('A', diff.a!, diff.folderName));
    } else if (diff.b != null) {
      rows.add(const Divider(height: AppSpacing.lg));
      rows.addAll(_emailSideRows('B', diff.b!, diff.folderName));
    }
    rows.add(_OpenButtons(a: diff.a, b: diff.b));

    return ExpansionTile(
      dense: true,
      leading: const Icon(Icons.email_outlined),
      title: Text(title),
      subtitle: Text(subtitle),
      childrenPadding: _childrenPadding,
      children: rows,
    );
  }

  String _subtitleFor(Email? e) {
    final date = e == null ? '' : '${_dateFmt.format(_dateOf(e))} · ';
    return '$date${diff.folderName} · ${diff.messageId}';
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
      childrenPadding: _childrenPadding,
      children: [
        _DetailRow(label: 'Message-ID', value: diff.messageId),
        _DetailRow(label: 'Folder', value: diff.folderName),
        const Divider(height: AppSpacing.lg),
        ..._comparisonRows(diff.a, diff.b, diff.folderName),
        const Divider(height: AppSpacing.lg),
        const _DetailRow(label: 'Body diff', value: 'A = −, B = +'),
        _BodyDiffView(lines: diff.diffLines),
        _OpenButtons(a: diff.a, b: diff.b),
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
    final isA = entry.side == ComparisonSide.a;
    return ExpansionTile(
      dense: true,
      leading: const Icon(Icons.help_outline),
      title: Text('$side · ${entry.subject ?? '(no subject)'}'),
      subtitle: Text(
        '${_dateFmt.format(_dateOf(entry.email))} · ${entry.folderName}',
      ),
      childrenPadding: _childrenPadding,
      children: [
        _DetailRow(label: 'Side', value: side),
        _DetailRow(label: 'Folder', value: entry.folderName),
        ..._emailSideRows(side, entry.email, entry.folderName),
        _OpenButtons(
          a: isA ? entry.email : null,
          b: isA ? null : entry.email,
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.equal = false,
  });

  final String label;
  final String value;

  /// When true the value came out identical on both sides; a muted "(equal)"
  /// tag is appended so the reader isn't left hunting for a difference.
  final bool equal;

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
          if (equal)
            Padding(
              padding: const EdgeInsets.only(left: AppSpacing.sm),
              child: Text(
                '(equal)',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Buttons that jump to the underlying message on whichever side(s) exist.
class _OpenButtons extends StatelessWidget {
  const _OpenButtons({required this.a, required this.b});

  final Email? a;
  final Email? b;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Wrap(
        spacing: AppSpacing.sm,
        children: [
          if (a != null)
            TextButton.icon(
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Open in A'),
              onPressed: () => _openEmail(context, a!),
            ),
          if (b != null)
            TextButton.icon(
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Open in B'),
              onPressed: () => _openEmail(context, b!),
            ),
        ],
      ),
    );
  }
}

/// Renders a short context diff between two cached bodies as a monospace block.
class _BodyDiffView extends StatelessWidget {
  const _BodyDiffView({required this.lines});

  final List<DiffLine> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (lines.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          '(bodies differ only in whitespace)',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }
    final mono = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      height: 1.3,
    );
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            SelectableText(
              _prefixed(line),
              style: mono?.copyWith(color: _colorFor(line.kind, theme)),
            ),
        ],
      ),
    );
  }

  String _prefixed(DiffLine line) {
    switch (line.kind) {
      case DiffLineKind.added:
        return '+ ${line.text}';
      case DiffLineKind.removed:
        return '- ${line.text}';
      case DiffLineKind.gap:
        return line.text;
      case DiffLineKind.context:
        return '  ${line.text}';
    }
  }

  Color? _colorFor(DiffLineKind kind, ThemeData theme) {
    switch (kind) {
      case DiffLineKind.added:
        return Colors.green.shade700;
      case DiffLineKind.removed:
        return theme.colorScheme.error;
      case DiffLineKind.gap:
      case DiffLineKind.context:
        return theme.colorScheme.onSurfaceVariant;
    }
  }
}

void _openEmail(BuildContext context, Email e) {
  unawaited(
    context.push(
      '/accounts/${e.accountId}/mailboxes'
      '/${Uri.encodeComponent(e.mailboxPath)}'
      '/emails/${Uri.encodeComponent(e.id)}',
    ),
  );
}

const _childrenPadding = EdgeInsets.fromLTRB(
  AppSpacing.xl,
  0,
  AppSpacing.lg,
  AppSpacing.sm,
);

/// One field on both sides, labelled for comparison. [folder] is the
/// human-readable folder name shared by the pair.
class _CompareField {
  const _CompareField(this.label, this.a, this.b);
  final String label;
  final String a;
  final String b;
}

List<_CompareField> _compareFields(Email a, Email b, String folder) {
  return [
    _CompareField(
      'date',
      _dateFmt.format(_dateOf(a)),
      _dateFmt.format(_dateOf(b)),
    ),
    _CompareField(
      'from',
      _formatAddresses(a.fromJson),
      _formatAddresses(b.fromJson),
    ),
    _CompareField(
      'to',
      _formatAddresses(a.toAddresses),
      _formatAddresses(b.toAddresses),
    ),
    _CompareField('subject', a.subject ?? '(none)', b.subject ?? '(none)'),
    _CompareField(
      'message-id',
      a.messageId ?? '(none)',
      b.messageId ?? '(none)',
    ),
    _CompareField('folder', folder, folder),
    _CompareField('flags', _flagsOf(a), _flagsOf(b)),
  ];
}

/// Field-by-field rows: one "(equal)" row when the values match, otherwise a
/// pair of `A · …` / `B · …` rows so only real differences are shown twice.
List<Widget> _comparisonRows(Email a, Email b, String folder) {
  final rows = <Widget>[];
  for (final f in _compareFields(a, b, folder)) {
    if (f.a == f.b) {
      rows.add(_DetailRow(label: f.label, value: f.a, equal: true));
    } else {
      rows.add(_DetailRow(label: 'A · ${f.label}', value: f.a));
      rows.add(_DetailRow(label: 'B · ${f.label}', value: f.b));
    }
  }
  return rows;
}

List<Widget> _emailSideRows(String side, Email e, String folder) {
  return [
    for (final f in _compareFields(e, e, folder))
      _DetailRow(label: '$side · ${f.label}', value: f.a),
  ];
}

String _flagsOf(Email e) => 'seen=${e.isSeen} flagged=${e.isFlagged}';

List<Widget> _mailboxSideRows(String side, MailboxRow row) {
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
