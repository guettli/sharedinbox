import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/encrypted_objects/entry_export.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/utils/save_file_as.dart';

import 'entries_fakes.dart';
import 'helpers.dart';

const _fileName = 'sharedinbox-export-alice@example.com-20261123-101010.zip';

class _FakeExportService implements EntryExportService {
  _FakeExportService({this.missing = const []});

  final List<String> missing;
  final exported = <String>[];
  final zip = Uint8List.fromList([0x50, 0x4b, 5, 6]);

  @override
  Future<EntryExportResult> export(Account account) async {
    exported.add(account.id);
    return (
      zip: zip,
      fileName: _fileName,
      entries: 3,
      conflictVersions: 1,
      images: 2,
      missingImages: missing,
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  _FakeExportService service,
  SaveLocationPicker picker,
) async {
  await tester.pumpWidget(
    buildApp(
      initialLocation: '/accounts/acc-1/personal-data',
      userPreferences: FakeUserPreferencesRepository(personalDataBeta: true),
      overrides: [
        ...baseOverrides(accounts: [kTestAccount]),
        encryptedKeyServiceProvider.overrideWithValue(
          FixedStatusKeyService(PersonalDataStatus.unlocked),
        ),
        entryRepositoryProvider.overrideWithValue(FakeEntryRepository()),
        mailObjectStoreProvider.overrideWithValue(FakeConflictStore({})),
        entryExportServiceProvider.overrideWithValue(service),
        saveLocationPickerProvider.overrideWithValue(picker),
      ],
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _startExport(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('exportPersonalData')));
  await tester.tap(find.byKey(const Key('exportPersonalData')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('exportPlaintextWarning')), findsOneWidget);
  expect(find.textContaining('NOT encrypted'), findsOneWidget);
}

/// Writing the ZIP is real I/O: alternate real waits with pumps.
Future<void> _waitForSnackBar(WidgetTester tester) async {
  for (var i = 0; i < 50; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (find.textContaining('Exported to').evaluate().isNotEmpty) return;
  }
}

/// The tile spinner keeps running behind the dialog, so pumpAndSettle
/// would time out: pump past the dialog's entrance instead.
Future<void> _pumpUntilMissingImagesDialog(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// Runs [body] as on Linux, where the export uses "Save as…". Reset inside
/// the body: the post-test invariant check runs before tearDown callbacks.
Future<void> _onLinux(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  testWidgets('Cancel on the plaintext warning exports nothing',
      (tester) async {
    final service = _FakeExportService();
    final names = <String>[];
    await _pump(tester, service, (name) async {
      names.add(name);
      return null;
    });
    await _startExport(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('exportPlaintextWarning')), findsNothing);
    expect(service.exported, isEmpty);
    expect(names, isEmpty);
  });

  testWidgets('confirm saves the ZIP where the user picks', (tester) async {
    await _onLinux(() async {
      final dir = Directory.systemTemp.createTempSync('export_save');
      addTearDown(() => dir.deleteSync(recursive: true));
      final target = '${dir.path}/export.zip';
      final service = _FakeExportService();
      final names = <String>[];
      await _pump(tester, service, (name) async {
        names.add(name);
        return target;
      });
      await _startExport(tester);
      await tester.tap(find.byKey(const Key('exportConfirm')));
      await _waitForSnackBar(tester);

      expect(service.exported, ['acc-1']);
      expect(names, [_fileName]);
      expect(find.byKey(const Key('exportMissingImages')), findsNothing);
      expect(File(target).readAsBytesSync(), service.zip);
      expect(find.text('Exported to $target'), findsOneWidget);
    });
  });

  testWidgets('missing images: Cancel saves nothing', (tester) async {
    await _onLinux(() async {
      final service = _FakeExportService(missing: ['a', 'b']);
      final names = <String>[];
      await _pump(tester, service, (name) async {
        names.add(name);
        return null;
      });
      await _startExport(tester);
      await tester.tap(find.byKey(const Key('exportConfirm')));
      await _pumpUntilMissingImagesDialog(tester);

      expect(find.byKey(const Key('exportMissingImages')), findsOneWidget);
      expect(
        find.textContaining('2 images could not be loaded'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('exportMissingImages')), findsNothing);
      expect(names, isEmpty);
    });
  });

  testWidgets('missing images: Save anyway saves', (tester) async {
    await _onLinux(() async {
      final dir = Directory.systemTemp.createTempSync('export_save');
      addTearDown(() => dir.deleteSync(recursive: true));
      final target = '${dir.path}/export.zip';
      final service = _FakeExportService(missing: ['a']);
      final names = <String>[];
      await _pump(tester, service, (name) async {
        names.add(name);
        return target;
      });
      await _startExport(tester);
      await tester.tap(find.byKey(const Key('exportConfirm')));
      await _pumpUntilMissingImagesDialog(tester);
      expect(
        find.textContaining('1 image could not be loaded'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('exportSaveAnyway')));
      await _waitForSnackBar(tester);

      expect(names, [_fileName]);
      expect(File(target).readAsBytesSync(), service.zip);
    });
  });
}
