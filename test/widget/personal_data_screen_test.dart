import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/encrypted_objects/pairing.dart';
import 'package:sharedinbox/core/encrypted_objects/recovery_key.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/di.dart';

import 'entries_fakes.dart';
import 'helpers.dart';

/// The key lifecycle as the screen sees it: a status stream and scripted
/// answers.
class _FakeKeyService implements EncryptedKeyService {
  _FakeKeyService(PersonalDataStatus initial) : _status = initial;

  PersonalDataStatus _status;
  final _statuses = StreamController<PersonalDataStatus>.broadcast();
  CreateKeyResult? createResult;
  UnlockFailure? unlockFailure;
  final unlockInputs = <String>[];
  final pairingCodes = <String>[];
  final pairingRequests = <String>[];
  int pairingChecks = 0;

  void setStatus(PersonalDataStatus s) {
    _status = s;
    _statuses.add(s);
  }

  @override
  Stream<PersonalDataStatus> watchStatus(String accountId) async* {
    yield _status;
    yield* _statuses.stream;
  }

  @override
  Future<CreateKeyResult> createKey(String accountId) async {
    setStatus(PersonalDataStatus.unlocked);
    return createResult!;
  }

  @override
  Future<void> unlockWithRecoveryKey(String accountId, String input) async {
    unlockInputs.add(input);
    final failure = unlockFailure;
    if (failure != null) throw UnlockFailed(failure);
    setStatus(PersonalDataStatus.unlocked);
  }

  @override
  Future<PairingStart> startPairing(String accountId) async => (
        request: '${pairingRequestPrefix}request',
        expiresAt: DateTime.now().add(const Duration(minutes: 20)),
      );

  @override
  Future<void> checkPairing(String accountId) async {
    pairingChecks++;
  }

  @override
  Future<void> acceptPairingCode(String accountId, String text) async {
    pairingCodes.add(text);
    if (text != 'good') {
      throw const PairingRejected(PairingRejection.tampered);
    }
    setStatus(PersonalDataStatus.unlocked);
  }

  @override
  Future<String> sendPairing(String accountId, String requestText) async {
    pairingRequests.add(requestText);
    if (requestText != 'mine') {
      throw const PairingRejected(PairingRejection.wrongAccount);
    }
    return '${pairingCodePrefix}reply';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_FakeKeyService> _pump(
  WidgetTester tester,
  PersonalDataStatus status, {
  bool beta = true,
  String location = '/accounts/acc-1/personal-data',
}) async {
  final service = _FakeKeyService(status);
  await tester.pumpWidget(
    buildApp(
      initialLocation: location,
      userPreferences: FakeUserPreferencesRepository(personalDataBeta: beta),
      overrides: [
        ...baseOverrides(accounts: [kTestAccount]),
        encryptedKeyServiceProvider.overrideWithValue(service),
        entryRepositoryProvider.overrideWithValue(FakeEntryRepository()),
      ],
    ),
  );
  await tester.pumpAndSettle();
  return service;
}

void main() {
  testWidgets('setup shows the recovery key and checks the last group',
      (tester) async {
    final key = RecoveryKey.generate();
    final formatted = await tester.runAsync(key.format);
    final service = await _pump(tester, PersonalDataStatus.notSetUp);
    service.createResult = KeyCreated(key, formatted!);
    expect(find.textContaining('server cannot read them'), findsOneWidget);

    await tester.tap(find.byKey(const Key('personalDataGenerate')));
    await tester.pumpAndSettle();

    expect(find.text(formatted), findsOneWidget);
    expect(find.byKey(const Key('recoveryKeyQrCode')), findsOneWidget);
    await tester.tap(find.byKey(const Key('recoveryKeySaved')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('recoveryKeyConfirmField')),
      'WRNG',
    );
    await tester.tap(find.byKey(const Key('recoveryKeyConfirm')));
    await tester.pumpAndSettle();
    expect(find.text('This does not match the last group.'), findsOneWidget);

    // Lenient: lower case is fine.
    await tester.enterText(
      find.byKey(const Key('recoveryKeyConfirmField')),
      formatted.split('-').last.toLowerCase(),
    );
    await tester.tap(find.byKey(const Key('recoveryKeyConfirm')));
    await tester.pumpAndSettle();
    expect(find.text('Unlocked on this device'), findsOneWidget);
  });

  testWidgets('unlock shows the reason it failed, then unlocks',
      (tester) async {
    final service = await _pump(tester, PersonalDataStatus.locked);
    expect(find.byKey(const Key('pairReceiveStart')), findsOneWidget);

    service.unlockFailure = UnlockFailure.badChecksum;
    await tester.enterText(find.byKey(const Key('recoveryKeyField')), 'abc');
    await tester.tap(find.byKey(const Key('recoveryKeyUnlock')));
    await tester.pumpAndSettle();
    expect(find.textContaining('has a typo'), findsOneWidget);

    service.unlockFailure = UnlockFailure.noSlotOpens;
    await tester.tap(find.byKey(const Key('recoveryKeyUnlock')));
    await tester.pumpAndSettle();
    expect(find.textContaining('does not unlock'), findsOneWidget);

    service.unlockFailure = null;
    await tester.tap(find.byKey(const Key('recoveryKeyUnlock')));
    await tester.pumpAndSettle();
    expect(service.unlockInputs, ['abc', 'abc', 'abc']);
    expect(find.text('Unlocked on this device'), findsOneWidget);
  });

  testWidgets('pairing: the request as QR code, then a pasted code unlocks',
      (tester) async {
    final service = await _pump(tester, PersonalDataStatus.locked);
    await tester.tap(find.byKey(const Key('pairReceiveStart')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pairRequestQrCode')), findsOneWidget);
    expect(find.text('${pairingRequestPrefix}request'), findsOneWidget);
    expect(find.byKey(const Key('pairCountdown')), findsOneWidget);

    // The keys folder is checked while the view waits.
    await tester.pump(const Duration(seconds: 10));
    expect(service.pairingChecks, 1);

    final field = find.byKey(const Key('pairingCodeField'));
    await tester.scrollUntilVisible(
      field,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(field, 'bad');
    await tester.tap(find.byKey(const Key('pairingCodeAccept')));
    await tester.pumpAndSettle();
    expect(find.textContaining('could not be decrypted'), findsOneWidget);

    await tester.enterText(field, 'good');
    await tester.tap(find.byKey(const Key('pairingCodeAccept')));
    await tester.pumpAndSettle();
    expect(service.pairingCodes, ['bad', 'good']);
    expect(find.text('Unlocked on this device'), findsOneWidget);
  });

  testWidgets('pair a new device: another account is refused, then sent',
      (tester) async {
    final service = await _pump(tester, PersonalDataStatus.unlocked);
    await tester.tap(find.byKey(const Key('pairSendStart')));
    await tester.pumpAndSettle();

    // No camera in tests: the paste form.
    final field = find.byKey(const Key('pairingRequestField'));
    await tester.enterText(field, 'other');
    await tester.tap(find.byKey(const Key('pairingSend')));
    await tester.pumpAndSettle();
    expect(find.textContaining('for another account'), findsOneWidget);
    expect(find.byKey(const Key('pairingSent')), findsNothing);

    await tester.enterText(field, 'mine');
    await tester.tap(find.byKey(const Key('pairingSend')));
    await tester.pumpAndSettle();
    expect(service.pairingRequests, ['other', 'mine']);
    expect(find.byKey(const Key('pairingSent')), findsOneWidget);
    expect(find.byKey(const Key('pairingCodeQrCode')), findsOneWidget);
    expect(find.text('${pairingCodePrefix}reply'), findsOneWidget);
  });

  testWidgets('a lost race asks for the other device’s recovery key',
      (tester) async {
    await _pump(tester, PersonalDataStatus.lostRace);
    expect(
      find.text(
        'Another device set up encryption first — enter its recovery key.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('recoveryKeyField')), findsOneWidget);
  });

  testWidgets('unlocked: the Entries tile opens the entries home',
      (tester) async {
    await _pump(tester, PersonalDataStatus.unlocked);
    await tester.tap(find.byKey(const Key('entriesTile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('entriesQuickAdd')), findsOneWidget);
    expect(find.text('No entries yet.'), findsOneWidget);
  });

  testWidgets('a foreign key mail shows a warning', (tester) async {
    await _pump(tester, PersonalDataStatus.foreignKeyWarning);
    expect(find.byKey(const Key('foreignKeyWarning')), findsOneWidget);
  });

  testWidgets('the account home entry shows only with the beta switch on',
      (tester) async {
    await _pump(
      tester,
      PersonalDataStatus.notSetUp,
      beta: false,
      location: '/accounts/acc-1',
    );
    expect(find.text('Personal data (beta)'), findsNothing);

    await _pump(
      tester,
      PersonalDataStatus.notSetUp,
      location: '/accounts/acc-1',
    );
    await tester.scrollUntilVisible(find.text('Personal data (beta)'), 200);
    await tester.tap(find.text('Personal data (beta)'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('personalDataGenerate')), findsOneWidget);
  });

  testWidgets('with the switch off the screen points to Preferences',
      (tester) async {
    await _pump(tester, PersonalDataStatus.notSetUp, beta: false);
    expect(find.textContaining('in Preferences'), findsOneWidget);
  });
}
