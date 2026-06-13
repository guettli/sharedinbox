import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:enough_mail/enough_mail.dart' as mail;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sharedinbox/core/models/account.dart' as model;
import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';

import 'sync_reliability_fuzz.dart';

Future<void> main() async {
  final rawArgs = Platform.environment['SYNC_RELIABILITY_ARGS'];
  final args = rawArgs == null || rawArgs.isEmpty
      ? const <String>[]
      : const LineSplitter().convert(rawArgs);
  await runSyncReliability(args);
}

Future<void> runSyncReliability(List<String> args) async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final options = _parseOptions(args);
  final random = Random();

  final fuzzPolicy = options.fuzz
      ? FuzzPolicy(seed: options.fuzzSeed, probability: options.fuzzProb)
      : null;

  stdout.writeln(
    'sync-reliability: updates=${options.updates} cycles=${options.cycles} '
    'imap-dbs=${options.imapDbs} jmap-dbs=${options.jmapDbs}'
    '${fuzzPolicy == null ? '' : ' fuzz=on seed=${fuzzPolicy.seed} '
        'prob=${fuzzPolicy.probability}'}',
  );

  final imapEnv = _StalwartEnv.fromEnvironment();
  final jmapEnv = _StalwartEnv.fromEnvironment();

  final protocolConfigs = <(_Protocol protocol, int dbCount)>[];
  if (options.imapDbs > 0) {
    protocolConfigs.add((_Protocol.imap, options.imapDbs));
  }
  if (options.jmapDbs > 0) {
    protocolConfigs.add((_Protocol.jmap, options.jmapDbs));
  }

  if (protocolConfigs.isEmpty) {
    throw StateError(
      'No DBs configured. Set --imap-dbs and/or --jmap-dbs > 0.',
    );
  }

  for (final config in protocolConfigs) {
    final protocol = config.$1;
    final dbCount = config.$2;
    stdout.writeln('\n== protocol: ${protocol.name} dbs=$dbCount ==');

    final tempRoot = await Directory.systemTemp.createTemp(
      'sharedinbox_sync_reliability_',
    );
    final runners = <_Runner>[];
    for (var i = 0; i < dbCount; i++) {
      final runner = await _createRunner(
        rootDir: Directory(p.join(tempRoot.path, 'db_${i + 1}')),
        accountId: 'sync-account',
        env: protocol == _Protocol.imap ? imapEnv : jmapEnv,
        protocol: protocol,
        fuzz: fuzzPolicy,
      );
      runners.add(runner);
    }

    try {
      for (var cycle = 1; cycle <= options.cycles; cycle++) {
        stdout.writeln('cycle $cycle/${options.cycles}: sync start');
        await _fullSyncAll(runners);

        final opPlan = await _buildOperationPlan(
          runners,
          updates: options.updates,
          random: random,
        );

        stdout.writeln(
          'cycle $cycle/${options.cycles}: running ${opPlan.length} concurrent mutations',
        );

        await Future.wait(opPlan.map((op) => op.run()));

        await _waitForConvergence(runners, cycle: cycle);
        stdout.writeln('cycle $cycle/${options.cycles}: OK');
      }
    } finally {
      for (final runner in runners) {
        await runner.close();
      }
      await tempRoot.delete(recursive: true);
    }
  }

  if (fuzzPolicy != null) {
    stdout.writeln(
      '\nfuzz summary (seed=${fuzzPolicy.seed}, prob=${fuzzPolicy.probability}):',
    );
    fuzzPolicy.fireCountsSnapshot().forEach((kind, count) {
      stdout.writeln('  ${kind.name}: $count');
    });
  }

  stdout.writeln('\nAll sync reliability checks passed.');
}

Future<void> _waitForConvergence(
  List<_Runner> runners, {
  required int cycle,
}) async {
  const maxAttempts = 20;
  const settleDelay = Duration(milliseconds: 250);

  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    await _fullSyncAll(runners);
    try {
      await _assertSnapshotsEqual(runners, cycle: cycle);
      if (attempt > 1) {
        stdout.writeln('cycle $cycle: converged after $attempt sync attempts');
      }
      return;
    } catch (_) {
      if (attempt == maxAttempts) break;
      await Future<void>.delayed(settleDelay);
    }
  }

  stdout.writeln(
    'cycle $cycle: convergence not reached, forcing full resync on all DBs',
  );
  await Future.wait(runners.map((r) => r.forceFullResync()));

  await _assertSnapshotsEqual(runners, cycle: cycle);
}

Future<void> _fullSyncAll(List<_Runner> runners) async {
  await Future.wait(runners.map((r) => r.syncAll()));
}

Future<List<_Op>> _buildOperationPlan(
  List<_Runner> runners, {
  required int updates,
  required Random random,
}) async {
  final allIdsSet = <String>{};
  for (final runner in runners) {
    allIdsSet.addAll(await runner.emailIds());
  }
  final allIds = allIdsSet.toList()..sort();
  final deletableIds = <String>{...allIds};

  final ops = <_Op>[];

  for (var i = 0; i < updates; i++) {
    final target = runners[random.nextInt(runners.length)];
    final roll = random.nextInt(100);

    if (roll < 40 || allIds.isEmpty) {
      ops.add(
        _Op(
          label: 'create',
          run: () async => target.createMessage(),
        ),
      );
      continue;
    }

    if (roll < 70) {
      final id = allIds[random.nextInt(allIds.length)];
      final updateSeen = random.nextBool();
      final flagValue = random.nextBool();
      ops.add(
        _Op(
          label: 'update',
          run: () async {
            await target.setRandomFlag(
              id,
              useSeen: updateSeen,
              value: flagValue,
            );
          },
        ),
      );
      continue;
    }

    if (deletableIds.isEmpty) {
      ops.add(
        _Op(
          label: 'create',
          run: () async => target.createMessage(),
        ),
      );
      continue;
    }

    final id = deletableIds.elementAt(random.nextInt(deletableIds.length));
    deletableIds.remove(id);
    ops.add(
      _Op(
        label: 'delete',
        run: () async => target.deleteIfPresent(id),
      ),
    );
  }

  return ops;
}

Future<void> _assertSnapshotsEqual(
  List<_Runner> runners, {
  required int cycle,
}) async {
  final baseline = runners.first;
  final baselineSnapshot = await baseline.snapshot();

  for (var i = 1; i < runners.length; i++) {
    final snapshot = await runners[i].snapshot();
    if (baselineSnapshot != snapshot) {
      final leftLines = const LineSplitter().convert(baselineSnapshot);
      final rightLines = const LineSplitter().convert(snapshot);
      final max = leftLines.length > rightLines.length
          ? leftLines.length
          : rightLines.length;

      var diffLine = -1;
      for (var line = 0; line < max; line++) {
        final l = line < leftLines.length ? leftLines[line] : '<missing>';
        final r = line < rightLines.length ? rightLines[line] : '<missing>';
        if (l != r) {
          diffLine = line + 1;
          break;
        }
      }

      throw StateError(
        'DB snapshots differ after cycle $cycle. '
        'First differing line: $diffLine between db1 and db${i + 1}\n'
        '--- db1 ---\n$baselineSnapshot\n'
        '--- db${i + 1} ---\n$snapshot',
      );
    }
  }

  for (var i = 0; i < runners.length; i++) {
    final pending = await runners[i].pendingCount();
    if (pending != 0) {
      throw StateError(
        'Pending queue not empty after cycle $cycle: db${i + 1}=$pending',
      );
    }
  }
}

Future<_Runner> _createRunner({
  required Directory rootDir,
  required String accountId,
  required _StalwartEnv env,
  required _Protocol protocol,
  FuzzPolicy? fuzz,
}) async {
  await rootDir.create(recursive: true);
  final dbFile = File(p.join(rootDir.path, 'db.sqlite'));
  final db = AppDatabase(NativeDatabase(dbFile));
  final storage = _MemSecureStorage();
  final accounts = AccountRepositoryImpl(db, storage);

  final imapConnect = fuzz == null
      ? _connectImapPlaintext
      : wrapImapConnect(fuzz, _connectImapPlaintext);
  final smtpConnect = fuzz == null
      ? _connectSmtpPlaintext
      : wrapSmtpConnect(fuzz, _connectSmtpPlaintext);
  http.Client buildHttpClient() {
    final base = http.Client();
    return fuzz == null ? base : FuzzHttpClient(fuzz, base);
  }

  final mailboxRepo = MailboxRepositoryImpl(
    db,
    accounts,
    imapConnect: imapConnect,
    httpClient: buildHttpClient(),
  );
  final emailRepo = EmailRepositoryImpl(
    db,
    accounts,
    imapConnect: imapConnect,
    smtpConnect: smtpConnect,
    httpClient: buildHttpClient(),
  );

  final account = switch (protocol) {
    _Protocol.imap => model.Account(
        id: accountId,
        displayName: 'Sync Reliability IMAP',
        email: env.user,
        imapHost: env.imapHost,
        imapPort: env.imapPort,
        smtpHost: env.smtpHost,
        smtpPort: env.smtpPort,
      ),
    _Protocol.jmap => model.Account(
        id: accountId,
        displayName: 'Sync Reliability JMAP',
        email: env.user,
        type: model.AccountType.jmap,
        jmapUrl: '${env.baseUrl}/.well-known/jmap',
        imapHost: env.imapHost,
        imapPort: env.imapPort,
        smtpHost: env.smtpHost,
        smtpPort: env.smtpPort,
      ),
  };

  await accounts.addAccount(account, env.password);

  return _Runner(
    protocol: protocol,
    accountId: accountId,
    accountEmail: env.user,
    imapHost: env.imapHost,
    imapPort: env.imapPort,
    accountPassword: env.password,
    db: db,
    mailboxes: mailboxRepo,
    emails: emailRepo,
  );
}

Future<mail.ImapClient> _connectImapPlaintext(
  model.Account account,
  String username,
  String password,
) async {
  final client = mail.ImapClient(
    defaultResponseTimeout: const Duration(seconds: 20),
  );
  await client.connectToServer(
    account.imapHost,
    account.imapPort,
    // ignore: avoid_redundant_argument_values
    isSecure: false,
  );
  await client.login(username, password);
  return client;
}

Future<mail.SmtpClient> _connectSmtpPlaintext(
  model.Account account,
  String username,
  String password,
) async {
  final at = account.email.lastIndexOf('@');
  final domain = at == -1 ? account.smtpHost : account.email.substring(at + 1);
  final client = mail.SmtpClient(domain);
  await client.connectToServer(
    account.smtpHost,
    account.smtpPort,
    // ignore: avoid_redundant_argument_values
    isSecure: false,
  );
  await client.ehlo();
  await client.authenticate(username, password);
  return client;
}

class _Runner {
  _Runner({
    required this.protocol,
    required this.accountId,
    required this.accountEmail,
    required this.imapHost,
    required this.imapPort,
    required this.accountPassword,
    required this.db,
    required this.mailboxes,
    required this.emails,
  });

  final _Protocol protocol;
  final String accountId;
  final String accountEmail;
  final String imapHost;
  final int imapPort;
  final String accountPassword;
  final AppDatabase db;
  final MailboxRepositoryImpl mailboxes;
  final EmailRepositoryImpl emails;

  int _createCounter = 0;

  Future<void> syncAll() async {
    await emails.flushPendingChanges(accountId, accountPassword);
    await mailboxes.syncMailboxes(accountId);
    final mailboxRows = await (db.select(db.mailboxes)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([(t) => OrderingTerm.asc(t.path)]))
        .get();
    if (mailboxRows.isEmpty) {
      throw StateError('No mailboxes found for account $accountId after sync');
    }

    for (final mailbox in mailboxRows) {
      await emails.syncEmails(accountId, mailbox.path);
    }
  }

  Future<void> createMessage() async {
    _createCounter++;
    final now = DateTime.now().microsecondsSinceEpoch;
    final builder = mail.MessageBuilder()
      ..from = [mail.MailAddress('Sync Bot', accountEmail)]
      ..to = [mail.MailAddress('Sync Bot', accountEmail)]
      ..subject = 'sync-reliability-${protocol.name}-$now-$_createCounter'
      ..text = 'sync reliability body $now';
    final client = mail.ImapClient(
      defaultResponseTimeout: const Duration(seconds: 20),
    );
    await client.connectToServer(
      imapHost,
      imapPort,
      // ignore: avoid_redundant_argument_values
      isSecure: false,
    );
    try {
      await client.login(accountEmail, accountPassword);
      await client.appendMessage(
        builder.buildMimeMessage(),
        targetMailboxPath: 'INBOX',
      );
    } finally {
      await client.logout();
    }
  }

  Future<void> setRandomFlag(
    String emailId, {
    required bool useSeen,
    required bool value,
  }) async {
    if (!await _emailExists(emailId)) {
      return;
    }

    if (useSeen) {
      await emails.setFlag(emailId, seen: value);
    } else {
      await emails.setFlag(emailId, flagged: value);
    }
  }

  Future<void> deleteIfPresent(String emailId) async {
    if (!await _emailExists(emailId)) {
      return;
    }
    await emails.deleteEmail(emailId);
  }

  Future<bool> _emailExists(String emailId) async {
    final row = await (db.select(db.emails)..where((t) => t.id.equals(emailId)))
        .getSingleOrNull();
    return row != null;
  }

  Future<List<String>> emailIds() async {
    final rows = await (db.select(db.emails)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();
    return rows.map((e) => e.id).toList(growable: false);
  }

  Future<int> pendingCount() async {
    final rows = await (db.select(db.pendingChanges)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    return rows.length;
  }

  Future<String> snapshot() async {
    final mailboxRows = await (db.select(db.mailboxes)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([(t) => OrderingTerm.asc(t.path)]))
        .get();
    final emailRows = await (db.select(db.emails)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();
    final pendingRows = await (db.select(db.pendingChanges)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();

    final obj = {
      'mailboxes': mailboxRows
          .map(
            (r) => {
              'id': r.id,
              'accountId': r.accountId,
              'path': r.path,
              'name': r.name,
              'unreadCount': r.unreadCount,
              'totalCount': r.totalCount,
              'role': r.role,
            },
          )
          .toList(growable: false),
      'emails': emailRows
          .map(
            (r) => {
              'id': r.id,
              'accountId': r.accountId,
              'mailboxPath': r.mailboxPath,
              'uid': r.uid,
              'subject': r.subject,
              'fromJson': r.fromJson,
              'toAddresses': r.toAddresses,
              'ccJson': r.ccJson,
              'preview': r.preview,
              'isSeen': r.isSeen,
              'isFlagged': r.isFlagged,
              'hasAttachment': r.hasAttachment,
            },
          )
          .toList(growable: false),
      'pendingChanges': pendingRows
          .map(
            (r) => {
              'accountId': r.accountId,
              'resourceType': r.resourceType,
              'resourceId': r.resourceId,
              'changeType': r.changeType,
              'payload': r.payload,
              'attempts': r.attempts,
              'lastError': r.lastError,
            },
          )
          .toList(growable: false),
    };

    return const JsonEncoder.withIndent('  ').convert(obj);
  }

  Future<void> close() async {
    await db.close();
  }

  Future<void> forceFullResync() async {
    await (db.delete(db.syncStates)
          ..where((t) => t.accountId.equals(accountId)))
        .go();
    await (db.delete(db.emails)..where((t) => t.accountId.equals(accountId)))
        .go();
    await (db.delete(db.mailboxes)..where((t) => t.accountId.equals(accountId)))
        .go();
    await syncAll();
  }
}

class _MemSecureStorage implements SecureStorage {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read({required String key}) async => _values[key];

  @override
  Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }

  @override
  Future<void> delete({required String key}) async {
    _values.remove(key);
  }
}

class _Op {
  _Op({required this.label, required this.run});

  final String label;
  final Future<void> Function() run;
}

class _StalwartEnv {
  const _StalwartEnv({
    required this.baseUrl,
    required this.imapHost,
    required this.imapPort,
    required this.smtpHost,
    required this.smtpPort,
    required this.user,
    required this.password,
  });

  final String baseUrl;
  final String imapHost;
  final int imapPort;
  final String smtpHost;
  final int smtpPort;
  final String user;
  final String password;

  factory _StalwartEnv.fromEnvironment() {
    final baseUrl =
        Platform.environment['STALWART_URL'] ?? 'http://127.0.0.1:8080';
    final imapHost = Platform.environment['STALWART_IMAP_HOST'] ?? '127.0.0.1';
    final imapPort =
        int.tryParse(Platform.environment['STALWART_IMAP_PORT'] ?? '') ?? 1430;
    final smtpHost = Platform.environment['STALWART_SMTP_HOST'] ?? '127.0.0.1';
    final smtpPort =
        int.tryParse(Platform.environment['STALWART_SMTP_PORT'] ?? '') ?? 1025;
    final user = Platform.environment['STALWART_USER_B'] ?? 'alice@example.com';
    final password = Platform.environment['STALWART_PASS_B'] ?? 'secret';

    return _StalwartEnv(
      baseUrl: baseUrl,
      imapHost: imapHost,
      imapPort: imapPort,
      smtpHost: smtpHost,
      smtpPort: smtpPort,
      user: user,
      password: password,
    );
  }
}

class _Options {
  const _Options({
    required this.updates,
    required this.cycles,
    required this.imapDbs,
    required this.jmapDbs,
    required this.fuzz,
    required this.fuzzSeed,
    required this.fuzzProb,
  });

  final int updates;
  final int cycles;
  final int imapDbs;
  final int jmapDbs;
  final bool fuzz;
  final int fuzzSeed;
  final double fuzzProb;
}

enum _Protocol { imap, jmap }

_Options _parseOptions(List<String> args) {
  var updates = 10;
  var cycles = 3;
  var imapDbs = 1;
  var jmapDbs = 1;
  var fuzz = false;
  int? fuzzSeed;
  var fuzzProb = 0.15;

  final positionals = <String>[];

  for (final arg in args) {
    if (arg == '--help' || arg == '-h') {
      _printUsageAndExit(0);
    }

    if (arg.startsWith('--updates=')) {
      updates = _parsePositiveInt(arg.split('=').last, '--updates');
      continue;
    }

    if (arg.startsWith('--cycles=')) {
      cycles = _parsePositiveInt(arg.split('=').last, '--cycles');
      continue;
    }

    if (arg.startsWith('--imap-dbs=')) {
      imapDbs = _parseNonNegativeInt(arg.split('=').last, '--imap-dbs');
      continue;
    }

    if (arg.startsWith('--jmap-dbs=')) {
      jmapDbs = _parseNonNegativeInt(arg.split('=').last, '--jmap-dbs');
      continue;
    }

    if (arg == '--fuzz') {
      fuzz = true;
      continue;
    }

    if (arg.startsWith('--fuzz-seed=')) {
      fuzz = true;
      fuzzSeed = _parseNonNegativeInt(arg.split('=').last, '--fuzz-seed');
      continue;
    }

    if (arg.startsWith('--fuzz-prob=')) {
      fuzz = true;
      fuzzProb = _parseProbability(arg.split('=').last, '--fuzz-prob');
      continue;
    }

    if (arg.startsWith('-')) {
      throw StateError('Unknown option: $arg');
    }

    positionals.add(arg);
  }

  if (positionals.isNotEmpty) {
    updates = _parsePositiveInt(positionals[0], 'updates');
  }
  if (positionals.length > 1) {
    cycles = _parsePositiveInt(positionals[1], 'cycles');
  }
  if (positionals.length > 2) {
    throw StateError('Too many positional args: $positionals');
  }

  if (imapDbs == 0 && jmapDbs == 0) {
    throw StateError('At least one of --imap-dbs or --jmap-dbs must be > 0');
  }

  return _Options(
    updates: updates,
    cycles: cycles,
    imapDbs: imapDbs,
    jmapDbs: jmapDbs,
    fuzz: fuzz,
    fuzzSeed: fuzzSeed ?? DateTime.now().millisecondsSinceEpoch,
    fuzzProb: fuzzProb,
  );
}

double _parseProbability(String value, String name) {
  final parsed = double.tryParse(value);
  if (parsed == null || parsed < 0.0 || parsed > 1.0) {
    throw StateError(
      '$name must be a number in [0.0, 1.0], got "$value"',
    );
  }
  return parsed;
}

int _parsePositiveInt(String value, String name) {
  final parsed = int.tryParse(value);
  if (parsed == null || parsed <= 0) {
    throw StateError('$name must be a positive integer, got "$value"');
  }
  return parsed;
}

int _parseNonNegativeInt(String value, String name) {
  final parsed = int.tryParse(value);
  if (parsed == null || parsed < 0) {
    throw StateError('$name must be a non-negative integer, got "$value"');
  }
  return parsed;
}

Never _printUsageAndExit(int code) {
  stdout.writeln(
    'Usage: fvm flutter pub run scripts/sync_reliability.dart [updates] [cycles] '
    '[--imap-dbs=N] [--jmap-dbs=N] [--fuzz] [--fuzz-seed=N] [--fuzz-prob=0..1]\n\n'
    'Defaults: updates=10 cycles=3 imap-dbs=1 jmap-dbs=1 '
    'fuzz=off fuzz-prob=0.15\n\n'
    'Fuzz mode injects randomised network and server-edge faults around the\n'
    'IMAP/SMTP/JMAP clients (connection failures, latency, 503 responses,\n'
    'truncated bodies, stateMismatch). The sync engine is expected to recover\n'
    'and all DB snapshots must still converge. Re-run with the printed seed to\n'
    'reproduce a failure.',
  );
  exit(code);
}
