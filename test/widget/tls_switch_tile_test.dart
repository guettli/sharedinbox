import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/ui/widgets/tls_switch_tile.dart';

const _key = Key('sslSwitch');

/// Hosts a [TlsSwitchTile] with its own bool state, like the account forms.
Future<TextEditingController> _pump(
  WidgetTester tester, {
  required TlsProtocol protocol,
  required bool initial,
  required String port,
}) async {
  final ctrl = TextEditingController(text: port);
  addTearDown(ctrl.dispose);
  var ssl = initial;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => TlsSwitchTile(
            switchKey: _key,
            protocol: protocol,
            value: ssl,
            portController: ctrl,
            onChanged: (v) => setState(() => ssl = v),
          ),
        ),
      ),
    ),
  );
  return ctrl;
}

void main() {
  testWidgets('subtitle describes the current state', (tester) async {
    await _pump(tester, protocol: TlsProtocol.imap, initial: true, port: '993');
    expect(find.text('On: implicit TLS (IMAP 993)'), findsOneWidget);
    expect(find.textContaining('Off:'), findsNothing);

    await tester.tap(find.byKey(_key));
    await tester.pump();
    expect(find.text('Off: upgrade with STARTTLS (IMAP 143)'), findsOneWidget);
    expect(find.textContaining('On:'), findsNothing);
  });

  testWidgets('toggling moves a standard IMAP port along', (tester) async {
    final ctrl = await _pump(
      tester,
      protocol: TlsProtocol.imap,
      initial: true,
      port: '993',
    );

    await tester.tap(find.byKey(_key));
    await tester.pump();
    expect(ctrl.text, '143');

    await tester.tap(find.byKey(_key));
    await tester.pump();
    expect(ctrl.text, '993');
  });

  testWidgets('toggling moves a standard SMTP port along', (tester) async {
    final ctrl = await _pump(
      tester,
      protocol: TlsProtocol.smtp,
      initial: true,
      port: '465',
    );

    await tester.tap(find.byKey(_key));
    await tester.pump();
    expect(ctrl.text, '587');
    expect(find.text('Off: upgrade with STARTTLS (SMTP 587)'), findsOneWidget);
  });

  testWidgets('toggling keeps a custom port', (tester) async {
    final ctrl = await _pump(
      tester,
      protocol: TlsProtocol.imap,
      initial: true,
      port: '1430',
    );

    await tester.tap(find.byKey(_key));
    await tester.pump();
    expect(ctrl.text, '1430');
  });
}
