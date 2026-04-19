import 'package:enough_mail/enough_mail.dart' as imap;

/// Configurable fake IMAP client that extends the real ImapClient but
/// overrides every network method to return pre-set data.
class FakeImapClient extends imap.ImapClient {
  FakeImapClient() : super();

  List<imap.MimeMessage> fetchResults = [];
  List<imap.Mailbox> listMailboxesResult = [];
  List<int> searchUids = [];
  /// If set, each [uidSearchMessages] call pops the first element.
  /// Falls back to [searchUids] when the queue is empty or null.
  List<List<int>>? searchCallQueue;
  int uidValidityResult = 0;
  bool logoutCalled = false;
  bool throwOnStatus = false;
  int markSeenCalls = 0;
  int markUnseenCalls = 0;
  int markFlaggedCalls = 0;
  int markUnflaggedCalls = 0;
  int markDeletedCalls = 0;
  int expungeCalls = 0;
  int moveEmailCalls = 0;
  int appendCalls = 0;
  String? lastAppendMailboxPath;
  int createMailboxCalls = 0;

  @override
  Future<imap.Mailbox> selectMailboxByPath(
    String path, {
    bool enableCondStore = false,
    imap.QResyncParameters? qresync,
  }) async =>
      imap.Mailbox(
        encodedName: path,
        encodedPath: path,
        flags: [],
        pathSeparator: '/',
        uidValidity: uidValidityResult,
      );

  @override
  Future<imap.FetchImapResult> fetchMessages(
    imap.MessageSequence sequence,
    String? fetchContentDefinition, {
    int? changedSinceModSequence,
    Duration? responseTimeout,
  }) async =>
      imap.FetchImapResult(List.of(fetchResults), null);

  @override
  Future<imap.FetchImapResult> uidFetchMessage(
    int messageUid,
    String fetchContentDefinition, {
    Duration? responseTimeout,
  }) async =>
      imap.FetchImapResult(
        fetchResults.isEmpty ? [] : [fetchResults.first],
        null,
      );

  @override
  Future<imap.StoreImapResult> uidMarkSeen(
    imap.MessageSequence sequence, {
    bool? silent,
    int? unchangedSinceModSequence,
  }) async {
    markSeenCalls++;
    return imap.StoreImapResult();
  }

  @override
  Future<imap.StoreImapResult> uidMarkUnseen(
    imap.MessageSequence sequence, {
    bool? silent,
    int? unchangedSinceModSequence,
  }) async {
    markUnseenCalls++;
    return imap.StoreImapResult();
  }

  @override
  Future<imap.StoreImapResult> uidMarkFlagged(
    imap.MessageSequence sequence, {
    bool? silent,
    int? unchangedSinceModSequence,
  }) async {
    markFlaggedCalls++;
    return imap.StoreImapResult();
  }

  @override
  Future<imap.StoreImapResult> uidMarkUnflagged(
    imap.MessageSequence sequence, {
    bool? silent,
    int? unchangedSinceModSequence,
  }) async {
    markUnflaggedCalls++;
    return imap.StoreImapResult();
  }

  @override
  Future<imap.StoreImapResult> uidMarkDeleted(
    imap.MessageSequence sequence, {
    bool? silent,
    int? unchangedSinceModSequence,
  }) async {
    markDeletedCalls++;
    return imap.StoreImapResult();
  }

  @override
  Future<imap.Mailbox?> uidExpunge(imap.MessageSequence sequence) async {
    expungeCalls++;
    return null;
  }

  @override
  Future<imap.Mailbox> createMailbox(String path) async {
    createMailboxCalls++;
    return imap.Mailbox(
      encodedName: path,
      encodedPath: path,
      flags: [],
      pathSeparator: '/',
    );
  }

  @override
  Future<imap.GenericImapResult> appendMessage(
    imap.MimeMessage message, {
    List<String>? flags,
    imap.Mailbox? targetMailbox,
    String? targetMailboxPath,
    Duration? responseTimeout,
  }) async {
    appendCalls++;
    lastAppendMailboxPath = targetMailboxPath;
    return imap.GenericImapResult();
  }

  @override
  Future<imap.GenericImapResult> uidMove(
    imap.MessageSequence sequence, {
    imap.Mailbox? targetMailbox,
    String? targetMailboxPath,
  }) async {
    moveEmailCalls++;
    return imap.GenericImapResult();
  }

  @override
  Future<imap.SearchImapResult> uidSearchMessages({
    String searchCriteria = 'UNSEEN',
    List<imap.ReturnOption>? returnOptions,
    Duration? responseTimeout,
  }) async {
    final uids = (searchCallQueue != null && searchCallQueue!.isNotEmpty)
        ? searchCallQueue!.removeAt(0)
        : searchUids;
    final result = imap.SearchImapResult();
    if (uids.isNotEmpty) {
      result.matchingSequence =
          imap.MessageSequence.fromIds(uids, isUid: true);
    }
    return result;
  }

  @override
  Future<List<imap.Mailbox>> listMailboxes({
    String path = '""',
    bool recursive = false,
    List<String>? mailboxPatterns,
    List<String>? selectionOptions,
    List<imap.ReturnOption>? returnOptions,
  }) async =>
      List.of(listMailboxesResult);

  @override
  Future<imap.Mailbox> statusMailbox(
    imap.Mailbox box,
    List<imap.StatusFlags> flags,
  ) async {
    if (throwOnStatus) throw Exception('STATUS not supported');
    return imap.Mailbox(
      encodedName: box.encodedName,
      encodedPath: box.encodedPath,
      flags: [],
      pathSeparator: '/',
      messagesUnseen: 3,
      messagesExists: 10,
    );
  }

  @override
  Future<dynamic> logout() async {
    logoutCalled = true;
  }
}

/// Configurable fake SMTP client.
class FakeSmtpClient extends imap.SmtpClient {
  FakeSmtpClient() : super('fake.domain');

  bool messageSent = false;
  bool quitCalled = false;
  imap.MimeMessage? lastSentMessage;

  @override
  Future<imap.SmtpResponse> sendMessage(
    imap.MimeMessage message, {
    bool use8BitEncoding = false,
    imap.MailAddress? from,
    List<imap.MailAddress>? recipients,
  }) async {
    messageSent = true;
    lastSentMessage = message;
    return imap.SmtpResponse(['250 OK']);
  }

  @override
  Future<imap.SmtpResponse> quit() async {
    quitCalled = true;
    return imap.SmtpResponse(['221 Bye']);
  }
}

/// Builds a [MimeMessage] with no envelope (simulates a malformed FETCH row
/// that should be skipped by the repository).
imap.MimeMessage buildMessageWithoutEnvelope() => imap.MimeMessage()..uid = 99;

/// Builds a [MimeMessage] that looks like an ENVELOPE fetch result.
imap.MimeMessage buildEnvelopeMessage({
  required int uid,
  String subject = 'Test Subject',
  DateTime? date,
  String fromEmail = 'sender@example.com',
  List<String> flags = const [],
}) {
  final envelope = imap.Envelope(
    subject: subject,
    date: date ?? DateTime(2024, 1, 15),
    from: [imap.MailAddress('Sender', fromEmail)],
    to: [const imap.MailAddress('Recipient', 'recipient@example.com')],
    cc: [],
  );
  return imap.MimeMessage.fromEnvelope(
    envelope,
    uid: uid,
    flags: List.of(flags),
  );
}
