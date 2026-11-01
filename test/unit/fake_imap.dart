import 'package:enough_mail/enough_mail.dart' as imap;
// ignore: implementation_imports
import 'package:enough_mail/src/private/util/client_base.dart'
    show ConnectionInfo;

/// Minimal fake IMAP client used by connection_test_service_test.dart.
/// Only overrides what is strictly needed to avoid real network calls.
class FakeImapClient extends imap.ImapClient {
  FakeImapClient() : super();

  @override
  final imap.ImapServerInfo serverInfo = imap.ImapServerInfo(
    const ConnectionInfo('fake.host', 993, isSecure: true),
  )..capabilities = [];

  @override
  Future<dynamic> logout() async {}
}

/// [FakeImapClient] whose SELECT succeeds for any path, returning an empty
/// mailbox of that name — or throws [selectError] when one is given.
class SelectingFakeImapClient extends FakeImapClient {
  SelectingFakeImapClient({this.selectError});

  final Object? selectError;

  @override
  Future<imap.Mailbox> selectMailboxByPath(
    String path, {
    bool enableCondStore = false,
    imap.QResyncParameters? qresync,
  }) async {
    if (selectError case final error?) throw error;
    return fakeMailbox(path);
  }
}

/// An empty, flagless mailbox at [path].
imap.Mailbox fakeMailbox(String path) => imap.Mailbox(
      encodedName: path,
      encodedPath: path,
      pathSeparator: '/',
      flags: [],
    );

/// Answers LIST with [listedMailboxes].
mixin StubMailboxList on imap.ImapClient {
  List<imap.Mailbox> get listedMailboxes;

  @override
  Future<List<imap.Mailbox>> listMailboxes({
    String path = '""',
    bool recursive = false,
    List<String>? mailboxPatterns,
    List<String>? selectionOptions,
    List<imap.ReturnOption>? returnOptions,
  }) async =>
      listedMailboxes;
}

/// Spy IMAP client that records snooze-related operations and succeeds silently.
class SnoozeSpyImapClient extends FakeImapClient with StubMailboxList {
  SnoozeSpyImapClient({
    this.copyUidValidity,
    this.copyUidSourceToTarget = const {},
    this.searchResults = const {},
    this.searchResultsByMailbox,
    this.onSearch,
    this.onUidMove,
    this.messageFlags,
  });

  /// When non-null, the flags a `UID FETCH … FLAGS` reports for the message.
  final List<String>? messageFlags;

  /// Every `UID STORE` and `UID MOVE`, in call order, as
  /// `'store <add|remove|…> <uids> <flags>'` / `'move <mailbox>:<uids>-><target>'`.
  final List<String> calls = [];

  String? selectedMailbox;
  String? createdMailbox;
  String? movedToMailbox;
  String? lastSearchCriteria;

  /// The `encodedPath` of the box handed to the most recent RENAME / DELETE —
  /// i.e. exactly what enough_mail would write onto the wire. Lets tests assert
  /// the source folder is sent in modified UTF-7 rather than raw Unicode.
  String? renamedFromEncodedPath;
  String? renamedToName;
  String? deletedEncodedPath;

  /// When non-null, `uidMove` returns a `COPYUID` response code built from
  /// these mappings (sourceUid → destinationUid) for the moved sequence.
  final int? copyUidValidity;
  final Map<int, int> copyUidSourceToTarget;

  /// Maps a `UID SEARCH HEADER Message-ID …` search criteria (the literal
  /// IMAP atom incl. quotes) to the UIDs the fake should return.
  final Map<String, List<int>> searchResults;

  /// When non-null, replaces [searchResults]: the UIDs any search returns in
  /// the currently selected mailbox (keyed by path).
  final Map<String, List<int>>? searchResultsByMailbox;

  /// When non-null, replaces both maps above: the UIDs a search returns given
  /// the selected mailbox and the criteria, e.g. to model a server whose
  /// index only catches up on a later search.
  final List<int> Function(String? mailbox, String criteria)? onSearch;

  /// Called at the start of every `uidMove`, e.g. to race an Undo against an
  /// in-flight flush.
  final Future<void> Function()? onUidMove;

  /// Every `uidMove` as `'<selected mailbox>:<uids>-><target>'`.
  final List<String> moves = [];

  @override
  Future<imap.Mailbox> selectMailboxByPath(
    String path, {
    bool enableCondStore = false,
    imap.QResyncParameters? qresync,
  }) async {
    selectedMailbox = path;
    return fakeMailbox(path);
  }

  @override
  Future<imap.Mailbox> createMailbox(String path) async {
    createdMailbox = path;
    return fakeMailbox(path);
  }

  @override
  Future<imap.Mailbox> renameMailbox(imap.Mailbox box, String newName) async {
    renamedFromEncodedPath = box.encodedPath;
    renamedToName = newName;
    return fakeMailbox(newName);
  }

  /// What `STATUS … (MESSAGES)` reports for any mailbox.
  int statusMessages = 0;

  @override
  Future<imap.Mailbox> statusMailbox(
    imap.Mailbox box,
    List<imap.StatusFlags> flags,
  ) async =>
      box..messagesExists = statusMessages;

  @override
  Future<imap.Mailbox> deleteMailbox(imap.Mailbox box) async {
    deletedEncodedPath = box.encodedPath;
    return box;
  }

  @override
  List<imap.Mailbox> get listedMailboxes => [fakeMailbox('INBOX')];

  @override
  Future<imap.StoreImapResult> uidStore(
    imap.MessageSequence sequence,
    List<String> flags, {
    imap.StoreAction? action,
    bool? silent,
    int? unchangedSinceModSequence,
  }) async {
    calls.add(
      'store ${action?.name} ${sequence.toList().join(',')} ${flags.join(' ')}',
    );
    return imap.StoreImapResult();
  }

  @override
  Future<imap.GenericImapResult> uidMove(
    imap.MessageSequence sequence, {
    imap.Mailbox? targetMailbox,
    String? targetMailboxPath,
  }) async {
    await onUidMove?.call();
    movedToMailbox = targetMailboxPath;
    moves.add(
      '$selectedMailbox:${sequence.toList().join(',')}->$targetMailboxPath',
    );
    calls.add('move ${moves.last}');
    final result = imap.GenericImapResult();
    if (copyUidValidity != null && copyUidSourceToTarget.isNotEmpty) {
      final sources = sequence.toList();
      final mapped = sources
          .where(copyUidSourceToTarget.containsKey)
          .map((uid) => copyUidSourceToTarget[uid]!)
          .toList();
      if (mapped.isNotEmpty) {
        final src = sources.join(',');
        final dst = mapped.join(',');
        result.responseCode = 'COPYUID $copyUidValidity $src $dst';
      }
    }
    return result;
  }

  @override
  Future<imap.SearchImapResult> uidSearchMessages({
    String searchCriteria = 'UNSEEN',
    List<imap.ReturnOption>? returnOptions,
    Duration? responseTimeout,
  }) async {
    lastSearchCriteria = searchCriteria;
    final hits = onSearch?.call(selectedMailbox, searchCriteria) ??
        (searchResultsByMailbox != null
            ? searchResultsByMailbox![selectedMailbox] ?? const <int>[]
            : searchResults[searchCriteria] ?? const <int>[]);
    final result = imap.SearchImapResult()
      ..matchingSequence = imap.MessageSequence.fromIds(hits, isUid: true);
    return result;
  }

  @override
  Future<imap.FetchImapResult> uidFetchMessages(
    imap.MessageSequence sequence,
    String? fetchContentDefinition, {
    int? changedSinceModSequence,
    Duration? responseTimeout,
  }) async {
    final flags = messageFlags;
    if (flags == null) return const imap.FetchImapResult([], null);
    return imap.FetchImapResult([imap.MimeMessage()..flags = flags], null);
  }
}

/// Minimal fake SMTP client; only `quit` is exercised by ConnectionTestService.
class FakeSmtpClient extends imap.SmtpClient {
  FakeSmtpClient() : super('fake.host');

  @override
  Future<imap.SmtpResponse> quit() async => imap.SmtpResponse(const []);
}

/// Fake SMTP client whose `sendMessage` accepts the message (`250 OK`), or —
/// with [rejectWith] — fails it the way enough_mail does for a 4xx/5xx reply,
/// by throwing an [imap.SmtpException] carrying those response lines.
class ScriptedSmtpClient extends FakeSmtpClient {
  ScriptedSmtpClient({this.rejectWith});

  final List<String>? rejectWith;

  @override
  Future<imap.SmtpResponse> sendMessage(
    imap.MimeMessage message, {
    bool use8BitEncoding = false,
    imap.MailAddress? from,
    List<imap.MailAddress>? recipients,
  }) async {
    final reject = rejectWith;
    if (reject != null) {
      throw imap.SmtpException(this, imap.SmtpResponse(reject));
    }
    return imap.SmtpResponse(const ['250 OK']);
  }
}
