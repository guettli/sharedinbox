import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/core/utils/html_utils.dart';
import 'package:sharedinbox/di.dart';

final _dateFmt = DateFormat('EEE, MMM d yyyy, HH:mm');

class EmailDetailScreen extends ConsumerStatefulWidget {
  const EmailDetailScreen({super.key, required this.emailId});
  final String emailId;

  @override
  ConsumerState<EmailDetailScreen> createState() => _EmailDetailScreenState();
}

class _EmailDetailScreenState extends ConsumerState<EmailDetailScreen> {
  late final Future<(Email?, EmailBody)> _dataFuture;
  bool _isFlagged = false;
  final Set<String> _downloading = {};

  @override
  void initState() {
    super.initState();
    final repo = ref.read(emailRepositoryProvider);
    _dataFuture = Future.wait([
      repo.getEmail(widget.emailId),
      repo.getEmailBody(widget.emailId),
    ]).then((results) {
      final email = results[0] as Email?;
      if (email != null && mounted) {
        setState(() => _isFlagged = email.isFlagged);
      }
      return (email, results[1] as EmailBody);
    });
    unawaited(repo.setFlag(widget.emailId, seen: true));
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(emailRepositoryProvider);
    return FutureBuilder<(Email?, EmailBody)>(
      future: _dataFuture,
      builder: (ctx, snap) {
        final header = snap.data?.$1;
        final body = snap.data?.$2;

        return Scaffold(
          appBar: AppBar(
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
                    : () => _reply(context, header, body, replyAll: false),
              ),
              IconButton(
                icon: const Icon(Icons.reply_all),
                tooltip: 'Reply all',
                onPressed: header == null
                    ? null
                    : () => _reply(context, header, body, replyAll: true),
              ),
              IconButton(
                icon: const Icon(Icons.forward),
                tooltip: 'Forward',
                onPressed: header == null
                    ? null
                    : () => _forward(context, header, body),
              ),
              IconButton(
                icon: const Icon(Icons.mark_email_unread_outlined),
                tooltip: 'Mark as unread',
                onPressed: () async {
                  await repo.setFlag(widget.emailId, seen: false);
                  if (context.mounted) context.pop();
                },
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
              IconButton(
                icon: const Icon(Icons.drive_file_move_outline),
                tooltip: 'Move to folder',
                onPressed:
                    header == null ? null : () => _moveTo(context, header),
              ),
              IconButton(
                icon: const Icon(Icons.delete),
                tooltip: 'Delete',
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Delete email'),
                      content: const Text(
                        'Move this email to Trash?',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed != true || !context.mounted) return;
                  await repo.deleteEmail(widget.emailId);
                  if (context.mounted) context.pop();
                },
              ),
            ],
          ),
          body: snap.connectionState == ConnectionState.waiting
              ? const Center(child: CircularProgressIndicator())
              : snap.hasError
                  ? Center(child: Text('Error: ${snap.error}'))
                  : _buildBody(ctx, header, body!),
        );
      },
    );
  }

  Widget _buildBody(BuildContext ctx, Email? header, EmailBody body) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (header != null) ...[
          _buildHeader(ctx, header),
          const Divider(),
        ],
        SelectableText(
          body.textBody ?? htmlToPlain(body.htmlBody ?? ''),
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

  Future<void> _downloadAndOpen(EmailAttachment att) async {
    setState(() => _downloading.add(att.filename));
    try {
      final path = await ref
          .read(emailRepositoryProvider)
          .downloadAttachment(widget.emailId, att);
      await OpenFilex.open(path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Opening file failed: $e')),
      );
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
      ],
    );
  }

  String _quotedBody(Email header, EmailBody? body) {
    final date = header.sentAt != null ? _dateFmt.format(header.sentAt!) : '';
    final from =
        header.from.isNotEmpty ? header.from.first.toString() : '(unknown)';
    final text = body?.textBody ?? htmlToPlain(body?.htmlBody ?? '');
    final quoted = text.trim().split('\n').map((l) => '> $l').join('\n');
    return '\n\n— On $date, $from wrote:\n$quoted';
  }

  void _reply(
    BuildContext context,
    Email header,
    EmailBody? body, {
    required bool replyAll,
  }) {
    final to = header.from.isNotEmpty ? header.from.first.email : '';
    final subject = (header.subject?.startsWith('Re:') ?? false)
        ? header.subject!
        : 'Re: ${header.subject ?? ''}';
    final cc = replyAll ? header.to.map((a) => a.email).join(', ') : '';
    unawaited(
      context.push(
        '/compose',
        extra: {
          'replyToEmailId': widget.emailId,
          'prefillTo': to,
          'prefillSubject': subject,
          'prefillBody': _quotedBody(header, body),
          if (cc.isNotEmpty) 'prefillCc': cc,
        },
      ),
    );
  }

  void _forward(BuildContext context, Email header, EmailBody? body) {
    final subject = (header.subject?.startsWith('Fwd:') ?? false)
        ? header.subject!
        : 'Fwd: ${header.subject ?? ''}';
    unawaited(
      context.push(
        '/compose',
        extra: {
          'prefillSubject': subject,
          'prefillBody': _quotedBody(header, body),
        },
      ),
    );
  }

  Future<void> _moveTo(BuildContext context, Email header) async {
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
    if (context.mounted) context.pop();
  }
}
