import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/encrypted_objects/pairing.dart';
import 'package:sharedinbox/core/encrypted_objects/passkey_slot.dart';
import 'package:sharedinbox/core/encrypted_objects/passphrase.dart';
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

  /// What [hasKeyMails] says.
  bool keyMailsVisible = true;

  @override
  Future<bool> hasKeyMails(String accountId) async => keyMailsVisible;
  CreateKeyResult? createResult;
  UnlockFailure? unlockFailure;
  final unlockInputs = <String>[];
  final pairingCodes = <String>[];
  final pairingRequests = <String>[];
  int pairingChecks = 0;
  bool hasPassphrase = false;
  Object? passphraseError;
  final passphrases = <String>[];
  @override
  bool passkeysAvailable = false;
  final passkeys = <PasskeySlotInfo>[];
  Object? passkeyError;
  UnlockFailure? passkeyUnlockFailure;
  final passkeyLabels = <String>[];
  final removedPasskeys = <String>[];

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
        fingerprint: 'ABCD-EFGH-JKMN-PQRS',
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
  Future<bool> hasPassphraseSlot(String accountId) async => hasPassphrase;

  @override
  Future<void> addPassphraseSlot(String accountId, String passphrase) async {
    passphrases.add(passphrase);
    final error = passphraseError;
    if (error != null) throw error;
    hasPassphrase = true;
  }

  @override
  Future<void> unlockWithPassphrase(String accountId, String passphrase) async {
    passphrases.add(passphrase);
    if (passphrase != 'good') {
      throw const UnlockFailed(UnlockFailure.noSlotOpens);
    }
    setStatus(PersonalDataStatus.unlocked);
  }

  @override
  Future<List<PasskeySlotInfo>> passkeySlots(String accountId) async =>
      List.of(passkeys);

  @override
  Future<PasskeySlotInfo> addPasskeySlot(
    String accountId, {
    String label = '',
  }) async {
    passkeyLabels.add(label);
    final error = passkeyError;
    if (error != null) throw error;
    final info = _passkey(passkeys.length + 1, label);
    passkeys.add(info);
    return info;
  }

  @override
  Future<void> removePasskeySlot(String accountId, String slotId) async {
    removedPasskeys.add(slotId);
    passkeys.removeWhere((p) => p.slotIdB64 == slotId);
  }

  @override
  Future<void> unlockWithPasskey(String accountId) async {
    final failure = passkeyUnlockFailure;
    if (failure != null) throw UnlockFailed(failure);
    setStatus(PersonalDataStatus.unlocked);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PasskeySlotInfo _passkey(int n, String label) => PasskeySlotInfo(
      slotId: Uint8List(16)..fillRange(0, 16, n),
      credentialId: Uint8List(16)..fillRange(0, 16, 0x40 + n),
      prfSalt: Uint8List(32),
      rpId: passkeyRpId,
      label: label,
    );

Future<_FakeKeyService> _pump(
  WidgetTester tester,
  PersonalDataStatus status, {
  bool beta = true,
  bool hasPassphrase = false,
  bool passkeys = false,
  List<PasskeySlotInfo> passkeySlots = const [],
  String location = '/accounts/acc-1/personal-data',
  bool keyMailsVisible = true,
}) async {
  final service = _FakeKeyService(status)
    ..keyMailsVisible = keyMailsVisible
    ..hasPassphrase = hasPassphrase
    ..passkeysAvailable = passkeys
    ..passkeys.addAll(passkeySlots);
  await tester.pumpWidget(
    buildApp(
      initialLocation: location,
      userPreferences: FakeUserPreferencesRepository(personalDataBeta: beta),
      overrides: [
        ...baseOverrides(accounts: [kTestAccount]),
        encryptedKeyServiceProvider.overrideWithValue(service),
        entryRepositoryProvider.overrideWithValue(FakeEntryRepository()),
        mailObjectStoreProvider.overrideWithValue(FakeConflictStore({})),
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
    expect(find.byKey(const Key('pairRequestSecretWarning')), findsOneWidget);
    final countdown = find.byKey(const Key('pairCountdown'));
    await tester.scrollUntilVisible(
      countdown,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('ABCD-EFGH-JKMN-PQRS'), findsOneWidget);
    expect(countdown, findsOneWidget);

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

  testWidgets('a pasted request is sent only after comparing the codes',
      (tester) async {
    final service = await _pump(tester, PersonalDataStatus.unlocked);
    await tester.tap(find.byKey(const Key('pairSendStart')));
    await tester.pumpAndSettle();
    final request = PairingRequest(
      keyId: Uint8List.fromList(List.filled(16, 1)),
      publicKey: Uint8List.fromList(List.filled(32, 2)),
      secret: Uint8List.fromList(List.filled(16, 3)),
      server: 'imap.example.com',
      username: 'alice@example.com',
    );
    final text = encodePairingRequest(request);
    await tester.enterText(
      find.byKey(const Key('pairingRequestField')),
      text,
    );
    await tester.tap(find.byKey(const Key('pairingSend')));
    await tester.pumpAndSettle();
    expect(find.text(pairingFingerprint(request)), findsOneWidget);

    await tester.tap(find.byKey(const Key('pairingFingerprintMismatch')));
    await tester.pumpAndSettle();
    expect(service.pairingRequests, isEmpty);

    await tester.tap(find.byKey(const Key('pairingSend')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pairingFingerprintMatch')));
    await tester.pumpAndSettle();
    expect(service.pairingRequests, [text]);
  });

  testWidgets(
      'add a passphrase: the brute-force warning, weak ones cannot be saved, '
      'offline says it needs a connection', (tester) async {
    final service = await _pump(tester, PersonalDataStatus.unlocked);
    expect(find.byKey(const Key('passphraseRemove')), findsNothing);
    await tester.tap(find.byKey(const Key('passphraseAdd')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('passphraseBruteForceWarning')),
      findsOneWidget,
    );
    expect(find.textContaining('offline without limit'), findsOneWidget);

    FilledButton save() =>
        tester.widget(find.byKey(const Key('passphraseSave')));
    final field = find.byKey(const Key('passphraseNewField'));
    final confirm = find.byKey(const Key('passphraseConfirmField'));

    await tester.enterText(field, 'short');
    await tester.enterText(confirm, 'short');
    await tester.pump();
    expect(
      find.text('Use at least $minPassphraseLength characters.'),
      findsOneWidget,
    );
    expect(save().onPressed, isNull);

    await tester.enterText(field, 'password1234');
    await tester.enterText(confirm, 'password1234');
    await tester.pump();
    expect(find.text('This is a common password.'), findsOneWidget);
    expect(save().onPressed, isNull);

    const good = 'violet tractor sings beneath copper rain';
    await tester.enterText(field, good);
    await tester.enterText(confirm, '${good}s');
    await tester.pump();
    expect(find.text('The passphrases differ.'), findsOneWidget);
    expect(save().onPressed, isNull);

    await tester.enterText(confirm, good);
    await tester.pump();
    expect(save().onPressed, isNotNull);

    service.passphraseError =
        const KeyMailOfflineException(SocketException('offline'));
    await tester.tap(find.byKey(const Key('passphraseSave')));
    await tester.pumpAndSettle();
    expect(find.textContaining('needs a connection'), findsOneWidget);

    service.passphraseError = null;
    await tester.tap(find.byKey(const Key('passphraseSave')));
    await tester.pumpAndSettle();
    expect(service.passphrases, [good, good]);
    expect(find.byKey(const Key('passphraseBruteForceWarning')), findsNothing);
    expect(find.byKey(const Key('passphraseChange')), findsOneWidget);
    expect(find.byKey(const Key('passphraseRemove')), findsOneWidget);
  });

  testWidgets('the passphrase unlock shows only with a passphrase slot',
      (tester) async {
    await _pump(tester, PersonalDataStatus.locked);
    expect(find.byKey(const Key('recoveryKeyField')), findsOneWidget);
    expect(find.byKey(const Key('passphraseField')), findsNothing);

    final service =
        await _pump(tester, PersonalDataStatus.locked, hasPassphrase: true);
    final field = find.byKey(const Key('passphraseField'));
    await tester.scrollUntilVisible(
      field,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(field, 'bad');
    await tester.ensureVisible(find.byKey(const Key('passphraseUnlock')));
    await tester.tap(find.byKey(const Key('passphraseUnlock')));
    await tester.pumpAndSettle();
    expect(find.textContaining('passphrase does not unlock'), findsOneWidget);

    await tester.enterText(field, 'good');
    await tester.tap(find.byKey(const Key('passphraseUnlock')));
    await tester.pumpAndSettle();
    expect(service.passphrases, ['bad', 'good']);
    expect(find.text('Unlocked on this device'), findsOneWidget);
  });

  testWidgets('passkeys show only with a provider', (tester) async {
    await _pump(
      tester,
      PersonalDataStatus.locked,
      passkeySlots: [_passkey(1, 'Phone')],
    );
    expect(find.byKey(const Key('passkeyUnlock')), findsNothing);
    await _pump(tester, PersonalDataStatus.unlocked);
    expect(find.byKey(const Key('passkeySection')), findsNothing);

    // With a provider, the unlock button needs a passkey slot.
    await _pump(tester, PersonalDataStatus.locked, passkeys: true);
    expect(find.byKey(const Key('passkeyUnlock')), findsNothing);
    await _pump(tester, PersonalDataStatus.unlocked, passkeys: true);
    expect(find.byKey(const Key('passkeySection')), findsOneWidget);
  });

  testWidgets('unlock with passkey: the reason it failed, then unlocks',
      (tester) async {
    final service = await _pump(
      tester,
      PersonalDataStatus.locked,
      passkeys: true,
      passkeySlots: [_passkey(1, 'Phone')],
    );
    final button = find.byKey(const Key('passkeyUnlock'));
    expect(button, findsOneWidget);

    for (final (failure, text) in [
      (UnlockFailure.passkeyCancelled, 'Cancelled.'),
      (UnlockFailure.passkeyUnsupported, 'does not support passkey'),
      (UnlockFailure.noPasskeySlot, 'has no passkey'),
      (UnlockFailure.noSlotOpens, 'None of your passkeys'),
    ]) {
      service.passkeyUnlockFailure = failure;
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.textContaining(text), findsOneWidget, reason: '$failure');
    }

    service.passkeyUnlockFailure = null;
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('Unlocked on this device'), findsOneWidget);
  });

  testWidgets('add a passkey: no PRF fails cleanly, then one is added',
      (tester) async {
    final service = await _pump(
      tester,
      PersonalDataStatus.unlocked,
      passkeys: true,
      passkeySlots: [_passkey(1, 'Phone')],
    );
    final add = find.byKey(const Key('passkeyAdd'));
    await tester.scrollUntilVisible(
      add,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Phone'), findsOneWidget);
    expect(find.textContaining('Keep your recovery key'), findsOneWidget);
    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('passkeyLabelField')), 'Tab');

    service.passkeyError = const PrfUnsupported('no PRF');
    await tester.tap(find.byKey(const Key('passkeySave')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('does not support passkey encryption (PRF)'),
      findsOneWidget,
    );
    expect(find.textContaining('delete the passkey'), findsOneWidget);

    service.passkeyError =
        const KeyMailOfflineException(SocketException('offline'));
    await tester.tap(find.byKey(const Key('passkeySave')));
    await tester.pumpAndSettle();
    expect(find.textContaining('needs a connection'), findsOneWidget);

    service.passkeyError = null;
    await tester.tap(find.byKey(const Key('passkeySave')));
    await tester.pumpAndSettle();
    expect(service.passkeyLabels, ['Tab', 'Tab', 'Tab']);
    expect(find.byKey(const Key('passkeySave')), findsNothing);
    expect(find.text('Tab'), findsOneWidget);
  });

  testWidgets('remove a passkey after confirming', (tester) async {
    final first = _passkey(1, 'Phone');
    final service = await _pump(
      tester,
      PersonalDataStatus.unlocked,
      passkeys: true,
      passkeySlots: [first, _passkey(2, 'Tablet')],
    );
    final remove = find.byKey(Key('passkeyRemove-${first.slotIdB64}'));
    await tester.scrollUntilVisible(
      remove,
      200,
      scrollable: find.byType(Scrollable).first,
    );

    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(service.removedPasskeys, isEmpty);

    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('passkeyRemoveConfirm')));
    await tester.pumpAndSettle();
    expect(service.removedPasskeys, [first.slotIdB64]);
    expect(find.text('Phone'), findsNothing);
    expect(find.text('Tablet'), findsOneWidget);
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

  testWidgets('locked with no key mail visible explains, no unlock form',
      (tester) async {
    await _pump(tester, PersonalDataStatus.locked, keyMailsVisible: false);
    expect(find.byKey(const Key('personalDataKeysMissing')), findsOneWidget);
    expect(find.textContaining('remove the account'), findsOneWidget);
  });
}
