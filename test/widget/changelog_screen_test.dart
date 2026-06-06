import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/changelog_screen.dart';

class _FakeAssetBundle extends CachingAssetBundle {
  final Map<String, String> _assets;
  _FakeAssetBundle(this._assets);

  @override
  Future<ByteData> load(String key) async {
    if (_assets.containsKey(key)) {
      final encoded = utf8.encode(_assets[key]!);
      return ByteData.view(Uint8List.fromList(encoded).buffer);
    }
    throw FlutterError('Asset not found: "$key"');
  }
}

Widget _buildScreen({
  required Map<String, String> assets,
  Map<String, DateTime> installedVersions = const {},
}) {
  return ProviderScope(
    overrides: [
      dbProvider.overrideWith((ref) {
        final db = AppDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        return db;
      }),
      installedVersionsProvider.overrideWith((ref) async => installedVersions),
    ],
    child: DefaultAssetBundle(
      bundle: _FakeAssetBundle(assets),
      child: const MaterialApp(home: ChangeLogScreen()),
    ),
  );
}

const _fakeChangelog =
    '* 2024-01-01 feat: initial release\n* 2024-01-02 fix: resolve crash\n';

void main() {
  testWidgets('ChangeLogScreen shows changelog content', (tester) async {
    await tester.pumpWidget(
      _buildScreen(assets: {'assets/changelog.txt': _fakeChangelog}),
    );
    await tester.pumpAndSettle();

    expect(find.text('ChangeLog'), findsOneWidget);
    expect(find.textContaining('initial release'), findsOneWidget);
    expect(find.textContaining('resolve crash'), findsOneWidget);
    expect(find.textContaining('Error loading changelog'), findsNothing);
  });

  testWidgets('ChangeLogScreen shows error when asset is missing', (
    tester,
  ) async {
    await tester.pumpWidget(_buildScreen(assets: {}));
    await tester.pumpAndSettle();

    expect(find.textContaining('Error loading changelog'), findsOneWidget);
  });

  testWidgets('ChangeLogScreen injects install marker for a known hash', (
    tester,
  ) async {
    const changelog =
        '* 2024-01-01 [abc1234](https://example.com/abc1234): feat: initial release\n';
    final installedAt = DateTime(2024, 6, 15, 14, 32);

    await tester.pumpWidget(
      _buildScreen(
        assets: {'assets/changelog.txt': changelog},
        installedVersions: {'abc1234': installedAt},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Installed: 14:32'), findsOneWidget);
    expect(find.textContaining('15 Jun 2024'), findsOneWidget);
    expect(find.textContaining('initial release'), findsOneWidget);
  });

  testWidgets('ChangeLogScreen shows no markers when no version recorded', (
    tester,
  ) async {
    const changelog =
        '* 2024-01-01 [abc1234](https://example.com/abc1234): feat: initial release\n';

    await tester.pumpWidget(
      _buildScreen(assets: {'assets/changelog.txt': changelog}),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Installed:'), findsNothing);
    expect(find.textContaining('initial release'), findsOneWidget);
  });

  testWidgets('ChangeLogScreen renders #NNN as a tappable link', (
    tester,
  ) async {
    const changelog = '* 2024-03-01 fix: resolve crash, see #42\n';

    await tester.pumpWidget(
      _buildScreen(assets: {'assets/changelog.txt': changelog}),
    );
    await tester.pumpAndSettle();

    // The link text "#42" must be visible in the rendered output.
    expect(find.textContaining('#42'), findsOneWidget);
  });
}
