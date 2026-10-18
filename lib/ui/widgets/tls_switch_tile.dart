import 'package:flutter/material.dart';

/// A mail protocol with its standard implicit-TLS and STARTTLS ports.
enum TlsProtocol {
  imap('IMAP', implicitTlsPort: 993, startTlsPort: 143),
  smtp('SMTP', implicitTlsPort: 465, startTlsPort: 587);

  const TlsProtocol(
    this.label, {
    required this.implicitTlsPort,
    required this.startTlsPort,
  });

  final String label;
  final int implicitTlsPort;
  final int startTlsPort;

  int defaultPort({required bool ssl}) => ssl ? implicitTlsPort : startTlsPort;
}

/// The "SSL/TLS" switch of the IMAP/SMTP account forms.
///
/// The subtitle describes the *current* state — it used to always read
/// "Off: upgrade with STARTTLS", even while the switch was on. Toggling also
/// moves [portController] to the other standard port (993 ⇄ 143,
/// 465 ⇄ 587), but only while it still holds the standard port of the state
/// being left, so a custom port is never overwritten.
class TlsSwitchTile extends StatelessWidget {
  const TlsSwitchTile({
    super.key,
    required this.switchKey,
    required this.protocol,
    required this.value,
    required this.portController,
    required this.onChanged,
  });

  /// Key for the inner [SwitchListTile], so tests can read its value.
  final Key switchKey;
  final TlsProtocol protocol;
  final bool value;
  final TextEditingController portController;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final port = protocol.defaultPort(ssl: value);
    final subtitle = value
        ? 'On: implicit TLS (${protocol.label} $port)'
        : 'Off: upgrade with STARTTLS (${protocol.label} $port)';
    return SwitchListTile(
      key: switchKey,
      title: const Text('SSL/TLS'),
      subtitle: Text(subtitle),
      value: value,
      onChanged: (v) {
        if (portController.text.trim() ==
            '${protocol.defaultPort(ssl: value)}') {
          portController.text = '${protocol.defaultPort(ssl: v)}';
        }
        onChanged(v);
      },
    );
  }
}
