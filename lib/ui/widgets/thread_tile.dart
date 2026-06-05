import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/models/email.dart';

final _dateFmt = DateFormat('MMM d');
// Cache formatted dates by local calendar day to avoid repeated DateFormat.format calls.
final _formattedDates = <int, String>{};

int _dayKey(DateTime dt) => dt.year * 10000 + dt.month * 100 + dt.day;

String _fmtDate(DateTime dt) =>
    _formattedDates[_dayKey(dt)] ??= _dateFmt.format(dt);

/// A list tile for an [EmailThread].
///
/// Used in inbox lists, combined inbox, and search result lists.
/// Pass a custom [leading] widget to support selection-mode checkboxes.
/// Pass [locationLabel] to show an extra subtitle line (e.g. account name or
/// "accountId • mailboxPath") — useful in cross-mailbox views.
class ThreadTile extends StatelessWidget {
  const ThreadTile({
    super.key,
    required this.thread,
    required this.onTap,
    this.leading,
    this.selected = false,
    this.onLongPress,
    this.locationLabel,
  });

  final EmailThread thread;
  final VoidCallback onTap;
  final Widget? leading;
  final bool selected;
  final VoidCallback? onLongPress;

  /// When non-null, appended as an extra subtitle line in primary colour.
  final String? locationLabel;

  @override
  Widget build(BuildContext context) {
    final senderNames = thread.participants.isEmpty
        ? '(unknown)'
        : thread.participants.map((a) => a.name ?? a.email).take(3).join(', ');

    return ListTile(
      leading: leading ??
          Icon(
            thread.hasUnread ? Icons.mail : Icons.mail_outline,
            color:
                thread.hasUnread ? Theme.of(context).colorScheme.primary : null,
          ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              senderNames,
              style: thread.hasUnread
                  ? const TextStyle(fontWeight: FontWeight.bold)
                  : null,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (thread.messageCount > 1)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                '[${thread.messageCount}]',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            thread.subject ?? '(no subject)',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: thread.hasUnread
                ? const TextStyle(fontWeight: FontWeight.bold)
                : null,
          ),
          if (thread.preview != null && thread.preview!.isNotEmpty)
            Text(
              thread.preview!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (locationLabel != null)
            Text(
              locationLabel!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (thread.isFlagged)
            const Icon(Icons.star, color: Colors.amber, size: 16),
          const SizedBox(width: 4),
          Text(
            _fmtDate(thread.latestDate),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      selected: selected,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}
