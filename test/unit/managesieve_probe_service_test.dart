import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/services/managesieve_probe_service.dart';

const _imapAccount = Account(
  id: 'acc-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

class _RecordingRepo implements AccountRepository {
  final updates = <Account>[];

  @override
  Future<void> updateAccount(Account account, {String? password}) async {
    updates.add(account);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ManageSieveProbeService _service(_RecordingRepo repo, {required bool result}) {
  return ManageSieveProbeService(
    repo,
    probeFn:
        ({
          required String host,
          required int port,
          required bool useTls,
        }) async => result,
  );
}

void main() {
  group('ManageSieveProbeService', () {
    test('marks unavailable when probe fails', () async {
      final repo = _RecordingRepo();
      await _service(repo, result: false).probe(_imapAccount);
      expect(repo.updates, hasLength(1));
      expect(repo.updates.first.manageSieveAvailable, false);
    });

    test('marks available when probe succeeds', () async {
      final repo = _RecordingRepo();
      await _service(repo, result: true).probe(_imapAccount);
      expect(repo.updates, hasLength(1));
      expect(repo.updates.first.manageSieveAvailable, true);
    });

    test('skips DB write when result matches stored value', () async {
      final repo = _RecordingRepo();
      const account = Account(
        id: 'acc-1',
        displayName: 'Alice',
        email: 'alice@example.com',
        imapHost: 'imap.example.com',
        smtpHost: 'smtp.example.com',
        manageSieveAvailable: false,
      );
      await _service(repo, result: false).probe(account);
      expect(repo.updates, isEmpty);
    });

    test('skips JMAP accounts entirely', () async {
      final repo = _RecordingRepo();
      var probeCalled = false;
      final svc = ManageSieveProbeService(
        repo,
        probeFn:
            ({
              required String host,
              required int port,
              required bool useTls,
            }) async {
              probeCalled = true;
              return true;
            },
      );
      const jmap = Account(
        id: 'acc-2',
        displayName: 'Bob',
        email: 'bob@example.com',
        type: AccountType.jmap,
        jmapUrl: 'https://example.com/jmap/session',
      );
      await svc.probe(jmap);
      expect(probeCalled, false);
      expect(repo.updates, isEmpty);
    });

    test('skips when imapHost and manageSieveHost are both empty', () async {
      final repo = _RecordingRepo();
      var probeCalled = false;
      final svc = ManageSieveProbeService(
        repo,
        probeFn:
            ({
              required String host,
              required int port,
              required bool useTls,
            }) async {
              probeCalled = true;
              return true;
            },
      );
      const blank = Account(
        id: 'acc-3',
        displayName: 'Carol',
        email: 'carol@example.com',
      );
      await svc.probe(blank);
      expect(probeCalled, false);
      expect(repo.updates, isEmpty);
    });

    test('uses manageSieveHost override when set', () async {
      final repo = _RecordingRepo();
      String? probedHost;
      int? probedPort;
      bool? probedTls;
      final svc = ManageSieveProbeService(
        repo,
        probeFn:
            ({
              required String host,
              required int port,
              required bool useTls,
            }) async {
              probedHost = host;
              probedPort = port;
              probedTls = useTls;
              return true;
            },
      );
      const account = Account(
        id: 'acc-1',
        displayName: 'Alice',
        email: 'alice@example.com',
        imapHost: 'imap.example.com',
        smtpHost: 'smtp.example.com',
        manageSieveHost: 'sieve.elsewhere.com',
        manageSievePort: 2000,
        manageSieveSsl: false,
      );
      await svc.probe(account);
      expect(probedHost, 'sieve.elsewhere.com');
      expect(probedPort, 2000);
      expect(probedTls, false);
    });

    test('falls back to imapHost when manageSieveHost is blank', () async {
      final repo = _RecordingRepo();
      String? probedHost;
      final svc = ManageSieveProbeService(
        repo,
        probeFn:
            ({
              required String host,
              required int port,
              required bool useTls,
            }) async {
              probedHost = host;
              return true;
            },
      );
      await svc.probe(_imapAccount);
      expect(probedHost, 'imap.example.com');
    });
  });
}
