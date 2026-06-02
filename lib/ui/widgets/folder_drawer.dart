import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/di.dart';

/// Drawer showing all folders for [accountId].
/// Highlights [currentMailboxPath] when provided.
class FolderDrawer extends ConsumerWidget {
  const FolderDrawer({
    super.key,
    required this.accountId,
    this.currentMailboxPath,
  });

  final String accountId;
  final String? currentMailboxPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountAsync = ref.watch(accountByIdProvider(accountId));
    final mailboxRepo = ref.watch(mailboxRepositoryProvider);

    return Drawer(
      child: Column(
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
            ),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: accountAsync.when(
                loading: () => const CircularProgressIndicator(),
                error: (_, __) => const Text('Account'),
                data: (account) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account?.displayName ?? '',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onPrimaryContainer,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    Text(
                      account?.email ?? '',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.switch_account),
            title: const Text('All accounts'),
            onTap: () {
              Navigator.pop(context);
              context.go('/accounts');
            },
          ),
          ListTile(
            leading: const Icon(Icons.dns),
            title: const Text('Remote Filters'),
            onTap: () {
              Navigator.pop(context);
              unawaited(context.push('/accounts/$accountId/sieve'));
            },
          ),
          ListTile(
            leading: const Icon(Icons.phone_android),
            title: const Text('Local Filters'),
            onTap: () {
              Navigator.pop(context);
              unawaited(context.push('/accounts/$accountId/sieve/local'));
            },
          ),
          const Divider(height: 1),
          Expanded(
            child: StreamBuilder(
              stream: mailboxRepo.observeMailboxes(accountId),
              builder: (ctx, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final mailboxes = List.of(snap.data!)..sort(compareMailboxes);
                return ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    for (final mb in mailboxes)
                      ListTile(
                        leading: const Icon(Icons.folder),
                        title: Text(
                          mb.name,
                          style: mb.unreadCount > 0
                              ? const TextStyle(fontWeight: FontWeight.bold)
                              : null,
                        ),
                        selected: mb.path == currentMailboxPath,
                        trailing: mb.unreadCount > 0
                            ? Badge(label: Text('${mb.unreadCount}'))
                            : null,
                        onTap: () {
                          Navigator.pop(context);
                          context.go(
                            '/accounts/$accountId/mailboxes'
                            '/${Uri.encodeComponent(mb.path)}/emails',
                          );
                        },
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
