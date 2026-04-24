import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/models/email.dart';
import '../../di.dart';

final _dateFmt = DateFormat('MMM d');

class ThreadDetailScreen extends ConsumerWidget {
  const ThreadDetailScreen({
    super.key,
    required this.accountId,
    required this.mailboxPath,
    required this.threadId,
  });

  final String accountId;
  final String mailboxPath;
  final String threadId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(emailRepositoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Thread')),
      body: StreamBuilder<List<EmailThread>>(
        stream: repo.observeThreads(accountId, mailboxPath),
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final thread =
              snap.data!.where((t) => t.threadId == threadId).firstOrNull;
          if (thread == null) {
            return const Center(child: Text('Thread not found'));
          }
          // Re-fetch the individual emails from observeEmails to show them.
          return StreamBuilder<List<Email>>(
            stream: repo.observeEmails(accountId, mailboxPath),
            builder: (ctx, emailSnap) {
              if (!emailSnap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final emails = emailSnap.data!
                  .where(
                    (e) => (e.threadId ?? e.id) == threadId,
                  )
                  .toList()
                ..sort((a, b) {
                  final da = a.sentAt ?? a.receivedAt;
                  final db = b.sentAt ?? b.receivedAt;
                  return da.compareTo(db);
                });

              if (emails.isEmpty) {
                return const Center(child: Text('No messages'));
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
                      color:
                          e.isSeen ? null : Theme.of(ctx).colorScheme.primary,
                    ),
                    title: Text(
                      sender,
                      style: e.isSeen
                          ? null
                          : const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      e.preview ?? e.subject ?? '(no subject)',
                      maxLines: 2,
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
          );
        },
      ),
    );
  }
}
