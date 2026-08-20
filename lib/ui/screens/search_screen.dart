import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/utils/logger.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/email_thread_list.dart';
import 'package:sharedinbox/ui/widgets/filter_builder.dart';

final _searchHistoryProvider = FutureProvider.autoDispose<List<String>>((
  ref,
) async {
  return ref.watch(searchHistoryRepositoryProvider).getRecentSearches();
});

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, this.accountId, this.initialFilter});
  final String? accountId;

  /// When non-null, the screen opens in advanced mode with this filter
  /// pre-loaded and runs the structured search immediately. Used by the
  /// "Find similar emails" action.
  final FilterGroup? initialFilter;

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
    if (widget.initialFilter != null && !widget.initialFilter!.isEmpty) {
      _advancedMode = true;
      _filterGroup = widget.initialFilter!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_searchStructured());
      });
    }
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
      _hiddenAccountIds.clear();
    });
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.trim().length < 3) {
      setState(() {
        _results = null;
        _hiddenAccountIds.clear();
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
      final emailRepo = ref.read(emailRepositoryProvider);

      // Run both queries in parallel. `searchEmailsGlobal` matches subject,
      // preview and From via FTS; `getEmailsByAddress` catches recipients
      // (To/Cc) that FTS does not index. Merge + dedup so a single message
      // list surfaces every match.
      final (globalHits, addressHits) = await (
        emailRepo.searchEmailsGlobal(widget.accountId, query),
        emailRepo.getEmailsByAddress(widget.accountId, query),
      ).wait;

      final seen = <String>{};
      final merged = <Email>[];
      for (final e in [...globalHits, ...addressHits]) {
        if (seen.add(e.id)) merged.add(e);
      }
      merged.sort((a, b) => b.receivedAt.compareTo(a.receivedAt));

      if (mounted) {
        setState(() {
          _results = merged;
          _hiddenAccountIds.clear();
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
          .searchEmailsStructured(widget.accountId, _filterGroup);
      if (mounted) {
        setState(() {
          _results = emails;
          _hiddenAccountIds.clear();
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
                        _hiddenAccountIds.clear();
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
      body: _buildBody(),
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
  /// [_hiddenAccountIds]).
  List<Email> get _visibleResults =>
      _results!.where((e) => !_hiddenAccountIds.contains(e.accountId)).toList();

  /// The account filter bar stacked above the message list. Only meaningful
  /// when a result set spans two or more accounts, so an empty box is returned
  /// otherwise. Deactivating an account is a pure [setState] view filter, so
  /// the list below rebuilds immediately with no re-query.
  Widget _buildResultsRegion(List<Email> results) {
    final visible = _visibleResults;
    return Column(
      children: [
        _buildAccountBar(results),
        Expanded(
          child: visible.isEmpty
              ? const Center(
                  child: Text('No accounts selected — tap an account to '
                      'show its mail'),
                )
              : _buildResultsList(visible),
        ),
      ],
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
          for (final id in ids)
            _buildAccountChip(id, accountDisplayLabel(accountsById[id], id)),
        ],
      ),
    );
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
            accountId: widget.accountId,
            onChanged: (g) => setState(() {
              _filterGroup = g;
              _results = null;
              _hiddenAccountIds.clear();
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
