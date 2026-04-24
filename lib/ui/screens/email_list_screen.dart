import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/models/account.dart';
import '../../core/models/email.dart';
import '../../core/repositories/email_repository.dart';
import '../../di.dart';
import '../widgets/folder_drawer.dart';

final _dateFmt = DateFormat('MMM d');

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
  bool _searching = false;
  final _searchCtrl = TextEditingController();
  List<Email>? _searchResults;
  bool _searchLoading = false;

  // Thread-level selection (key = threadId).
  final Set<String> _selectedThreadIds = {};
  // Last-emitted thread list, used to resolve emailIds for batch operations.
  List<EmailThread> _currentThreads = [];
  bool get _selecting => _selectedThreadIds.isNotEmpty;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

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

  // All email IDs belonging to currently selected threads.
  List<String> get _selectedEmailIds => _currentThreads
      .where((t) => _selectedThreadIds.contains(t.threadId))
      .expand((t) => t.emailIds)
      .toList();

  Future<void> _runSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _searchResults = null);
      return;
    }
    setState(() => _searchLoading = true);
    try {
      final results = await ref.read(emailRepositoryProvider).searchEmails(
            widget.accountId,
            widget.mailboxPath,
            query.trim(),
          );
      if (mounted) setState(() => _searchResults = results);
    } finally {
      if (mounted) setState(() => _searchLoading = false);
    }
  }

  void _closeSearch() {
    setState(() {
      _searching = false;
      _searchResults = null;
      _searchCtrl.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(emailRepositoryProvider);
    final accountAsync = ref.watch(accountByIdProvider(widget.accountId));
    return Scaffold(
      appBar: _selecting
          ? _selectionBar()
          : (_searching ? _searchBar() : _normalBar(repo, accountAsync)),
      drawer: (_selecting || _searching)
          ? null
          : FolderDrawer(
              accountId: widget.accountId,
              currentMailboxPath: widget.mailboxPath,
            ),
      bottomNavigationBar: _selecting ? _selectionBottomBar() : null,
      body: _searching ? _buildSearchBody() : _buildStreamBody(repo),
    );
  }

  AppBar _normalBar(
    EmailRepository emailRepo,
    AsyncValue<Account?> accountAsync,
  ) {
    return AppBar(
      title: Text(widget.mailboxPath),
      actions: [
        accountAsync.when(
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
          data: (account) => Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Center(
              child: Text(
                account?.displayName ?? '',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: 'Search',
          onPressed: () => setState(() => _searching = true),
        ),
        IconButton(
          icon: const Icon(Icons.sync),
          onPressed: () =>
              emailRepo.syncEmails(widget.accountId, widget.mailboxPath),
        ),
        IconButton(
          icon: const Icon(Icons.edit),
          onPressed: () => context.push(
            '/compose',
            extra: {'accountId': widget.accountId},
          ),
        ),
      ],
    );
  }

  AppBar _selectionBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _clearSelection,
      ),
      title: Text('${_selectedThreadIds.length} selected'),
    );
  }

  AppBar _searchBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: _closeSearch,
      ),
      title: TextField(
        controller: _searchCtrl,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'Search…',
          border: InputBorder.none,
        ),
        onSubmitted: _runSearch,
        textInputAction: TextInputAction.search,
      ),
      actions: [
        if (_searchCtrl.text.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.clear),
            onPressed: () {
              _searchCtrl.clear();
              setState(() => _searchResults = null);
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
          IconButton(
            icon: const Icon(Icons.report),
            tooltip: 'Mark as spam',
            onPressed: _batchMarkSpam,
          ),
          IconButton(
            icon: const Icon(Icons.drive_file_move),
            tooltip: 'Move to folder',
            onPressed: _batchMove,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBody() {
    if (_searchLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searchResults == null) {
      return const Center(child: Text('Type a query and press Enter'));
    }
    if (_searchResults!.isEmpty) {
      return const Center(child: Text('No results'));
    }
    return _buildEmailList(_searchResults!);
  }

  Widget _buildStreamBody(EmailRepository emailRepo) {
    return StreamBuilder<List<EmailThread>>(
      stream: emailRepo.observeThreads(widget.accountId, widget.mailboxPath),
      builder: (ctx, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final threads = snap.data!;
        _currentThreads = threads;
        if (threads.isEmpty) {
          return const Center(child: Text('No emails'));
        }
        return _buildThreadList(threads);
      },
    );
  }

  Future<void> _batchArchive() async {
    final ids = _selectedEmailIds;
    _clearSelection();
    final archive = await ref
        .read(mailboxRepositoryProvider)
        .findMailboxByRole(widget.accountId, 'archive');
    if (!mounted) return;
    if (archive == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No archive folder found')),
      );
      return;
    }
    final repo = ref.read(emailRepositoryProvider);
    for (final id in ids) {
      await repo.moveEmail(id, archive.path);
    }
  }

  Future<void> _batchDelete() async {
    final ids = _selectedEmailIds;
    _clearSelection();
    final repo = ref.read(emailRepositoryProvider);
    for (final id in ids) {
      await repo.deleteEmail(id);
    }
  }

  Future<void> _batchMarkSpam() async {
    final ids = _selectedEmailIds;
    _clearSelection();
    final junk = await ref
        .read(mailboxRepositoryProvider)
        .findMailboxByRole(widget.accountId, 'junk');
    if (!mounted) return;
    if (junk == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No spam folder found')),
      );
      return;
    }
    final repo = ref.read(emailRepositoryProvider);
    for (final id in ids) {
      await repo.moveEmail(id, junk.path);
    }
  }

  Future<void> _batchMove() async {
    final ids = _selectedEmailIds;
    final mailboxes = await ref
        .read(mailboxRepositoryProvider)
        .observeMailboxes(widget.accountId)
        .first;
    final destinations =
        mailboxes.where((m) => m.path != widget.mailboxPath).toList();

    if (!mounted) return;

    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        children: [
          const ListTile(
            title: Text(
              'Move to…',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          for (final m in destinations)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(m.name),
              onTap: () => Navigator.pop(ctx, m.path),
            ),
        ],
      ),
    );

    if (chosen == null || !mounted) return;
    _clearSelection();
    final repo = ref.read(emailRepositoryProvider);
    for (final id in ids) {
      await repo.moveEmail(id, chosen);
    }
  }

  Widget _buildThreadList(List<EmailThread> threads) {
    return ListView.builder(
      itemCount: threads.length,
      itemBuilder: (ctx, i) {
        final t = threads[i];
        final isSelected = _selectedThreadIds.contains(t.threadId);
        final senderNames =
            t.participants.map((a) => a.name ?? a.email).take(3).join(', ');

        final tile = ListTile(
          leading: _selecting
              ? Checkbox(
                  value: isSelected,
                  onChanged: (_) => _toggleThreadSelection(t),
                )
              : Icon(
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
          subtitle: Text(
            t.subject ?? '(no subject)',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          selected: isSelected,
          trailing: _selecting
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (t.isFlagged)
                      const Icon(Icons.star, color: Colors.amber, size: 16),
                    const SizedBox(width: 4),
                    Text(
                      _dateFmt.format(t.latestDate),
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  ],
                ),
          onTap: _selecting
              ? () => _toggleThreadSelection(t)
              : t.messageCount > 1
                  ? () => context.push(
                        '/accounts/${widget.accountId}/mailboxes/${Uri.encodeComponent(widget.mailboxPath)}/threads/${Uri.encodeComponent(t.threadId)}',
                      )
                  : () => context.push(
                        '/accounts/${widget.accountId}/mailboxes/${Uri.encodeComponent(widget.mailboxPath)}/emails/${Uri.encodeComponent(t.latestEmailId)}',
                      ),
          onLongPress: () => _toggleThreadSelection(t),
        );

        if (_selecting) return tile;

        // For swipe actions on threads, operate on the latest email only
        // (single-email threads) or the whole thread.
        return Dismissible(
          key: ValueKey(t.threadId),
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
          onDismissed: (direction) async {
            final repo = ref.read(emailRepositoryProvider);
            if (direction == DismissDirection.startToEnd) {
              final archive = await ref
                  .read(mailboxRepositoryProvider)
                  .findMailboxByRole(widget.accountId, 'archive');
              if (!mounted || archive == null) return;
              for (final id in t.emailIds) {
                await repo.moveEmail(id, archive.path);
              }
            } else {
              for (final id in t.emailIds) {
                await repo.deleteEmail(id);
              }
            }
          },
          child: tile,
        );
      },
    );
  }

  // Used for search results, which are individual emails.
  Widget _buildEmailList(List<Email> emails) {
    return ListView.builder(
      itemCount: emails.length,
      itemBuilder: (ctx, i) {
        final e = emails[i];
        final sender = e.from.isNotEmpty
            ? (e.from.first.name ?? e.from.first.email)
            : '(unknown)';
        return ListTile(
          leading: Icon(
            e.isSeen ? Icons.mail_outline : Icons.mail,
            color: e.isSeen ? null : Theme.of(ctx).colorScheme.primary,
          ),
          title: Text(
            sender,
            style:
                e.isSeen ? null : const TextStyle(fontWeight: FontWeight.bold),
          ),
          subtitle: Text(
            e.subject ?? '(no subject)',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(
            e.sentAt != null ? _dateFmt.format(e.sentAt!) : '',
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
          onTap: () => context.push(
            '/accounts/${widget.accountId}/mailboxes/${Uri.encodeComponent(widget.mailboxPath)}/emails/${Uri.encodeComponent(e.id)}',
          ),
        );
      },
    );
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
