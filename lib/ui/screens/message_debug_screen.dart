import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/sync/message_debug_service.dart';
import 'package:sharedinbox/core/sync/message_probe.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

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
        title: Text(total == 1 ? 'Debug 1 message' : 'Debug $total messages'),
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
  ProbeResult? _probe;
  bool _fetchingProbe = false;
  bool _resyncing = false;
  String? _resyncMessage;
  bool _probeDispatched = false;

  @override
  Widget build(BuildContext context) {
    final snapshotAsync = ref.watch(
      messageDebugSnapshotProvider(widget.messageRef),
    );
    if (widget.initiallyExpanded && !_probeDispatched) {
      final snapshot = snapshotAsync.value;
      if (snapshot != null && snapshot.email != null) {
        _probeDispatched = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _runProbe());
      }
    }

    final headline =
        snapshotAsync.value?.email?.subject?.trim().isNotEmpty == true
            ? snapshotAsync.value!.email!.subject!
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
          '${widget.messageRef.accountId} • '
          '${widget.messageRef.mailboxPath} • '
          '${widget.messageRef.emailId}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: _RemoteStatusChip(
          snapshot: snapshotAsync.value,
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
            child: snapshotAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Text('Failed to load local state: $e'),
              data: (snapshot) => _buildBody(context, snapshot),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _runProbe() async {
    if (_fetchingProbe) return;
    final snapshot = ref.read(
      messageDebugSnapshotProvider(widget.messageRef),
    );
    final local = snapshot.value;
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
        if (!mounted) return;
        setState(
          () => _probe = const ProbeResult.error('Account not found'),
        );
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
      ref.invalidate(messageDebugSnapshotProvider(widget.messageRef));
      await _runProbe();
    } catch (e) {
      if (!mounted) return;
      setState(() => _resyncMessage = 'Resync failed: $e');
    } finally {
      if (mounted) setState(() => _resyncing = false);
    }
  }

  Widget _buildBody(BuildContext context, MessageDebugSnapshot snapshot) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionLabel(context, 'Local state'),
        _localTable(snapshot),
        const SizedBox(height: AppSpacing.sm),
        _sectionLabel(context, 'Pending changes (${snapshot.pending.length})'),
        _pendingList(snapshot.pending),
        const SizedBox(height: AppSpacing.sm),
        _sectionLabel(context, 'Sync state'),
        _syncStateSection(context, snapshot),
        const SizedBox(height: AppSpacing.md),
        _sectionLabel(context, 'Remote state'),
        _remoteSection(context, snapshot),
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
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
      );

  Widget _localTable(MessageDebugSnapshot snapshot) {
    final email = snapshot.email;
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
        email.sentAt != null ? _timeFmt.format(email.sentAt!.toLocal()) : '',
      ),
      ('receivedAt', _timeFmt.format(email.receivedAt.toLocal())),
      ('from', email.fromJson),
      ('to', email.toAddresses),
      ('cc', email.ccJson),
      ('preview', email.preview ?? ''),
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
            : '',
      ),
      ('snoozedFromMailboxPath', email.snoozedFromMailboxPath ?? ''),
      ('listUnsubscribeHeader', email.listUnsubscribeHeader ?? ''),
    ];
    if (snapshot.body != null) {
      rows.addAll([
        (
          'body.cachedAt',
          snapshot.body!.cachedAt != null
              ? _timeFmt.format(snapshot.body!.cachedAt!.toLocal())
              : '(never)',
        ),
        ('body.textBytes', snapshot.body!.textBodyLength.toString()),
        ('body.htmlBytes', snapshot.body!.htmlBodyLength.toString()),
      ]);
    } else {
      rows.add(('body', '(not cached)'));
    }
    return _KeyValueTable(rows: rows);
  }

  Widget _pendingList(List<MessageDebugPending> pending) {
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

  Widget _syncStateSection(
    BuildContext context,
    MessageDebugSnapshot snapshot,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _KeyValueTable(
          rows: [
            for (final s in snapshot.syncStates)
              (
                s.resourceType,
                '${s.state} (synced ${_timeFmt.format(s.syncedAt.toLocal())})',
              ),
            if (snapshot.lastSyncLog != null)
              (
                'lastSyncLog',
                '${snapshot.lastSyncLog!.result} at '
                    '${_timeFmt.format(snapshot.lastSyncLog!.startedAt.toLocal())}'
                    '${snapshot.lastSyncLog!.errorMessage != null ? ' — ${snapshot.lastSyncLog!.errorMessage}' : ''}',
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

  Widget _remoteSection(BuildContext context, MessageDebugSnapshot snapshot) {
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
    final remote = probe.snapshot!;
    final email = snapshot.email;
    if (email == null) {
      return const Text('No local row; nothing to compare.');
    }
    final comparison = compareMessage(
      _buildLocalSnapshot(email, snapshot.attachments),
      remote,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _KeyValueTable(
          rows: [
            ('subject', remote.subject ?? ''),
            ('isSeen', remote.isSeen.toString()),
            ('isFlagged', remote.isFlagged.toString()),
            ('mailboxPath', remote.mailboxPath),
            ('messageId', remote.messageId ?? ''),
            if (remote.uid != null) ('uid', remote.uid.toString()),
            if (remote.sizeBytes != null)
              ('sizeBytes', remote.sizeBytes.toString()),
            ('attachmentCount', remote.attachments.length.toString()),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        _diffTable(comparison),
        if (remote.headers.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          _sectionLabel(context, 'Headers'),
          _KeyValueTable(
            rows: [
              for (final e in remote.headers.entries) (e.key, e.value),
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
    required this.snapshot,
    required this.probe,
    required this.fetching,
  });

  final MessageDebugSnapshot? snapshot;
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
    final remote = probe!.snapshot!;
    final email = snapshot?.email;
    if (email == null) {
      return const _StatusChip(label: 'Remote-only', color: Colors.blue);
    }
    final comparison = compareMessage(
      _buildLocalSnapshot(email, snapshot!.attachments),
      remote,
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
      return Text('(none)', style: Theme.of(context).textTheme.bodySmall);
    }
    final labelStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 160, child: Text(k, style: labelStyle)),
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

LocalMessageSnapshot _buildLocalSnapshot(
  MessageDebugEmail email,
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
    from: decodeMessageDebugAddresses(email.fromJson),
    to: decodeMessageDebugAddresses(email.toAddresses),
    cc: decodeMessageDebugAddresses(email.ccJson),
    inReplyTo: email.inReplyTo,
    references: email.references,
    listUnsubscribeHeader: email.listUnsubscribeHeader,
    attachments: attachments,
  );
}
