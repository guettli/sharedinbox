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

/// Spy IMAP client that records snooze-related operations and succeeds silently.
class SnoozeSpyImapClient extends FakeImapClient {
  SnoozeSpyImapClient({
    this.copyUidValidity,
    this.copyUidSourceToTarget = const {},
    this.searchResults = const {},
  });

  String? selectedMailbox;
  String? createdMailbox;
  String? movedToMailbox;
  String? lastSearchCriteria;

  /// When non-null, `uidMove` returns a `COPYUID` response code built from
  /// these mappings (sourceUid → destinationUid) for the moved sequence.
  final int? copyUidValidity;
  final Map<int, int> copyUidSourceToTarget;

  /// Maps a `UID SEARCH HEADER Message-ID …` search criteria (the literal
  /// IMAP atom incl. quotes) to the UIDs the fake should return.
  final Map<String, List<int>> searchResults;

  imap.Mailbox _fakeMailbox(String path) => imap.Mailbox(
        encodedName: path,
        encodedPath: path,
        pathSeparator: '/',
        flags: [],
      );

  @override
  Future<imap.Mailbox> selectMailboxByPath(
    String path, {
    bool enableCondStore = false,
    imap.QResyncParameters? qresync,
  }) async {
    selectedMailbox = path;
    return _fakeMailbox(path);
  }

  @override
  Future<imap.Mailbox> createMailbox(String path) async {
    createdMailbox = path;
    return _fakeMailbox(path);
  }

  @override
  Future<imap.StoreImapResult> uidStore(
    imap.MessageSequence sequence,
    List<String> flags, {
    imap.StoreAction? action,
    bool? silent,
    int? unchangedSinceModSequence,
  }) async =>
      imap.StoreImapResult();

  @override
  Future<imap.GenericImapResult> uidMove(
    imap.MessageSequence sequence, {
    imap.Mailbox? targetMailbox,
    String? targetMailboxPath,
  }) async {
    movedToMailbox = targetMailboxPath;
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
    final hits = searchResults[searchCriteria] ?? const <int>[];
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
  }) async =>
      const imap.FetchImapResult([], null);
}

/// Minimal fake SMTP client; only `quit` is exercised by ConnectionTestService.
class FakeSmtpClient extends imap.SmtpClient {
  FakeSmtpClient() : super('fake.host');

  @override
  Future<imap.SmtpResponse> quit() async => imap.SmtpResponse(const []);
}
