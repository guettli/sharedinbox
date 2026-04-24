import 'dart:async';

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart' show SyncEmailsResult;
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/repositories/sync_log_repository.dart';
import 'package:sharedinbox/core/utils/logger.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart'
    show ImapConnectFn, connectImap, verboseLogKey;

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
              account,
              _accounts,
              _mailboxes,
              _emails,
              _imapConnect,
              _syncLog,
            ),
          AccountType.jmap =>
            _JmapAccountSync(account, _mailboxes, _emails, _accounts, _syncLog),
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
    unawaited(_accountsSub?.cancel());
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
  _AccountSync(
    this.account,
    this._accounts,
    this._mailboxes,
    this._emails,
    this._imapConnect,
    this._syncLog,
  );

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
    unawaited(_loop());
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
        final (_SyncStats stats, String? capturedLog) =
            await _runSync(account.verbose);
        await _syncLog.log(
          accountId: account.id,
          success: true,
          protocol: 'imap',
          emailsFetched: stats.emailsFetched,
          emailsSkipped: stats.emailsSkipped,
          mailboxesSynced: stats.mailboxesSynced,
          pendingFlushed: stats.pendingFlushed,
          bytesTransferred: stats.bytesTransferred,
          startedAt: startedAt,
          finishedAt: DateTime.now(),
          mailboxStats: stats.mailboxStats,
          protocolLog: capturedLog,
        );
        await _idle();
        _backoffSeconds = 5;
      } catch (e, st) {
        try {
          await _syncLog.log(
            accountId: account.id,
            success: false,
            errorMessage: e.toString(),
            protocol: 'imap',
            emailsFetched: 0,
            emailsSkipped: 0,
            mailboxesSynced: 0,
            pendingFlushed: 0,
            bytesTransferred: 0,
            startedAt: startedAt,
            finishedAt: DateTime.now(),
          );
        } catch (logErr) {
          log('Failed to write IMAP sync log entry: $logErr');
        }
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

  Future<(_SyncStats, String?)> _runSync(bool verbose) async {
    if (!verbose) return (await _sync(), null);
    final buffer = StringBuffer();
    final stats = await runZoned(
      _sync,
      zoneValues: {verboseLogKey: buffer},
      zoneSpecification: ZoneSpecification(
        print: (_, __, ___, line) => buffer.writeln(line),
      ),
    );
    return (stats, _redactCredentials(buffer.toString()));
  }

  Future<_SyncStats> _sync() async {
    final password = await _accounts.getPassword(account.id);
    final pendingFlushed =
        await _emails.flushPendingChanges(account.id, password);
    final mailboxesSynced = await _mailboxes.syncMailboxes(account.id);
    final mailboxes = await _mailboxes.observeMailboxes(account.id).first;
    var emailResult = SyncEmailsResult.zero;
    final mailboxStats = <MailboxSyncStats>[];
    for (final mailbox in mailboxes) {
      if (!_running) break;
      final r = await _emails.syncEmails(account.id, mailbox.path);
      emailResult += r;
      mailboxStats.add(
        MailboxSyncStats(
          mailboxPath: mailbox.path,
          fetched: r.fetched,
          skipped: r.skipped,
          bytesTransferred: r.bytesTransferred,
        ),
      );
    }
    return _SyncStats(
      emailsFetched: emailResult.fetched,
      emailsSkipped: emailResult.skipped,
      mailboxesSynced: mailboxesSynced,
      pendingFlushed: pendingFlushed,
      bytesTransferred: emailResult.bytesTransferred,
      mailboxStats: mailboxStats,
    );
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
                e is imap.ImapMessagesExistEvent || e is imap.ImapExpungeEvent,
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
    this.account,
    this._mailboxes,
    this._emails,
    this._accounts,
    this._syncLog,
  );

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
    unawaited(_loop());
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
        final (_SyncStats stats, String? capturedLog) =
            await _runSync(account.verbose);
        await _syncLog.log(
          accountId: account.id,
          success: true,
          protocol: 'jmap',
          emailsFetched: stats.emailsFetched,
          emailsSkipped: stats.emailsSkipped,
          mailboxesSynced: stats.mailboxesSynced,
          pendingFlushed: stats.pendingFlushed,
          bytesTransferred: stats.bytesTransferred,
          startedAt: startedAt,
          finishedAt: DateTime.now(),
          mailboxStats: stats.mailboxStats,
          protocolLog: capturedLog,
        );
        _backoffSeconds = 5;
        await _wait();
      } catch (e, st) {
        try {
          await _syncLog.log(
            accountId: account.id,
            success: false,
            errorMessage: e.toString(),
            protocol: 'jmap',
            emailsFetched: 0,
            emailsSkipped: 0,
            mailboxesSynced: 0,
            pendingFlushed: 0,
            bytesTransferred: 0,
            startedAt: startedAt,
            finishedAt: DateTime.now(),
          );
        } catch (logErr) {
          log('Failed to write JMAP sync log entry: $logErr');
        }
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

  Future<(_SyncStats, String?)> _runSync(bool verbose) async {
    if (!verbose) return (await _sync(), null);
    final buffer = StringBuffer();
    final stats = await runZoned(
      _sync,
      zoneValues: {verboseLogKey: buffer},
      zoneSpecification: ZoneSpecification(
        print: (_, __, ___, line) => buffer.writeln(line),
      ),
    );
    return (stats, buffer.toString());
  }

  Future<_SyncStats> _sync() async {
    final password = await _accounts.getPassword(account.id);

    // Drain outbound queue before pulling from server.
    final pendingFlushed =
        await _emails.flushPendingChanges(account.id, password);

    final mailboxesSynced = await _mailboxes.syncMailboxes(account.id);

    final mailboxes = await _mailboxes.observeMailboxes(account.id).first;
    var emailResult = SyncEmailsResult.zero;
    final mailboxStats = <MailboxSyncStats>[];
    for (final mailbox in mailboxes) {
      if (!_running) break;
      final r = await _emails.syncEmails(account.id, mailbox.path);
      emailResult += r;
      mailboxStats.add(
        MailboxSyncStats(
          mailboxPath: mailbox.path,
          fetched: r.fetched,
          skipped: r.skipped,
          bytesTransferred: r.bytesTransferred,
        ),
      );
    }
    return _SyncStats(
      emailsFetched: emailResult.fetched,
      emailsSkipped: emailResult.skipped,
      mailboxesSynced: mailboxesSynced,
      pendingFlushed: pendingFlushed,
      bytesTransferred: emailResult.bytesTransferred,
      mailboxStats: mailboxStats,
    );
  }

  Future<void> _wait() async {
    if (!_running) return;
    _stopSignal = Completer<void>();
    final password = await _accounts.getPassword(account.id);

    // Try JMAP push (RFC 8887 EventSource). Falls back to poll timer when
    // the server doesn't advertise an eventSourceUrl or the connection fails.
    final pushReady = Completer<void>();
    final pushSub = _emails.watchJmapPush(account.id, password).listen(
      (_) {
        if (!pushReady.isCompleted) pushReady.complete();
      },
      onDone: () {},
      onError: (_) {},
    );

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

class _SyncStats {
  const _SyncStats({
    required this.emailsFetched,
    required this.emailsSkipped,
    required this.mailboxesSynced,
    required this.pendingFlushed,
    required this.bytesTransferred,
    required this.mailboxStats,
  });

  final int emailsFetched;
  final int emailsSkipped;
  final int mailboxesSynced;
  final int pendingFlushed;
  final int bytesTransferred;
  final List<MailboxSyncStats> mailboxStats;
}

/// Replaces credentials in a captured IMAP protocol log.
///
/// Redacts the password argument from LOGIN commands and the base64 payload
/// from AUTHENTICATE commands. Other lines pass through unchanged.
String _redactCredentials(String log) {
  return log
      .replaceAllMapped(
        RegExp(r'(LOGIN\s+\S+\s+)\S+', caseSensitive: false),
        (m) => '${m.group(1)}[REDACTED]',
      )
      .replaceAllMapped(
        RegExp(r'(AUTHENTICATE\s+\w+\s+)\S+', caseSensitive: false),
        (m) => '${m.group(1)}[REDACTED]',
      );
}
