import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/ui/screens/email_action_helpers.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/thread_tile.dart';

/// Controller for [EmailThreadList].
///
/// Holds the current selection set and the last-seen thread list, so the host
/// screen can listen for selection-mode changes (to swap AppBars, hide the
/// drawer, etc.) and read [selectedThreads] when wiring batch-action buttons.
class EmailThreadListController extends ChangeNotifier {
  final Set<String> _selected = <String>{};
  List<EmailThread> _threads = const [];

  /// All threads currently rendered (latest stream emission or static input).
  List<EmailThread> get visibleThreads => List.unmodifiable(_threads);

  /// Threads whose `threadId` is selected (preserving the list's order).
  List<EmailThread> get selectedThreads =>
      _threads.where((t) => _selected.contains(t.threadId)).toList();

  Set<String> get selectedIds => Set.unmodifiable(_selected);

  bool get isSelecting => _selected.isNotEmpty;
  int get selectionCount => _selected.length;

  bool isSelected(EmailThread t) => _selected.contains(t.threadId);

  void toggle(EmailThread t) {
    if (!_selected.add(t.threadId)) {
      _selected.remove(t.threadId);
    }
    notifyListeners();
  }

  void clear() {
    if (_selected.isEmpty) return;
    _selected.clear();
    notifyListeners();
  }

  void selectAll() {
    final before = _selected.length;
    _selected.addAll(_threads.map((t) => t.threadId));
    if (_selected.length != before) notifyListeners();
  }

  /// Called by [EmailThreadList] whenever the visible threads change. Drops
  /// any selected ids that no longer appear in the list. Hosts should not
  /// call this directly.
  void updateThreads(List<EmailThread> threads) {
    _threads = threads;
    final visibleIds = threads.map((t) => t.threadId).toSet();
    final before = _selected.length;
    _selected.retainAll(visibleIds);
    if (_selected.length != before) notifyListeners();
  }
}

/// A unified list of email threads used by folder, combined-inbox, search and
/// address-emails views.
///
/// Renders selection-mode checkboxes, optional swipe-to-archive/delete and
/// optional pagination. Selection state lives in [controller]; the host screen
/// listens to it to swap its AppBar / BottomBar for selection-mode equivalents
/// (see [buildSelectionAppBar] / [buildSelectionBottomBar]).
///
/// Provide exactly one of [stream] (live data) or [items] (static list, used
/// for search / by-address results).
class EmailThreadList extends ConsumerStatefulWidget {
  const EmailThreadList({
    super.key,
    required this.controller,
    this.stream,
    this.items,
    this.enableSwipe = true,
    this.enablePagination = false,
    this.pageSize = 50,
    this.showAccountLabel = false,
    this.showLocationLabel = false,
    this.accountNames = const {},
    this.onTap,
    this.onLoadMore,
    this.emptyMessage = 'No emails',
  }) : assert(
          (stream == null) != (items == null),
          'Provide exactly one of stream or items',
        );

  final EmailThreadListController controller;

  /// Live thread source (folder view, combined inbox). Mutually exclusive with
  /// [items].
  final Stream<List<EmailThread>>? stream;

  /// Static thread list (search results, by-address). Mutually exclusive with
  /// [stream].
  final List<EmailThread>? items;

  /// When true, threads can be swiped to archive (start→end) or delete
  /// (end→start). Disabled for search-result lists where a swipe would
  /// silently drop an item from a filtered view.
  final bool enableSwipe;

  /// When true, the list shows a "Load more" button once the visible count
  /// equals the current page size.
  final bool enablePagination;

  /// Page size for [enablePagination].
  final int pageSize;

  /// Show an extra subtitle line with the account name (combined inbox).
  /// Looked up in [accountNames] keyed by `accountId`.
  final bool showAccountLabel;
  final Map<String, String> accountNames;

  /// Show a per-tile location label ("accountId • mailboxPath"). Used by
  /// global search results.
  final bool showLocationLabel;

  /// Optional tap handler. When null, the default navigates to the email or
  /// thread detail route based on `messageCount`.
  final ValueChanged<EmailThread>? onTap;

  /// Notification fired when the user taps "Load more". Hosts that use a
  /// stream can grow their `limit` here.
  final VoidCallback? onLoadMore;

  /// Message shown when the list is empty.
  final String emptyMessage;

  @override
  ConsumerState<EmailThreadList> createState() => _EmailThreadListState();
}

class _EmailThreadListState extends ConsumerState<EmailThreadList> {
  int _limit = 50;

  @override
  void initState() {
    super.initState();
    _limit = widget.pageSize;
    widget.controller.addListener(_onControllerChange);
  }

  @override
  void didUpdateWidget(EmailThreadList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChange);
      widget.controller.addListener(_onControllerChange);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChange);
    super.dispose();
  }

  void _onControllerChange() {
    if (mounted) setState(() {});
  }

  void _publishThreads(List<EmailThread> threads) {
    if (listEquals(threads, widget.controller.visibleThreads)) return;
    // Defer so we don't notifyListeners during a build phase.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.updateThreads(threads);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items != null) {
      return _buildList(widget.items!);
    }
    return StreamBuilder<List<EmailThread>>(
      stream: widget.stream,
      builder: (ctx, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return _buildList(snap.data!);
      },
    );
  }

  Widget _buildList(List<EmailThread> threads) {
    _publishThreads(threads);
    if (threads.isEmpty) {
      return ListView(
        children: [
          SizedBox(
            height: 300,
            child: Center(child: Text(widget.emptyMessage)),
          ),
        ],
      );
    }
    final hasMore = widget.enablePagination && threads.length == _limit;
    return ListView.builder(
      itemCount: threads.length + (hasMore ? 1 : 0),
      itemBuilder: (ctx, i) {
        if (i == threads.length) {
          return TextButton(
            onPressed: () {
              setState(() => _limit += widget.pageSize);
              widget.onLoadMore?.call();
            },
            child: const Text('Load more'),
          );
        }
        return _tileFor(threads[i]);
      },
    );
  }

  Widget _tileFor(EmailThread t) {
    final isSelected = widget.controller.isSelected(t);
    final isSelecting = widget.controller.isSelecting;
    final accountName = widget.accountNames[t.accountId];
    final locationLabel = widget.showLocationLabel
        ? '${t.accountId} • ${t.mailboxPath}'
        : widget.showAccountLabel
            ? accountName
            : null;

    final tile = ThreadTile(
      thread: t,
      selected: isSelected,
      locationLabel: locationLabel,
      leading: isSelecting
          ? SizedBox(
              width: 40,
              child: Checkbox(
                value: isSelected,
                onChanged: (_) => widget.controller.toggle(t),
              ),
            )
          : null,
      onTap: () => _onTileTap(t),
      onLongPress: () => widget.controller.toggle(t),
    );

    if (!widget.enableSwipe) return tile;

    return Dismissible(
      key: ValueKey('${t.accountId}:${t.threadId}'),
      direction:
          isSelecting ? DismissDirection.none : DismissDirection.horizontal,
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
      onDismissed: (direction) =>
          unawaited(swipeDismissThread(ref, t, direction)),
      child: tile,
    );
  }

  void _onTileTap(EmailThread t) {
    if (widget.controller.isSelecting) {
      widget.controller.toggle(t);
      return;
    }
    if (widget.onTap != null) {
      widget.onTap!(t);
      return;
    }
    if (t.messageCount > 1) {
      unawaited(
        context.push(
          '/accounts/${t.accountId}/mailboxes'
          '/${Uri.encodeComponent(t.mailboxPath)}'
          '/threads/${Uri.encodeComponent(t.threadId)}',
        ),
      );
      return;
    }
    unawaited(
      context.push(
        '/accounts/${t.accountId}/mailboxes'
        '/${Uri.encodeComponent(t.mailboxPath)}'
        '/emails/${Uri.encodeComponent(t.latestEmailId)}',
      ),
    );
  }

  static Widget _swipeBackground({
    required AlignmentGeometry alignment,
    required Color color,
    required IconData icon,
    required String label,
  }) {
    return Container(
      color: color,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white),
          const SizedBox(width: AppSpacing.sm),
          Text(label, style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }
}

/// Standard "N selected" AppBar with X-close and select-all actions.
PreferredSizeWidget buildSelectionAppBar(EmailThreadListController controller) {
  return AppBar(
    leading: IconButton(
      icon: const Icon(Icons.close),
      onPressed: controller.clear,
    ),
    title: Text('${controller.selectionCount} selected'),
    actions: [
      IconButton(
        icon: const Icon(Icons.select_all),
        tooltip: 'Select all',
        onPressed: controller.selectAll,
      ),
    ],
  );
}

/// Standard batch-action BottomAppBar.
///
/// [onAfterAction] runs after the helper finishes and the selection is
/// cleared. It receives the list of thread IDs that were targeted so the host
/// can refresh static result lists (e.g. search results) and pop if empty.
Widget buildSelectionBottomBar(
  BuildContext context,
  WidgetRef ref,
  EmailThreadListController controller, {
  bool includeArchive = true,
  bool includeDelete = true,
  bool includeSpam = true,
  bool includeMove = true,
  bool includeSnooze = true,
  void Function(List<String> actedThreadIds)? onAfterAction,
}) {
  void run(Future<void> Function() body) {
    final actedIds = controller.selectedThreads.map((t) => t.threadId).toList();
    unawaited(() async {
      await body();
      controller.clear();
      onAfterAction?.call(actedIds);
    }());
  }

  return BottomAppBar(
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        if (includeArchive)
          IconButton(
            icon: const Icon(Icons.archive),
            tooltip: 'Archive',
            onPressed: () => run(
              () => batchArchive(
                context,
                ref,
                threads: controller.selectedThreads,
              ),
            ),
          ),
        if (includeDelete)
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: 'Delete',
            onPressed: () => run(
              () => batchDelete(ref, threads: controller.selectedThreads),
            ),
          ),
        if (includeSpam)
          IconButton(
            icon: const Icon(Icons.report),
            tooltip: 'Mark as spam',
            onPressed: () => run(
              () => batchMarkSpam(
                context,
                ref,
                threads: controller.selectedThreads,
              ),
            ),
          ),
        if (includeMove)
          IconButton(
            icon: const Icon(Icons.drive_file_move),
            tooltip: 'Move to folder',
            onPressed: () => run(
              () => batchMove(
                context,
                ref,
                threads: controller.selectedThreads,
              ),
            ),
          ),
        if (includeSnooze)
          IconButton(
            icon: const Icon(Icons.access_time),
            tooltip: 'Snooze',
            onPressed: () => run(
              () => batchSnooze(
                context,
                ref,
                threads: controller.selectedThreads,
              ),
            ),
          ),
      ],
    ),
  );
}
