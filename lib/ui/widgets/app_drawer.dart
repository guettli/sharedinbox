import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/widgets/mailbox_count_label.dart';

/// Identifies the currently-active destination so the drawer can highlight
/// the matching row. Use the named constructors below at call sites.
sealed class AppDrawerSelection {
  const AppDrawerSelection();

  const factory AppDrawerSelection.none() = _DrawerSelectionNone;
  const factory AppDrawerSelection.combinedInbox() =
      _DrawerSelectionCombinedInbox;
  const factory AppDrawerSelection.manageAccounts() =
      _DrawerSelectionManageAccounts;
  const factory AppDrawerSelection.account(String accountId) =
      _DrawerSelectionAccount;
  const factory AppDrawerSelection.mailbox(
    String accountId,
    String mailboxPath,
  ) = _DrawerSelectionMailbox;

  /// The account whose tree should auto-expand on first build, if any.
  String? get activeAccountId => switch (this) {
        _DrawerSelectionAccount(:final accountId) => accountId,
        _DrawerSelectionMailbox(:final accountId) => accountId,
        _ => null,
      };
}

class _DrawerSelectionNone extends AppDrawerSelection {
  const _DrawerSelectionNone();
}

class _DrawerSelectionCombinedInbox extends AppDrawerSelection {
  const _DrawerSelectionCombinedInbox();
}

class _DrawerSelectionManageAccounts extends AppDrawerSelection {
  const _DrawerSelectionManageAccounts();
}

class _DrawerSelectionAccount extends AppDrawerSelection {
  const _DrawerSelectionAccount(this.accountId);
  final String accountId;
}

class _DrawerSelectionMailbox extends AppDrawerSelection {
  const _DrawerSelectionMailbox(this.accountId, this.mailboxPath);
  final String accountId;
  final String mailboxPath;
}

/// One drawer used on every top-level screen. The structure is always the same:
/// combined inbox, every account (expandable into its folder tree), global
/// actions. The active row, if any, is highlighted via [current].
class AppDrawer extends ConsumerWidget {
  const AppDrawer({super.key, this.current = const AppDrawerSelection.none()});

  final AppDrawerSelection current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountsAsync = ref.watch(allAccountsProvider);
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            DrawerHeader(
              decoration: const BoxDecoration(color: Colors.blueGrey),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Text(
                  'sharedinbox.de',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        color: Colors.white,
                      ),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  ListTile(
                    leading: const Icon(Icons.inbox),
                    title: const Text('Combined Inbox'),
                    selected: current is _DrawerSelectionCombinedInbox,
                    onTap: () {
                      Navigator.pop(context);
                      context.go('/inbox');
                    },
                  ),
                  const Divider(height: 1),
                  accountsAsync.when(
                    loading: () => const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                    error: (e, _) => Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('Error loading accounts: $e'),
                    ),
                    data: (accounts) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final account in accounts)
                          _AccountSection(
                            account: account,
                            current: current,
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.manage_accounts),
                    title: const Text('Manage accounts'),
                    selected: current is _DrawerSelectionManageAccounts,
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
                  ListTile(
                    leading: const Icon(Icons.qr_code_scanner),
                    title: const Text('Receive accounts'),
                    onTap: () {
                      Navigator.pop(context);
                      unawaited(context.push('/accounts/receive'));
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.settings),
                    title: const Text('Preferences'),
                    onTap: () {
                      Navigator.pop(context);
                      unawaited(context.push('/accounts/preferences'));
                    },
                  ),
                  const _SentQueueDrawerTile(),
                  const _PendingChangesDrawerTile(),
                  ListTile(
                    leading: const Icon(Icons.history),
                    title: const Text('Undo Log'),
                    onTap: () {
                      Navigator.pop(context);
                      unawaited(context.push('/accounts/undo-log'));
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.list_alt),
                    title: const Text('Application Log'),
                    onTap: () {
                      Navigator.pop(context);
                      unawaited(context.push('/accounts/app-log'));
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.update),
                    title: const Text('ChangeLog'),
                    onTap: () {
                      Navigator.pop(context);
                      unawaited(context.push('/accounts/changelog'));
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
            ),
          ],
        ),
      ),
    );
  }
}

/// Per-account row: tapping the title opens the account home, tapping the
/// chevron expands the folder tree. The tree is only subscribed to once the
/// section is expanded, so collapsed accounts don't stream mailbox updates.
class _AccountSection extends ConsumerStatefulWidget {
  const _AccountSection({required this.account, required this.current});

  final Account account;
  final AppDrawerSelection current;

  @override
  ConsumerState<_AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends ConsumerState<_AccountSection> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.current.activeAccountId == widget.account.id;
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.current;
    final account = widget.account;
    final isActiveAccount =
        current is _DrawerSelectionAccount && current.accountId == account.id;
    final activeMailboxPath =
        current is _DrawerSelectionMailbox && current.accountId == account.id
            ? current.mailboxPath
            : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: const Icon(Icons.account_circle),
          title: Text(account.displayName),
          subtitle: Text(account.email),
          selected: isActiveAccount,
          trailing: IconButton(
            icon: Icon(
              _expanded ? Icons.expand_less : Icons.expand_more,
            ),
            tooltip: _expanded ? 'Collapse folders' : 'Show folders',
            onPressed: () => setState(() => _expanded = !_expanded),
          ),
          onTap: () {
            Navigator.pop(context);
            context.go('/accounts/${account.id}');
          },
        ),
        if (_expanded)
          _FolderList(
            accountId: account.id,
            activeMailboxPath: activeMailboxPath,
          ),
      ],
    );
  }
}

/// Global "Sent Queue" drawer entry — lists every message waiting to leave
/// the device across all accounts. Shows a count badge when non-empty so
/// stuck messages are visible without opening the screen.
class _SentQueueDrawerTile extends ConsumerWidget {
  const _SentQueueDrawerTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(allOutboxProvider).value?.length ?? 0;
    return ListTile(
      leading: const Icon(Icons.outbox),
      title: const Text('Sent Queue'),
      trailing: count > 0 ? Badge(label: Text('$count')) : null,
      onTap: () {
        Navigator.pop(context);
        unawaited(context.push('/sent-queue'));
      },
    );
  }
}

/// Global "Pending Changes" drawer entry — surfaces the outbound queue of
/// local mutations (flag/move/delete) that have not yet been flushed to the
/// server. Shows a badge with the total count so a growing queue is visible
/// without opening the screen.
class _PendingChangesDrawerTile extends ConsumerWidget {
  const _PendingChangesDrawerTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(allPendingChangesProvider).value?.length ?? 0;
    return ListTile(
      leading: const Icon(Icons.sync_problem),
      title: const Text('Pending Changes'),
      trailing: count > 0 ? Badge(label: Text('$count')) : null,
      onTap: () {
        Navigator.pop(context);
        unawaited(context.push('/pending-changes'));
      },
    );
  }
}

/// Surfaces the per-account offline send queue in the drawer. Shows a count
/// badge when there are queued messages so the user knows they need delivery.
class _OutboxTile extends ConsumerWidget {
  const _OutboxTile({required this.accountId});

  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(outboxRepositoryProvider);
    return StreamBuilder(
      stream: repo.observeOutbox(accountId),
      builder: (ctx, snap) {
        final count = snap.data?.length ?? 0;
        return ListTile(
          leading: const Icon(Icons.outbox),
          title: const Text('Outbox'),
          trailing: count > 0 ? Badge(label: Text('$count')) : null,
          onTap: () {
            Navigator.pop(context);
            context.go('/accounts/$accountId/outbox');
          },
        );
      },
    );
  }
}

class _FolderList extends ConsumerWidget {
  const _FolderList({required this.accountId, this.activeMailboxPath});

  final String accountId;
  final String? activeMailboxPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mailboxRepo = ref.watch(mailboxRepositoryProvider);
    return StreamBuilder(
      stream: mailboxRepo.observeMailboxes(accountId),
      builder: (ctx, snap) {
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final mailboxes = List.of(snap.data!)..sort(compareMailboxes);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mb in mailboxes)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: ListTile(
                  leading: const Icon(Icons.folder),
                  title: Text(
                    mb.name,
                    style: mb.unreadCount > 0
                        ? const TextStyle(fontWeight: FontWeight.bold)
                        : null,
                  ),
                  selected: mb.path == activeMailboxPath,
                  trailing: MailboxCountLabel(
                    unread: mb.unreadCount,
                    total: mb.totalCount,
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    context.go(
                      '/accounts/$accountId/mailboxes'
                      '/${Uri.encodeComponent(mb.path)}/emails',
                    );
                  },
                ),
              ),
            // Local-only "folder" surfacing queued offline sends.
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: _OutboxTile(accountId: accountId),
            ),
          ],
        );
      },
    );
  }
}
