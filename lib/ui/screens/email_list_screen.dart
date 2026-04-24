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

  final Set<String> _selectedIds = {};
  bool get _selecting => _selectedIds.isNotEmpty;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _clearSelection() => setState(() => _selectedIds.clear());

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
      title: Text('${_selectedIds.length} selected'),
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
    return _buildList(_searchResults!);
  }

  Widget _buildStreamBody(EmailRepository emailRepo) {
    return StreamBuilder<List<Email>>(
      stream: emailRepo.observeEmails(widget.accountId, widget.mailboxPath),
      builder: (ctx, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final emails = snap.data!;
        if (emails.isEmpty) {
          return const Center(child: Text('No emails'));
        }
        return _buildList(emails);
      },
    );
  }

  Future<void> _archiveEmail(Email email) async {
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
    await ref.read(emailRepositoryProvider).moveEmail(email.id, archive.path);
  }

  Future<void> _deleteEmail(Email email) async {
    await ref.read(emailRepositoryProvider).deleteEmail(email.id);
  }

  Future<void> _batchArchive() async {
    final ids = Set<String>.from(_selectedIds);
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
    final ids = Set<String>.from(_selectedIds);
    _clearSelection();
    final repo = ref.read(emailRepositoryProvider);
    for (final id in ids) {
      await repo.deleteEmail(id);
    }
  }

  Future<void> _batchMarkSpam() async {
    final ids = Set<String>.from(_selectedIds);
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
    final ids = Set<String>.from(_selectedIds);
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

  Widget _buildList(List<Email> emails) {
    return ListView.builder(
      itemCount: emails.length,
      itemBuilder: (ctx, i) {
        final e = emails[i];
        final isSelected = _selectedIds.contains(e.id);
        final sender = e.from.isNotEmpty
            ? (e.from.first.name ?? e.from.first.email)
            : '(unknown)';

        final tile = ListTile(
          leading: _selecting
              ? Checkbox(
                  value: isSelected,
                  onChanged: (_) => _toggleSelection(e.id),
                )
              : Icon(
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
          selected: isSelected,
          trailing: _selecting
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (e.isFlagged)
                      const Icon(Icons.star, color: Colors.amber, size: 16),
                    if (e.hasAttachment)
                      const Icon(Icons.attach_file, size: 16),
                    const SizedBox(width: 4),
                    Text(
                      e.sentAt != null ? _dateFmt.format(e.sentAt!) : '',
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  ],
                ),
          onTap: _selecting
              ? () => _toggleSelection(e.id)
              : () => context.push(
                    '/accounts/${widget.accountId}/mailboxes/${Uri.encodeComponent(widget.mailboxPath)}/emails/${Uri.encodeComponent(e.id)}',
                  ),
          onLongPress: () => _toggleSelection(e.id),
        );

        if (_selecting) return tile;

        return Dismissible(
          key: ValueKey(e.id),
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
            if (direction == DismissDirection.startToEnd) {
              await _archiveEmail(e);
            } else {
              await _deleteEmail(e);
            }
          },
          child: tile,
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
