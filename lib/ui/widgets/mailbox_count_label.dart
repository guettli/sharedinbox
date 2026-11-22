import 'dart:math' show max;

import 'package:flutter/material.dart';

/// Trailing label for a mailbox tile that shows "unread / total".
///
/// An empty folder renders a bare `0` (rather than nothing) so it is visibly
/// distinct from a folder whose count has not been computed yet (#498). The
/// unread portion is bolded when [unread] is greater than zero. The total
/// shown is never below [unread]: a folder with unread mail never reads
/// `0` (#1333).
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
    final baseStyle = Theme.of(context).textTheme.bodySmall;
    final shownTotal = max(total, unread);
    if (shownTotal <= 0) return Text('0', style: baseStyle);

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
          TextSpan(text: ' / $shownTotal'),
        ],
      ),
    );
  }
}
