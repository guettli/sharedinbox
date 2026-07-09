import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
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

/// Returns true if [text] contains a word that starts with [query].
/// "foo" matches "foobar" or "My Foobar" but NOT "blafoo".
bool _hasWordPrefix(String text, String query) =>
    RegExp(r'\b' + RegExp.escape(query), caseSensitive: false).hasMatch(text);

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
  _SearchResults? _results;
  bool _loading = false;
  bool _fieldFocused = false;

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
    final remaining = _results!.emails
        .where((e) => !actedSet.contains(e.threadId ?? e.id))
        .toList();
    setState(() {
      final updated = _SearchResults(
        mailboxes: _results!.mailboxes,
        addresses: _results!.addresses,
        emails: remaining,
      );
      _results = updated.isEmpty ? null : updated;
    });
  }

  void _toggleAdvanced() {
    setState(() {
      _advancedMode = !_advancedMode;
      _results = null;
    });
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.trim().length < 3) {
      setState(() => _results = null);
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => _search(value.trim()),
    );
  }

  Future<void> _search(String query) async {
    setState(() => _loading = true);
    unawaited(
      ref
          .read(searchHistoryRepositoryProvider)
          .saveSearch(query)
          .then((_) => ref.invalidate(_searchHistoryProvider)),
    );
    try {
      final emailRepo = ref.read(emailRepositoryProvider);
      final mailboxRepo = ref.read(mailboxRepositoryProvider);
      final ql = query.toLowerCase();

      final (allMailboxes, emails, addressEmails) = await (
        mailboxRepo.observeMailboxes(widget.accountId).first,
        emailRepo.searchEmailsGlobal(widget.accountId, query),
        emailRepo.getEmailsByAddress(widget.accountId, query),
      ).wait;

      final matchedMailboxes = allMailboxes
          .where((m) => _hasWordPrefix(m.name, ql))
          .toList()
        ..sort(compareMailboxes);

      // Collect unique addresses from address-search results where the
      // email or display name contains the query.
      final seen = <String>{};
      final addresses = <(EmailAddress, int, String)>[];
      for (final email in addressEmails) {
        for (final addr in [...email.from, ...email.to, ...email.cc]) {
          final key = '${email.accountId}:${addr.email}';
          if (seen.contains(key)) continue;
          final matchesEmail = _hasWordPrefix(addr.email, ql);
          final matchesName =
              addr.name != null && _hasWordPrefix(addr.name!, ql);
          if (!matchesEmail && !matchesName) continue;
          seen.add(key);
          final addrEmail = addr.email;
          final accId = email.accountId;
          final count = addressEmails
              .where(
                (e) =>
                    e.accountId == accId &&
                    [
                      ...e.from,
                      ...e.to,
                      ...e.cc,
                    ].any((a) => a.email == addrEmail),
              )
              .length;
          addresses.add((addr, count, accId));
        }
      }

      if (mounted) {
        setState(() {
          _results = _SearchResults(
            mailboxes: matchedMailboxes,
            addresses: addresses,
            emails: emails,
          );
          _loading = false;
        });
      }
    } catch (e) {
      log('Search failed: $e');
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
          _results = _SearchResults(
            mailboxes: const [],
            addresses: const [],
            emails: emails,
          );
          _loading = false;
        });
      }
    } catch (e) {
      log('Structured search failed: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selecting = _selection.isSelecting;
    return Scaffold(
      appBar: selecting
          ? buildSelectionAppBar(_selection)
          : AppBar(
              title: _advancedMode
                  ? const Text('Advanced Search')
                  : TextField(
                      controller: _ctrl,
                      focusNode: _focusNode,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: 'Search folders, addresses, emails…',
                        border: InputBorder.none,
                      ),
                      onChanged: _onChanged,
                    ),
              actions: [
                if (!_advancedMode && _ctrl.text.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: 'Clear search',
                    onPressed: () {
                      _ctrl.clear();
                      setState(() => _results = null);
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
    return _buildResultsList(r);
  }

  Widget _buildAdvancedBody() {
    final filterHeader = Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilterBuilderWidget(
            initialValue: _filterGroup,
            onChanged: (g) => setState(() {
              _filterGroup = g;
              _results = null;
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

    if (!_loading && _results != null && !_results!.isEmpty) {
      return Column(
        children: [
          filterHeader,
          Expanded(child: _buildResultsList(_results!)),
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

  Widget _buildResultsList(_SearchResults r) {
    final messagesList = EmailThreadList(
      controller: _selection,
      items: r.emails.map(EmailThread.fromEmail).toList(),
      enableSwipe: false,
      showLocationLabel: true,
    );

    final hasNonMessageSections =
        r.mailboxes.isNotEmpty || r.addresses.isNotEmpty;
    if (!hasNonMessageSections) return messagesList;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (r.mailboxes.isNotEmpty) ...[
          const _SectionHeader('Folders'),
          for (final mb in r.mailboxes)
            _FolderTile(mb: mb, accountId: mb.accountId),
        ],
        if (r.addresses.isNotEmpty) ...[
          const _SectionHeader('Addresses'),
          for (final (addr, count, accId) in r.addresses)
            _AddressTile(addr: addr, count: count, accountId: accId),
        ],
        if (r.emails.isNotEmpty) ...[
          const _SectionHeader('Messages'),
          Expanded(child: messagesList),
        ],
      ],
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

class _SearchResults {
  const _SearchResults({
    required this.mailboxes,
    required this.addresses,
    required this.emails,
  });

  final List<Mailbox> mailboxes;
  final List<(EmailAddress, int, String)> addresses;
  final List<Email> emails;

  bool get isEmpty => mailboxes.isEmpty && addresses.isEmpty && emails.isEmpty;
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: Text(title, style: Theme.of(context).textTheme.labelLarge),
    );
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({required this.mb, required this.accountId});
  final Mailbox mb;
  final String accountId;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.folder),
      title: Text(
        mb.name,
        style: mb.unreadCount > 0
            ? const TextStyle(fontWeight: FontWeight.bold)
            : null,
      ),
      subtitle: Text(accountId, style: Theme.of(context).textTheme.bodySmall),
      trailing:
          mb.unreadCount > 0 ? Badge(label: Text('${mb.unreadCount}')) : null,
      onTap: () => context.go(
        '/accounts/$accountId/mailboxes'
        '/${Uri.encodeComponent(mb.path)}/emails',
      ),
    );
  }
}

class _AddressTile extends StatelessWidget {
  const _AddressTile({
    required this.addr,
    required this.count,
    required this.accountId,
  });

  final EmailAddress addr;
  final int count;
  final String accountId;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.person),
      title: Text(addr.name ?? addr.email),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (addr.name != null) Text(addr.email),
          Text(accountId, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      trailing: Text('$count mail${count == 1 ? '' : 's'}'),
      onTap: () => context.push(
        '/accounts/$accountId/emails/by-address'
        '/${Uri.encodeComponent(addr.email)}',
      ),
    );
  }
}
