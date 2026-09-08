import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/search_scope.dart';
import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_drawer.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:sharedinbox/ui/widgets/email_thread_list.dart';

class EmailListScreen extends ConsumerStatefulWidget {
  const EmailListScreen({
    super.key,
    required this.accountId,
    required this.mailboxPath,
  });

  final String accountId;
  final String mailboxPath;

  @override
  ConsumerState<EmailListScreen> createState() => _EmailListScreenState();
}

class _EmailListScreenState extends ConsumerState<EmailListScreen> {
  final _searchController = SearchController();
  List<Email>? _searchResults;
  bool _searchLoading = false;
  bool get _searching => _searchController.text.isNotEmpty;

  // Search scope. The folder view's search defaults to every account and folder
  // (junk/trash excluded); the scope chips narrow it to this account or the
  // current folder, and the toggle brings junk/trash back in.
  SearchScope _scope = SearchScope.all;
  bool _includeJunkTrash = false;

  // Error banner — tracks the last error message that the user dismissed.
  String? _dismissedError;

  // Once the mailbox has been observed at least once, we treat a later
  // transition to "not found locally" as a server-side deletion and bounce
  // the user back to the account's folder list. The flag prevents an early
  // null (before mailboxes have streamed in) from triggering the redirect.
  bool _mailboxSeen = false;
  bool _gonePending = false;

  late final EmailThreadListController _selection;

  // Pagination: number of threads currently requested from the DB.
  static const _pageSize = 50;
  int _limit = _pageSize;

  // Incremented on every search start; stale completions are ignored when the
  // generation has advanced (prevents out-of-order IMAP responses from
  // overwriting fresh results with results for an older query).
  int _searchGeneration = 0;
  // The query whose results are currently settled in _searchResults.
  // Used to skip redundant re-runs when the user presses Enter on an
  // already-settled search (issue #473).
  String? _lastSettledQuery;

  @override
  void initState() {
    super.initState();
    _selection = EmailThreadListController()..addListener(_onSelectionChange);
    _searchController.addListener(() {
      if (_searchController.text.isEmpty) {
        setState(() {
          _searchResults = null;
          _searchLoading = false;
          _lastSettledQuery = null;
        });
      }
    });
  }

  @override
  void dispose() {
    _selection
      ..removeListener(_onSelectionChange)
      ..dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onSelectionChange() {
    if (mounted) setState(() {});
  }

  Future<void> _runSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      setState(() {
        _searchResults = null;
        _lastSettledQuery = null;
      });
      return;
    }
    // Skip if results are already settled for this exact query — prevents the
    // Enter key from re-triggering a search that already completed.
    if (_searchResults != null && !_searchLoading && q == _lastSettledQuery) {
      return;
    }
    final generation = ++_searchGeneration;
    setState(() => _searchLoading = true);
    try {
      final repo = ref.read(emailRepositoryProvider);
      final accountId = _scope.accountIdFor(widget.accountId);
      final mailboxPath = _scope.mailboxPathFor(widget.mailboxPath);
      final includeJunkTrash =
          _includeJunkTrash || _scope.alwaysIncludesJunkTrash;

      // `searchEmailsGlobal` matches subject/preview/From/body/notes via FTS;
      // `getEmailsByAddress` catches To/Cc recipients FTS does not index.
      // Merge + dedup into one message list, newest first.
      final (globalHits, addressHits) = await (
        repo.searchEmailsGlobal(
          accountId,
          q,
          mailboxPath: mailboxPath,
          includeJunkTrash: includeJunkTrash,
        ),
        repo.getEmailsByAddress(
          accountId,
          q,
          mailboxPath: mailboxPath,
          includeJunkTrash: includeJunkTrash,
        ),
      ).wait;

      final seen = <String>{};
      final merged = <Email>[];
      for (final e in [...globalHits, ...addressHits]) {
        if (seen.add(e.id)) merged.add(e);
      }
      merged.sort((a, b) => b.receivedAt.compareTo(a.receivedAt));

      if (mounted && generation == _searchGeneration) {
        setState(() {
          _searchResults = merged;
          _lastSettledQuery = q;
        });
      }
    } finally {
      if (mounted && generation == _searchGeneration) {
        setState(() => _searchLoading = false);
      }
    }
  }

  void _onSearchChanged(String value) {
    if (value.trim().isNotEmpty) unawaited(_runSearch(value.trim()));
  }

  void _onScopeChanged(SearchScope scope) {
    setState(() {
      _scope = scope;
      // Force a re-run even though the query text is unchanged.
      _lastSettledQuery = null;
    });
    final q = _searchController.text.trim();
    if (q.isNotEmpty) unawaited(_runSearch(q));
  }

  void _onIncludeJunkTrashChanged(bool value) {
    setState(() {
      _includeJunkTrash = value;
      _lastSettledQuery = null;
    });
    final q = _searchController.text.trim();
    if (q.isNotEmpty) unawaited(_runSearch(q));
  }

  /// Watches the cached mailbox for the current folder and, if it disappears
  /// after having been observed at least once (i.e. it was deleted on the
  /// server and pruned from the local DB), bounces the user back to the
  /// account's mailbox list with a one-shot snackbar.
  void _watchForMailboxDeletion() {
    final mailboxAsync = ref.watch(
      mailboxByPathProvider((widget.accountId, widget.mailboxPath)),
    );
    final mailbox = mailboxAsync.value;
    if (mailbox != null) {
      _mailboxSeen = true;
      return;
    }
    if (!_mailboxSeen || _gonePending || !mailboxAsync.hasValue) return;
    _gonePending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.showAppSnackBar(
        'Folder "${widget.mailboxPath}" was deleted on the server.',
      );
      context.go('/accounts/${widget.accountId}/mailboxes');
    });
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(emailRepositoryProvider);
    final accountAsync = ref.watch(accountByIdProvider(widget.accountId));
    final prefs =
        ref.watch(userPreferencesProvider).value ?? const UserPreferences();
    final menuAtBottom = prefs.menuPosition == MenuPosition.bottom;
    final selecting = _selection.isSelecting;

    _watchForMailboxDeletion();

    return Scaffold(
      appBar: _buildAppBar(repo, accountAsync, menuAtBottom: menuAtBottom),
      drawer: selecting
          ? null
          : AppDrawer(
              current: AppDrawerSelection.mailbox(
                widget.accountId,
                widget.mailboxPath,
              ),
            ),
      bottomNavigationBar: selecting
          ? buildSelectionBottomBar(
              context,
              ref,
              _selection,
              currentFolderRole: ref
                  .watch(
                    mailboxByPathProvider(
                      (widget.accountId, widget.mailboxPath),
                    ),
                  )
                  .value
                  ?.role,
              onAfterAction: _onAfterBatchAction,
            )
          : (menuAtBottom ? _folderNavBottomBar() : null),
      body: Column(
        children: [
          _buildSyncErrorBanner(),
          Expanded(
            child: (_searchResults != null || _searchLoading)
                ? _buildSearchBody()
                : _buildStreamBody(repo),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(
    EmailRepository emailRepo,
    AsyncValue<Account?> accountAsync, {
    required bool menuAtBottom,
  }) {
    if (_selection.isSelecting) {
      return buildDebugSelectionAppBar(context, _selection);
    }

    // For JMAP accounts the mailboxPath stores the opaque server id (e.g. "a"),
    // so resolve to the human-readable name when the mailbox is cached locally.
    final mailbox = ref
        .watch(mailboxByPathProvider((widget.accountId, widget.mailboxPath)))
        .value;
    final title = mailbox?.name ?? widget.mailboxPath;
    return AppBar(
      automaticallyImplyLeading: !menuAtBottom,
      title: Text(title),
      actions: [
        accountAsync.when(
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
          data: (account) => Padding(
            padding: const EdgeInsets.only(right: AppSpacing.xs),
            child: Center(
              child: Text(
                account?.displayName ?? '',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ),
        _buildSyncButton(emailRepo),
        IconButton(
          icon: const Icon(Icons.edit),
          tooltip: 'Compose',
          onPressed: () => context.push(
            '/compose',
            extra: {'accountId': widget.accountId},
          ),
        ),
        PopupMenuButton<String>(
          onSelected: (value) async {
            if (value == 'mark_all_read') {
              await emailRepo.markAllAsRead(
                widget.accountId,
                widget.mailboxPath,
              );
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 'mark_all_read',
              child: Text('Mark all as read'),
            ),
          ],
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(60),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.sm,
            0,
            AppSpacing.sm,
            AppSpacing.sm,
          ),
          child: SearchBar(
            controller: _searchController,
            hintText: 'Search…',
            leading: const Icon(Icons.search),
            trailing: [
              if (_searchController.text.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.clear),
                  tooltip: 'Clear search',
                  onPressed: () => _searchController.clear(),
                ),
            ],
            onChanged: _onSearchChanged,
            onSubmitted: (value) {
              // Only run the search if results haven't settled yet via
              // onChanged — prevents a second IMAP round-trip from reordering
              // the already-visible results when the user presses Enter.
              if (_searchResults == null && !_searchLoading) {
                unawaited(_runSearch(value));
              }
            },
            textInputAction: TextInputAction.search,
          ),
        ),
      ),
    );
  }

  Widget _buildSyncButton(EmailRepository emailRepo) {
    final isSyncing =
        ref.watch(isSyncingProvider(widget.accountId)).value ?? false;
    final hasError =
        ref.watch(syncLastErrorProvider(widget.accountId)).value != null;
    return IconButton(
      tooltip: isSyncing
          ? 'Syncing…'
          : hasError
              ? 'Sync error'
              : 'Sync',
      icon: isSyncing
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : hasError
              ? const Icon(Icons.sync_problem, color: Colors.red)
              : const Icon(Icons.sync),
      onPressed: isSyncing
          ? null
          : () async {
              try {
                // Trigger the full per-account sync cycle (flushPendingChanges,
                // flushOutbox, syncMailboxes, …) so a manual tap also drains
                // queued offline sends — not just refreshes the current folder.
                ref.read(syncManagerProvider).syncNow(widget.accountId);
                await emailRepo.syncEmails(
                  widget.accountId,
                  widget.mailboxPath,
                );
              } catch (e) {
                if (!mounted) return;
                context.showAppSnackBar(
                  'Sync failed: $e',
                  level: AppLogLevel.error,
                  error: e,
                  duration: const Duration(seconds: 5),
                );
              }
            },
    );
  }

  Widget _folderNavBottomBar() {
    return BottomAppBar(
      child: Row(
        children: [
          Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.menu),
              tooltip: 'Open folders',
              onPressed: () => Scaffold.of(context).openDrawer(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBody() {
    return Column(
      children: [
        _buildScopeBar(),
        Expanded(child: _buildSearchResults()),
      ],
    );
  }

  /// Scope chips shown above the search results: a mutually-exclusive selector
  /// (all accounts / this account / this folder) plus an independent
  /// "trash & junk" toggle that stacks on top of it.
  Widget _buildScopeBar() {
    const scopes = [
      SearchScope.all,
      SearchScope.currentAccount,
      SearchScope.currentFolder,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        0,
      ),
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.xs,
        children: [
          for (final scope in scopes)
            ChoiceChip(
              label: Text(scope.label),
              selected: _scope == scope,
              onSelected: (v) {
                if (v) _onScopeChanged(scope);
              },
            ),
          FilterChip(
            label: const Text('Trash & junk'),
            selected: _includeJunkTrash,
            onSelected: _onIncludeJunkTrashChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResults() {
    if (_searchLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searchResults == null) {
      return const Center(child: Text('Type a query and press Enter'));
    }
    if (_searchResults!.isEmpty) {
      return const Center(child: Text('No results'));
    }
    final results = _searchResults!;
    // Results can span accounts and folders, so surface where each hit lives
    // and let EmailThreadList's default navigation open it in the right place.
    final accounts = ref.watch(allAccountsProvider).value ?? const [];
    final accountNames = {
      for (final a in accounts) a.id: accountDisplayLabel(a, a.id),
    };
    return EmailThreadList(
      controller: _selection,
      items: results.map(EmailThread.fromEmail).toList(),
      enableSwipe: false,
      showLocationLabel: true,
      accountNames: accountNames,
    );
  }

  Widget _buildSyncErrorBanner() {
    final errorAsync = ref.watch(syncLastErrorProvider(widget.accountId));
    final error = errorAsync.value;
    if (error == null || error == _dismissedError) {
      return const SizedBox.shrink();
    }
    return MaterialBanner(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.sm,
        AppSpacing.sm,
      ),
      content: Text(error, maxLines: 2, overflow: TextOverflow.ellipsis),
      leading: Icon(
        Icons.sync_problem,
        color: Theme.of(context).colorScheme.error,
      ),
      backgroundColor: Theme.of(context).colorScheme.errorContainer,
      actions: [
        TextButton(
          onPressed: () {
            ref.read(syncManagerProvider).syncNow(widget.accountId);
          },
          child: const Text('Retry'),
        ),
        TextButton(
          onPressed: () =>
              context.push('/accounts/${widget.accountId}/sync-log'),
          child: const Text('View log'),
        ),
        TextButton(
          onPressed: () => setState(() => _dismissedError = error),
          child: const Text('Dismiss'),
        ),
      ],
    );
  }

  Widget _buildStreamBody(EmailRepository emailRepo) {
    return RefreshIndicator(
      onRefresh: () async {
        // Trigger a background sync cycle immediately.
        ref.read(syncManagerProvider).syncNow(widget.accountId);
        // Also wait for this specific mailbox to sync for immediate feedback.
        await emailRepo.syncEmails(widget.accountId, widget.mailboxPath);
      },
      child: EmailThreadList(
        controller: _selection,
        stream: emailRepo.observeThreads(
          widget.accountId,
          widget.mailboxPath,
          limit: _limit,
        ),
        enablePagination: true,
        onLoadMore: () => setState(() => _limit += _pageSize),
      ),
    );
  }

  void _onAfterBatchAction(List<String> actedThreadIds) {
    if (!_searching || !mounted) return;

    // Filter acted-on emails out of the local results immediately. Calling
    // searchEmails would still return them because the delete is only
    // enqueued — not yet applied to the local DB.
    final actedSet = actedThreadIds.toSet();
    final remaining = (_searchResults ?? [])
        .where((e) => !actedSet.contains(e.threadId ?? e.id))
        .toList();
    if (remaining.isEmpty) {
      if (context.canPop()) {
        context.pop();
        return;
      }
      _searchController.clear();
      return;
    }
    setState(() => _searchResults = remaining);
  }
}
