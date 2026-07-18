import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/sync/message_probe.dart';
import 'package:sharedinbox/data/db/database.dart' as db;
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

/// Coordinate identifying a single message the debug screen should inspect.
///
/// Named `DebugMessageRef` (rather than `MessageRef`) to avoid clashing with
/// other repositories' terminology if they ever add a similar concept.
class DebugMessageRef {
  const DebugMessageRef({
    required this.accountId,
    required this.mailboxPath,
    required this.emailId,
  });

  final String accountId;
  final String mailboxPath;
  final String emailId;
}

final _timeFmt = DateFormat('yyyy-MM-dd HH:mm:ss');

/// Debug view over a set of selected messages. Shows the locally cached
/// fields, any pending outbound mutations, the account's last sync log entry,
/// and — when online — the remote server's current view of the same message.
class MessageDebugScreen extends ConsumerStatefulWidget {
  const MessageDebugScreen({super.key, required this.messages});

  final List<DebugMessageRef> messages;

  @override
  ConsumerState<MessageDebugScreen> createState() => _MessageDebugScreenState();
}

class _MessageDebugScreenState extends ConsumerState<MessageDebugScreen> {
  @override
  Widget build(BuildContext context) {
    final total = widget.messages.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          total == 1 ? 'Debug 1 message' : 'Debug $total messages',
        ),
      ),
      body: widget.messages.isEmpty
          ? const Center(child: Text('No messages selected.'))
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              itemCount: widget.messages.length,
              itemBuilder: (context, index) => _MessageDebugCard(
                key: ValueKey(widget.messages[index].emailId),
                messageRef: widget.messages[index],
                initiallyExpanded: index == 0,
              ),
            ),
    );
  }
}

class _MessageDebugCard extends ConsumerStatefulWidget {
  const _MessageDebugCard({
    super.key,
    required this.messageRef,
    required this.initiallyExpanded,
  });

  final DebugMessageRef messageRef;
  final bool initiallyExpanded;

  @override
  ConsumerState<_MessageDebugCard> createState() => _MessageDebugCardState();
}

class _MessageDebugCardState extends ConsumerState<_MessageDebugCard> {
  _LocalState? _local;
  ProbeResult? _probe;
  bool _fetchingProbe = false;
  bool _resyncing = false;
  String? _resyncMessage;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLocal());
  }

  Future<void> _loadLocal() async {
    try {
      final state = await _readLocalState(ref, widget.messageRef);
      if (!mounted) return;
      setState(() {
        _local = state;
        _loadError = null;
      });
      if (widget.initiallyExpanded) {
        unawaited(_runProbe());
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
      });
    }
  }

  Future<void> _runProbe() async {
    if (_fetchingProbe) return;
    final local = _local;
    if (local == null || local.email == null) return;
    setState(() {
      _fetchingProbe = true;
      _probe = null;
    });
    try {
      final probe = ref.read(messageProbeProvider);
      final accountRepo = ref.read(accountRepositoryProvider);
      final account = await accountRepo.getAccount(widget.messageRef.accountId);
      if (account == null) {
        setState(() {
          _probe = const ProbeResult.error('Account not found');
        });
        return;
      }
      final password = await accountRepo.getPassword(account.id);
      final result = await probe.fetch(
        account: account,
        password: password,
        mailboxPath: widget.messageRef.mailboxPath,
        emailId: widget.messageRef.emailId,
        uid: local.email!.uid,
      );
      if (!mounted) return;
      setState(() => _probe = result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _probe = ProbeResult.error(e.toString()));
    } finally {
      if (mounted) setState(() => _fetchingProbe = false);
    }
  }

  Future<void> _resync() async {
    if (_resyncing) return;
    setState(() {
      _resyncing = true;
      _resyncMessage = null;
    });
    try {
      final repo = ref.read(emailRepositoryProvider);
      await repo.syncEmails(
        widget.messageRef.accountId,
        widget.messageRef.mailboxPath,
      );
      await repo.getEmailBody(widget.messageRef.emailId, forceRefresh: true);
      if (!mounted) return;
      setState(() => _resyncMessage = 'Resync complete');
      await _loadLocal();
      await _runProbe();
    } catch (e) {
      if (!mounted) return;
      setState(() => _resyncMessage = 'Resync failed: $e');
    } finally {
      if (mounted) setState(() => _resyncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ref = widget.messageRef;
    final headline = _local?.email?.subject?.trim().isNotEmpty == true
        ? _local!.email!.subject!
        : '(no subject)';
    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      child: ExpansionTile(
        initiallyExpanded: widget.initiallyExpanded,
        onExpansionChanged: (expanded) {
          if (expanded && _probe == null && !_fetchingProbe) {
            unawaited(_runProbe());
          }
        },
        title: Text(
          headline,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        subtitle: Text(
          '${ref.accountId} • ${ref.mailboxPath} • ${ref.emailId}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: _RemoteStatusChip(
          local: _local,
          probe: _probe,
          fetching: _fetchingProbe,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.md,
            ),
            child: _buildBody(context),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loadError != null) {
      return Text('Failed to load local state: $_loadError');
    }
    final local = _local;
    if (local == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionLabel(context, 'Local state'),
        _localTable(local),
        const SizedBox(height: AppSpacing.sm),
        _sectionLabel(context, 'Pending changes (${local.pending.length})'),
        _pendingList(local.pending),
        const SizedBox(height: AppSpacing.sm),
        _sectionLabel(context, 'Sync state'),
        _syncStateSection(context, local),
        const SizedBox(height: AppSpacing.md),
        _sectionLabel(context, 'Remote state'),
        _remoteSection(context, local),
        const SizedBox(height: AppSpacing.sm),
        _actionsRow(),
        if (_resyncMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              _resyncMessage!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Widget _sectionLabel(BuildContext context, String label) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
        child: Text(
          label,
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
      );

  Widget _localTable(_LocalState local) {
    final email = local.email;
    if (email == null) {
      return const Text('No local row for this message ID.');
    }
    final rows = <(String, String)>[
      ('id', email.id),
      ('accountId', email.accountId),
      ('mailboxPath', email.mailboxPath),
      ('uid', email.uid.toString()),
      ('subject', email.subject ?? ''),
      (
        'sentAt',
        email.sentAt != null ? _timeFmt.format(email.sentAt!.toLocal()) : ''
      ),
      ('receivedAt', _timeFmt.format(email.receivedAt.toLocal())),
      ('from', email.fromJson),
      ('to', email.toAddresses),
      ('cc', email.ccJson),
      ('isSeen', email.isSeen.toString()),
      ('isFlagged', email.isFlagged.toString()),
      ('hasAttachment', email.hasAttachment.toString()),
      ('threadId', email.threadId ?? ''),
      ('messageId', email.messageId ?? ''),
      ('inReplyTo', email.inReplyTo ?? ''),
      ('references', email.references ?? ''),
      (
        'snoozedUntil',
        email.snoozedUntil != null
            ? _timeFmt.format(email.snoozedUntil!.toLocal())
            : ''
      ),
      ('snoozedFromMailboxPath', email.snoozedFromMailboxPath ?? ''),
      ('listUnsubscribeHeader', email.listUnsubscribeHeader ?? ''),
    ];
    if (local.body != null) {
      rows.addAll([
        (
          'body.cachedAt',
          local.body!.cachedAt != null
              ? _timeFmt.format(local.body!.cachedAt!.toLocal())
              : '(never)'
        ),
        ('body.textBytes', (local.body!.textBody?.length ?? 0).toString()),
        ('body.htmlBytes', (local.body!.htmlBody?.length ?? 0).toString()),
      ]);
    } else {
      rows.add(('body', '(not cached)'));
    }
    return _KeyValueTable(rows: rows);
  }

  Widget _pendingList(List<db.PendingChangeRow> pending) {
    if (pending.isEmpty) {
      return const Text('No pending mutations for this message.');
    }
    return Column(
      children: [
        for (final p in pending)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: _KeyValueTable(
              rows: [
                ('changeType', p.changeType),
                ('attempts', p.attempts.toString()),
                ('createdAt', _timeFmt.format(p.createdAt.toLocal())),
                if (p.lastError != null) ('lastError', p.lastError!),
                ('payload', p.payload),
              ],
            ),
          ),
      ],
    );
  }

  Widget _syncStateSection(BuildContext context, _LocalState local) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _KeyValueTable(
          rows: [
            for (final s in local.syncStates)
              (
                s.resourceType,
                '${s.state} (synced ${_timeFmt.format(s.syncedAt.toLocal())})'
              ),
            if (local.lastSyncLog != null)
              (
                'lastSyncLog',
                '${local.lastSyncLog!.result} at '
                    '${_timeFmt.format(local.lastSyncLog!.startedAt.toLocal())}'
                    '${local.lastSyncLog!.errorMessage != null ? ' — ${local.lastSyncLog!.errorMessage}' : ''}'
              ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.article_outlined, size: 18),
            label: const Text('Open sync log'),
            onPressed: () => context.push(
              '/accounts/${widget.messageRef.accountId}/sync-log',
            ),
          ),
        ),
      ],
    );
  }

  Widget _remoteSection(BuildContext context, _LocalState local) {
    if (_fetchingProbe) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final probe = _probe;
    if (probe == null) {
      return Row(
        children: [
          const Expanded(
            child: Text('Not fetched yet. Tap "Check remote" to compare.'),
          ),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.cloud_sync),
            label: const Text('Check remote'),
            onPressed: _runProbe,
          ),
        ],
      );
    }
    if (probe.notFound) {
      return const Text(
        'Message not found on server. Local row may be stale — try Resync.',
      );
    }
    if (probe.error != null) {
      return Text('Remote fetch failed: ${probe.error}');
    }
    final snapshot = probe.snapshot!;
    final email = local.email;
    if (email == null) {
      return const Text('No local row; nothing to compare.');
    }
    final comparison = compareMessage(
      _buildLocalSnapshot(email, local.attachments),
      snapshot,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _KeyValueTable(
          rows: [
            ('subject', snapshot.subject ?? ''),
            ('isSeen', snapshot.isSeen.toString()),
            ('isFlagged', snapshot.isFlagged.toString()),
            ('mailboxPath', snapshot.mailboxPath),
            ('messageId', snapshot.messageId ?? ''),
            if (snapshot.uid != null) ('uid', snapshot.uid.toString()),
            if (snapshot.sizeBytes != null)
              ('sizeBytes', snapshot.sizeBytes.toString()),
            ('attachmentCount', snapshot.attachments.length.toString()),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        _diffTable(comparison),
        if (snapshot.headers.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          _sectionLabel(context, 'Headers'),
          _KeyValueTable(
            rows: [
              for (final e in snapshot.headers.entries) (e.key, e.value),
            ],
          ),
        ],
      ],
    );
  }

  Widget _diffTable(MessageComparison comparison) {
    if (comparison.isMatch) {
      return Text(
        'Match: local and remote agree on every checked field.',
        style: TextStyle(color: Colors.green.shade700),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Mismatch: ${comparison.diffs.length} field(s) differ.',
          style: TextStyle(
            color: Theme.of(context).colorScheme.error,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        _KeyValueTable(
          rows: [
            for (final d in comparison.diffs)
              (d.field, 'local=${d.local}\nremote=${d.remote}'),
          ],
        ),
      ],
    );
  }

  Widget _actionsRow() {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.refresh),
          label: const Text('Refetch remote'),
          onPressed: _fetchingProbe ? null : _runProbe,
        ),
        FilledButton.tonalIcon(
          icon: _resyncing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.sync),
          label: const Text('Resync this message'),
          onPressed: _resyncing ? null : _resync,
        ),
      ],
    );
  }
}

class _RemoteStatusChip extends StatelessWidget {
  const _RemoteStatusChip({
    required this.local,
    required this.probe,
    required this.fetching,
  });

  final _LocalState? local;
  final ProbeResult? probe;
  final bool fetching;

  @override
  Widget build(BuildContext context) {
    if (fetching) {
      return const _StatusChip(label: 'Loading', color: Colors.grey);
    }
    if (probe == null) {
      return const _StatusChip(label: 'Pending', color: Colors.grey);
    }
    if (probe!.error != null) {
      return _StatusChip(
        label: 'Error',
        color: Theme.of(context).colorScheme.error,
      );
    }
    if (probe!.notFound) {
      return const _StatusChip(label: 'Missing', color: Colors.orange);
    }
    final snapshot = probe!.snapshot!;
    final email = local?.email;
    if (email == null) {
      return const _StatusChip(label: 'Remote-only', color: Colors.blue);
    }
    final comparison = compareMessage(
      _buildLocalSnapshot(email, local!.attachments),
      snapshot,
    );
    return comparison.isMatch
        ? const _StatusChip(label: 'Match', color: Colors.green)
        : _StatusChip(
            label: 'Mismatch',
            color: Theme.of(context).colorScheme.error,
          );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(label),
      backgroundColor: color.withValues(alpha: 0.15),
      side: BorderSide(color: color),
      labelStyle: TextStyle(color: color),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _KeyValueTable extends StatelessWidget {
  const _KeyValueTable({required this.rows});
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Text(
        '(none)',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    final labelStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          fontWeight: FontWeight.w600,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 160,
                  child: Text(k, style: labelStyle),
                ),
                Expanded(
                  child: GestureDetector(
                    onLongPress: () async {
                      await Clipboard.setData(ClipboardData(text: v));
                    },
                    child: SelectableText(
                      v.isEmpty ? '—' : v,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ── Local-state loading ─────────────────────────────────────────────────────

class _LocalState {
  const _LocalState({
    required this.email,
    required this.body,
    required this.pending,
    required this.syncStates,
    required this.lastSyncLog,
    required this.attachments,
  });

  final db.Email? email;
  final db.EmailBody? body;
  final List<db.PendingChangeRow> pending;
  final List<db.SyncStateRow> syncStates;
  final db.SyncLogRow? lastSyncLog;
  final List<EmailAttachment> attachments;
}

Future<_LocalState> _readLocalState(
  WidgetRef ref,
  DebugMessageRef messageRef,
) async {
  final db = ref.read(dbProvider);
  final email = await (db.select(db.emails)
        ..where((t) => t.id.equals(messageRef.emailId)))
      .getSingleOrNull();
  final body = await (db.select(db.emailBodies)
        ..where((t) => t.emailId.equals(messageRef.emailId)))
      .getSingleOrNull();
  final pending = await (db.select(db.pendingChanges)
        ..where(
          (t) =>
              t.accountId.equals(messageRef.accountId) &
              t.resourceId.equals(messageRef.emailId),
        )
        ..orderBy([(t) => drift.OrderingTerm.asc(t.createdAt)]))
      .get();
  final syncStates = await (db.select(db.syncStates)
        ..where((t) => t.accountId.equals(messageRef.accountId)))
      .get();
  final lastSyncLog = await (db.select(db.syncLogs)
        ..where((t) => t.accountId.equals(messageRef.accountId))
        ..orderBy([(t) => drift.OrderingTerm.desc(t.finishedAt)])
        ..limit(1))
      .getSingleOrNull();

  final attachments = <EmailAttachment>[];
  if (body != null) {
    try {
      attachments.addAll(_decodeAttachments(body.attachmentsJson));
    } catch (_) {
      // Malformed cache — leave attachments empty, still show the row above.
    }
  }

  return _LocalState(
    email: email,
    body: body,
    pending: pending,
    syncStates: syncStates,
    lastSyncLog: lastSyncLog,
    attachments: attachments,
  );
}

LocalMessageSnapshot _buildLocalSnapshot(
  db.Email email,
  List<EmailAttachment> attachments,
) {
  return LocalMessageSnapshot(
    mailboxPath: email.mailboxPath,
    messageId: email.messageId,
    subject: email.subject,
    sentAt: email.sentAt,
    receivedAt: email.receivedAt,
    isSeen: email.isSeen,
    isFlagged: email.isFlagged,
    hasAttachment: email.hasAttachment,
    uid: email.uid,
    from: _decodeAddresses(email.fromJson),
    to: _decodeAddresses(email.toAddresses),
    cc: _decodeAddresses(email.ccJson),
    inReplyTo: email.inReplyTo,
    references: email.references,
    listUnsubscribeHeader: email.listUnsubscribeHeader,
    attachments: attachments,
  );
}

List<EmailAddress> _decodeAddresses(String rawJson) {
  if (rawJson.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is! List) return const [];
    return [
      for (final e in decoded)
        EmailAddress(
          name: (e as Map<String, dynamic>)['name'] as String?,
          email: e['email'] as String? ?? '',
        ),
    ];
  } catch (_) {
    return const [];
  }
}

List<EmailAttachment> _decodeAttachments(String rawJson) {
  if (rawJson.trim().isEmpty) return const [];
  final decoded = jsonDecode(rawJson);
  if (decoded is! List) return const [];
  return [
    for (final e in decoded)
      EmailAttachment(
        filename: (e as Map<String, dynamic>)['filename'] as String? ?? '',
        contentType: e['contentType'] as String? ?? '',
        size: (e['size'] as int?) ?? 0,
        fetchPartId: e['fetchPartId'] as String? ?? '',
      ),
  ];
}
