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
/// being left (or is empty), so a custom port is never overwritten.
///
/// Off means STARTTLS — except on localhost, where it means plaintext (see
/// `Account.imapSsl`); pass [isLocalhost] so the subtitle says so.
class TlsSwitchTile extends StatelessWidget {
  const TlsSwitchTile({
    super.key,
    required this.switchKey,
    required this.protocol,
    required this.value,
    required this.portController,
    required this.onChanged,
    this.isLocalhost = false,
  });

  /// Key for the inner [SwitchListTile], so tests can read its value.
  final Key switchKey;
  final TlsProtocol protocol;
  final bool value;
  final TextEditingController portController;
  final ValueChanged<bool> onChanged;

  /// Whether the server host is localhost, where Off means plaintext.
  final bool isLocalhost;

  @override
  Widget build(BuildContext context) {
    final port = protocol.defaultPort(ssl: value);
    // "standard port": the field may hold a custom one.
    final String subtitle;
    if (value) {
      subtitle = 'On: implicit TLS (standard ${protocol.label} port $port)';
    } else if (isLocalhost) {
      subtitle = 'Off: plaintext, localhost only '
          '(standard ${protocol.label} port $port)';
    } else {
      subtitle = 'Off: upgrade with STARTTLS '
          '(standard ${protocol.label} port $port)';
    }
    return SwitchListTile(
      key: switchKey,
      title: const Text('SSL/TLS'),
      subtitle: Text(subtitle),
      value: value,
      onChanged: (v) {
        final current = portController.text.trim();
        if (current.isEmpty ||
            current == '${protocol.defaultPort(ssl: value)}') {
          portController.text = '${protocol.defaultPort(ssl: v)}';
        }
        onChanged(v);
      },
    );
  }
}
