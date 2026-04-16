import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../di.dart';

class MailboxListScreen extends ConsumerWidget {
  const MailboxListScreen({super.key, required this.accountId});
  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(mailboxRepositoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Mailboxes')),
      body: StreamBuilder(
        stream: repo.observeMailboxes(accountId),
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final mailboxes = snap.data!;
          return ListView.builder(
            itemCount: mailboxes.length,
            itemBuilder: (ctx, i) {
              final mb = mailboxes[i];
              return ListTile(
                leading: const Icon(Icons.folder),
                title: Text(mb.name),
                trailing: mb.unreadCount > 0
                    ? Badge(label: Text('${mb.unreadCount}'))
                    : null,
                onTap: () => context.push(
                  '/accounts/$accountId/mailboxes/${Uri.encodeComponent(mb.path)}/emails',
                ),
              );
            },
          );
        },
      ),
    );
  }
}
