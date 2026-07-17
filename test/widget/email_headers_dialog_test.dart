import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/ui/router.dart' show SieveEditPrefill;
import 'package:sharedinbox/ui/widgets/email_headers_dialog.dart';

/// Records the target path + extra of every `context.push` performed inside
/// the header dialog's action bottom sheet.
class _RecordingRouter {
  final pushes = <({String path, Object? extra})>[];

  GoRouter build(Widget child) => GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, __) => child),
          GoRoute(
            path: '/accounts/:accountId/search',
            builder: (ctx, state) {
              pushes.add((path: state.uri.toString(), extra: state.extra));
              return const Scaffold(body: Text('search'));
            },
          ),
          GoRoute(
            path: '/accounts/:accountId/sieve/edit',
            builder: (ctx, state) {
              pushes.add((path: state.uri.toString(), extra: state.extra));
              return const Scaffold(body: Text('remote'));
            },
          ),
          GoRoute(
            path: '/accounts/:accountId/sieve/local/edit',
            builder: (ctx, state) {
              pushes.add((path: state.uri.toString(), extra: state.extra));
              return const Scaffold(body: Text('local'));
            },
          ),
        ],
      );
}

Future<void> _openDialog(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  // Headers dialog buckets `List-*` headers into the "List- Headers" section.
  await tester.tap(find.text('List- Headers (1)'));
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.more_vert));
  await tester.pumpAndSettle();
}

void main() {
  const testHeader = EmailHeader(
    name: 'List-Id',
    value: '<newsletter.example.com>',
  );

  Widget makeApp(_RecordingRouter recorder) {
    // A tiny host page that just shows a button to open the headers dialog.
    return Builder(
      builder: (ctx) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => showDialog<void>(
              context: ctx,
              builder: (dctx) => const EmailHeadersDialog(
                headers: [testHeader],
                accountId: 'acc-1',
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
  }

  testWidgets('search action pushes /accounts/:id/search with header filter',
      (tester) async {
    final recorder = _RecordingRouter();
    final router = recorder.build(makeApp(recorder));
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));

    await _openDialog(tester);
    await tester.tap(find.text('Search mails with this header'));
    await tester.pumpAndSettle();

    expect(recorder.pushes, hasLength(1));
    expect(recorder.pushes.first.path, '/accounts/acc-1/search');
    final filter = recorder.pushes.first.extra as FilterGroup;
    final leaf = filter.children.first as FilterLeaf;
    expect(leaf.field, FilterField.header);
    expect(leaf.headerName, 'List-Id');
    expect(leaf.value, '<newsletter.example.com>');
    expect(leaf.comparison, FilterComparison.is_);
    // The headers dialog must not remain on top of the destination screen —
    // see #269.
    expect(find.text('Mail Headers'), findsNothing);
  });

  testWidgets('remote-filter action pushes sieve/edit with prefill',
      (tester) async {
    final recorder = _RecordingRouter();
    final router = recorder.build(makeApp(recorder));
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));

    await _openDialog(tester);
    await tester.tap(find.text('Create remote filter'));
    await tester.pumpAndSettle();

    expect(recorder.pushes, hasLength(1));
    expect(recorder.pushes.first.path, '/accounts/acc-1/sieve/edit');
    final prefill = recorder.pushes.first.extra as SieveEditPrefill;
    expect(prefill.name, startsWith('List-Id: '));
    final leaf = prefill.filter.children.first as FilterLeaf;
    expect(leaf.field, FilterField.header);
    expect(leaf.headerName, 'List-Id');
    expect(find.text('Mail Headers'), findsNothing);
  });

  testWidgets('local-filter action pushes sieve/local/edit', (tester) async {
    final recorder = _RecordingRouter();
    final router = recorder.build(makeApp(recorder));
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));

    await _openDialog(tester);
    await tester.tap(find.text('Create local filter'));
    await tester.pumpAndSettle();

    expect(recorder.pushes, hasLength(1));
    expect(recorder.pushes.first.path, '/accounts/acc-1/sieve/local/edit');
    expect(recorder.pushes.first.extra, isA<SieveEditPrefill>());
    expect(find.text('Mail Headers'), findsNothing);
  });
}
