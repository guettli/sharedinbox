import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/utils/logger.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/utils/global_email_search.dart';
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
  bool _fieldFocused = false;

  /// Accounts the user has deactivated on the current result set. Purely a
  /// client-side view filter over [_results] — deactivating an account hides
  /// its mail immediately without re-running the search. Reset whenever a new
  /// result set arrives so a stale set never silently filters a later query.
  final Set<String> _hiddenAccountIds = {};

  /// Folder the current result set is focused on (null = no focus), keyed by
  /// [_folderKey]. Like [_hiddenAccountIds] this is a pure client-side view
  /// filter over [_results] — tapping a result's folder name and choosing
  /// "Only this folder" narrows the visible list without re-running the search
  /// (#844). Reset with the other view filters whenever a new result set
  /// arrives.
  String? _focusedFolderKey;

  /// Folders excluded from the current result set, keyed by [_folderKey]. Same
  /// client-side lifecycle as [_focusedFolderKey]; multiple exclusions
  /// accumulate (#844).
  final Set<String> _excludedFolderKeys = {};

  /// Stable per-folder key. NUL-joins `accountId` and `mailboxPath` so a common
  /// folder name (e.g. "INBOX") on two accounts stays distinct, and so
  /// excluding one account's folder never touches another's.
  String _folderKey(String accountId, String mailboxPath) =>
      '$accountId\u0000$mailboxPath';

  /// Clears every client-side view filter (hidden accounts, focused/excluded
  /// folders). Called wherever a fresh result set is about to replace the old
  /// one so a stale filter never silently narrows a later query.
  void _resetViewFilters() {
    _hiddenAccountIds.clear();
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

  void _onAfterBatchAction(List<String> actedThreadIds) {
    if (_results == null || !mounted) return;
    final actedSet = actedThreadIds.toSet();
    final remaining =
        _results!.where((e) => !actedSet.contains(e.threadId ?? e.id)).toList();
    setState(() => _results = remaining);
  }

  void _toggleAdvanced() {
    setState(() {
      _advancedMode = !_advancedMode;
      _results = null;
      _resetViewFilters();
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
      setState(() {
        _results = null;
        _resetViewFilters();
      });
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

  Future<void> _search(String query) async {
    setState(() => _loading = true);
    try {
      final merged = await searchEmailsGlobalMerged(
        ref.read(emailRepositoryProvider),
        _effectiveAccountId,
        query,
      );

      if (mounted) {
        setState(() {
          _results = merged;
          _resetViewFilters();
          _loading = false;
        });
      }
    } catch (e, stack) {
      log('Search failed: $e');
      unawaited(
        ref.read(appLoggerProvider).warn(
              'search.failed',
              'Global search failed',
              screen: 'SearchScreen',
              accountId: widget.accountId,
              error: e,
              stack: stack,
            ),
      );
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _searchStructured() async {
    if (_filterGroup.isEmpty) return;
    setState(() => _loading = true);
    try {
      final emails = await ref
          .read(emailRepositoryProvider)
          .searchEmailsStructured(_effectiveAccountId, _filterGroup);
      if (mounted) {
        setState(() {
          _results = emails;
          _resetViewFilters();
          _loading = false;
        });
      }
    } catch (e, stack) {
      log('Structured search failed: $e');
      unawaited(
        ref.read(appLoggerProvider).warn(
              'search.failed',
              'Structured search failed',
              screen: 'SearchScreen',
              accountId: widget.accountId,
              error: e,
              stack: stack,
            ),
      );
      if (mounted) setState(() => _loading = false);
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
                        _results = null;
                        _resetViewFilters();
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
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_advancedMode) return _buildAdvancedBody();
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_results == null) {
      if (_fieldFocused && _ctrl.text.isEmpty) {
        return _buildHistoryPanel();
      }
      return const Center(child: Text('Type 3+ characters to search'));
    }
    final r = _results!;
    if (r.isEmpty) return const Center(child: Text('No results'));
    return _buildResultsRegion(r);
  }

  /// Results after removing mail from deactivated accounts (see
  /// [_hiddenAccountIds]) and applying the folder focus/exclusion (#844).
  List<Email> get _visibleResults => _results!.where((e) {
        if (_hiddenAccountIds.contains(e.accountId)) return false;
        final key = _folderKey(e.accountId, e.mailboxPath);
        if (_excludedFolderKeys.contains(key)) return false;
        if (_focusedFolderKey != null && key != _focusedFolderKey) return false;
        return true;
      }).toList();

  /// The account and folder filter bars stacked above the message list.
  /// Deactivating an account or focusing/excluding a folder is a pure
  /// [setState] view filter, so the list below rebuilds immediately with no
  /// re-query.
  Widget _buildResultsRegion(List<Email> results) {
    final visible = _visibleResults;
    final folderFiltered =
        _focusedFolderKey != null || _excludedFolderKeys.isNotEmpty;
    return Column(
      children: [
        _buildAccountBar(results),
        _buildFolderFilterBar(),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Text(
                    folderFiltered
                        ? 'No mail matches the folder filter'
                        : 'No accounts selected — tap an account to '
                            'show its mail',
                  ),
                )
              : _buildResultsList(visible),
        ),
      ],
    );
  }

  /// Handles a tap on a result row's folder name: asks whether to focus on or
  /// exclude that folder, then applies the choice as a client-side view filter
  /// over the current results (#844). Focusing the already-focused folder
  /// clears the focus (toggle); excluding a folder drops it from any active
  /// focus, and vice versa, so the two never contradict each other.
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
    final sep = key.indexOf('\u0000');
    final accountId = key.substring(0, sep);
    final path = key.substring(sep + 1);
    final name = ref
            .watch(mailboxByPathProvider((accountId, path)))
            .value
            ?.displayPath ??
        path;
    return InputChip(
      label: Text(focus ? 'Only: $name' : 'Excluding: $name'),
      onDeleted: () => setState(() {
        if (focus) {
          _focusedFolderKey = null;
        } else {
          _excludedFolderKeys.remove(key);
        }
      }),
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
      // Deactivated chips stay put and re-include the account when tapped, so
      // hiding is always reversible without re-running the search.
      onPressed: hidden
          ? () => setState(() => _hiddenAccountIds.remove(accountId))
          : null,
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
              _results = null;
              _resetViewFilters();
            }),
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            onPressed: _filterGroup.isEmpty ? null : _searchStructured,
            icon: const Icon(Icons.search),
            label: const Text('Search'),
          ),
        ],
      ),
    );

    if (!_loading && _results != null && _results!.isNotEmpty) {
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
