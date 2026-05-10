import 'package:sharedinbox/core/models/email.dart';

enum UndoType { move, delete }

class UndoAction {
  UndoAction({
    required this.id,
    required this.accountId,
    required this.type,
    required this.emailIds,
    required this.sourceMailboxPath,
    this.destinationMailboxPath,
    this.originalEmails = const [],
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  final String id;
  final String accountId;
  final UndoType type;
  final List<String> emailIds;
  final String sourceMailboxPath;
  final String? destinationMailboxPath;
  final DateTime timestamp;

  /// Full email data for restoring hard-deleted rows (e.g. IMAP move/delete).
  final List<Email> originalEmails;

  String get description {
    final count = emailIds.length;
    final s = count == 1 ? '' : 's';
    if (type == UndoType.delete) {
      return 'Deleted $count email$s from $sourceMailboxPath';
    } else {
      return 'Moved $count email$s from $sourceMailboxPath to $destinationMailboxPath';
    }
  }
}
