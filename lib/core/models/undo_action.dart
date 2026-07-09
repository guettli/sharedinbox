import 'package:sharedinbox/core/models/email.dart';

enum UndoType { move, delete, snooze }

class UndoAction {
  UndoAction({
    required this.id,
    required this.accountId,
    required this.type,
    required this.emailIds,
    required this.sourceMailboxPath,
    this.destinationMailboxPath,
    this.destinationMailboxRole,
    this.originalEmails = const [],
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  final String id;
  final String accountId;
  final UndoType type;
  final List<String> emailIds;
  final String sourceMailboxPath;
  final String? destinationMailboxPath;

  /// Semantic role of the destination mailbox (e.g. 'archive', 'junk') for
  /// move actions. Lets the undo snackbar pick action-specific colour/icon/
  /// verb; undo semantics don't depend on it.
  final String? destinationMailboxRole;
  final DateTime timestamp;

  /// Full email data for restoring hard-deleted rows (e.g. IMAP move/delete).
  final List<Email> originalEmails;

  factory UndoAction.fromJson(Map<String, dynamic> json) {
    return UndoAction(
      id: json['id'] as String,
      accountId: json['accountId'] as String,
      type: UndoType.values.firstWhere((e) => e.name == json['type']),
      emailIds: List<String>.from(json['emailIds'] as List),
      sourceMailboxPath: json['sourceMailboxPath'] as String,
      destinationMailboxPath: json['destinationMailboxPath'] as String?,
      destinationMailboxRole: json['destinationMailboxRole'] as String?,
      timestamp: DateTime.parse(json['timestamp'] as String),
      originalEmails: (json['originalEmails'] as List<dynamic>)
          .map((e) => Email.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'accountId': accountId,
      'type': type.name,
      'emailIds': emailIds,
      'sourceMailboxPath': sourceMailboxPath,
      'destinationMailboxPath': destinationMailboxPath,
      'destinationMailboxRole': destinationMailboxRole,
      'timestamp': timestamp.toIso8601String(),
      'originalEmails': originalEmails.map((e) => e.toJson()).toList(),
    };
  }

  String get description {
    final count = emailIds.length;
    final s = count == 1 ? '' : 's';
    if (type == UndoType.delete) {
      return 'Deleted $count email$s from $sourceMailboxPath';
    } else if (type == UndoType.snooze) {
      return 'Snoozed $count email$s from $sourceMailboxPath';
    } else {
      return 'Moved $count email$s from $sourceMailboxPath to $destinationMailboxPath';
    }
  }
}
