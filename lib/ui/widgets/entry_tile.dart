import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/models/entry.dart';

/// One entry in a list: its title (or first line), preview and last edit,
/// a conflict icon and, with [onDelete], a menu to delete it.
class EntryTile extends StatelessWidget {
  const EntryTile({
    super.key,
    required this.entry,
    required this.onTap,
    this.onDelete,
    required this.onResolve,
  });

  final Entry entry;
  final VoidCallback onTap;

  /// Shows a menu with "Delete" when set.
  final VoidCallback? onDelete;
  final VoidCallback onResolve;

  @override
  Widget build(BuildContext context) {
    final preview = entry.preview;
    final updated =
        DateFormat.yMMMd().add_Hm().format(entry.updatedAt.toLocal());
    return ListTile(
      key: Key('entry_${entry.itemId}'),
      title: Text(
        entry.displayTitle.isEmpty ? '(empty)' : entry.displayTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        preview.isEmpty ? updated : '$preview\n$updated',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: preview.isNotEmpty,
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (entry.hasConflict)
            IconButton(
              key: Key('entryConflict_${entry.itemId}'),
              tooltip: 'Edited on several devices — resolve',
              icon: Icon(
                Icons.call_split,
                color: Theme.of(context).colorScheme.error,
              ),
              onPressed: onResolve,
            ),
          if (onDelete != null)
            PopupMenuButton<String>(
              key: Key('entryMenu_${entry.itemId}'),
              onSelected: (_) => onDelete!(),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'delete',
                  key: Key('entryDelete'),
                  child: Text('Delete'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
