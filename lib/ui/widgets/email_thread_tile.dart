import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/models/email.dart';

final _dateFmt = DateFormat('MMM d');
final _formattedDates = <int, String>{};

int _dayKey(DateTime dt) => dt.year * 10000 + dt.month * 100 + dt.day;

String _fmtDate(DateTime dt) =>
    _formattedDates[_dayKey(dt)] ??= _dateFmt.format(dt);

/// A swipeable list tile for an [EmailThread].
///
/// Handles the [Dismissible] wrapper (archive left, delete right) and
/// selection-mode checkbox. Pass [showAccount] to display an extra subtitle
/// line with the account name — used in the combined-inbox view.
class EmailThreadTile extends StatelessWidget {
  const EmailThreadTile({
    super.key,
    required this.thread,
    required this.isSelected,
    required this.isSelecting,
    required this.onTap,
    required this.onLongPress,
    required this.onDismissed,
    this.showAccount = false,
    this.accountName,
  });

  final EmailThread thread;
  final bool isSelected;
  final bool isSelecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final Future<void> Function(DismissDirection) onDismissed;

  /// When true, renders an extra subtitle line with [accountName].
  final bool showAccount;
  final String? accountName;

  @override
  Widget build(BuildContext context) {
    final t = thread;
    final senderNames =
        t.participants.map((a) => a.name ?? a.email).take(3).join(', ');

    final tile = ListTile(
      leading: SizedBox(
        width: 40,
        child: isSelecting
            ? Checkbox(
                value: isSelected,
                onChanged: (_) => onTap(),
              )
            : Icon(
                t.hasUnread ? Icons.mail : Icons.mail_outline,
                color:
                    t.hasUnread ? Theme.of(context).colorScheme.primary : null,
              ),
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
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.subject ?? '(no subject)',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.hasUnread
                ? const TextStyle(fontWeight: FontWeight.bold)
                : null,
          ),
          if (t.preview != null && t.preview!.isNotEmpty)
            Text(
              t.preview!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (showAccount && accountName != null)
            Text(
              accountName!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
        ],
      ),
      selected: isSelected,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (t.isFlagged)
            const Icon(Icons.star, color: Colors.amber, size: 16),
          const SizedBox(width: 4),
          Text(
            _fmtDate(t.latestDate),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      onTap: onTap,
      onLongPress: onLongPress,
    );

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
      onDismissed: onDismissed,
      child: tile,
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
