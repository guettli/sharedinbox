import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/core/utils/html_utils.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/email_action_helpers.dart';
import 'package:sharedinbox/ui/widgets/secure_email_webview.dart';
import 'package:sharedinbox/ui/widgets/snooze_picker.dart';
import 'package:url_launcher/url_launcher.dart';

final _dateFmt = DateFormat('EEE, MMM d yyyy, HH:mm');

class EmailDetailScreen extends ConsumerStatefulWidget {
  const EmailDetailScreen({super.key, required this.emailId});
  final String emailId;

  @override
  ConsumerState<EmailDetailScreen> createState() => _EmailDetailScreenState();
}

class _EmailDetailScreenState extends ConsumerState<EmailDetailScreen> {
  bool _isFlagged = false;
  bool _loadRemoteImages = false;
  final Set<String> _downloading = {};

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(emailRepositoryProvider);
    final detail = ref.watch(emailDetailProvider(widget.emailId));

    ref.listen<AsyncValue<(Email?, EmailBody)>>(
      emailDetailProvider(widget.emailId),
      (_, next) {
        final email = next.value?.$1;
        if (email != null && mounted) {
          setState(() => _isFlagged = email.isFlagged);
        }
      },
    );

    final header = detail.value?.$1;
    final body = detail.value?.$2;

    final isMobile = defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !isMobile,
        title: Text(
          header?.subject ?? '(loading…)',
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.reply),
            tooltip: 'Reply',
            onPressed: header == null
                ? null
                : () {
                    unawaited(
                      _replyWithRecipientDialog(context, header, body),
                    );
                  },
          ),
          IconButton(
            icon: const Icon(Icons.forward),
            tooltip: 'Forward',
            onPressed: header == null
                ? null
                : () {
                    unawaited(_forward(context, header, body));
                  },
          ),
          IconButton(
            icon: const Icon(Icons.archive),
            tooltip: 'Archive',
            onPressed: header == null
                ? null
                : () {
                    unawaited(_archive(context, header));
                  },
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: 'Delete',
            onPressed: () async {
              final nextEmailId = await _getNextEmailIdIfNeeded(header);
              final destPath = await repo.deleteEmail(widget.emailId);

              if (header != null) {
                unawaited(
                  ref.read(undoServiceProvider.notifier).pushAction(
                        UndoAction(
                          id: DateTime.now().toIso8601String(),
                          accountId: header.accountId,
                          type: UndoType.delete,
                          emailIds: [widget.emailId],
                          sourceMailboxPath: header.mailboxPath,
                          destinationMailboxPath: destPath,
                          originalEmails: [header],
                        ),
                      ),
                );
              }

              if (context.mounted) _navigateTo(context, header, nextEmailId);
            },
          ),
          IconButton(
            icon: const Icon(Icons.report_outlined),
            tooltip: 'Mark as spam',
            onPressed: header == null
                ? null
                : () {
                    unawaited(_markAsSpam(context, header));
                  },
          ),
          IconButton(
            icon: const Icon(Icons.drive_file_move_outline),
            tooltip: 'Move to folder',
            onPressed: header == null ? null : () => _moveTo(context, header),
          ),
          IconButton(
            icon: const Icon(Icons.access_time),
            tooltip: 'Snooze',
            onPressed: header == null ? null : () => _snooze(context, header),
          ),
          IconButton(
            icon: Icon(
              _isFlagged ? Icons.star : Icons.star_border,
              color: _isFlagged ? Colors.amber : null,
            ),
            tooltip: _isFlagged ? 'Unflag' : 'Flag',
            onPressed: () async {
              final next = !_isFlagged;
              await repo.setFlag(widget.emailId, flagged: next);
              if (mounted) setState(() => _isFlagged = next);
            },
          ),
          PopupMenuButton<String>(
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'mark_unread',
                child: Text('Mark as unread'),
              ),
              const PopupMenuItem(
                value: 'headers',
                child: Text('Show Mail Headers'),
              ),
              const PopupMenuItem(
                value: 'structure',
                child: Text('Show Mail Structure'),
              ),
              const PopupMenuItem(
                value: 'rfc',
                child: Text('Show Raw Email'),
              ),
            ],
            onSelected: (value) async {
              if (value == 'mark_unread') {
                final nextEmailId = await _getNextEmailIdIfNeeded(header);
                await repo.setFlag(widget.emailId, seen: false);
                if (context.mounted) _navigateTo(context, header, nextEmailId);
              } else if (value == 'headers' && body != null) {
                _showHeaders(context, body);
              } else if (value == 'structure' && body != null) {
                _showStructure(context, body);
              } else if (value == 'rfc') {
                unawaited(_showRaw(context, header));
              }
            },
          ),
        ],
      ),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (d) => _buildBody(context, d.$1, d.$2),
      ),
    );
  }

  Widget _buildBody(BuildContext ctx, Email? header, EmailBody body) {
    final hasHtml = (body.htmlBody ?? '').trim().isNotEmpty;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (header != null) ...[_buildHeader(ctx, header), const Divider()],
        if (hasHtml) ...[
          if (!_loadRemoteImages)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.image_outlined, size: 18),
                  label: const Text('Load remote images'),
                  onPressed: () => setState(() => _loadRemoteImages = true),
                ),
              ),
            ),
          SecureEmailWebView(
            htmlBody: body.htmlBody!,
            loadRemoteImages: _loadRemoteImages,
          ),
        ] else
          SelectableText(
            body.textBody ?? '',
            style: Theme.of(ctx).textTheme.bodyMedium,
          ),
        if (body.attachments.isNotEmpty) ...[
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'Attachments',
              style: Theme.of(ctx).textTheme.titleSmall,
            ),
          ),
          for (final att in body.attachments)
            ListTile(
              dense: true,
              leading: const Icon(Icons.attach_file),
              title: Text(att.filename),
              subtitle: Text('${att.contentType} • ${fmtSize(att.size)}'),
              trailing: _downloading.contains(att.filename)
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      icon: const Icon(Icons.download),
                      tooltip: 'Download and open',
                      onPressed: () => _downloadAndOpen(att),
                    ),
            ),
        ],
      ],
    );
  }

  Future<String?> _getNextEmailIdIfNeeded(Email? header) async {
    if (header == null) return null;
    final prefs = ref.read(userPreferencesProvider).value;
    final action =
        prefs?.afterMailViewAction ?? AfterMailViewAction.nextMessage;
    if (action != AfterMailViewAction.nextMessage) return null;

    final threads = await ref
        .read(emailRepositoryProvider)
        .observeThreads(header.accountId, header.mailboxPath)
        .first;

    final currentIndex =
        threads.indexWhere((t) => t.emailIds.contains(widget.emailId));
    if (currentIndex >= 0 && currentIndex + 1 < threads.length) {
      return threads[currentIndex + 1].latestEmailId;
    }
    return null;
  }

  void _navigateTo(BuildContext context, Email? header, String? nextEmailId) {
    if (!context.mounted) return;
    if (nextEmailId != null && header != null) {
      context.go(
        '/accounts/${header.accountId}'
        '/mailboxes/${Uri.encodeComponent(header.mailboxPath)}'
        '/emails/${Uri.encodeComponent(nextEmailId)}',
      );
    } else {
      context.pop();
    }
  }

  Future<void> _downloadAndOpen(EmailAttachment att) async {
    setState(() => _downloading.add(att.filename));
    try {
      final path = await ref
          .read(emailRepositoryProvider)
          .downloadAttachment(widget.emailId, att);
      await OpenFilex.open(path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Opening file failed: $e')));
    } finally {
      if (mounted) setState(() => _downloading.remove(att.filename));
    }
  }

  Widget _buildHeader(BuildContext ctx, Email email) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          email.subject ?? '(no subject)',
          style: Theme.of(ctx).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        if (email.from.isNotEmpty)
          Text(
            'From: ${email.from.first}',
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
        if (email.to.isNotEmpty)
          Text(
            'To: ${email.to.map((a) => a.toString()).join(', ')}',
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
        if (email.sentAt != null)
          Text(
            _dateFmt.format(email.sentAt!),
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
        if (email.listUnsubscribeHeader != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _UnsubscribeChip(header: email.listUnsubscribeHeader!),
          ),
      ],
    );
  }

  Future<String> _quotedBody(Email header, EmailBody? body) async {
    final date = header.sentAt != null ? _dateFmt.format(header.sentAt!) : '';
    final from =
        header.from.isNotEmpty ? header.from.first.toString() : '(unknown)';
    final rawText = body?.textBody;
    final text = (rawText != null && rawText.isNotEmpty)
        ? rawText
        : await compute(htmlToPlain, body?.htmlBody ?? '');
    final quoted = text.trim().split('\n').map((l) => '> $l').join('\n');
    return '\n\n— On $date, $from wrote:\n$quoted';
  }

  Future<void> _replyWithRecipientDialog(
    BuildContext context,
    Email header,
    EmailBody? body,
  ) async {
    final account =
        await ref.read(accountRepositoryProvider).getAccount(header.accountId);
    final ownEmail = account?.email.toLowerCase() ?? '';

    final seen = <String>{};
    final candidates = <_Candidate>[];

    void addIfNew(EmailAddress addr, _Placement defaultPlacement) {
      final key = addr.email.toLowerCase();
      if (key == ownEmail || seen.contains(key)) return;
      seen.add(key);
      candidates.add(_Candidate(addr, defaultPlacement));
    }

    for (final addr in header.from) {
      addIfNew(addr, _Placement.to);
    }
    for (final addr in header.to) {
      addIfNew(addr, _Placement.to);
    }
    for (final addr in header.cc) {
      addIfNew(addr, _Placement.cc);
    }

    if (!context.mounted) return;

    if (candidates.length <= 1) {
      final to = candidates
          .where((c) => c.placement == _Placement.to)
          .map((c) => c.address.email)
          .join(', ');
      final cc = candidates
          .where((c) => c.placement == _Placement.cc)
          .map((c) => c.address.email)
          .join(', ');
      await _composeReply(context, header, body, to: to, cc: cc);
      return;
    }

    final confirmed = await showDialog<List<_Candidate>>(
      context: context,
      builder: (ctx) => _ReplyAllDialog(candidates: candidates),
    );

    if (confirmed == null || !context.mounted) return;

    final to = confirmed
        .where((c) => c.placement == _Placement.to)
        .map((c) => c.address.email)
        .join(', ');
    final cc = confirmed
        .where((c) => c.placement == _Placement.cc)
        .map((c) => c.address.email)
        .join(', ');
    await _composeReply(context, header, body, to: to, cc: cc);
  }

  Future<void> _composeReply(
    BuildContext context,
    Email header,
    EmailBody? body, {
    required String to,
    required String cc,
  }) async {
    final subject = (header.subject?.startsWith('Re:') ?? false)
        ? header.subject!
        : 'Re: ${header.subject ?? ''}';
    final quoted = await _quotedBody(header, body);
    if (!context.mounted) return;
    unawaited(
      context.push(
        '/compose',
        extra: {
          'replyToEmailId': widget.emailId,
          'prefillTo': to,
          'prefillSubject': subject,
          'prefillBody': quoted,
          if (cc.isNotEmpty) 'prefillCc': cc,
        },
      ),
    );
  }

  Future<void> _archive(BuildContext context, Email header) async {
    final nextEmailId = await _getNextEmailIdIfNeeded(header);
    if (!context.mounted) return;

    final mailbox = await resolveMailboxByRole(
      context,
      ref.read(mailboxRepositoryProvider),
      header.accountId,
      header.mailboxPath,
      'archive',
      dialogTitle: 'No archive folder found',
      createFolderName: 'Archive',
    );

    if (mailbox == null || !context.mounted) return;

    await ref
        .read(emailRepositoryProvider)
        .moveEmail(widget.emailId, mailbox.path);

    unawaited(
      ref.read(undoServiceProvider.notifier).pushAction(
            UndoAction(
              id: DateTime.now().toIso8601String(),
              accountId: header.accountId,
              type: UndoType.move,
              emailIds: [widget.emailId],
              sourceMailboxPath: header.mailboxPath,
              destinationMailboxPath: mailbox.path,
            ),
          ),
    );

    if (context.mounted) _navigateTo(context, header, nextEmailId);
  }

  Future<void> _markAsSpam(BuildContext context, Email header) async {
    final nextEmailId = await _getNextEmailIdIfNeeded(header);
    if (!context.mounted) return;

    final mailbox = await resolveMailboxByRole(
      context,
      ref.read(mailboxRepositoryProvider),
      header.accountId,
      header.mailboxPath,
      'junk',
      dialogTitle: 'No spam folder found',
      createFolderName: 'Junk',
    );

    if (mailbox == null || !context.mounted) return;

    await ref
        .read(emailRepositoryProvider)
        .moveEmail(widget.emailId, mailbox.path);

    unawaited(
      ref.read(undoServiceProvider.notifier).pushAction(
            UndoAction(
              id: DateTime.now().toIso8601String(),
              accountId: header.accountId,
              type: UndoType.move,
              emailIds: [widget.emailId],
              sourceMailboxPath: header.mailboxPath,
              destinationMailboxPath: mailbox.path,
            ),
          ),
    );

    if (context.mounted) _navigateTo(context, header, nextEmailId);
  }

  Future<void> _forward(
    BuildContext context,
    Email header,
    EmailBody? body,
  ) async {
    final subject = (header.subject?.startsWith('Fwd:') ?? false)
        ? header.subject!
        : 'Fwd: ${header.subject ?? ''}';
    final quoted = await _quotedBody(header, body);
    if (!context.mounted) return;
    unawaited(
      context.push(
        '/compose',
        extra: {
          'prefillSubject': subject,
          'prefillBody': quoted,
        },
      ),
    );
  }

  Future<void> _moveTo(BuildContext context, Email header) async {
    final nextEmailId = await _getNextEmailIdIfNeeded(header);

    final mailboxRepo = ref.read(mailboxRepositoryProvider);
    final mailboxes =
        await mailboxRepo.observeMailboxes(header.accountId).first;

    // Remove the current mailbox from the list.
    final destinations =
        mailboxes.where((m) => m.path != header.mailboxPath).toList();

    if (!context.mounted) return;

    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        children: [
          const ListTile(
            title: Text(
              'Move to…',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          for (final m in destinations)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(m.name),
              onTap: () => Navigator.pop(ctx, m.path),
            ),
        ],
      ),
    );

    if (chosen == null || !context.mounted) return;

    await ref.read(emailRepositoryProvider).moveEmail(widget.emailId, chosen);

    unawaited(
      ref.read(undoServiceProvider.notifier).pushAction(
            UndoAction(
              id: DateTime.now().toIso8601String(),
              accountId: header.accountId,
              type: UndoType.move,
              emailIds: [widget.emailId],
              sourceMailboxPath: header.mailboxPath,
              destinationMailboxPath: chosen,
            ),
          ),
    );

    if (context.mounted) _navigateTo(context, header, nextEmailId);
  }

  Future<void> _snooze(BuildContext context, Email header) async {
    final nextEmailId = await _getNextEmailIdIfNeeded(header);
    if (!context.mounted) return;

    final until = await showModalBottomSheet<DateTime>(
      context: context,
      builder: (ctx) => const SnoozePicker(),
    );
    if (until == null || !context.mounted) return;

    final repo = ref.read(emailRepositoryProvider);
    final action = UndoAction(
      id: DateTime.now().toIso8601String(),
      accountId: header.accountId,
      type: UndoType.snooze,
      emailIds: [widget.emailId],
      sourceMailboxPath: header.mailboxPath,
      originalEmails: [header],
    );
    unawaited(ref.read(undoServiceProvider.notifier).pushAction(action));
    await repo.snoozeEmail(widget.emailId, until);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          content: Text(
            'Snoozed until ${DateFormat('MMM d, HH:mm').format(until)}',
          ),
        ),
      );
      _navigateTo(context, header, nextEmailId);
    }
  }

  Future<void> _showRaw(BuildContext context, Email? header) async {
    final String raw;
    try {
      raw = await ref
          .read(emailRepositoryProvider)
          .fetchRawRfc822(widget.emailId);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to fetch raw email: $e')),
      );
      return;
    }

    if (!context.mounted) return;

    unawaited(
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Raw Email'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fmtSize(raw.length),
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).colorScheme.outline,
                      ),
                ),
                const SizedBox(height: 4),
                Flexible(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      raw,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: raw));
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('Copied to clipboard')),
                  );
                }
              },
              child: const Text('Copy'),
            ),
            TextButton(
              onPressed: () async {
                await _downloadRaw(ctx, header, raw);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Download'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _downloadRaw(
    BuildContext context,
    Email? header,
    String raw,
  ) async {
    try {
      final dir = await getTemporaryDirectory();
      final subject = (header?.subject ?? 'email')
          .replaceAll(RegExp(r'[^\w\s-]'), '_')
          .trim();
      final filename = '$subject.eml';
      final file = File('${dir.path}/$filename');
      await file.writeAsString(raw);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved $filename'),
          action: SnackBarAction(
            label: 'Share',
            onPressed: () => SharePlus.instance.share(
              ShareParams(files: [XFile(file.path)]),
            ),
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Download failed: $e')));
    }
  }

  void _showHeaders(BuildContext context, EmailBody body) {
    if (body.headers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 5),
          content: Text('No headers available. Try re-syncing the email.'),
        ),
      );
      return;
    }

    unawaited(
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Mail Headers'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: body.headers.length,
              itemBuilder: (ctx, i) {
                final header = body.headers[i];
                return Container(
                  color: i.isEven
                      ? Theme.of(ctx).colorScheme.surfaceContainerHighest
                      : Theme.of(ctx).colorScheme.surface,
                  padding: const EdgeInsets.symmetric(
                    vertical: 4,
                    horizontal: 8,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: SelectableText(
                          header.name,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(flex: 2, child: SelectableText(header.value)),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  void _showStructure(BuildContext context, EmailBody body) {
    final tree = body.mimeTree;
    if (tree == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 5),
          content: Text(
            'Structure not available. Try re-syncing the email.',
          ),
        ),
      );
      return;
    }

    final rows = <_MimeRow>[];
    _flattenMimeTree(tree, 0, rows);

    unawaited(
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Mail Structure'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: rows.length,
              itemBuilder: (ctx, i) {
                final row = rows[i];
                return Container(
                  color: i.isEven
                      ? Theme.of(ctx).colorScheme.surfaceContainerHighest
                      : Theme.of(ctx).colorScheme.surface,
                  padding: const EdgeInsets.symmetric(
                    vertical: 4,
                    horizontal: 8,
                  ),
                  child: Row(
                    children: [
                      SizedBox(width: row.depth * 16.0),
                      Expanded(
                        child: Text(
                          row.label,
                          style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                              ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}

enum _Placement { to, cc, skip }

class _Candidate {
  _Candidate(this.address, this.placement);
  final EmailAddress address;
  _Placement placement;
}

class _ReplyAllDialog extends StatefulWidget {
  const _ReplyAllDialog({required this.candidates});
  final List<_Candidate> candidates;

  @override
  State<_ReplyAllDialog> createState() => _ReplyAllDialogState();
}

class _ReplyAllDialogState extends State<_ReplyAllDialog> {
  late final List<_Candidate> _candidates;

  @override
  void initState() {
    super.initState();
    _candidates = [
      for (final c in widget.candidates) _Candidate(c.address, c.placement),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reply All'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final c in _candidates)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        c.address.toString(),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SegmentedButton<_Placement>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: _Placement.to,
                          label: Text('To'),
                        ),
                        ButtonSegment(
                          value: _Placement.cc,
                          label: Text('Cc'),
                        ),
                        ButtonSegment(
                          value: _Placement.skip,
                          label: Text('Skip'),
                        ),
                      ],
                      selected: {c.placement},
                      onSelectionChanged: (s) =>
                          setState(() => c.placement = s.first),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _candidates),
          child: const Text('Reply'),
        ),
      ],
    );
  }
}

class _MimeRow {
  const _MimeRow(this.depth, this.label);
  final int depth;
  final String label;
}

void _flattenMimeTree(MimePart part, int depth, List<_MimeRow> out) {
  final parts = <String>[part.contentType];
  if (part.filename != null) parts.add('"${part.filename}"');
  if (part.size != null) parts.add(fmtSize(part.size!));
  if (part.encoding != null) parts.add(part.encoding!);
  out.add(_MimeRow(depth, parts.join('  ')));
  for (final child in part.children) {
    _flattenMimeTree(child, depth + 1, out);
  }
}

/// Parses a List-Unsubscribe header and returns the first usable URI.
/// Prefers mailto: so unsubscribing sends an email; falls back to https:.
Uri? _parseUnsubscribeUri(String header) {
  final matches = RegExp(r'<([^>]+)>').allMatches(header);
  Uri? fallback;
  for (final m in matches) {
    final raw = m.group(1)!.trim();
    final uri = Uri.tryParse(raw);
    if (uri == null) continue;
    if (uri.scheme == 'mailto') return uri;
    if ((uri.scheme == 'https' || uri.scheme == 'http') && fallback == null) {
      fallback = uri;
    }
  }
  return fallback;
}

class _UnsubscribeChip extends StatelessWidget {
  const _UnsubscribeChip({required this.header});
  final String header;

  @override
  Widget build(BuildContext context) {
    final uri = _parseUnsubscribeUri(header);
    if (uri == null) return const SizedBox.shrink();
    return Tooltip(
      message: uri.toString(),
      child: ActionChip(
        avatar: const Icon(Icons.unsubscribe_outlined, size: 16),
        label: const Text('Unsubscribe'),
        onPressed: () => launchUrl(uri, mode: LaunchMode.externalApplication),
      ),
    );
  }
}
