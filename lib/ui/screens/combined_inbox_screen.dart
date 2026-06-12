import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/widgets/email_thread_list.dart';

class CombinedInboxScreen extends ConsumerStatefulWidget {
  const CombinedInboxScreen({super.key});

  @override
  ConsumerState<CombinedInboxScreen> createState() =>
      _CombinedInboxScreenState();
}

class _CombinedInboxScreenState extends ConsumerState<CombinedInboxScreen> {
  static const _pageSize = 50;
  int _limit = _pageSize;

  late final EmailThreadListController _selection;

  @override
  void initState() {
    super.initState();
    _selection = EmailThreadListController()..addListener(_onSelectionChange);
  }

  @override
  void dispose() {
    _selection
      ..removeListener(_onSelectionChange)
      ..dispose();
    super.dispose();
  }

  void _onSelectionChange() {
    if (mounted) setState(() {});
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
        final selecting = _selection.isSelecting;

        return Scaffold(
          appBar: selecting
              ? buildSelectionAppBar(_selection)
              : _buildAppBar(accounts),
          drawer: selecting ? null : _buildDrawer(context, accounts),
          bottomNavigationBar: selecting
              ? buildSelectionBottomBar(context, ref, _selection)
              : null,
          body: _buildBody(accountNames, showAccount),
          floatingActionButton: selecting
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
      child: EmailThreadList(
        controller: _selection,
        stream: emailRepo.observeAllInboxThreads(limit: _limit),
        enablePagination: true,
        showAccountLabel: showAccount,
        accountNames: accountNames,
        onLoadMore: () => setState(() => _limit += _pageSize),
      ),
    );
  }
}
