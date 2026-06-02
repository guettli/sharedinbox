import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/models/email.dart';

final _dateFmt = DateFormat('MMM d');

/// A flat list tile for an individual [email].
///
/// Used in search-result lists and the per-mailbox search overlay.
/// Pass a custom [leading] widget to support selection-mode checkboxes.
class EmailTile extends StatelessWidget {
  const EmailTile({
    super.key,
    required this.email,
    required this.onTap,
    this.leading,
    this.selected = false,
    this.onLongPress,
    this.showLocation = false,
  });

  final Email email;
  final VoidCallback onTap;
  final Widget? leading;
  final bool selected;
  final VoidCallback? onLongPress;

  /// When true, appends `accountId • mailboxPath` as a second subtitle line.
  final bool showLocation;

  @override
  Widget build(BuildContext context) {
    final sender = email.from.isNotEmpty
        ? (email.from.first.name ?? email.from.first.email)
        : '(unknown)';
    final date = email.sentAt != null ? _dateFmt.format(email.sentAt!) : '';

    return ListTile(
      leading:
          leading ??
          Icon(
            email.isSeen ? Icons.mail_outline : Icons.mail,
            color: email.isSeen ? null : Theme.of(context).colorScheme.primary,
          ),
      title: Text(
        sender,
        style: email.isSeen
            ? null
            : const TextStyle(fontWeight: FontWeight.bold),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            email.subject ?? '(no subject)',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (showLocation)
            Text(
              '${email.accountId} • ${email.mailboxPath}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
      trailing: date.isEmpty
          ? null
          : Text(date, style: Theme.of(context).textTheme.bodySmall),
      selected: selected,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}
