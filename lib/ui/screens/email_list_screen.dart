import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../di.dart';

final _dateFmt = DateFormat('MMM d');

class EmailListScreen extends ConsumerWidget {
  const EmailListScreen({
    super.key,
    required this.accountId,
    required this.mailboxPath,
  });

  final String accountId;
  final String mailboxPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(emailRepositoryProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(mailboxPath),
        actions: [
          IconButton(
            icon: const Icon(Icons.sync),
            onPressed: () =>
                repo.syncEmails(accountId, mailboxPath),
          ),
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () => context.push(
              '/compose',
              extra: {'accountId': accountId},
            ),
          ),
        ],
      ),
      body: StreamBuilder(
        stream: repo.observeEmails(accountId, mailboxPath),
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final emails = snap.data!;
          if (emails.isEmpty) {
            return const Center(child: Text('No emails'));
          }
          return ListView.builder(
            itemCount: emails.length,
            itemBuilder: (ctx, i) {
              final e = emails[i];
              final sender = e.from.isNotEmpty
                  ? (e.from.first.name ?? e.from.first.email)
                  : '(unknown)';
              return ListTile(
                leading: Icon(
                  e.isSeen ? Icons.mail_outline : Icons.mail,
                  color: e.isSeen ? null : Theme.of(ctx).colorScheme.primary,
                ),
                title: Text(
                  sender,
                  style: e.isSeen
                      ? null
                      : const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  e.subject ?? '(no subject)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Text(
                  e.sentAt != null ? _dateFmt.format(e.sentAt!) : '',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                onTap: () => context.push(
                  '/accounts/$accountId/mailboxes/${Uri.encodeComponent(mailboxPath)}/emails/${Uri.encodeComponent(e.id)}',
                ),
              );
            },
          );
        },
      ),
    );
  }
}
