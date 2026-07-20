import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/widgets/app_drawer.dart';
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
              ? buildDebugSelectionAppBar(context, _selection)
              : _buildAppBar(accounts),
          drawer: selecting
              ? null
              : const AppDrawer(current: AppDrawerSelection.combinedInbox()),
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
