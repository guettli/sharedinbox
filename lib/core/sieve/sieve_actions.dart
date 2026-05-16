sealed class SieveAction {}

final class FileIntoAction extends SieveAction {
  FileIntoAction(this.folder);
  final String folder;
}

final class KeepAction extends SieveAction {}

final class DiscardAction extends SieveAction {}

final class MarkAsSeenAction extends SieveAction {}

final class FlagAction extends SieveAction {
  FlagAction(this.flags);
  final List<String> flags;
}
