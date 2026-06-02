import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/utils/logger.dart';
import 'package:sharedinbox/data/imap/managesieve_client.dart';

/// Returns true if the endpoint accepts a ManageSieve handshake.
typedef ManageSieveProbeFn =
    Future<bool> Function({
      required String host,
      required int port,
      required bool useTls,
    });

Future<bool> _defaultManageSieveProbe({
  required String host,
  required int port,
  required bool useTls,
}) async {
  try {
    final client = await ManageSieveClient.connect(
      host: host,
      port: port,
      useTls: useTls,
    );
    try {
      await client.logout();
    } catch (_) {
      /* best-effort */
    }
    return true;
  } catch (e) {
    log('ManageSieve probe failed for $host:$port — $e');
    return false;
  }
}

/// Probes whether [account]'s configured ManageSieve endpoint accepts a TCP
/// + STARTTLS handshake, and persists the result on the account row.
///
/// Runs after account add / edit so the IMAP/SMTP form can omit Sieve fields
/// for the common case (port 4190 on the IMAP host). The result drives whether
/// the "Email filters" menu item is shown for this account.
class ManageSieveProbeService {
  ManageSieveProbeService(
    this._accounts, {
    ManageSieveProbeFn probeFn = _defaultManageSieveProbe,
  }) : _probeFn = probeFn;

  final AccountRepository _accounts;
  final ManageSieveProbeFn _probeFn;

  Future<void> probe(Account account) async {
    if (account.type != AccountType.imap) return;
    final host = account.manageSieveHost.trim().isNotEmpty
        ? account.manageSieveHost.trim()
        : account.imapHost;
    if (host.isEmpty) return;
    final available = await _probeFn(
      host: host,
      port: account.manageSievePort,
      useTls: account.manageSieveSsl,
    );
    if (account.manageSieveAvailable == available) return;
    final updated = _withAvailability(account, available);
    await _accounts.updateAccount(updated);
  }

  Account _withAvailability(Account a, bool available) => Account(
    id: a.id,
    displayName: a.displayName,
    email: a.email,
    username: a.username,
    type: a.type,
    imapHost: a.imapHost,
    imapPort: a.imapPort,
    imapSsl: a.imapSsl,
    smtpHost: a.smtpHost,
    smtpPort: a.smtpPort,
    smtpSsl: a.smtpSsl,
    manageSieveHost: a.manageSieveHost,
    manageSievePort: a.manageSievePort,
    manageSieveSsl: a.manageSieveSsl,
    manageSieveAvailable: available,
    jmapUrl: a.jmapUrl,
    verbose: a.verbose,
  );
}
