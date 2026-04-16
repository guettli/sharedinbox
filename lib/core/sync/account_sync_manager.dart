import 'dart:async';

import 'package:enough_mail/enough_mail.dart' as imap;

import '../models/account.dart';
import '../repositories/account_repository.dart';
import '../repositories/email_repository.dart';
import '../repositories/mailbox_repository.dart';
import '../../data/imap/imap_client_factory.dart';

/// Manages one IMAP IDLE connection per account.
/// On new message notification it triggers a sync and notifies listeners.
class AccountSyncManager {
  AccountSyncManager(this._accounts, this._mailboxes, this._emails);

  final AccountRepository _accounts;
  final MailboxRepository _mailboxes;
  final EmailRepository _emails;

  final Map<String, _AccountSync> _active = {};

  Future<void> start() async {
    _accounts.observeAccounts().listen((accounts) {
      final ids = accounts.map((a) => a.id).toSet();
      // Start new
      for (final account in accounts) {
        if (!_active.containsKey(account.id)) {
          _start(account);
        }
      }
      // Stop removed
      for (final id in _active.keys.toList()) {
        if (!ids.contains(id)) {
          _active.remove(id)?.stop();
        }
      }
    });
  }

  void _start(Account account) {
    final sync = _AccountSync(account, _accounts, _mailboxes, _emails);
    _active[account.id] = sync;
    sync.start();
  }

  void dispose() {
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
    await client.selectMailboxByPath('INBOX');
    final idleDone = Completer<void>();
    await client.idleStart();
    client.eventBus
        .on<imap.ImapEvent>()
        .where((e) => e is imap.ImapMessagesExistEvent)
        .first
        .then((_) => idleDone.complete());
    // Stop idle after 25 minutes to stay within server limits
    Future.delayed(const Duration(minutes: 25)).then((_) {
      if (!idleDone.isCompleted) idleDone.complete();
    });
    await idleDone.future;
    await client.idleDone();
    await client.logout();
    _idleClient = null;
  }
}
