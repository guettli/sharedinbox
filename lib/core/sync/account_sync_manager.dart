import 'dart:async';

import 'package:enough_mail/enough_mail.dart' as imap;

import '../models/account.dart';
import '../repositories/account_repository.dart';
import '../repositories/email_repository.dart';
import '../repositories/mailbox_repository.dart';
import '../repositories/sync_log_repository.dart';
import '../utils/logger.dart';
import '../../data/imap/imap_client_factory.dart';

/// Manages background sync for all accounts.
///
/// IMAP accounts get an IDLE-based sync loop (_AccountSync).
/// JMAP accounts get a polling-based sync loop (_JmapAccountSync).
class AccountSyncManager {
  AccountSyncManager(
    this._accounts,
    this._mailboxes,
    this._emails, {
    ImapConnectFn imapConnect = connectImap,
    SyncLogRepository syncLog = const NoOpSyncLogRepository(),
  })  : _imapConnect = imapConnect,
        _syncLog = syncLog;

  final AccountRepository _accounts;
  final MailboxRepository _mailboxes;
  final EmailRepository _emails;
  final ImapConnectFn _imapConnect;
  final SyncLogRepository _syncLog;

  final Map<String, _SyncLoop> _active = {};
  StreamSubscription<List<Account>>? _accountsSub;

  void start() {
    _accountsSub = _accounts.observeAccounts().listen((accounts) {
      final currentIds = accounts.map((a) => a.id).toSet();

      for (final account in accounts) {
        if (_active.containsKey(account.id)) continue;
        final loop = switch (account.type) {
          AccountType.imap => _AccountSync(
              account, _accounts, _mailboxes, _emails, _imapConnect, _syncLog),
          AccountType.jmap => _JmapAccountSync(
              account, _mailboxes, _emails, _accounts, _syncLog),
        };
        _active[account.id] = loop;
        loop.start();
      }

      for (final id in _active.keys.toList()) {
        if (!currentIds.contains(id)) {
          _active.remove(id)?.stop();
        }
      }
    });
  }

  void dispose() {
    _accountsSub?.cancel();
    for (final s in _active.values) {
      s.stop();
    }
    _active.clear();
  }
}

// ── Shared interface ──────────────────────────────────────────────────────────

abstract class _SyncLoop {
  void start();
  void stop();
}

// ── IMAP ──────────────────────────────────────────────────────────────────────

class _AccountSync implements _SyncLoop {
  _AccountSync(this.account, this._accounts, this._mailboxes, this._emails,
      this._imapConnect, this._syncLog);

  final Account account;
  final AccountRepository _accounts;
  final MailboxRepository _mailboxes;
  final EmailRepository _emails;
  final ImapConnectFn _imapConnect;
  final SyncLogRepository _syncLog;

  imap.ImapClient? _idleClient;
  bool _running = false;
  int _backoffSeconds = 5;
  Completer<void>? _stopSignal;

  @override
  void start() {
    _running = true;
    _loop();
  }

  @override
  void stop() {
    _running = false;
    if (_stopSignal != null && !_stopSignal!.isCompleted) {
      _stopSignal!.complete();
    }
    _idleClient?.logout().ignore();
    _idleClient = null;
  }

  Future<void> _loop() async {
    while (_running) {
      final startedAt = DateTime.now();
      try {
        await _sync();
        await _syncLog.log(
          accountId: account.id,
          success: true,
          startedAt: startedAt,
          finishedAt: DateTime.now(),
        );
        await _idle();
        _backoffSeconds = 5;
      } catch (e, st) {
        await _syncLog.log(
          accountId: account.id,
          success: false,
          errorMessage: e.toString(),
          startedAt: startedAt,
          finishedAt: DateTime.now(),
        );
        log(
          'Sync failed for ${account.email}, retrying in ${_backoffSeconds}s',
          error: e,
          stackTrace: st,
        );
        await Future.delayed(Duration(seconds: _backoffSeconds));
        _backoffSeconds = (_backoffSeconds * 2).clamp(5, 300);
      }
    }
  }

  Future<void> _sync() async {
    final password = await _accounts.getPassword(account.id);
    await _emails.flushPendingChanges(account.id, password);
    await _mailboxes.syncMailboxes(account.id);
    final mailboxes = await _mailboxes.observeMailboxes(account.id).first;
    for (final mailbox in mailboxes) {
      if (!_running) break;
      await _emails.syncEmails(account.id, mailbox.path);
    }
  }

  Future<void> _idle() async {
    if (!_running) return;
    _stopSignal = Completer<void>();
    final password = await _accounts.getPassword(account.id);
    final username =
        account.username.isNotEmpty ? account.username : account.email;
    final client = await _imapConnect(account, username, password);
    _idleClient = client;
    try {
      await client.selectMailboxByPath('INBOX');

      final newMessageCompleter = Completer<void>();

      final sub = client.eventBus
          .on<imap.ImapEvent>()
          .where(
            (e) =>
                e is imap.ImapMessagesExistEvent ||
                e is imap.ImapExpungeEvent,
          )
          .listen((_) {
        if (!newMessageCompleter.isCompleted) newMessageCompleter.complete();
      });

      await client.idleStart();

      // Cap IDLE at 25 minutes (RFC 2177). Also wakes up when stop() is
      // called or a new message / expunge event arrives.
      await Future.any([
        newMessageCompleter.future,
        Future.delayed(const Duration(minutes: 25)),
        _stopSignal!.future,
      ]);

      await client.idleDone();
      await sub.cancel();
    } finally {
      await client.logout();
      _idleClient = null;
      _stopSignal = null;
    }
  }
}

// ── JMAP ──────────────────────────────────────────────────────────────────────

class _JmapAccountSync implements _SyncLoop {
  _JmapAccountSync(
      this.account, this._mailboxes, this._emails, this._accounts, this._syncLog);

  final Account account;
  final MailboxRepository _mailboxes;
  final EmailRepository _emails;
  final AccountRepository _accounts;
  final SyncLogRepository _syncLog;

  bool _running = false;
  int _backoffSeconds = 5;
  Completer<void>? _stopSignal;

  static const _pollInterval = Duration(seconds: 30);

  @override
  void start() {
    _running = true;
    _loop();
  }

  @override
  void stop() {
    _running = false;
    if (_stopSignal != null && !_stopSignal!.isCompleted) {
      _stopSignal!.complete();
    }
  }

  Future<void> _loop() async {
    while (_running) {
      final startedAt = DateTime.now();
      try {
        await _sync();
        await _syncLog.log(
          accountId: account.id,
          success: true,
          startedAt: startedAt,
          finishedAt: DateTime.now(),
        );
        _backoffSeconds = 5;
        await _wait();
      } catch (e, st) {
        await _syncLog.log(
          accountId: account.id,
          success: false,
          errorMessage: e.toString(),
          startedAt: startedAt,
          finishedAt: DateTime.now(),
        );
        log(
          'JMAP sync failed for ${account.email}, retrying in ${_backoffSeconds}s',
          error: e,
          stackTrace: st,
        );
        await _waitSeconds(_backoffSeconds);
        _backoffSeconds = (_backoffSeconds * 2).clamp(5, 300);
      }
    }
  }

  Future<void> _sync() async {
    final password = await _accounts.getPassword(account.id);

    // Drain outbound queue before pulling from server.
    await _emails.flushPendingChanges(account.id, password);

    await _mailboxes.syncMailboxes(account.id);

    final mailboxes = await _mailboxes.observeMailboxes(account.id).first;
    for (final mailbox in mailboxes) {
      if (!_running) break;
      await _emails.syncEmails(account.id, mailbox.path);
    }
  }

  Future<void> _wait() async {
    if (!_running) return;
    _stopSignal = Completer<void>();
    final password = await _accounts.getPassword(account.id);

    // Try JMAP push (RFC 8887 EventSource). Falls back to poll timer when
    // the server doesn't advertise an eventSourceUrl or the connection fails.
    final pushReady = Completer<void>();
    final pushSub = _emails
        .watchJmapPush(account.id, password)
        .listen((_) {
          if (!pushReady.isCompleted) pushReady.complete();
        }, onDone: () {}, onError: (_) {});

    await Future.any([
      pushReady.future,
      Future.delayed(_pollInterval),
      _stopSignal!.future,
    ]);

    await pushSub.cancel();
    _stopSignal = null;
  }

  Future<void> _waitSeconds(int seconds) async {
    if (!_running) return;
    _stopSignal = Completer<void>();
    await Future.any([
      Future.delayed(Duration(seconds: seconds)),
      _stopSignal!.future,
    ]);
    _stopSignal = null;
  }
}
