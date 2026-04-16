import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/models/email.dart';
import '../../core/utils/format_utils.dart';
import '../../core/utils/html_utils.dart';
import '../../di.dart';

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
    repo.setFlag(widget.emailId, seen: true);
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
                    : () => _reply(context, header, replyAll: false),
              ),
              IconButton(
                icon: const Icon(Icons.reply_all),
                tooltip: 'Reply all',
                onPressed: header == null
                    ? null
                    : () => _reply(context, header, replyAll: true),
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
                icon: const Icon(Icons.delete),
                tooltip: 'Delete',
                onPressed: () async {
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
              subtitle: Text(fmtSize(att.size)),
            ),
        ],
      ],
    );
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

  void _reply(BuildContext context, Email header, {required bool replyAll}) {
    final to = header.from.isNotEmpty ? header.from.first.email : '';
    final subject = (header.subject?.startsWith('Re:') ?? false)
        ? header.subject!
        : 'Re: ${header.subject ?? ''}';
    final cc = replyAll
        ? header.to.map((a) => a.email).join(', ')
        : '';
    context.push('/compose', extra: {
      'replyToEmailId': widget.emailId,
      'prefillTo': to,
      'prefillSubject': subject,
      if (cc.isNotEmpty) 'prefillCc': cc,
    });
  }

}
