import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart';
import 'package:sharedinbox/core/utils/mail_header_decode.dart';

/// The file name of a MIME part: Content-Disposition `filename` or
/// Content-Type `name`, in their RFC 2231 forms first.
///
/// enough_mail reads only the plain parameters, so a name sent the way
/// Thunderbird sends non-ASCII names — `filename*=UTF-8''%C3%9Cbersicht.pdf`,
/// or split into `filename*0*=…; filename*1*=…` — came out empty. Returns
/// null when the part carries no name.
String? mimePartFileName(
  ContentDispositionHeader? disposition,
  ContentTypeHeader? contentType,
) {
  final dispositionParams = disposition?.parameters ?? const {};
  final typeParams = contentType?.parameters ?? const {};
  final name = rfc2231Parameter(dispositionParams, 'filename') ??
      rfc2231Parameter(typeParams, 'name') ??
      decodeMailHeader(dispositionParams['filename'] ?? typeParams['name']);
  final trimmed = name?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// The RFC 2231 value of parameter [name] in [params] (keys lower-case, as
/// enough_mail stores them): `name*=charset'lang'%XX…`, or the continuations
/// `name*0`, `name*0*`, `name*1*`, … joined in order. Null when absent.
String? rfc2231Parameter(Map<String, String> params, String name) {
  final single = params['$name*'];
  final segments = <int, (String, bool)>{
    if (single != null) 0: (single, true),
  };
  if (single == null) {
    final key = RegExp('^${RegExp.escape(name)}\\*(\\d+)(\\*?)\$');
    params.forEach((k, v) {
      final m = key.firstMatch(k);
      if (m != null) segments[int.parse(m[1]!)] = (v, m[2]!.isNotEmpty);
    });
  }
  if (segments.isEmpty) return null;

  String? charset;
  final bytes = <int>[];
  for (var i = 0; segments.containsKey(i); i++) {
    var (value, extended) = segments[i]!;
    if (i == 0 && extended) {
      // charset'language'value; both may be empty.
      final parts = value.split("'");
      if (parts.length >= 3) {
        charset = parts[0];
        value = parts.sublist(2).join("'");
      }
    }
    bytes.addAll(extended ? _percentDecode(value) : latin1.encode(value));
  }
  return _decode(Uint8List.fromList(bytes), charset);
}

List<int> _percentDecode(String value) {
  final out = <int>[];
  for (var i = 0; i < value.length; i++) {
    final c = value.codeUnitAt(i);
    if (c == 0x25 && i + 2 < value.length) {
      final byte = int.tryParse(value.substring(i + 1, i + 3), radix: 16);
      if (byte != null) {
        out.add(byte);
        i += 2;
        continue;
      }
    }
    // Raw non-ASCII is not allowed here but turns up; keep it as UTF-8.
    out.addAll(c < 0x80 ? [c] : utf8.encode(String.fromCharCode(c)));
  }
  return out;
}

String _decode(Uint8List bytes, String? charset) {
  final cs = charset?.trim().toLowerCase() ?? '';
  if (cs.isEmpty || cs == 'utf-8' || cs == 'utf8') {
    return utf8.decode(bytes, allowMalformed: true);
  }
  try {
    return MailCodec.decodeAsText(bytes, '8bit', cs);
  } catch (_) {
    return utf8.decode(bytes, allowMalformed: true);
  }
}
