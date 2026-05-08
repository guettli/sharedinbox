enum UndoType { move, delete }

class UndoAction {
  const UndoAction({
    required this.id,
    required this.accountId,
    required this.type,
    required this.emailIds,
    required this.sourceMailboxPath,
    this.destinationMailboxPath,
  });

  final String id;
  final String accountId;
  final UndoType type;
  final List<String> emailIds;
  final String sourceMailboxPath;
  final String? destinationMailboxPath;
}
