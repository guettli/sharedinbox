import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';

/// The `SharedInbox/Keys` folder of one account, shared by the devices of a
/// test: mails by UID, UIDs ascending.
class FakeKeysServer {
  int _nextUid = 1;
  final Map<int, ({String messageId, Uint8List mail})> mails = {};

  int append(String messageId, Uint8List mail) {
    final uid = _nextUid++;
    mails[uid] = (messageId: messageId, mail: mail);
    return uid;
  }

  List<String> get messageIds => [
        for (final uid in mails.keys.toList()..sort()) mails[uid]!.messageId,
      ];
}

/// A [MailObjectStore] of one device holding only the keys folder. [sync]
/// works like the IMAP store: pull first, then push.
class FakeKeysStore implements MailObjectStore {
  FakeKeysStore(this.server);

  final FakeKeysServer server;
  final Map<String, MailObject> _rows = {};
  final _changes = StreamController<void>.broadcast();

  bool offline = false;
  int reopens = 0;
  int syncs = 0;

  /// Runs between the pull and the push of a sync, e.g. another device's
  /// APPEND.
  void Function()? betweenPullAndPush;

  /// Whether a mail gone from the server is uploaded again; all by default.
  Future<bool> Function(MailObject row) keepVanished = (_) async => true;

  List<MailObject> get rows => _rows.values.toList();

  @override
  Stream<List<MailObject>> observe(
    String accountId,
    MailObjectFolder folder,
  ) async* {
    yield _visible();
    yield* _changes.stream.map((_) => _visible());
  }

  List<MailObject> _visible() => [
        for (final r in _rows.values)
          if (!r.pendingDelete) r,
      ]..sort((a, b) => a.messageId.compareTo(b.messageId));

  @override
  Future<MailObject> appendRaw(String accountId, Uint8List mail) async {
    final id = imap.MimeMessage.parseFromData(mail)
        .getHeaderValue('Message-ID')!
        .trim();
    final row = _rows[id] ??= _row(accountId, id, mail, pendingUpload: true);
    _changes.add(null);
    return row;
  }

  @override
  Future<void> deleteRaw(String accountId, String messageId) async {
    final row = _rows[messageId];
    if (row == null) return;
    _rows[messageId] = _row(
      accountId,
      messageId,
      row.payload!,
      serverId: row.serverId,
      pendingDelete: true,
    );
    _changes.add(null);
  }

  @override
  Future<void> sync(String accountId) async {
    syncs++;
    if (offline) throw const SocketException('offline');
    for (final MapEntry(key: uid, value: m) in server.mails.entries) {
      final known = _rows[m.messageId];
      if (known != null && known.serverId != null) continue;
      if (known != null && known.pendingUpload) {
        _rows[m.messageId] = _row(accountId, m.messageId, m.mail, uid: uid);
        continue;
      }
      _rows[m.messageId] ??= _row(accountId, m.messageId, m.mail, uid: uid);
    }
    // Vanished from the server: uploaded again if [keepVanished] (4.3).
    for (final r in _rows.values.toList()) {
      final uid = int.tryParse(r.serverId ?? '');
      if (uid == null || server.mails.containsKey(uid)) continue;
      if (r.pendingDelete || !await keepVanished(r)) {
        _rows.remove(r.messageId);
        continue;
      }
      _rows[r.messageId] =
          _row(accountId, r.messageId, r.payload!, pendingUpload: true);
    }
    betweenPullAndPush?.call();
    for (final r in _rows.values.toList()) {
      if (r.pendingDelete) {
        server.mails.removeWhere((_, m) => m.messageId == r.messageId);
        _rows.remove(r.messageId);
        continue;
      }
      if (!r.pendingUpload) continue;
      final uid = server.append(r.messageId, r.payload!);
      _rows[r.messageId] = _row(accountId, r.messageId, r.payload!, uid: uid);
    }
    _changes.add(null);
  }

  @override
  Future<void> reopen(String accountId) async => reopens++;

  static MailObject _row(
    String accountId,
    String messageId,
    Uint8List mail, {
    int? uid,
    String? serverId,
    bool pendingUpload = false,
    bool pendingDelete = false,
  }) =>
      MailObject(
        accountId: accountId,
        folder: MailObjectFolder.keys,
        messageId: messageId,
        serverId: uid?.toString() ?? serverId,
        sizeBytes: mail.length,
        pendingUpload: pendingUpload,
        pendingDelete: pendingDelete,
        payload: mail,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
