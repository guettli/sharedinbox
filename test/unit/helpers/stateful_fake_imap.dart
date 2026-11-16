import 'dart:collection';

import 'package:enough_mail/enough_mail.dart' as imap;

import '../fake_imap.dart' show FakeImapClient, StaleAnswerHook, StoreAndMove;

/// One message on a [StatefulFakeImapServer].
class FakeServerMessage {
  FakeServerMessage({
    required this.uid,
    required this.messageId,
    required this.modSeq,
    Iterable<String> flags = const [],
  }) : flags = {...flags};

  int uid;
  int modSeq;

  /// The bare Message-ID (no angle brackets), unique on the server.
  final String messageId;
  final Set<String> flags;

  bool get seen => flags.contains(r'\Seen');
  bool get flagged => flags.contains(r'\Flagged');
}

/// One folder on a [StatefulFakeImapServer], messages keyed by UID.
class FakeServerFolder {
  FakeServerFolder(this.path, this.uidValidity);

  final String path;
  final int uidValidity;
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
      folders[path] = FakeServerFolder(path, validity);
    }
  }

  /// Whether connections advertise UIDPLUS (`COPYUID` on MOVE).
  final bool uidPlus;

  /// Whether connections advertise OBJECTID (RFC 8474): each message then
  /// has a move-stable EMAILID, `E-<Message-ID>`
  /// ([StatefulFakeImapClient.emailIdsOf]).
  final bool objectIds;

  final Map<String, FakeServerFolder> folders = {};
  final List<FakeServerHit> hits = [];

  /// When it returns true for a message, every `STORE` and `MOVE` touching
  /// it is refused with `NO`: a permanent server error.
  bool Function(String messageId)? refuses;

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
  }) {
    final folder = folders[path]!;
    final message = FakeServerMessage(
      uid: folder.uidNext++,
      messageId: messageId,
      modSeq: _bump(folder),
      flags: flags,
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
        for (final message in _named(sequence))
          message.uid: 'E-${message.messageId}',
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
  Future<imap.Mailbox> selectMailboxByPath(
    String path, {
    bool enableCondStore = false,
    imap.QResyncParameters? qresync,
  }) async {
    final folder = server.folders[path];
    // A failed SELECT leaves no mailbox selected (RFC 3501 §6.3.1).
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
    if (criteria == 'ALL') return messages.keys.toList();
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
    final full = items.contains('ENVELOPE');
    final messages = [
      for (final m in _named(sequence))
        if (since == null || m.modSeq > since)
          full ? _fullMessage(m) : _flagsMessage(m, withSize: items),
    ];
    final what = full ? 'headers' : items;
    return _answer(
      'FETCH $what${since == null ? '' : ' CHANGEDSINCE'}',
      imap.FetchImapResult(messages, null),
    );
  }

  imap.MimeMessage _flagsMessage(
    FakeServerMessage m, {
    required String withSize,
  }) =>
      imap.MimeMessage()
        ..uid = m.uid
        ..flags = m.flags.toList()
        ..size = withSize.contains('RFC822.SIZE') ? 100 : null;

  imap.MimeMessage _fullMessage(FakeServerMessage m) =>
      imap.MimeMessage.parseFromText(
        'Message-ID: <${m.messageId}>\r\n'
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
          messageId: '<${m.messageId}>',
        );

  @override
  Future<imap.StoreImapResult> fakeStore(
    imap.MessageSequence sequence,
    List<String> flags,
    imap.StoreAction action,
  ) async {
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
    _expungeDeleted(_named(sequence));
    return _answer('UID EXPUNGE', null);
  }

  @override
  Future<imap.Mailbox?> expunge() async {
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
