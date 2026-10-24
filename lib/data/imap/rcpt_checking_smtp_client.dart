// ignore_for_file: implementation_imports
import 'package:enough_mail/enough_mail.dart';
import 'package:enough_mail/src/private/smtp/smtp_command.dart';

/// One envelope recipient the SMTP server refused at `RCPT TO`.
class RejectedRecipient {
  const RejectedRecipient(this.email, this.reply);

  final String email;

  /// The server's reply to this recipient's `RCPT TO`.
  final SmtpResponseLine reply;

  /// A 5xx reply: retrying the same address will fail the same way.
  bool get isPermanent => reply.code >= 500;

  @override
  String toString() => '$email: ${reply.message}';
}

/// The server refused one or more `RCPT TO` recipients, so the message was
/// sent to nobody: the transaction was reset before `DATA`.
///
/// An [SmtpException] whose code is 550 when any rejection was permanent and
/// the first rejection's 4xx code otherwise — a retry can only help when every
/// rejection was temporary.
class SmtpRecipientsRejectedException extends SmtpException {
  SmtpRecipientsRejectedException(
    SmtpClient client,
    this.rejected,
  ) : super(
          client,
          SmtpResponse([
            '${_code(rejected)} ${describeRejectedRecipients(rejected)}',
          ]),
        );

  final List<RejectedRecipient> rejected;

  bool get isPermanent => rejected.any((r) => r.isPermanent);

  static int _code(List<RejectedRecipient> rejected) =>
      rejected.any((r) => r.isPermanent) ? 550 : rejected.first.reply.code;

  @override
  String toString() => message ?? describeRejectedRecipients(rejected);
}

/// "Rejected recipient carol@example.com: 5.1.2 Mailbox does not exist." —
/// or, for several, "Rejected recipients: a@x: …; b@y: …".
String describeRejectedRecipients(List<RejectedRecipient> rejected) =>
    rejected.length == 1
        ? 'Rejected recipient ${rejected.single}'
        : 'Rejected recipients: ${rejected.join('; ')}';

/// An [SmtpClient] whose [sendMessage] checks the reply to every `RCPT TO`.
///
/// enough_mail's own send command issues all `RCPT TO`s back to back and only
/// looks at the reply to the last one, so with the bad address anywhere but
/// last the message went to the remaining recipients and the send reported
/// success. Here any rejected recipient aborts the transaction with `RSET`
/// before `DATA`, nobody gets the message, and [sendMessage] throws a
/// [SmtpRecipientsRejectedException] naming the refused addresses.
class RcptCheckingSmtpClient extends SmtpClient {
  RcptCheckingSmtpClient(super.clientDomain);

  @override
  Future<SmtpResponse> sendMessage(
    MimeMessage message, {
    bool use8BitEncoding = false,
    MailAddress? from,
    List<MailAddress>? recipients,
  }) {
    final recipientEmails = recipients != null
        ? recipients.map((r) => r.email).toList()
        : message.recipientAddresses;
    if (recipientEmails.isEmpty) {
      throw SmtpException(this, SmtpResponse(['500 no recipients']));
    }
    return sendCommand(
      _RcptCheckingSendCommand(
        this,
        // Same Bcc stripping as enough_mail's SmtpSendMailCommand.
        () => message
            .renderMessage()
            .replaceAll(RegExp('^Bcc:.*\r\n', multiLine: true), ''),
        from?.email ?? message.fromEmail,
        recipientEmails,
        use8BitEncoding: use8BitEncoding,
      ),
    );
  }
}

enum _Step { mailFrom, rcptTo, reset, data, done }

/// MAIL FROM, one RCPT TO per recipient, then DATA — or RSET when any
/// recipient was refused. A command that throws from [nextCommand] completes
/// with that error (see `SmtpClient.onServerResponse`).
class _RcptCheckingSendCommand extends SmtpCommand {
  _RcptCheckingSendCommand(
    this._client,
    this._getData,
    this._fromEmail,
    this._recipients, {
    required this.use8BitEncoding,
  }) : super('MAIL FROM');

  final SmtpClient _client;
  final String Function() _getData;
  final String? _fromEmail;
  final List<String> _recipients;
  final bool use8BitEncoding;
  final _rejected = <RejectedRecipient>[];
  _Step _step = _Step.mailFrom;
  int _nextRecipient = 0;

  @override
  String get command => use8BitEncoding
      ? 'MAIL FROM:<$_fromEmail> BODY=8BITMIME'
      : 'MAIL FROM:<$_fromEmail>';

  @override
  String? nextCommand(SmtpResponse response) {
    switch (_step) {
      case _Step.mailFrom:
        if (!response.isOkStatus) throw SmtpException(_client, response);
        _step = _Step.rcptTo;
        return _rcptTo();
      case _Step.rcptTo:
        if (!response.isOkStatus) {
          _rejected.add(
            RejectedRecipient(
              _recipients[_nextRecipient - 1],
              response.responseLines.last,
            ),
          );
        }
        if (_nextRecipient < _recipients.length) return _rcptTo();
        if (_rejected.isNotEmpty) {
          _step = _Step.reset;
          return 'RSET';
        }
        _step = _Step.data;
        return 'DATA';
      case _Step.reset:
        throw SmtpRecipientsRejectedException(_client, _rejected);
      case _Step.data:
        if (response.code != 354) throw SmtpException(_client, response);
        _step = _Step.done;
        // RFC 5321 §4.5.2 dot-stuffing: a line starting with "." gets another.
        final data =
            _getData().replaceAll(RegExp(r'^\.', multiLine: true), '..');
        return '$data\r\n.';
      case _Step.done:
        return null;
    }
  }

  String _rcptTo() => 'RCPT TO:<${_recipients[_nextRecipient++]}>';
}
