import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:sharedinbox/core/utils/mail_header_encode.dart';

final _controlChars = RegExp(r'[\x00-\x1F\x7F]');

/// An address for a header the app builds: its display name goes out as
/// [encodeDisplayName] makes it, not as enough_mail's [imap.MailAddress.encode]
/// (encoded-words inside quotes, ASCII names unescaped). A name from a reply
/// may carry CR/LF from a hostile encoded-word; neither it nor the address
/// can end the header.
class HeaderMailAddress extends imap.MailAddress {
  HeaderMailAddress(String? personalName, String email)
      : super(personalName, email.replaceAll(_controlChars, ''));

  @override
  String encode() {
    final name = encodeDisplayName(personalName ?? '');
    return name.isEmpty ? email : '$name <$email>';
  }
}
