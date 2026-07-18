import 'package:flutter/material.dart';

/// Trailing label for a mailbox tile that shows "unread / total".
///
/// Renders nothing when [total] is zero, so empty folders stay uncluttered.
/// The unread portion is bolded when [unread] is greater than zero.
class MailboxCountLabel extends StatelessWidget {
  const MailboxCountLabel({
    super.key,
    required this.unread,
    required this.total,
  });

  final int unread;
  final int total;

  @override
  Widget build(BuildContext context) {
    if (total <= 0) return const SizedBox.shrink();

    final baseStyle = Theme.of(context).textTheme.bodySmall;
    final hasUnread = unread > 0;

    return Text.rich(
      TextSpan(
        style: baseStyle,
        children: [
          TextSpan(
            text: '$unread',
            style:
                hasUnread ? const TextStyle(fontWeight: FontWeight.bold) : null,
          ),
          TextSpan(text: ' / $total'),
        ],
      ),
    );
  }
}
