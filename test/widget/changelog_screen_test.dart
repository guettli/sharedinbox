import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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

const _fakeChangelog =
    '* 2024-01-01 feat: initial release\n* 2024-01-02 fix: resolve crash\n';

void main() {
  testWidgets('ChangeLogScreen shows changelog content', (tester) async {
    await tester.pumpWidget(
      DefaultAssetBundle(
        bundle: _FakeAssetBundle({'assets/changelog.txt': _fakeChangelog}),
        child: const MaterialApp(home: ChangeLogScreen()),
      ),
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
    await tester.pumpWidget(
      DefaultAssetBundle(
        bundle: _FakeAssetBundle({}),
        child: const MaterialApp(home: ChangeLogScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Error loading changelog'), findsOneWidget);
  });
}
