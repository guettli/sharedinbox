import 'dart:collection';

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:sharedinbox/data/imap/mailbox_id_status.dart';

import '../fake_imap.dart'
    show FakeImapClient, StaleAnswerHook, StoreAndMove, fakeMailbox;

/// A message delivered with a Message-ID starting with this has no
/// Message-ID header: the id only names it in the test.
const noMessageIdPrefix = 'no-message-id:';

/// One message on a [StatefulFakeImapServer].
class FakeServerMessage {
  FakeServerMessage({
    required this.uid,
    required this.messageId,
    required this.modSeq,
    Iterable<String> flags = const [],
    String? emailId,
    this.messageIdHeader,
  })  : flags = {...flags},
        emailId = emailId ?? 'E-$messageId';

  /// The raw `Message-ID` header of the message body, when it differs from
  /// the envelope's `<messageId>` (a relay's comment after it, a different
  /// folding); empty: the body has no such header. Null: `<messageId>`.
  final String? messageIdHeader;

  int uid;
  int modSeq;

  /// The bare Message-ID (no angle brackets), unique on the server.
  final String messageId;
  final Set<String> flags;

  /// The move-stable EMAILID (RFC 8474) the server reports when it
  /// advertises OBJECTID; Gmail gives each label folder's copy the same one.
  final String emailId;

  bool get seen => flags.contains(r'\Seen');
  bool get flagged => flags.contains(r'\Flagged');
}

/// One folder on a [StatefulFakeImapServer], messages keyed by UID.
class FakeServerFolder {
  FakeServerFolder(this.path, this.uidValidity, {this.mailboxId});

  final String path;
  final int uidValidity;

  /// The folder's RFC 8474 `MAILBOXID`, which a rename keeps; STATUS gives
  /// it when the server advertises OBJECTID. Null: none.
  final String? mailboxId;
  int uidNext = 1;
  int highestModSeq = 1;
  final SplayTreeMap<int, FakeServerMessage> messages = SplayTreeMap();
}

/// A change an app connection made on the server: a `STORE` (one entry per
/// flag, e.g. `STORE +\Seen`), `MOVE <src>-><dest>` or `EXPUNGE`, with the
/// Message-ID of the message it hit. Changes made through
/// [StatefulFakeImapServer]'s "other client" methods are not recorded.
typedef FakeServerHit = ({String command, String messageId});

/// An in-memory IMAP server with a few folders, holding UIDs, Message-IDs,
/// flags, UIDVALIDITY and MODSEQ — just what the sync and flush paths of
/// `EmailRepositoryImpl` ask for. Every [connect] returns a new connection
/// ([StatefulFakeImapClient]) with its own selected folder, all sharing this
/// state.
///
/// Stale answers: [beforeAnswer] (from [StaleAnswerHook]) runs after a
/// command's answer is fixed — for a write, after the server applied it — and
/// before the app gets it, with the command (e.g. `FETCH FLAGS` or `MOVE`)
/// and the selected folder.
class StatefulFakeImapServer with StaleAnswerHook {
  StatefulFakeImapServer({
    required Map<String, int> uidValidityByFolder,
    this.uidPlus = true,
    this.objectIds = false,
  }) {
    for (final MapEntry(key: path, value: validity)
        in uidValidityByFolder.entries) {
      folders[path] = FakeServerFolder(path, validity, mailboxId: _newId());
    }
  }

  /// Whether connections advertise UIDPLUS (`COPYUID` on MOVE).
  final bool uidPlus;

  /// Whether connections advertise OBJECTID (RFC 8474): each message then
  /// has a move-stable EMAILID, by default `E-<Message-ID>`
  /// ([FakeServerMessage.emailId], [StatefulFakeImapClient.emailIdsOf]).
  final bool objectIds;

  final Map<String, FakeServerFolder> folders = {};
  final List<FakeServerHit> hits = [];

  /// When it returns true for a folder path, `CREATE` / `RENAME` to that
  /// path is refused with `NO [CANNOT]`: a permanent server error.
  bool Function(String path)? refusesFolder;

  /// UIDVALIDITY of the next folder a `CREATE` makes.
  int nextUidValidity = 900;

  /// Every `CREATE`, `RENAME` and `DELETE` an app connection sent, as
  /// `CREATE <path>` / `RENAME <from>-><to>` / `DELETE <path>`.
  final List<String> folderCommands = [];

  /// When set, a `DELETE` fails with a plain `NO` (no response code): a
  /// failure that may pass, retried.
  bool failDeletes = false;

  /// When it returns true for a folder path, LIST leaves the folder out
  /// although it exists: a partial or empty listing (a glitch, #1312).
  bool Function(String path)? listHides;

  /// When it returns a text for a folder path, `SELECT` of it fails with
  /// that `NO`, whether the folder exists or not (#1312).
  String? Function(String path)? selectError;

  /// When it returns a text for a folder path, `STATUS` of it fails with
  /// that `NO`, whether the folder exists or not (#1312).
  String? Function(String path)? statusError;

  /// How many LISTs app connections sent.
  int listCount = 0;

  /// How many `STATUS … (MAILBOXID)` app connections sent.
  int mailboxIdStatusCount = 0;

  /// When set, `STATUS … (MAILBOXID)` is refused with `BAD` although the
  /// server advertises OBJECTID.
  bool refusesMailboxIdStatus = false;

  /// When set, `UID SEARCH ALL` lists no message although the folders have
  /// some (a server whose index lags, or a glitch).
  bool searchAllEmpty = false;

  /// Another client deletes folder [path] (with its messages).
  void deleteFolder(String path) => folders.remove(path);

  /// Another client creates (or this test sets up) folder [path].
  FakeServerFolder addFolder(String path) => folders[path] =
      FakeServerFolder(path, nextUidValidity++, mailboxId: _newId());

  int _mailboxIds = 0;
  String _newId() => 'F${++_mailboxIds}';

  /// Another client renames folder [from] to [to], with its subfolders
  /// (`/` is the hierarchy separator; messages, UIDs and the MAILBOXID
  /// kept). The UIDVALIDITY is kept too, unless [newUidValidity]: then each
  /// renamed folder gets a fresh one, as Stalwart does.
  void renameFolder(String from, String to, {bool newUidValidity = false}) {
    for (final path in folders.keys.toList()) {
      if (path != from && !path.startsWith('$from/')) continue;
      final old = folders.remove(path)!;
      final newPath = '$to${path.substring(from.length)}';
      final renamed = FakeServerFolder(
        newPath,
        newUidValidity ? nextUidValidity++ : old.uidValidity,
        mailboxId: old.mailboxId,
      )
        ..uidNext = old.uidNext
        ..highestModSeq = old.highestModSeq;
      renamed.messages.addAll(old.messages);
      folders[newPath] = renamed;
    }
  }

  /// When set, a `CREATE` fails with a plain `NO` (no response code): a
  /// failure that may pass, retried.
  bool failCreates = false;

  /// When it returns true for a message, every `STORE` and `MOVE` touching
  /// it is refused with `NO`: a permanent server error.
  bool Function(String messageId)? refuses;

  /// When it returns an error for a command (`SELECT`, `STORE`, `MOVE`,
  /// `EXPUNGE` for both kinds, `STATUS`, `CREATE`, `RENAME` or `DELETE`),
  /// the command throws it before it changes anything: e.g. [badAnswer], or
  /// a `SocketException`.
  Object? Function(String command)? failBefore;

  /// The [imap.ImapException] enough_mail throws for a tagged `BAD` [text]:
  /// unlike a `NO`, its message keeps the `BAD ` status word.
  static imap.ImapException badAnswer(String text) =>
      imap.ImapException(imap.ImapClient(), 'BAD $text');

  int _modSeq = 1;

  StatefulFakeImapClient connect() => StatefulFakeImapClient(this);

  /// Where [messageId] is now, or null when it is gone.
  ({FakeServerFolder folder, FakeServerMessage message})? find(
    String messageId,
  ) {
    for (final folder in folders.values) {
      for (final message in folder.messages.values) {
        if (message.messageId == messageId) {
          return (folder: folder, message: message);
        }
      }
    }
    return null;
  }

  /// Delivers a new message to [path], as SMTP would.
  FakeServerMessage deliver(
    String path,
    String messageId, {
    Iterable<String> flags = const [],
    String? emailId,
    String? messageIdHeader,
  }) {
    final folder = folders[path]!;
    final message = FakeServerMessage(
      uid: folder.uidNext++,
      messageId: messageId,
      modSeq: _bump(folder),
      flags: flags,
      emailId: emailId,
      messageIdHeader: messageIdHeader,
    );
    folder.messages[message.uid] = message;
    return message;
  }

  /// Another client sets or clears [flag] on [messageId].
  void setFlagElsewhere(String messageId, String flag, {required bool on}) {
    final found = find(messageId)!;
    on ? found.message.flags.add(flag) : found.message.flags.remove(flag);
    found.message.modSeq = _bump(found.folder);
  }

  /// Another client moves [messageId] to [dest].
  void moveElsewhere(String messageId, String dest) {
    final found = find(messageId)!;
    _move(found.folder, found.message, folders[dest]!);
  }

  /// Another client expunges [messageId].
  void expungeElsewhere(String messageId) {
    final found = find(messageId)!;
    found.folder.messages.remove(found.message.uid);
    _bump(found.folder);
  }

  /// The server renumbers folder [path] (a UIDVALIDITY change: e.g. the
  /// folder was deleted and made again with the same mail): it gets
  /// [uidValidity], and its messages, with their Message-IDs, flags and
  /// EMAILIDs, get new UIDs from 1, in reverse order when [reverse] (so
  /// that an old UID names another mail now).
  void renumberFolder(String path, int uidValidity, {bool reverse = false}) {
    final old = folders[path]!;
    final renumbered = folders[path] =
        FakeServerFolder(path, uidValidity, mailboxId: old.mailboxId);
    final messages = old.messages.values.toList();
    for (final m in reverse ? messages.reversed : messages) {
      final message = FakeServerMessage(
        uid: renumbered.uidNext++,
        messageId: m.messageId,
        modSeq: _bump(renumbered),
        flags: m.flags,
        emailId: m.emailId,
        messageIdHeader: m.messageIdHeader,
      );
      renumbered.messages[message.uid] = message;
    }
  }

  int _bump(FakeServerFolder folder) => folder.highestModSeq = ++_modSeq;

  int _move(
    FakeServerFolder src,
    FakeServerMessage message,
    FakeServerFolder dest,
  ) {
    src.messages.remove(message.uid);
    _bump(src);
    message
      ..uid = dest.uidNext++
      ..modSeq = _bump(dest);
    dest.messages[message.uid] = message;
    return message.uid;
  }
}

/// One connection to a [StatefulFakeImapServer].
class StatefulFakeImapClient extends FakeImapClient with StoreAndMove {
  StatefulFakeImapClient(this.server) {
    serverInfo.capabilities = [
      const imap.Capability('CONDSTORE'),
      const imap.Capability('MOVE'),
      if (server.uidPlus) const imap.Capability('UIDPLUS'),
      if (server.objectIds) const imap.Capability('OBJECTID'),
    ];
  }

  /// The EMAILID of each message of the selected folder that [sequence]
  /// names, by UID, as `FETCH (EMAILID)` would answer.
  Future<Map<int, String>> emailIdsOf(imap.MessageSequence sequence) =>
      _answer('FETCH EMAILID', {
        for (final message in _named(sequence)) message.uid: message.emailId,
      });

  final StatefulFakeImapServer server;
  FakeServerFolder? _selected;

  FakeServerFolder get _folder =>
      _selected ?? (throw StateError('fake IMAP: no mailbox selected'));

  Future<T> _answer<T>(String command, T answer) =>
      server.answerLate('$command (${_selected?.path})', answer);

  imap.ImapException _no(String text) => imap.ImapException(this, text);

  /// The messages of the selected folder that [sequence] names.
  List<FakeServerMessage> _named(imap.MessageSequence sequence) {
    final messages = _folder.messages;
    if (sequence.containsLast()) {
      // The app only sends `1:*` (all messages); `n:*` would need the
      // RFC 3501 §6.4.4 rule [_search] implements.
      if (sequence.toString() != '1:*') {
        throw UnsupportedError('fake IMAP: sequence $sequence');
      }
      return messages.values.toList();
    }
    return [
      for (final uid in sequence.toList())
        if (messages[uid] case final message?) message,
    ];
  }

  /// Throws what [StatefulFakeImapServer.failBefore] returns for [command].
  void _failBefore(String command) {
    final error = server.failBefore?.call(command);
    if (error != null) throw error;
  }

  void _checkAllowed(List<FakeServerMessage> messages) {
    final refuses = server.refuses;
    if (refuses == null) return;
    for (final message in messages) {
      if (refuses(message.messageId)) {
        throw _no('NO [CANNOT] refused by the test server');
      }
    }
  }

  @override
  Future<List<imap.Mailbox>> listMailboxes({
    String path = '""',
    bool recursive = false,
    List<String>? mailboxPatterns,
    List<String>? selectionOptions,
    List<imap.ReturnOption>? returnOptions,
  }) {
    server.listCount++;
    return _answer('LIST', [
      for (final f in server.folders.values)
        if (!(server.listHides?.call(f.path) ?? false))
          imap.Mailbox(
            encodedName: f.path.split('/').last,
            encodedPath: f.path,
            pathSeparator: '/',
            flags: [],
          ),
    ]);
  }

  @override
  Future<imap.Mailbox> createMailbox(String path) async {
    _failBefore('CREATE');
    server.folderCommands.add('CREATE $path');
    if (server.folders.containsKey(path)) {
      throw _no('NO [ALREADYEXISTS] Mailbox already exists');
    }
    if (server.refusesFolder?.call(path) ?? false) {
      throw _no('NO [CANNOT] Invalid mailbox name');
    }
    if (server.failCreates) throw _no('NO Server busy, try again later');
    server.addFolder(path);
    return _answer('CREATE', fakeMailbox(path));
  }

  @override
  Future<imap.Mailbox> renameMailbox(imap.Mailbox box, String newName) async {
    _failBefore('RENAME');
    final from = box.encodedPath;
    server.folderCommands.add('RENAME $from->$newName');
    if (!server.folders.containsKey(from)) {
      throw _no('NO [NONEXISTENT] Mailbox does not exist');
    }
    if (server.folders.containsKey(newName)) {
      throw _no('NO [ALREADYEXISTS] Mailbox already exists');
    }
    if (server.refusesFolder?.call(newName) ?? false) {
      throw _no('NO [CANNOT] Invalid mailbox name');
    }
    server.renameFolder(from, newName);
    return _answer('RENAME', fakeMailbox(newName));
  }

  @override
  Future<imap.Mailbox> statusMailbox(
    imap.Mailbox box,
    List<imap.StatusFlags> flags,
  ) async {
    _failBefore('STATUS');
    if (server.statusError?.call(box.encodedPath) case final text?) {
      throw _no(text);
    }
    final folder = server.folders[box.encodedPath];
    if (folder == null) throw _no('NO [NONEXISTENT] Mailbox does not exist');
    return box
      ..messagesExists = folder.messages.length
      ..messagesUnseen = folder.messages.values.where((m) => !m.seen).length
      ..uidValidity = folder.uidValidity;
  }

  /// `STATUS` of [box] with its `MAILBOXID`, as
  /// `statusWithMailboxIdFromServer` would answer; only asked when the
  /// server advertises OBJECTID.
  Future<ImapFolderStatus> statusWithMailboxId(
    imap.Mailbox box,
    List<imap.StatusFlags> flags,
  ) async {
    server.mailboxIdStatusCount++;
    if (!server.objectIds || server.refusesMailboxIdStatus) {
      throw _no('BAD Unknown STATUS item MAILBOXID');
    }
    final status = await statusMailbox(box, flags);
    return (
      messages: status.messagesExists,
      unseen: status.messagesUnseen,
      uidValidity: status.uidValidity,
      mailboxId: server.folders[box.encodedPath]?.mailboxId,
    );
  }

  @override
  Future<imap.Mailbox> deleteMailbox(imap.Mailbox box) async {
    _failBefore('DELETE');
    final path = box.encodedPath;
    server.folderCommands.add('DELETE $path');
    if (!server.folders.containsKey(path)) {
      throw _no('NO [NONEXISTENT] Mailbox does not exist');
    }
    if (server.failDeletes) throw _no('NO Server busy, try again later');
    server.folders.remove(path);
    return _answer('DELETE', box);
  }

  @override
  Future<imap.Mailbox> selectMailboxByPath(
    String path, {
    bool enableCondStore = false,
    imap.QResyncParameters? qresync,
  }) async {
    final folder = server.folders[path];
    // A failed SELECT leaves no mailbox selected (RFC 3501 §6.3.1).
    if (server.failBefore?.call('SELECT') case final error?) {
      _selected = null;
      throw error;
    }
    if (server.selectError?.call(path) case final text?) {
      _selected = null;
      throw _no(text);
    }
    _selected = folder;
    if (folder == null) throw _no('NO Mailbox does not exist');
    return _answer(
      'SELECT',
      imap.Mailbox(
        encodedName: path,
        encodedPath: path,
        pathSeparator: '/',
        flags: [],
        uidValidity: folder.uidValidity,
        uidNext: folder.uidNext,
        messagesExists: folder.messages.length,
        highestModSequence: folder.highestModSeq,
      ),
    );
  }

  @override
  Future<imap.SearchImapResult> uidSearchMessages({
    String searchCriteria = 'UNSEEN',
    List<imap.ReturnOption>? returnOptions,
    Duration? responseTimeout,
  }) async {
    final uids = _search(searchCriteria);
    return _answer(
      'SEARCH $searchCriteria',
      imap.SearchImapResult()
        ..matchingSequence = imap.MessageSequence.fromIds(uids, isUid: true),
    );
  }

  List<int> _search(String criteria) {
    final messages = _folder.messages;
    if (criteria == 'ALL') {
      // A server whose index lags, or a glitch: nothing listed.
      if (server.searchAllEmpty) return const [];
      return messages.keys.toList();
    }
    if (criteria == 'DELETED') {
      return [
        for (final m in messages.values)
          if (m.flags.contains(r'\Deleted')) m.uid,
      ];
    }
    if (criteria == 'UNSEEN') {
      return [
        for (final m in messages.values)
          if (!m.seen) m.uid,
      ];
    }
    final range = RegExp(r'^UID (\d+):\*$').firstMatch(criteria);
    if (range != null) {
      // RFC 3501 §6.4.4: past the largest UID, `n:*` still matches it.
      final from = int.parse(range.group(1)!);
      final hits = messages.keys.where((uid) => uid >= from).toList();
      if (hits.isNotEmpty || messages.isEmpty) return hits;
      return [messages.lastKey()!];
    }
    final header = RegExp(r'^HEADER Message-ID "(.*)"$').firstMatch(criteria);
    if (header == null) throw UnsupportedError('fake IMAP: SEARCH $criteria');
    final wanted = _bare(header.group(1)!);
    return [
      for (final m in messages.values)
        if (m.messageId == wanted) m.uid,
    ];
  }

  static String _bare(String id) => id.startsWith('<') && id.endsWith('>')
      ? id.substring(1, id.length - 1)
      : id;

  @override
  Future<imap.FetchImapResult> uidFetchMessages(
    imap.MessageSequence sequence,
    String? fetchContentDefinition, {
    int? changedSinceModSequence,
    Duration? responseTimeout,
  }) async {
    final items = fetchContentDefinition ?? '';
    final since = changedSinceModSequence;
    final headers = items.contains('ENVELOPE');
    // The whole message (a body, attachment or raw-source fetch).
    final body = items.contains('BODY.PEEK[]') || items.contains('BODY[]');
    final full = headers || body;
    final messages = [
      for (final m in _named(sequence))
        if (since == null || m.modSeq > since)
          full ? _fullMessage(m) : _flagsMessage(m, withSize: items),
    ];
    final what = headers
        ? 'headers'
        : body
            ? 'body'
            : items;
    return _answer(
      'FETCH $what${since == null ? '' : ' CHANGEDSINCE'}',
      imap.FetchImapResult(messages, null),
    );
  }

  @override
  Future<imap.FetchImapResult> uidFetchMessage(
    int messageUid,
    String fetchContentDefinition, {
    Duration? responseTimeout,
  }) =>
      uidFetchMessages(
        imap.MessageSequence.fromId(messageUid, isUid: true),
        fetchContentDefinition,
      );

  imap.MimeMessage _flagsMessage(
    FakeServerMessage m, {
    required String withSize,
  }) =>
      imap.MimeMessage()
        ..uid = m.uid
        ..flags = m.flags.toList()
        ..size = withSize.contains('RFC822.SIZE') ? 100 : null;

  /// A message whose [FakeServerMessage.messageId] starts with
  /// [noMessageIdPrefix] has no Message-ID header (the id only names it in
  /// the test).
  imap.MimeMessage _fullMessage(FakeServerMessage m) {
    final hasId = !m.messageId.startsWith(noMessageIdPrefix);
    final header = m.messageIdHeader ?? (hasId ? '<${m.messageId}>' : '');
    return imap.MimeMessage.parseFromText(
      '${header.isEmpty ? '' : 'Message-ID: $header\r\n'}'
      'Subject: Mail ${m.messageId}\r\n'
      'Content-Type: text/plain; charset=UTF-8\r\n'
      '\r\n'
      'Body of ${m.messageId}\r\n',
    )
      ..uid = m.uid
      ..flags = m.flags.toList()
      ..size = 100
      ..envelope = imap.Envelope(
        date: DateTime.utc(2026, 1, 1, 12),
        subject: 'Mail ${m.messageId}',
        from: const [imap.MailAddress(null, 'bob@example.com')],
        to: const [imap.MailAddress(null, 'alice@example.com')],
        messageId: hasId ? '<${m.messageId}>' : null,
      );
  }

  @override
  Future<imap.StoreImapResult> fakeStore(
    imap.MessageSequence sequence,
    List<String> flags,
    imap.StoreAction action,
  ) async {
    _failBefore('STORE');
    final messages = _named(sequence);
    _checkAllowed(messages);
    for (final m in messages) {
      for (final flag in flags) {
        switch (action) {
          case imap.StoreAction.add:
            m.flags.add(flag);
          case imap.StoreAction.remove:
            m.flags.remove(flag);
          case imap.StoreAction.replace:
            throw UnsupportedError('fake IMAP: STORE FLAGS');
        }
        final sign = action == imap.StoreAction.add ? '+' : '-';
        server.hits.add((command: 'STORE $sign$flag', messageId: m.messageId));
      }
      m.modSeq = server._bump(_folder);
    }
    return _answer('STORE', imap.StoreImapResult());
  }

  @override
  Future<imap.GenericImapResult> fakeMove(
    imap.MessageSequence sequence,
    String? targetMailboxPath,
  ) async {
    _failBefore('MOVE');
    final dest = server.folders[targetMailboxPath];
    if (dest == null) throw _no('NO [TRYCREATE] Mailbox does not exist');
    final src = _folder;
    final messages = _named(sequence);
    _checkAllowed(messages);
    final sources = <int>[];
    final targets = <int>[];
    for (final m in messages) {
      sources.add(m.uid);
      targets.add(server._move(src, m, dest));
      server.hits.add(
        (command: 'MOVE ${src.path}->${dest.path}', messageId: m.messageId),
      );
    }
    final result = imap.GenericImapResult();
    if (server.uidPlus && sources.isNotEmpty) {
      result.responseCode =
          'COPYUID ${dest.uidValidity} ${sources.join(',')} ${targets.join(',')}';
    }
    return _answer('MOVE', result);
  }

  @override
  Future<imap.Mailbox?> uidExpunge(imap.MessageSequence sequence) async {
    // UID EXPUNGE is part of UIDPLUS (RFC 4315).
    if (!server.uidPlus) throw _no('BAD Unknown command UID EXPUNGE');
    _failBefore('EXPUNGE');
    _expungeDeleted(_named(sequence));
    return _answer('UID EXPUNGE', null);
  }

  @override
  Future<imap.Mailbox?> expunge() async {
    _failBefore('EXPUNGE');
    _expungeDeleted(_folder.messages.values.toList());
    return _answer('EXPUNGE', null);
  }

  void _expungeDeleted(List<FakeServerMessage> candidates) {
    final folder = _folder;
    for (final m in candidates) {
      if (!m.flags.contains(r'\Deleted')) continue;
      folder.messages.remove(m.uid);
      server._bump(folder);
      server.hits.add((command: 'EXPUNGE', messageId: m.messageId));
    }
  }

  @override
  Future<imap.FetchImapResult> fetchMessages(
    imap.MessageSequence sequence,
    String? fetchContentDefinition, {
    int? changedSinceModSequence,
    Duration? responseTimeout,
  }) =>
      throw UnsupportedError('fake IMAP: FETCH by sequence number');
}
