import 'package:sharedinbox/core/models/email.dart';

enum UndoType { move, delete }

class UndoAction {
  const UndoAction({
    required this.id,
    required this.accountId,
    required this.type,
    required this.emailIds,
    required this.sourceMailboxPath,
    this.destinationMailboxPath,
    this.originalEmails = const [],
  });

  final String id;
  final String accountId;
  final UndoType type;
  final List<String> emailIds;
  final String sourceMailboxPath;
  final String? destinationMailboxPath;

  /// Full email data for restoring hard-deleted rows (e.g. IMAP move/delete).
  final List<Email> originalEmails;
}
