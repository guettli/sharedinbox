import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/sync/message_debug_service.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/email_action_helpers.dart';
import 'package:sharedinbox/ui/screens/email_detail_nav.dart';
import 'package:sharedinbox/ui/widgets/swipe_tree/swipe_action_menu.dart';
import 'package:sharedinbox/ui/widgets/swipe_tree/swipe_tree_node.dart';
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
/// Renders selection-mode checkboxes, an optional swipe-to-open action tree
/// and optional pagination. Selection state lives in [controller]; the host
/// screen
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

  /// When true, a horizontal swipe on a row opens the radial tree of actions
  /// (archive, star, delete, spam, move, snooze — see [SwipeActionMenu], #240).
  /// Disabled for search-result lists where acting on a row would silently drop
  /// an item from a filtered view.
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

  /// Show a per-tile location label like `"Work • Archive/2026"`. Used by
  /// global search results. The account is resolved through [accountNames]
  /// (keyed by `accountId`), falling back to the raw id when the map lacks the
  /// entry. The folder is resolved through the local mailbox cache, so JMAP
  /// mailboxes render as their human-readable hierarchical path — never as the
  /// opaque server id (#288).
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

  /// Resolves a raw `mailboxPath` (server key) to the human-readable
  /// `displayPath` for the given account. For IMAP the two are equal; for JMAP
  /// `mailboxPath` is an opaque server id (e.g. `"a"`) and rendering it
  /// verbatim would leak the id into the UI (#288). Falls back to the raw
  /// value when the mailbox is not yet cached locally.
  String _displayFolder(String accountId, String rawPath) {
    final mailbox =
        ref.watch(mailboxByPathProvider((accountId, rawPath))).value;
    return mailbox?.displayPath ?? rawPath;
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
        ? '${accountName ?? t.accountId} • ${_displayFolder(t.accountId, t.mailboxPath)}'
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

    // A horizontal swipe opens a radial tree of actions instead of the old
    // fixed archive/delete dismiss (#240). The tree is rebuilt on each swipe so
    // it reflects the current selection: a swipe while multi-selecting drives
    // the batch handlers on every selected thread, otherwise just this row.
    return SwipeActionMenu(
      key: ValueKey('swipe:${t.accountId}:${t.threadId}'),
      buildRoot: () => _buildActionTree(t),
      child: tile,
    );
  }

  /// Threads a swipe on row [t] acts on: the whole selection while
  /// multi-selecting, otherwise just [t].
  List<EmailThread> _targetThreads(EmailThread t) =>
      widget.controller.isSelecting ? widget.controller.selectedThreads : [t];

  /// Runs a batch [body] and clears the selection afterwards when the swipe
  /// acted on a multi-selection, mirroring [buildSelectionBottomBar].
  void _invoke(Future<void> Function() body) {
    final wasSelecting = widget.controller.isSelecting;
    unawaited(() async {
      await body();
      if (wasSelecting) widget.controller.clear();
    }());
  }

  /// Builds the hard-coded action tree (#240). Every leaf routes to the shared
  /// batch helpers in `email_action_helpers.dart`, so undo behaves exactly as
  /// the selection bottom bar does. Only the `Move` folder list is dynamic.
  BranchNode _buildActionTree(EmailThread t) {
    final targets = _targetThreads(t);
    final allStarred = targets.isNotEmpty && targets.every((t) => t.isFlagged);

    return BranchNode(
      icon: Icons.more_horiz,
      label: 'Actions',
      color: Colors.blueGrey,
      children: [
        ActionNode(
          icon: Icons.archive,
          label: 'Archive',
          color: const Color(0xFF2E7D32),
          onInvoke: () => _invoke(
            () => batchArchive(context, ref, threads: targets),
          ),
        ),
        ActionNode(
          icon: allStarred ? Icons.star : Icons.star_border,
          label: allStarred ? 'Unstar' : 'Star',
          color: Colors.amber.shade700,
          onInvoke: () => _invoke(
            () => batchStar(ref, threads: targets, flagged: !allStarred),
          ),
        ),
        ActionNode(
          icon: Icons.delete,
          label: 'Delete',
          color: Colors.red.shade700,
          onInvoke: () => _invoke(() => batchDelete(ref, threads: targets)),
        ),
        ActionNode(
          icon: Icons.report,
          label: 'Spam',
          color: const Color(0xFFE65100),
          onInvoke: () => _invoke(
            () => batchMarkSpam(context, ref, threads: targets),
          ),
        ),
        BranchNode(
          icon: Icons.drive_file_move,
          label: 'Move',
          color: Colors.blue.shade700,
          loadChildren: () => _moveFolderNodes(targets),
        ),
        BranchNode(
          icon: Icons.access_time,
          label: 'Snooze',
          color: Colors.deepPurple,
          children: [
            ScrubberNode(
              icon: Icons.today,
              label: 'Days',
              color: Colors.deepPurple,
              format: (v) => v == 0 ? 'Cancel' : '$v day${v == 1 ? '' : 's'}',
              onPick: (v) => _snoozeIn(targets, Duration(days: v)),
            ),
            ScrubberNode(
              icon: Icons.date_range,
              label: 'Weeks',
              color: Colors.deepPurple,
              format: (v) => v == 0 ? 'Cancel' : '$v week${v == 1 ? '' : 's'}',
              onPick: (v) => _snoozeIn(targets, Duration(days: v * 7)),
            ),
          ],
        ),
      ],
    );
  }

  /// Resolves the `Move` branch children: one folder leaf per destination for a
  /// single-account selection, or a single "Choose…" leaf that opens the
  /// existing per-account modal picker when the selection spans accounts.
  Future<List<SwipeTreeNode>> _moveFolderNodes(
    List<EmailThread> targets,
  ) async {
    final accounts = targets.map((t) => t.accountId).toSet();
    final blue = Colors.blue.shade700;
    if (accounts.length != 1) {
      return [
        ActionNode(
          icon: Icons.drive_file_move,
          label: 'Choose…',
          color: blue,
          onInvoke: () =>
              _invoke(() => batchMove(context, ref, threads: targets)),
        ),
      ];
    }
    final accountId = accounts.first;
    final currentPath = targets.first.mailboxPath;
    final mailboxes = await ref
        .read(mailboxRepositoryProvider)
        .observeMailboxes(accountId)
        .first;
    return [
      for (final m in mailboxes.where((m) => m.path != currentPath))
        ActionNode(
          icon: Icons.folder_outlined,
          label: m.name,
          color: blue,
          onInvoke: () => _invoke(
            () => moveThreadsToPath(ref, threads: targets, destPath: m.path),
          ),
        ),
    ];
  }

  /// Snoozes [targets] by [d]. A zero duration (the scrubber at its minimum)
  /// is treated as a cancel.
  void _snoozeIn(List<EmailThread> targets, Duration d) {
    if (d.inSeconds <= 0) return;
    _invoke(
      () => snoozeThreadsUntil(
        ref,
        threads: targets,
        until: DateTime.now().add(d),
      ),
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
    unawaited(
      context.push(
        '/accounts/${t.accountId}/mailboxes'
        '/${Uri.encodeComponent(t.mailboxPath)}'
        '/emails/${Uri.encodeComponent(t.latestEmailId)}',
        extra: EmailDetailNav.fromThreads(widget.controller.visibleThreads),
      ),
    );
  }
}

/// Opens the per-message debug screen for every email in the currently
/// selected threads. Shared by folder, combined-inbox, search and
/// address-emails views so the "..." overflow entry behaves the same in each.
void openDebugForSelection(
  BuildContext context,
  EmailThreadListController controller,
) {
  final messages = <DebugMessageRef>[
    for (final t in controller.selectedThreads)
      for (final emailId in t.emailIds)
        DebugMessageRef(
          accountId: t.accountId,
          mailboxPath: t.mailboxPath,
          emailId: emailId,
        ),
  ];
  if (messages.isEmpty) return;
  unawaited(context.push('/debug/messages', extra: messages));
}

/// Convenience wrapper around [buildSelectionAppBar] that adds the standard
/// "Debug messages" entry to the "..." overflow. Every list view uses the
/// same entry, so wiring it via this helper avoids repeating the boilerplate
/// (and the resulting jscpd duplicate) at each call site.
PreferredSizeWidget buildDebugSelectionAppBar(
  BuildContext context,
  EmailThreadListController controller,
) =>
    buildSelectionAppBar(
      controller,
      overflowActions: [
        ('Debug messages', () => openDebugForSelection(context, controller)),
      ],
    );

/// Standard "N selected" AppBar with X-close and select-all actions.
///
/// [overflowActions] adds a "..." overflow menu after "Select all" when
/// non-empty. Each entry is a `(label, callback)` tuple; the callback runs on
/// tap and the menu closes automatically. Used e.g. by the email list screen
/// to surface the "Debug messages" entry point (#303).
PreferredSizeWidget buildSelectionAppBar(
  EmailThreadListController controller, {
  List<(String label, VoidCallback onSelected)> overflowActions = const [],
}) {
  return AppBar(
    leading: IconButton(
      icon: const Icon(Icons.close),
      tooltip: 'Clear selection',
      onPressed: controller.clear,
    ),
    title: Text('${controller.selectionCount} selected'),
    actions: [
      IconButton(
        icon: const Icon(Icons.select_all),
        tooltip: 'Select all',
        onPressed: controller.selectAll,
      ),
      if (overflowActions.isNotEmpty)
        PopupMenuButton<int>(
          tooltip: 'More actions',
          onSelected: (index) => overflowActions[index].$2(),
          itemBuilder: (_) => [
            for (int i = 0; i < overflowActions.length; i++)
              PopupMenuItem(value: i, child: Text(overflowActions[i].$1)),
          ],
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
  bool includeStar = true,
  String? currentFolderRole,
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

  // In Junk/Trash the destructive action becomes a "move back to Inbox" button;
  // both variants are identical apart from their icon and tooltip.
  Widget moveToInboxButton({required IconData icon, required String tooltip}) {
    return _BulkActionButton(
      icon: icon,
      tooltip: tooltip,
      color: const Color(0xFF2E7D32),
      haptic: HapticFeedback.mediumImpact,
      onPressed: () => run(
        () => batchMoveToInbox(
          context,
          ref,
          threads: controller.selectedThreads,
        ),
      ),
    );
  }

  // If every selected thread is already starred, the button unstars them all;
  // otherwise it stars every selection (so a mixed selection resolves to
  // "everything gets starred").
  final selected = controller.selectedThreads;
  final allStarred = selected.isNotEmpty && selected.every((t) => t.isFlagged);

  return BottomAppBar(
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        if (includeArchive)
          _BulkActionButton(
            icon: Icons.archive,
            tooltip: 'Archive',
            color: const Color(0xFF2E7D32),
            haptic: HapticFeedback.mediumImpact,
            onPressed: () => run(
              () => batchArchive(
                context,
                ref,
                threads: controller.selectedThreads,
              ),
            ),
          ),
        if (includeStar)
          _BulkActionButton(
            icon: allStarred ? Icons.star : Icons.star_border,
            tooltip: allStarred ? 'Unstar' : 'Star',
            color: Colors.amber.shade700,
            haptic: HapticFeedback.selectionClick,
            onPressed: () => run(
              () => batchStar(
                ref,
                threads: controller.selectedThreads,
                flagged: !allStarred,
              ),
            ),
          ),
        if (includeDelete)
          if (currentFolderRole == 'trash')
            moveToInboxButton(
              icon: Icons.restore_from_trash,
              tooltip: 'Restore',
            )
          else
            _BulkActionButton(
              icon: Icons.delete,
              tooltip: 'Delete',
              color: Colors.red.shade700,
              haptic: HapticFeedback.heavyImpact,
              onPressed: () => run(
                () => batchDelete(ref, threads: controller.selectedThreads),
              ),
            ),
        if (includeSpam)
          if (currentFolderRole == 'junk')
            moveToInboxButton(
              icon: Icons.report_off,
              tooltip: 'Not junk',
            )
          else
            _BulkActionButton(
              icon: Icons.report,
              tooltip: 'Mark as spam',
              color: const Color(0xFFE65100),
              haptic: HapticFeedback.mediumImpact,
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

/// Bulk-select destructive action button.
///
/// Distinct from the tiny [IconButton]s the bar used to render: a coloured
/// tinted circle at rest identifies the action, and a pronounced scale +
/// saturation pulse on tap makes the tap unmistakable. Feedback for the
/// resulting action (Archived N, Deleted N, Marked N as spam) lands in the
/// UndoShell banner + SnackBar (#233).
class _BulkActionButton extends StatefulWidget {
  const _BulkActionButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
    required this.haptic,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onPressed;
  final Future<void> Function() haptic;

  @override
  State<_BulkActionButton> createState() => _BulkActionButtonState();
}

class _BulkActionButtonState extends State<_BulkActionButton> {
  bool _pulsing = false;
  Timer? _pulseTimer;

  @override
  void dispose() {
    _pulseTimer?.cancel();
    super.dispose();
  }

  void _handle() {
    unawaited(widget.haptic());
    setState(() => _pulsing = true);
    _pulseTimer?.cancel();
    _pulseTimer = Timer(const Duration(milliseconds: 320), () {
      if (mounted) setState(() => _pulsing = false);
    });
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: InkResponse(
        onTap: _handle,
        radius: 28,
        child: AnimatedScale(
          scale: _pulsing ? 1.5 : 1.0,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutBack,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _pulsing
                  ? widget.color
                  : widget.color.withValues(alpha: 0.18),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: 24,
              color: _pulsing ? Colors.white : widget.color,
            ),
          ),
        ),
      ),
    );
  }
}
