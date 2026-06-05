import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/widgets/email_thread_tile.dart';

class CombinedInboxScreen extends ConsumerStatefulWidget {
  const CombinedInboxScreen({super.key});

  @override
  ConsumerState<CombinedInboxScreen> createState() =>
      _CombinedInboxScreenState();
}

class _CombinedInboxScreenState extends ConsumerState<CombinedInboxScreen> {
  static const _pageSize = 50;
  int _limit = _pageSize;

  // Thread-level selection (key = threadId).
  final Set<String> _selectedThreadIds = {};
  // Last-emitted thread list, used to resolve emailIds for batch operations.
  List<EmailThread> _currentThreads = [];

  bool get _selecting => _selectedThreadIds.isNotEmpty;

  void _toggleThreadSelection(EmailThread thread) {
    setState(() {
      if (_selectedThreadIds.contains(thread.threadId)) {
        _selectedThreadIds.remove(thread.threadId);
      } else {
        _selectedThreadIds.add(thread.threadId);
      }
    });
  }

  void _clearSelection() => setState(() => _selectedThreadIds.clear());

  void _selectAll() {
    setState(
      () => _selectedThreadIds.addAll(_currentThreads.map((t) => t.threadId)),
    );
  }

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
          drawer: _selecting ? null : _buildDrawer(context, accounts),
          bottomNavigationBar: _selecting ? _selectionBottomBar() : null,
          body: _buildBody(accountNames, showAccount),
          floatingActionButton: _selecting
              ? null
              : FloatingActionButton(
                  onPressed: () => context.push('/compose'),
                  child: const Icon(Icons.edit),
                ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar(List<Account> accounts) {
    if (_selecting) {
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _clearSelection,
        ),
        title: Text('${_selectedThreadIds.length} selected'),
        actions: [
          IconButton(
            icon: const Icon(Icons.select_all),
            tooltip: 'Select all',
            onPressed: _selectAll,
          ),
        ],
      );
    }

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

  Widget _selectionBottomBar() {
    return BottomAppBar(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            icon: const Icon(Icons.archive),
            tooltip: 'Archive',
            onPressed: _batchArchive,
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: 'Delete',
            onPressed: _batchDelete,
          ),
        ],
      ),
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
          _currentThreads = threads;
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
        final t = threads[i];
        return EmailThreadTile(
          thread: t,
          isSelected: _selectedThreadIds.contains(t.threadId),
          isSelecting: _selecting,
          showAccount: showAccount,
          accountName: accountNames[t.accountId],
          onTap: _selecting
              ? () => _toggleThreadSelection(t)
              : t.messageCount > 1
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
          onLongPress: () => _toggleThreadSelection(t),
          onDismissed: (direction) => _onSwipeDismissed(t, direction),
        );
      },
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

  Future<void> _batchArchive() async {
    final repo = ref.read(emailRepositoryProvider);
    final mailboxRepo = ref.read(mailboxRepositoryProvider);

    // Group selected threads by accountId so we look up each account's archive once.
    final byAccount = <String, List<EmailThread>>{};
    for (final t in _currentThreads) {
      if (!_selectedThreadIds.contains(t.threadId)) continue;
      (byAccount[t.accountId] ??= []).add(t);
    }

    _clearSelection();

    for (final entry in byAccount.entries) {
      final accountId = entry.key;
      final threads = entry.value;
      final archive = await mailboxRepo.findMailboxByRole(accountId, 'archive');
      if (!mounted || archive == null) continue;

      for (final t in threads) {
        final originalEmails = (await Future.wait(
          t.emailIds.map((id) => repo.getEmail(id)),
        ))
            .whereType<Email>()
            .toList();

        for (final id in t.emailIds) {
          await repo.moveEmail(id, archive.path);
        }

        final action = UndoAction(
          id: DateTime.now().toIso8601String(),
          accountId: accountId,
          type: UndoType.move,
          emailIds: t.emailIds,
          sourceMailboxPath: t.mailboxPath,
          destinationMailboxPath: archive.path,
          originalEmails: originalEmails,
        );
        unawaited(ref.read(undoServiceProvider.notifier).pushAction(action));
      }
    }
  }

  Future<void> _batchDelete() async {
    final repo = ref.read(emailRepositoryProvider);

    final selectedThreads = _currentThreads
        .where((t) => _selectedThreadIds.contains(t.threadId))
        .toList();

    _clearSelection();

    for (final t in selectedThreads) {
      final originalEmails = (await Future.wait(
        t.emailIds.map((id) => repo.getEmail(id)),
      ))
          .whereType<Email>()
          .toList();

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
  }
}
