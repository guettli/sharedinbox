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
  bool isLocalhost = false,
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
            isLocalhost: isLocalhost,
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
    expect(
      find.text('On: implicit TLS (standard IMAP port 993)'),
      findsOneWidget,
    );
    expect(find.textContaining('Off:'), findsNothing);

    await tester.tap(find.byKey(_key));
    await tester.pump();
    expect(
      find.text('Off: upgrade with STARTTLS (standard IMAP port 143)'),
      findsOneWidget,
    );
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
    expect(
      find.text('Off: upgrade with STARTTLS (standard SMTP port 587)'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(_key));
    await tester.pump();
    expect(ctrl.text, '465');
  });

  testWidgets('subtitle changes from Off to On', (tester) async {
    await _pump(
      tester,
      protocol: TlsProtocol.smtp,
      initial: false,
      port: '587',
    );
    expect(find.textContaining('On:'), findsNothing);

    await tester.tap(find.byKey(_key));
    await tester.pump();
    expect(
      find.text('On: implicit TLS (standard SMTP port 465)'),
      findsOneWidget,
    );
    expect(find.textContaining('Off:'), findsNothing);
  });

  testWidgets('Off on localhost says plaintext, not STARTTLS', (tester) async {
    await _pump(
      tester,
      protocol: TlsProtocol.imap,
      initial: false,
      port: '1430',
      isLocalhost: true,
    );
    expect(
      find.text('Off: plaintext, localhost only (standard IMAP port 143)'),
      findsOneWidget,
    );
    expect(find.textContaining('STARTTLS'), findsNothing);
  });

  testWidgets('toggling fills an empty port with the standard one', (
    tester,
  ) async {
    final ctrl = await _pump(
      tester,
      protocol: TlsProtocol.imap,
      initial: false,
      port: '',
    );

    await tester.tap(find.byKey(_key));
    await tester.pump();
    expect(ctrl.text, '993');
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
