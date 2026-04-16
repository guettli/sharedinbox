import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/models/email.dart';
import '../../di.dart';

final _dateFmt = DateFormat('EEE, MMM d yyyy, HH:mm');

class EmailDetailScreen extends ConsumerStatefulWidget {
  const EmailDetailScreen({super.key, required this.emailId});
  final String emailId;

  @override
  ConsumerState<EmailDetailScreen> createState() => _EmailDetailScreenState();
}

class _EmailDetailScreenState extends ConsumerState<EmailDetailScreen> {
  late Future<EmailBody> _bodyFuture;

  @override
  void initState() {
    super.initState();
    _loadBody();
    _markSeen();
  }

  void _loadBody() {
    _bodyFuture =
        ref.read(emailRepositoryProvider).getEmailBody(widget.emailId);
  }

  Future<void> _markSeen() async {
    await ref
        .read(emailRepositoryProvider)
        .setFlag(widget.emailId, seen: true);
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(emailRepositoryProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Email'),
        actions: [
          IconButton(
            icon: const Icon(Icons.reply),
            tooltip: 'Reply',
            onPressed: () => _reply(context, replyAll: false),
          ),
          IconButton(
            icon: const Icon(Icons.reply_all),
            tooltip: 'Reply all',
            onPressed: () => _reply(context, replyAll: true),
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () async {
              await repo.deleteEmail(widget.emailId);
              if (context.mounted) context.pop();
            },
          ),
        ],
      ),
      body: FutureBuilder<EmailBody>(
        future: _bodyFuture,
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          final body = snap.data!;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildHeader(ctx, body),
              const Divider(),
              SelectableText(
                body.textBody ??
                    _htmlToPlain(body.htmlBody ?? '') ,
              ),
              if (body.attachments.isNotEmpty) ...[
                const Divider(),
                const Text(
                  'Attachments',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                for (final att in body.attachments)
                  ListTile(
                    leading: const Icon(Icons.attach_file),
                    title: Text(att.filename),
                    subtitle: Text(_fmtSize(att.size)),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildHeader(BuildContext ctx, EmailBody body) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          body.emailId, // we'd look up subject from DB in real code
          style: Theme.of(ctx).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  void _reply(BuildContext context, {required bool replyAll}) {
    context.push('/compose', extra: {
      'replyToEmailId': widget.emailId,
    });
  }

  String _htmlToPlain(String html) {
    return html
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&nbsp;', ' ');
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
