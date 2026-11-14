import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/utils/logger.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/utils/global_email_search.dart';
import 'package:sharedinbox/ui/widgets/accessible_dropdown.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:sharedinbox/ui/widgets/email_thread_list.dart';
import 'package:sharedinbox/ui/widgets/filter_builder.dart';
import 'package:sharedinbox/ui/widgets/folder_scope_dialog.dart';

final _searchHistoryProvider = FutureProvider.autoDispose<List<String>>((
  ref,
) async {
  return ref.watch(searchHistoryRepositoryProvider).getRecentSearches();
});

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({
    super.key,
    this.accountId,
    this.initialFilter,
    this.initialQuery,
  });
  final String? accountId;

  /// When non-null, the screen opens in advanced mode with this filter
  /// pre-loaded and runs the structured search immediately. Used by the
  /// "Find similar emails" action.
  final FilterGroup? initialFilter;

  /// When non-empty (and [initialFilter] is not given), the screen opens in
  /// advanced mode seeded with a single `subject contains <query>` condition
  /// and runs the structured search immediately. Lets the folder search bar
  /// hand its typed text off to advanced search as a starting point the user
  /// can refine.
  final String? initialQuery;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _ctrl = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;
  List<Email>? _results;
  bool _loading = false;

  /// True when the last search threw, so the body says so instead of falling
  /// back to the "Type 3+ characters" hint or keeping an older result list.
  bool _failed = false;

  /// Bumped by every search and every reset. A search whose number is no
  /// longer current when it completes is dropped, so a slow older query can
  /// neither replace newer results nor report a failure nobody waits for.
  int _searchSeq = 0;
  bool _fieldFocused = false;

  /// How many results the active search should show, and the query that
  /// produced [_results] (called again with a larger limit by "Load more").
  /// A new search starts back at one page.
  int _limit = searchPageSize;

  /// How many rows the last fetch asked [_activeFetch] for. At least [_limit];
  /// more when a folder filter hides fetched rows and further pages were
  /// loaded automatically to fill the list (see [_fetchPage]).
  int _fetchLimit = searchPageSize;

  /// Upper bound on the pages one fill loads automatically beyond the first,
  /// so a folder that matches almost nothing cannot pull the whole result set
  /// in one go. Past it, "Load more" takes over.
  static const _maxAutoFillPages = 10;
  Future<List<Email>> Function(int limit)? _activeFetch;
  bool _loadingMore = false;

  /// Whether the last fetch filled its page (more matches may exist). Kept
  /// from the fetch result, not the live [_results] length, so rows a batch
  /// action removes locally do not hide "Load more".
  bool _lastPageFull = false;

  /// Mail the user acted on from this result set, keyed by [_mailKey], with
  /// the folder it was in. After a batch action the active search re-runs so
  /// the list refills with the next matches. Mail that still matches after
  /// being moved out of that folder (e.g. deleted into Trash, which a search
  /// without a folder focus also covers) is kept out of the refreshed list.
  /// Mail still in its folder (starred, or a delete that was undone) shows
  /// again. Cleared by every new search.
  final Map<String, String> _dismissedMail = {};

  /// Identity of a mail that survives a move. The local id embeds the folder
  /// and the IMAP UID, both of which change when a move syncs, so the
  /// Message-ID is used when there is one.
  String _mailKey(Email e) => '${e.accountId}\u0000${e.messageId ?? e.id}';

  /// Whether [e] was acted on and has since left the folder it was in.
  bool _isDismissed(Email e) {
    final from = _dismissedMail[_mailKey(e)];
    return from != null && from != e.mailboxPath;
  }

  /// Accounts the user has deactivated on the current result set. Purely a
  /// client-side view filter over [_results] — deactivating an account hides
  /// its mail immediately without re-running the search. Reset whenever a new
  /// result set arrives so a stale set never silently filters a later query.
  final Set<String> _hiddenAccountIds = {};

  /// Folder the search is focused on (null = no focus), keyed by
  /// [_folderKey]. Set by tapping a result's folder name and choosing "Only
  /// this folder" (#844). Unlike [_hiddenAccountIds] it survives re-running
  /// the search (pressing Search again, the refresh after a batch action):
  /// it stays until the user clears its chip, clears the search or switches
  /// between simple and advanced mode. Advanced search adds it to the query
  /// itself, so each page is drawn from that folder only; simple search
  /// applies it as a view filter over [_results] and loads further pages
  /// automatically when it hides too many rows (see [_fetchPage]).
  String? _focusedFolderKey;

  /// Folders excluded from the results, keyed by [_folderKey]. A view filter
  /// over [_results] with the same lifetime as [_focusedFolderKey]; multiple
  /// exclusions accumulate (#844).
  final Set<String> _excludedFolderKeys = {};

  bool get _folderFiltered =>
      _focusedFolderKey != null || _excludedFolderKeys.isNotEmpty;

  /// Stable per-folder key. NUL-joins `accountId` and `mailboxPath` so a common
  /// folder name (e.g. "INBOX") on two accounts stays distinct, and so
  /// excluding one account's folder never touches another's.
  String _folderKey(String accountId, String mailboxPath) =>
      '$accountId\u0000$mailboxPath';

  /// Splits a [_folderKey] back into its account id and mailbox path.
  (String, String) _splitFolderKey(String key) {
    final sep = key.indexOf('\u0000');
    return (key.substring(0, sep), key.substring(sep + 1));
  }

  /// Clears the hidden accounts. Called wherever a fresh result set is about
  /// to replace the old one: the account bar is built from the results, so a
  /// stale hidden account could otherwise filter a later query with no chip
  /// to undo it. The folder filters always show their chips, so they persist.
  void _resetViewFilters() {
    _hiddenAccountIds.clear();
  }

  /// Drops the folder focus and exclusions. Only call inside [setState].
  void _clearFolderFilters() {
    _focusedFolderKey = null;
    _excludedFolderKeys.clear();
  }

  /// Account a global search is scoped to (null = all accounts). Only used
  /// when [SearchScreen.accountId] is null; a per-account search screen always
  /// searches its own account. Unlike [_hiddenAccountIds] this re-scopes the
  /// query itself, so the search runs against a single account in the DB.
  String? _selectedAccountId;

  /// The account every query in this screen should run against: the fixed
  /// per-account scope when present, otherwise the user-picked global scope.
  String? get _effectiveAccountId => widget.accountId ?? _selectedAccountId;

  // Advanced (structured) search state.
  bool _advancedMode = false;
  FilterGroup _filterGroup = FilterGroup.empty();

  late final EmailThreadListController _selection;

  @override
  void initState() {
    super.initState();
    _selection = EmailThreadListController()..addListener(_onSelectionChange);
    _focusNode.addListener(() {
      if (mounted) setState(() => _fieldFocused = _focusNode.hasFocus);
    });
    final seed = _seedFilter();
    if (seed != null) {
      _advancedMode = true;
      _filterGroup = seed;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_searchStructured());
      });
    }
  }

  /// The filter advanced mode should open pre-loaded with, or null to start in
  /// simple search. [SearchScreen.initialFilter] wins when both are supplied;
  /// otherwise a non-empty [SearchScreen.initialQuery] becomes a single
  /// `subject contains <query>` condition.
  FilterGroup? _seedFilter() {
    final filter = widget.initialFilter;
    if (filter != null && !filter.isEmpty) return filter;
    final query = widget.initialQuery?.trim() ?? '';
    if (query.isEmpty) return null;
    return FilterGroup(
      operator: FilterOperator.and_,
      children: [
        FilterLeaf(
          field: FilterField.subject,
          comparison: FilterComparison.contains,
          value: query,
        ),
      ],
    );
  }

  @override
  void dispose() {
    _selection
      ..removeListener(_onSelectionChange)
      ..dispose();
    _ctrl.dispose();
    _focusNode.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onSelectionChange() {
    if (mounted) setState(() {});
  }

  /// Drops the acted-on mail from the list right away, then re-runs the
  /// active search so the list refills with the next matching mail.
  void _onAfterBatchAction(List<String> actedThreadIds) {
    if (_results == null || !mounted) return;
    final actedSet = actedThreadIds.toSet();
    final remaining = <Email>[];
    for (final e in _results!) {
      if (actedSet.contains(e.threadId ?? e.id)) {
        _dismissedMail[_mailKey(e)] = e.mailboxPath;
        continue;
      }
      remaining.add(e);
    }
    setState(() => _results = remaining);
    unawaited(_refresh());
  }

  void _toggleAdvanced() {
    setState(() {
      _advancedMode = !_advancedMode;
      _clearResults();
      _clearFolderFilters();
    });
  }

  /// Re-scope a global search to a single account (or back to all accounts).
  /// Re-runs whatever search is currently active so results reflect the new
  /// scope immediately, mirroring how toggling advanced mode re-queries.
  void _onAccountScopeChanged(String? accountId) {
    if (accountId == _selectedAccountId) return;
    setState(() => _selectedAccountId = accountId);
    if (_advancedMode) {
      if (!_filterGroup.isEmpty) unawaited(_searchStructured());
    } else {
      final query = _ctrl.text.trim();
      if (query.length >= 3) unawaited(_search(query));
    }
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.trim().length < 3) {
      setState(_clearResults);
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => _search(value.trim()),
    );
  }

  /// Persist a term to the recent-search history. Called only on an explicit
  /// commit (submitting the field or tapping a recent-search chip), never from
  /// the live-results debounce — otherwise a partial term the user typed on the
  /// way to their real query ("foob" → "foobar") would land in the history.
  void _commitToHistory(String query) {
    final trimmed = query.trim();
    if (trimmed.length < 3) return;
    unawaited(
      ref
          .read(searchHistoryRepositoryProvider)
          .saveSearch(trimmed)
          .then((_) => ref.invalidate(_searchHistoryProvider)),
    );
  }

  void _onSubmitted(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.length < 3) return;
    _commitToHistory(query);
    unawaited(_search(query));
  }

  Future<void> _search(String query) => _runSearch(
        fetch: (limit) => searchEmailsGlobalMerged(
          ref.read(emailRepositoryProvider),
          _effectiveAccountId,
          query,
          limit: limit,
        ),
        logLabel: 'Search failed',
        warnMessage: 'Global search failed',
      );

  Future<void> _searchStructured() async {
    if (_filterGroup.isEmpty || _filterGroup.hasInvalidCondition) return;
    final accountId = _effectiveAccountId;
    final filter = _filterGroup;
    await _runSearch(
      fetch: (limit) => _fetchStructured(accountId, filter, limit),
      logLabel: 'Structured search failed',
      warnMessage: 'Structured search failed',
    );
  }

  /// Runs the structured search, narrowed to the focused folder when there
  /// is one. The focus is read on every call, so changing it and re-running
  /// the active fetch (see [_onFolderTap]) re-queries that folder. Adding it
  /// to the query, rather than filtering the fetched page, keeps every page
  /// full of mail from that folder.
  Future<List<Email>> _fetchStructured(
    String? accountId,
    FilterGroup filter,
    int limit,
  ) async {
    final repo = ref.read(emailRepositoryProvider);
    final focus = _focusedFolderKey;
    if (focus == null) {
      return repo.searchEmailsStructured(accountId, filter, limit: limit);
    }
    final (focusAccountId, mailboxPath) = _splitFolderKey(focus);
    // The search is scoped to another account than the focused folder's.
    if (accountId != null && accountId != focusAccountId) return const [];
    return repo.searchEmailsStructured(
      focusAccountId,
      FilterGroup(
        operator: FilterOperator.and_,
        children: [
          filter,
          FilterLeaf(
            field: FilterField.folder,
            comparison: FilterComparison.is_,
            value: mailboxPath,
          ),
        ],
      ),
      limit: limit,
    );
  }

  /// Fetches with [fetch] until [target] rows pass the folder filters,
  /// leaving out dismissed mail (see [_dismissedMail]). Starts at
  /// [fetchLimit] rows (at least [target]) and, while the folder
  /// focus/exclusions hide too many of them and more matches exist, loads
  /// further pages automatically, up to [_maxAutoFillPages]. Each request
  /// asks for as many extra rows as there is dismissed mail, so that does not
  /// shorten the page either. Returns the rows, whether the last fetch filled
  /// its page, and the limit it used.
  Future<(List<Email>, bool, int)> _fetchPage(
    Future<List<Email>> Function(int limit) fetch,
    int target, {
    int? fetchLimit,
  }) async {
    final dismissedCount = _dismissedMail.length;
    var limit = fetchLimit == null || fetchLimit < target ? target : fetchLimit;
    // A focus on a folder outside the account scope can never be filled.
    final maxRounds = _focusOutsideScope ? 0 : _maxAutoFillPages;
    for (var round = 0;; round++) {
      final want = limit + dismissedCount;
      final rows = await fetch(want);
      final kept = rows.where((e) => !_isDismissed(e)).toList();
      final full = rows.length >= want;
      if (!full ||
          round >= maxRounds ||
          kept.where(_passesFolderFilters).length >= target) {
        return (kept, full, limit);
      }
      limit += searchPageSize;
    }
  }

  /// Whether the focused folder belongs to an account the search does not
  /// cover, so no result can pass the focus.
  bool get _focusOutsideScope {
    final focus = _focusedFolderKey;
    final scope = _effectiveAccountId;
    if (focus == null || scope == null) return false;
    return _splitFolderKey(focus).$1 != scope;
  }

  /// Whether [e] survives the folder focus and exclusions.
  bool _passesFolderFilters(Email e) {
    final key = _folderKey(e.accountId, e.mailboxPath);
    if (_excludedFolderKeys.contains(key)) return false;
    return _focusedFolderKey == null || key == _focusedFolderKey;
  }

  /// Runs [fetch] for the first page, shows its results, and marks the screen
  /// failed on error. Results or failures from a search superseded by a newer
  /// one are dropped.
  Future<void> _runSearch({
    required Future<List<Email>> Function(int limit) fetch,
    required String logLabel,
    required String warnMessage,
  }) async {
    final seq = ++_searchSeq;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _failed = false;
      _limit = searchPageSize;
      _activeFetch = fetch;
      _dismissedMail.clear();
    });
    try {
      final (emails, full, fetchLimit) = await _fetchPage(fetch, _limit);
      if (mounted && seq == _searchSeq) {
        setState(() {
          _results = emails;
          _lastPageFull = full;
          _fetchLimit = fetchLimit;
          _resetViewFilters();
          _loading = false;
        });
      }
    } catch (e, stack) {
      log('$logLabel: $e');
      unawaited(
        ref.read(appLoggerProvider).warn(
              'search.failed',
              warnMessage,
              screen: 'SearchScreen',
              accountId: widget.accountId,
              error: e,
              stack: stack,
            ),
      );
      if (mounted && seq == _searchSeq) setState(_markFailed);
    }
  }

  /// A full page means more matches may exist (same rule as the folder list).
  /// Judged on the fetched [_results], not the client-side filtered view.
  bool get _hasMore => _activeFetch != null && !_loadingMore && _lastPageFull;

  /// "Load more": re-runs the active search with one more page. The current
  /// results and view filters stay on screen meanwhile; a newer search or a
  /// reset supersedes it.
  Future<void> _loadMore() async {
    final fetch = _activeFetch;
    if (fetch == null || _loading || _loadingMore) return;
    final seq = ++_searchSeq;
    setState(() {
      _loadingMore = true;
      _limit += searchPageSize;
    });
    try {
      final (emails, full, fetchLimit) = await _fetchPage(
        fetch,
        _limit,
        fetchLimit: _fetchLimit + searchPageSize,
      );
      if (mounted && seq == _searchSeq) {
        setState(() {
          _results = emails;
          _lastPageFull = full;
          _fetchLimit = fetchLimit;
          _loadingMore = false;
        });
      }
    } catch (e, stack) {
      log('Load more failed: $e');
      unawaited(
        ref.read(appLoggerProvider).warn(
              'search.failed',
              'Loading more search results failed',
              screen: 'SearchScreen',
              accountId: widget.accountId,
              error: e,
              stack: stack,
            ),
      );
      // Keep the results already shown; the button comes back for a retry.
      if (mounted && seq == _searchSeq) {
        setState(() {
          _loadingMore = false;
          _limit -= searchPageSize;
        });
        context.showAppSnackBar('Could not load more results.');
      }
    }
  }

  /// Re-runs the active search in place: after a batch action (keeping the
  /// pages already loaded, so the list refills with the next matches), after
  /// a folder filter hid rows (auto-loading the next matches) or after the
  /// folder focus changed in advanced mode ([resetLimit], since that is a
  /// different query). The current results stay on screen until the new ones
  /// arrive; a newer search or a reset supersedes it.
  Future<void> _refresh({bool resetLimit = false}) async {
    final fetch = _activeFetch;
    if (fetch == null || _loading) return;
    final seq = ++_searchSeq;
    setState(() => _loadingMore = false);
    // A reset applies only once its results arrive: a failed re-query keeps
    // the list on screen together with the limits that produced it.
    final target = resetLimit ? searchPageSize : _limit;
    try {
      final (emails, full, fetchLimit) = await _fetchPage(
        fetch,
        target,
        fetchLimit: resetLimit ? searchPageSize : _fetchLimit,
      );
      if (mounted && seq == _searchSeq) {
        setState(() {
          _results = emails;
          _lastPageFull = full;
          _limit = target;
          _fetchLimit = fetchLimit;
        });
      }
    } catch (e, stack) {
      log('Refreshing search results failed: $e');
      unawaited(
        ref.read(appLoggerProvider).warn(
              'search.failed',
              'Refreshing search results failed',
              screen: 'SearchScreen',
              accountId: widget.accountId,
              error: e,
              stack: stack,
            ),
      );
      if (mounted && seq == _searchSeq) {
        context.showAppSnackBar('Could not refresh the search results.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final selecting = _selection.isSelecting;
    return Scaffold(
      appBar: selecting
          ? buildDebugSelectionAppBar(context, _selection)
          : AppBar(
              title: _advancedMode
                  ? const Text('Advanced Search')
                  : TextField(
                      controller: _ctrl,
                      focusNode: _focusNode,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: 'Search emails…',
                        border: InputBorder.none,
                      ),
                      textInputAction: TextInputAction.search,
                      onChanged: _onChanged,
                      onSubmitted: _onSubmitted,
                    ),
              actions: [
                if (!_advancedMode && _ctrl.text.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: 'Clear search',
                    onPressed: () {
                      _ctrl.clear();
                      setState(() {
                        _clearResults();
                        _clearFolderFilters();
                      });
                    },
                  ),
                IconButton(
                  icon: Icon(
                    _advancedMode ? Icons.search : Icons.tune,
                    color: _advancedMode
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  tooltip: _advancedMode ? 'Simple search' : 'Advanced search',
                  onPressed: _toggleAdvanced,
                ),
              ],
            ),
      bottomNavigationBar: selecting
          ? buildSelectionBottomBar(
              context,
              ref,
              _selection,
              onAfterAction: _onAfterBatchAction,
            )
          : null,
      body: Column(
        children: [
          _buildAccountScopeSelector(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  /// Dropdown that scopes a global search to a single account. Shown only for
  /// global search ([SearchScreen.accountId] == null) when the user has two or
  /// more accounts; a single-account user has nothing to choose between, and a
  /// per-account search screen is already locked to its account. Applies to
  /// both simple and advanced search.
  Widget _buildAccountScopeSelector() {
    if (widget.accountId != null) return const SizedBox.shrink();
    final accounts = ref.watch(allAccountsProvider).value ?? const [];
    if (accounts.length < 2) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        0,
      ),
      child: Row(
        children: [
          const Icon(Icons.filter_list, size: 20),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            // Reports its enabled state to screen readers (#1179).
            child: AccessibleDropdown(
              child: DropdownButton<String?>(
                isExpanded: true,
                value: _selectedAccountId,
                items: [
                  const DropdownMenuItem<String?>(
                    child: Text('All accounts'),
                  ),
                  for (final a in accounts)
                    DropdownMenuItem<String?>(
                      value: a.id,
                      child: Text(accountDisplayLabel(a, a.id)),
                    ),
                ],
                onChanged: _onAccountScopeChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Drops the current results, any failure and any search still running.
  /// Only call inside [setState].
  void _clearResults() {
    _searchSeq++;
    _loading = false;
    _loadingMore = false;
    _activeFetch = null;
    _results = null;
    _failed = false;
    _resetViewFilters();
  }

  /// Only call inside [setState].
  void _markFailed() {
    _loading = false;
    _loadingMore = false;
    _activeFetch = null;
    _results = null;
    _resetViewFilters();
    _failed = true;
  }

  /// What the body shows after a failed search, with a way to the log entry.
  Widget _buildFailure() {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Search failed.'),
          TextButton(
            onPressed: () => unawaited(context.push('/accounts/app-log')),
            child: const Text('View in application log'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_advancedMode) return _buildAdvancedBody();
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_failed) return Center(child: _buildFailure());
    if (_results == null) {
      if (_fieldFocused && _ctrl.text.isEmpty) {
        return _buildHistoryPanel();
      }
      return const Center(child: Text('Type 3+ characters to search'));
    }
    final r = _results!;
    // With a folder filter the region still renders, so its chip can clear it.
    if (r.isEmpty && !_folderFiltered) {
      return const Center(child: Text('No results'));
    }
    return _buildResultsRegion(r);
  }

  /// Results after removing mail from deactivated accounts (see
  /// [_hiddenAccountIds]) and applying the folder focus/exclusion (#844).
  List<Email> get _visibleResults => _results!
      .where(
        (e) =>
            !_hiddenAccountIds.contains(e.accountId) && _passesFolderFilters(e),
      )
      .toList();

  /// The account and folder filter bars stacked above the message list.
  /// Deactivating an account or focusing/excluding a folder is a pure
  /// [setState] view filter, so the list below rebuilds immediately with no
  /// re-query.
  Widget _buildResultsRegion(List<Email> results) {
    final visible = _visibleResults;
    final folderFiltered = _folderFiltered;
    return Column(
      children: [
        _buildAccountBar(results),
        _buildFolderFilterBar(),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        folderFiltered
                            ? 'No mail matches the folder filter'
                            : 'No accounts selected — tap an account to '
                                'show its mail',
                      ),
                      // The filter hides every fetched row, but later pages
                      // may still hold matching mail.
                      if (_hasMore)
                        TextButton(
                          onPressed: () => unawaited(_loadMore()),
                          child: const Text('Load more'),
                        ),
                    ],
                  ),
                )
              : _buildResultsList(visible),
        ),
      ],
    );
  }

  /// Handles a tap on a result row's folder name: asks whether to focus on or
  /// exclude that folder, then applies the choice (#844). Focusing the
  /// already-focused folder clears the focus (toggle); excluding a folder
  /// drops it from any active focus, and vice versa, so the two never
  /// contradict each other. A focus change re-queries in advanced mode (see
  /// [_fetchStructured]); everything else is a view filter over [_results].
  Future<void> _onFolderTap(String accountId, String mailboxPath) async {
    final folderName = ref
            .read(mailboxByPathProvider((accountId, mailboxPath)))
            .value
            ?.displayPath ??
        mailboxPath;
    final choice = await showFolderScopeDialog(
      context,
      folderDisplayName: folderName,
    );
    if (choice == null || !mounted) return;
    final key = _folderKey(accountId, mailboxPath);
    final focusBefore = _focusedFolderKey;
    setState(() {
      switch (choice) {
        case FolderScopeChoice.focus:
          _focusedFolderKey = _focusedFolderKey == key ? null : key;
          _excludedFolderKeys.remove(key);
        case FolderScopeChoice.exclude:
          _excludedFolderKeys.add(key);
          if (_focusedFolderKey == key) _focusedFolderKey = null;
      }
    });
    _afterFolderFilterChange(focusBefore);
  }

  /// Keeps the list full after the folder filters changed. In advanced mode
  /// the folder focus is part of the query, so a changed focus re-runs it
  /// from the first page. Otherwise the filters only hide fetched rows, so
  /// when they hide too many and more matches exist, the next pages load
  /// automatically.
  void _afterFolderFilterChange(String? focusBefore) {
    if (_advancedMode && _focusedFolderKey != focusBefore) {
      unawaited(_refresh(resetLimit: true));
      return;
    }
    final results = _results;
    if (results == null || !_lastPageFull) return;
    if (results.where(_passesFolderFilters).length >= _limit) return;
    unawaited(_refresh());
  }

  /// The bar of chips describing the active folder focus/exclusions, each
  /// clearable via its delete icon. An empty box when no folder filter is
  /// active. Mirrors [_buildAccountChip]'s idiom (#844).
  Widget _buildFolderFilterBar() {
    final chips = <Widget>[
      if (_focusedFolderKey != null)
        _buildFolderChip(_focusedFolderKey!, focus: true),
      for (final key in _excludedFolderKeys)
        _buildFolderChip(key, focus: false),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return _buildChipBar(chips);
  }

  /// Wraps a list of filter chips in the padding/spacing shared by the account
  /// and folder filter bars.
  Widget _buildChipBar(List<Widget> chips) {
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
        children: chips,
      ),
    );
  }

  Widget _buildFolderChip(String key, {required bool focus}) {
    final (accountId, path) = _splitFolderKey(key);
    final name = ref
            .watch(mailboxByPathProvider((accountId, path)))
            .value
            ?.displayPath ??
        path;
    return InputChip(
      label: Text(focus ? 'Only: $name' : 'Excluding: $name'),
      onDeleted: () {
        final focusBefore = _focusedFolderKey;
        setState(() {
          if (focus) {
            _focusedFolderKey = null;
            return;
          }
          _excludedFolderKeys.remove(key);
        });
        _afterFolderFilterChange(focusBefore);
      },
      deleteIcon: const Icon(Icons.close, size: 18),
      deleteButtonTooltipMessage: 'Clear folder filter',
    );
  }

  Widget _buildAccountBar(List<Email> results) {
    // Distinct account ids in first-seen (received) order.
    final ids = <String>[];
    final seen = <String>{};
    for (final e in results) {
      if (seen.add(e.accountId)) ids.add(e.accountId);
    }
    // A single-account result set needs no filter.
    if (ids.length < 2) return const SizedBox.shrink();

    final accounts = ref.watch(allAccountsProvider).value ?? const [];
    final accountsById = {for (final a in accounts) a.id: a};
    return _buildChipBar([
      for (final id in ids)
        _buildAccountChip(id, accountDisplayLabel(accountsById[id], id)),
    ]);
  }

  Widget _buildAccountChip(String accountId, String label) {
    final hidden = _hiddenAccountIds.contains(accountId);
    return InputChip(
      label: Text(
        label,
        style: hidden
            ? TextStyle(
                decoration: TextDecoration.lineThrough,
                color: Theme.of(context).disabledColor,
              )
            : null,
      ),
      selected: !hidden,
      showCheckmark: false,
      // Tapping the chip toggles the account, so the chip itself is an enabled,
      // actionable button for keyboard and screen-reader users (not just the
      // small X). Deactivated chips stay put, so hiding is always reversible
      // without re-running the search.
      onPressed: () => setState(() {
        if (!_hiddenAccountIds.remove(accountId)) {
          _hiddenAccountIds.add(accountId);
        }
      }),
      onDeleted: hidden
          ? null
          : () => setState(() => _hiddenAccountIds.add(accountId)),
      deleteIcon: const Icon(Icons.close, size: 18),
      deleteButtonTooltipMessage: 'Hide $label',
    );
  }

  Widget _buildAdvancedBody() {
    final filterHeader = Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilterBuilderWidget(
            initialValue: _filterGroup,
            accountId: _effectiveAccountId,
            onChanged: (g) => setState(() {
              _filterGroup = g;
              _clearResults();
            }),
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            onPressed: _filterGroup.isEmpty || _filterGroup.hasInvalidCondition
                ? null
                : _searchStructured,
            icon: const Icon(Icons.search),
            label: const Text('Search'),
          ),
        ],
      ),
    );

    if (!_loading &&
        _results != null &&
        (_results!.isNotEmpty || _folderFiltered)) {
      return Column(
        children: [
          filterHeader,
          Expanded(child: _buildResultsRegion(_results!)),
        ],
      );
    }

    Widget resultsRegion;
    if (_loading) {
      resultsRegion = const Padding(
        padding: EdgeInsets.only(top: AppSpacing.xl),
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (_failed) {
      resultsRegion = Center(child: _buildFailure());
    } else if (_results == null) {
      resultsRegion = const SizedBox.shrink();
    } else {
      resultsRegion = const Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Center(child: Text('No results')),
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [filterHeader, resultsRegion],
      ),
    );
  }

  Widget _buildResultsList(List<Email> emails) {
    final accounts = ref.watch(allAccountsProvider).value ?? const [];
    final accountNames = {
      for (final a in accounts) a.id: accountDisplayLabel(a, a.id),
    };
    return EmailThreadList(
      controller: _selection,
      items: emails.map(EmailThread.fromEmail).toList(),
      enableSwipe: false,
      showLocationLabel: true,
      accountNames: accountNames,
      onFolderTap: _onFolderTap,
      hasMore: _hasMore,
      onLoadMore: () => unawaited(_loadMore()),
    );
  }

  Widget _buildHistoryPanel() {
    final history = ref.watch(_searchHistoryProvider);
    return history.when(
      loading: () => const Center(child: Text('Type 3+ characters to search')),
      error: (_, __) =>
          const Center(child: Text('Type 3+ characters to search')),
      data: (terms) {
        if (terms.isEmpty) {
          return const Center(child: Text('Type 3+ characters to search'));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                AppSpacing.xs,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Recent searches',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  TextButton(
                    onPressed: () async {
                      await ref
                          .read(searchHistoryRepositoryProvider)
                          .clearHistory();
                      ref.invalidate(_searchHistoryProvider);
                    },
                    child: const Text('Clear'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final term in terms)
                    InputChip(
                      label: Text(term),
                      onPressed: () {
                        _ctrl.text = term;
                        _ctrl.selection = TextSelection.fromPosition(
                          TextPosition(offset: term.length),
                        );
                        // Re-running a past search is an explicit commit, so
                        // bump it back to the top of the history.
                        _commitToHistory(term);
                        unawaited(_search(term));
                      },
                      onDeleted: () async {
                        await ref
                            .read(searchHistoryRepositoryProvider)
                            .deleteSearch(term);
                        ref.invalidate(_searchHistoryProvider);
                      },
                      deleteIcon: const Icon(Icons.close, size: 18),
                      deleteButtonTooltipMessage: 'Remove from history',
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
