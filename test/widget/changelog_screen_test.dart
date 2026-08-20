import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/services/changelog_status_service.dart';
import 'package:sharedinbox/core/services/update_service.dart';
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
  RepoStatus? repoStatus,
  UpdateInfo? updateInfo,
}) {
  return ProviderScope(
    overrides: [
      dbProvider.overrideWith((ref) {
        final db = AppDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        return db;
      }),
      installedVersionsProvider.overrideWith((ref) async => installedVersions),
      repoStatusProvider.overrideWith((ref) async => repoStatus),
      updateInfoProvider.overrideWith((ref) async => updateInfo),
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

  testWidgets('renders the changelog body while the header still loads', (
    tester,
  ) async {
    // A repoStatusProvider that never completes leaves the header spinning.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dbProvider.overrideWith((ref) {
            final db = AppDatabase(NativeDatabase.memory());
            ref.onDispose(db.close);
            return db;
          }),
          installedVersionsProvider.overrideWith((ref) async => const {}),
          repoStatusProvider.overrideWith(
            (ref) => Completer<RepoStatus?>().future,
          ),
          updateInfoProvider.overrideWith((ref) async => null),
        ],
        child: DefaultAssetBundle(
          bundle: _FakeAssetBundle({'assets/changelog.txt': _fakeChangelog}),
          child: const MaterialApp(home: ChangeLogScreen()),
        ),
      ),
    );
    // Let the asset future resolve without settling the header spinner.
    await tester.pump();
    await tester.pump();

    expect(find.text('Checking GitHub…'), findsOneWidget);
    // The body is not blocked by the header spinner.
    expect(find.textContaining('initial release'), findsOneWidget);
  });

  testWidgets('shows how many commits behind main with the latest date', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildScreen(
        assets: {'assets/changelog.txt': _fakeChangelog},
        repoStatus: RepoStatus(
          state: RepoStatusState.behind,
          behindCount: 3,
          latestCommitDate: DateTime(2026, 8, 20),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('3 commits behind main'), findsOneWidget);
    expect(find.textContaining('20 Aug 2026'), findsOneWidget);
  });

  testWidgets('shows up to date when the build is the tip of main', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildScreen(
        assets: {'assets/changelog.txt': _fakeChangelog},
        repoStatus: const RepoStatus(state: RepoStatusState.upToDate),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Up to date with main'), findsOneWidget);
  });

  testWidgets('shows a development-build note when there is no comparison', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildScreen(
        assets: {'assets/changelog.txt': _fakeChangelog},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Development build'), findsOneWidget);
  });

  testWidgets('shows a new-app-version line when an update is available', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildScreen(
        assets: {'assets/changelog.txt': _fakeChangelog},
        repoStatus: const RepoStatus(state: RepoStatusState.upToDate),
        updateInfo: const UpdateInfo(
          latestVersion: 'v2.0',
          downloadUrl: 'https://example.com/download',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('A new app version is available (v2.0)'),
      findsOneWidget,
    );
  });
}
