sealed class SieveAction {}

final class FileIntoAction extends SieveAction {
  FileIntoAction(this.folder);
  final String folder;
}

final class KeepAction extends SieveAction {}

final class DiscardAction extends SieveAction {}

final class MarkAsSeenAction extends SieveAction {}

final class StarMessageAction extends SieveAction {}

final class FlagAction extends SieveAction {
  FlagAction(this.flags);
  final List<String> flags;
}

/// Builds the action for a `setflag` / `addflag` flag list. Only a list
/// holding exactly `\Seen` or exactly `\Flagged` becomes the dedicated
/// mark-read / star action; anything else (several flags, keywords) stays a
/// [FlagAction] so no flag is lost.
SieveAction sieveFlagAction(List<String> flags) {
  if (flags.length == 1) {
    final f = flags.single.trim().toLowerCase();
    if (f == r'\seen' || f == r'\\seen') return MarkAsSeenAction();
    if (f == r'\flagged' || f == r'\\flagged') return StarMessageAction();
  }
  return FlagAction(flags);
}
