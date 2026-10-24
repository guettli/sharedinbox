// ignore_for_file: implementation_imports
import 'package:enough_mail/enough_mail.dart';
import 'package:enough_mail/src/private/smtp/smtp_command.dart';

/// One envelope recipient the server refused.
class RejectedRecipient {
  const RejectedRecipient(this.email, this.code, this.message);

  /// From an SMTP reply such as `550 5.1.2 Mailbox does not exist.` — as JMAP
  /// reports it in an EmailSubmission's `deliveryStatus.smtpReply`. A reply
  /// without a leading 3-digit code counts as a permanent (550) refusal.
  factory RejectedRecipient.fromReply(String email, String? reply) {
    final text = (reply ?? '').trim();
    final code = text.length >= 3 ? int.tryParse(text.substring(0, 3)) : null;
    if (code == null) {
      return RejectedRecipient(
        email,
        550,
        text.isEmpty ? 'not delivered' : text,
      );
    }
    return RejectedRecipient(email, code, text.substring(3).trim());
  }

  final String email;

  /// The reply code, e.g. 550.
  final int code;

  /// The reply text after the code; every line of a multi-line reply.
  final String message;

  /// A 5xx reply: retrying the same address will fail the same way.
  bool get isPermanent => code >= 500;

  @override
  String toString() => '$email: $message';
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
      rejected.any((r) => r.isPermanent) ? 550 : rejected.first.code;

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
///
/// Built on enough_mail internals (`SmtpCommand` and the way
/// `SmtpClient.onServerResponse` drives it), which is why pubspec.yaml pins
/// enough_mail to an exact version. The fake-server tests in
/// test/unit/rcpt_checking_smtp_client_test.dart are the canary for an
/// upgrade: run them before raising the pin.
///
/// The other send methods would bypass the check: [sendMessageData] and
/// [sendMessageText] go through it too, the `BDAT` variants are unsupported.
class RcptCheckingSmtpClient extends SmtpClient {
  RcptCheckingSmtpClient(super.clientDomain);

  @override
  Future<SmtpResponse> sendMessage(
    MimeMessage message, {
    bool use8BitEncoding = false,
    MailAddress? from,
    List<MailAddress>? recipients,
  }) =>
      _send(
        // Same Bcc stripping as enough_mail's SmtpSendMailCommand.
        () => _stripBcc(message.renderMessage()),
        from?.email ?? message.fromEmail,
        recipients?.map((r) => r.email).toList() ?? message.recipientAddresses,
        use8BitEncoding: use8BitEncoding,
      );

  @override
  Future<SmtpResponse> sendMessageData(
    MimeData data,
    MailAddress from,
    List<MailAddress> recipients, {
    bool use8BitEncoding = false,
  }) =>
      _send(
        () => _stripBcc(data.toString()),
        from.email,
        recipients.map((r) => r.email).toList(),
        use8BitEncoding: use8BitEncoding,
      );

  @override
  Future<SmtpResponse> sendMessageText(
    String text,
    MailAddress from,
    List<MailAddress> recipients, {
    bool use8BitEncoding = false,
  }) =>
      _send(
        () => text,
        from.email,
        recipients.map((r) => r.email).toList(),
        use8BitEncoding: use8BitEncoding,
      );

  @override
  Future<SmtpResponse> sendChunkedMessage(
    MimeMessage message, {
    required bool supportUnicode,
    bool use8BitEncoding = false,
    MailAddress? from,
    List<MailAddress>? recipients,
  }) =>
      throw _bdatUnsupported;

  @override
  Future<SmtpResponse> sendChunkedMessageData(
    MimeData data,
    MailAddress from,
    List<MailAddress> recipients, {
    required bool supportUnicode,
    bool use8BitEncoding = false,
  }) =>
      throw _bdatUnsupported;

  @override
  Future<SmtpResponse> sendChunkedMessageText(
    String text,
    MailAddress from,
    List<MailAddress> recipients, {
    required bool supportUnicode,
    bool use8BitEncoding = false,
  }) =>
      throw _bdatUnsupported;

  static final _bdatUnsupported = UnsupportedError(
    'BDAT does not check each RCPT TO reply; use sendMessage',
  );

  static String _stripBcc(String text) =>
      text.replaceAll(RegExp('^Bcc:.*\r\n', multiLine: true), '');

  Future<SmtpResponse> _send(
    String Function() getData,
    String? fromEmail,
    List<String> recipients, {
    required bool use8BitEncoding,
  }) {
    if (recipients.isEmpty) {
      throw SmtpException(this, SmtpResponse(['500 no recipients']));
    }
    return sendCommand(
      _RcptCheckingSendCommand(
        this,
        getData,
        fromEmail,
        recipients,
        use8BitEncoding: use8BitEncoding,
      ),
    );
  }
}

/// RFC 5321 §4.5.2 dot-stuffing: a "." that starts a line gets another.
String dotStuff(String data) => data.replaceAllMapped(
      RegExp(r'(^|\r\n)\.'),
      (m) => '${m[1]}..',
    );

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
              response.code ?? 550,
              response.responseLines.map((l) => l.message).join(' '),
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
        return '${dotStuff(_getData())}\r\n.';
      case _Step.done:
        return null;
    }
  }

  String _rcptTo() => 'RCPT TO:<${_recipients[_nextRecipient++]}>';
}
