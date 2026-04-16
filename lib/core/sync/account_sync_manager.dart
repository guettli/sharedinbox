import 'dart:async';

import 'package:enough_mail/enough_mail.dart' as imap;

import '../models/account.dart';
import '../repositories/account_repository.dart';
import '../repositories/email_repository.dart';
import '../repositories/mailbox_repository.dart';
import '../../data/imap/imap_client_factory.dart';

/// Manages one IMAP IDLE connection per account.
/// On a new-message notification it triggers a re-sync then goes back to IDLE.
class AccountSyncManager {
  AccountSyncManager(this._accounts, this._mailboxes, this._emails);

  final AccountRepository _accounts;
  final MailboxRepository _mailboxes;
  final EmailRepository _emails;

  final Map<String, _AccountSync> _active = {};
  StreamSubscription<List<Account>>? _accountsSub;

  void start() {
    _accountsSub = _accounts.observeAccounts().listen((accounts) {
      final currentIds = accounts.map((a) => a.id).toSet();

      // Start sync for newly added accounts.
      for (final account in accounts) {
        if (!_active.containsKey(account.id)) {
          final sync = _AccountSync(account, _accounts, _mailboxes, _emails);
          _active[account.id] = sync;
          sync.start();
        }
      }

      // Stop sync for removed accounts.
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

class _AccountSync {
  _AccountSync(this.account, this._accounts, this._mailboxes, this._emails);

  final Account account;
  final AccountRepository _accounts;
  final MailboxRepository _mailboxes;
  final EmailRepository _emails;

  imap.ImapClient? _idleClient;
  bool _running = false;
  int _backoffSeconds = 5;

  void start() {
    _running = true;
    _loop();
  }

  void stop() {
    _running = false;
    _idleClient?.logout().ignore();
    _idleClient = null;
  }

  Future<void> _loop() async {
    while (_running) {
      try {
        await _sync();
        await _idle();
        _backoffSeconds = 5;
      } catch (_) {
        await Future.delayed(Duration(seconds: _backoffSeconds));
        _backoffSeconds = (_backoffSeconds * 2).clamp(5, 300);
      }
    }
  }

  Future<void> _sync() async {
    await _mailboxes.syncMailboxes(account.id);
    await _emails.syncEmails(account.id, 'INBOX');
  }

  Future<void> _idle() async {
    if (!_running) return;
    final password = await _accounts.getPassword(account.id);
    final client = await connectImap(account, password);
    _idleClient = client;
    try {
      await client.selectMailboxByPath('INBOX');

      final newMessageCompleter = Completer<void>();

      // Wake up when new messages arrive or messages are expunged.
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

      // Cap IDLE at 25 minutes to stay within the RFC 2177 recommendation.
      await Future.any([
        newMessageCompleter.future,
        Future.delayed(const Duration(minutes: 25)),
      ]);

      await client.idleDone();
      await sub.cancel();
    } finally {
      await client.logout();
      _idleClient = null;
    }
  }
}
