import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/di.dart';

final _dateFmt = DateFormat('MMM d');
final _formattedDates = <int, String>{};

int _dayKey(DateTime dt) => dt.year * 10000 + dt.month * 100 + dt.day;

String _fmtDate(DateTime dt) =>
    _formattedDates[_dayKey(dt)] ??= _dateFmt.format(dt);

class CombinedInboxScreen extends ConsumerStatefulWidget {
  const CombinedInboxScreen({super.key});

  @override
  ConsumerState<CombinedInboxScreen> createState() =>
      _CombinedInboxScreenState();
}

class _CombinedInboxScreenState extends ConsumerState<CombinedInboxScreen> {
  static const _pageSize = 50;
  int _limit = _pageSize;

  @override
  Widget build(BuildContext context) {
    final accountsAsync = ref.watch(allAccountsProvider);

    return accountsAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        body: Center(child: Text('Error: $e')),
      ),
      data: (accounts) {
        if (accounts.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) context.go('/accounts');
          });
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final accountNames = {
          for (final a in accounts) a.id: a.displayName,
        };
        final showAccount = accounts.length > 1;

        return Scaffold(
          appBar: _buildAppBar(accounts),
          drawer: _buildDrawer(context, accounts),
          body: _buildBody(accountNames, showAccount),
          floatingActionButton: FloatingActionButton(
            onPressed: () => context.push('/compose'),
            child: const Icon(Icons.edit),
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar(List<Account> accounts) {
    return AppBar(
      title: const Text('Combined Inbox'),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: 'Search',
          onPressed: () => context.push('/search'),
        ),
        IconButton(
          icon: const Icon(Icons.sync),
          tooltip: 'Sync all',
          onPressed: () {
            for (final a in accounts) {
              ref.read(syncManagerProvider).syncNow(a.id);
            }
          },
        ),
      ],
    );
  }

  Widget _buildDrawer(BuildContext context, List<Account> accounts) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          const DrawerHeader(
            decoration: BoxDecoration(color: Colors.blueGrey),
            child: Text(
              'sharedinbox.de',
              style: TextStyle(color: Colors.white, fontSize: 24),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.manage_accounts),
            title: const Text('Accounts'),
            onTap: () {
              Navigator.pop(context);
              context.go('/accounts');
            },
          ),
          ListTile(
            leading: const Icon(Icons.person_add),
            title: const Text('Add account'),
            onTap: () {
              Navigator.pop(context);
              unawaited(context.push('/accounts/add'));
            },
          ),
          const Divider(),
          for (final account in accounts)
            ListTile(
              leading: const Icon(Icons.inbox),
              title: Text(account.displayName),
              subtitle: Text(account.email),
              onTap: () {
                Navigator.pop(context);
                unawaited(context.push('/accounts/${account.id}/mailboxes'));
              },
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('Preferences'),
            onTap: () {
              Navigator.pop(context);
              unawaited(context.push('/accounts/preferences'));
            },
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Undo Log'),
            onTap: () {
              Navigator.pop(context);
              unawaited(context.push('/accounts/undo-log'));
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            onTap: () {
              Navigator.pop(context);
              unawaited(context.push('/accounts/about'));
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBody(Map<String, String> accountNames, bool showAccount) {
    final emailRepo = ref.watch(emailRepositoryProvider);
    return RefreshIndicator(
      onRefresh: () async {
        final accounts = ref.read(allAccountsProvider).value ?? [];
        for (final a in accounts) {
          ref.read(syncManagerProvider).syncNow(a.id);
        }
      },
      child: StreamBuilder<List<EmailThread>>(
        stream: emailRepo.observeAllInboxThreads(limit: _limit),
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final threads = snap.data!;
          if (threads.isEmpty) {
            return ListView(
              children: const [
                SizedBox(
                  height: 300,
                  child: Center(child: Text('No emails')),
                ),
              ],
            );
          }
          return _buildThreadList(threads, accountNames, showAccount);
        },
      ),
    );
  }

  Widget _buildThreadList(
    List<EmailThread> threads,
    Map<String, String> accountNames,
    bool showAccount,
  ) {
    final hasMore = threads.length == _limit;
    return ListView.builder(
      itemCount: threads.length + (hasMore ? 1 : 0),
      itemBuilder: (ctx, i) {
        if (i == threads.length) {
          return TextButton(
            onPressed: () => setState(() => _limit += _pageSize),
            child: const Text('Load more'),
          );
        }
        return _buildThreadTile(ctx, threads[i], accountNames, showAccount);
      },
    );
  }

  Widget _buildThreadTile(
    BuildContext ctx,
    EmailThread t,
    Map<String, String> accountNames,
    bool showAccount,
  ) {
    final senderNames =
        t.participants.map((a) => a.name ?? a.email).take(3).join(', ');

    final tile = ListTile(
      leading: Icon(
        t.hasUnread ? Icons.mail : Icons.mail_outline,
        color: t.hasUnread ? Theme.of(ctx).colorScheme.primary : null,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              senderNames.isEmpty ? '(unknown)' : senderNames,
              style: t.hasUnread
                  ? const TextStyle(fontWeight: FontWeight.bold)
                  : null,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (t.messageCount > 1)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                '[${t.messageCount}]',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.subject ?? '(no subject)',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.hasUnread
                ? const TextStyle(fontWeight: FontWeight.bold)
                : null,
          ),
          if (t.preview != null && t.preview!.isNotEmpty)
            Text(
              t.preview!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          if (showAccount)
            Text(
              accountNames[t.accountId] ?? t.accountId,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.primary,
                  ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (t.isFlagged)
            const Icon(Icons.star, color: Colors.amber, size: 16),
          const SizedBox(width: 4),
          Text(
            _fmtDate(t.latestDate),
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
        ],
      ),
      onTap: t.messageCount > 1
          ? () => context.push(
                '/accounts/${t.accountId}/mailboxes'
                '/${Uri.encodeComponent(t.mailboxPath)}'
                '/threads/${Uri.encodeComponent(t.threadId)}',
              )
          : () => context.push(
                '/accounts/${t.accountId}/mailboxes'
                '/${Uri.encodeComponent(t.mailboxPath)}'
                '/emails/${Uri.encodeComponent(t.latestEmailId)}',
              ),
    );

    return Dismissible(
      key: ValueKey('${t.accountId}:${t.threadId}'),
      background: _swipeBackground(
        alignment: Alignment.centerLeft,
        color: Colors.green,
        icon: Icons.archive,
        label: 'Archive',
      ),
      secondaryBackground: _swipeBackground(
        alignment: Alignment.centerRight,
        color: Colors.red,
        icon: Icons.delete,
        label: 'Delete',
      ),
      onDismissed: (direction) => unawaited(_onSwipeDismissed(t, direction)),
      child: tile,
    );
  }

  Future<void> _onSwipeDismissed(
    EmailThread t,
    DismissDirection direction,
  ) async {
    final repo = ref.read(emailRepositoryProvider);

    final originalEmails = (await Future.wait(
      t.emailIds.map((id) => repo.getEmail(id)),
    ))
        .whereType<Email>()
        .toList();

    if (direction == DismissDirection.startToEnd) {
      final archive = await ref
          .read(mailboxRepositoryProvider)
          .findMailboxByRole(t.accountId, 'archive');
      if (!mounted || archive == null) return;

      for (final id in t.emailIds) {
        await repo.moveEmail(id, archive.path);
      }
      final action = UndoAction(
        id: DateTime.now().toIso8601String(),
        accountId: t.accountId,
        type: UndoType.move,
        emailIds: t.emailIds,
        sourceMailboxPath: t.mailboxPath,
        destinationMailboxPath: archive.path,
        originalEmails: originalEmails,
      );
      unawaited(ref.read(undoServiceProvider.notifier).pushAction(action));
      return;
    }

    String? lastDestPath;
    for (final id in t.emailIds) {
      lastDestPath = await repo.deleteEmail(id);
    }
    final action = UndoAction(
      id: DateTime.now().toIso8601String(),
      accountId: t.accountId,
      type: UndoType.delete,
      emailIds: t.emailIds,
      sourceMailboxPath: t.mailboxPath,
      destinationMailboxPath: lastDestPath,
      originalEmails: originalEmails,
    );
    unawaited(ref.read(undoServiceProvider.notifier).pushAction(action));
  }

  Widget _swipeBackground({
    required AlignmentGeometry alignment,
    required Color color,
    required IconData icon,
    required String label,
  }) {
    return Container(
      color: color,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }
}
