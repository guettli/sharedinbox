import 'dart:io';

import 'package:sharedinbox/core/services/db_encryption_service.dart';
import 'package:sharedinbox/core/storage/db_encryption.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String dbPath;
  late DbEncryptionService service;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('si_db_enc_service_');
    dbPath = '${tmp.path}/sharedinbox.db';
    service = DbEncryptionService(dbPath);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('status() reports plaintext-with-no-pending by default', () {
    final s = service.status();
    expect(s.isEncrypted, isFalse);
    expect(s.pendingChange, isNull);
    expect(s.hasPendingChange, isFalse);
  });

  test('scheduleEnable on plaintext stages a pending enable', () {
    service.scheduleEnable();
    final s = service.status();
    expect(s.isEncrypted, isFalse);
    expect(s.pendingChange, PendingEncryptionChange.enable);
  });

  test('scheduleEnable is idempotent when already encrypted', () {
    markDbEncrypted(dbPath);
    service.scheduleEnable();
    expect(service.status().pendingChange, isNull);
  });

  test('scheduleEnable cancels a pending disable when already encrypted', () {
    markDbEncrypted(dbPath);
    service.scheduleDisable();
    expect(service.status().pendingChange, PendingEncryptionChange.disable);
    service.scheduleEnable();
    expect(service.status().pendingChange, isNull);
  });

  test('scheduleDisable on encrypted stages a pending disable', () {
    markDbEncrypted(dbPath);
    service.scheduleDisable();
    final s = service.status();
    expect(s.isEncrypted, isTrue);
    expect(s.pendingChange, PendingEncryptionChange.disable);
  });

  test('scheduleDisable cancels a pending enable when already plaintext', () {
    service.scheduleEnable();
    expect(service.status().pendingChange, PendingEncryptionChange.enable);
    service.scheduleDisable();
    expect(service.status().pendingChange, isNull);
  });

  test('cancelPendingChange clears any queued state change', () {
    service.scheduleEnable();
    service.cancelPendingChange();
    expect(service.status().pendingChange, isNull);
  });
}
