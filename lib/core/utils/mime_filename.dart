import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart';
import 'package:path/path.dart' as p;
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
  // RFC 2183 makes the disposition's filename the primary name.
  final candidates = <String? Function()>[
    () => rfc2231Parameter(dispositionParams, 'filename'),
    () => decodeMailHeader(dispositionParams['filename']),
    () => rfc2231Parameter(typeParams, 'name'),
    () => decodeMailHeader(typeParams['name']),
  ];
  for (final candidate in candidates) {
    String? name;
    try {
      name = candidate();
    } catch (_) {
      // A malformed name must never cost the whole attachment list.
      continue;
    }
    final trimmed = name?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

/// A name for saving an attachment: [name] without any directory part or
/// control characters, so a crafted name ("../../.config/x", "/x") cannot
/// leave the folder it is saved in.
String safeFileName(String name) {
  final base = p
      .basename(name.replaceAll(r'\', '/'))
      .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '_')
      .trim();
  return base.isEmpty || base == '.' || base == '..' || base.contains('/')
      ? 'attachment'
      : base;
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
      final index = m == null ? null : int.tryParse(m[1]!);
      if (index != null && index < 1000) {
        segments[index] = (v, m![2]!.isNotEmpty);
      }
    });
  }
  if (!segments.containsKey(0)) return null;

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
    bytes.addAll(extended ? _percentDecode(value) : _rawBytes(value));
  }
  return _decode(Uint8List.fromList(bytes), charset);
}

final _hexPair = RegExp(r'^[0-9A-Fa-f]{2}$');

List<int> _percentDecode(String value) {
  final out = <int>[];
  for (var i = 0; i < value.length; i++) {
    if (value.codeUnitAt(i) == 0x25 && i + 2 < value.length) {
      final hex = value.substring(i + 1, i + 3);
      if (_hexPair.hasMatch(hex)) {
        out.add(int.parse(hex, radix: 16));
        i += 2;
        continue;
      }
    }
    out.addAll(_rawBytes(value[i]));
  }
  return out;
}

/// ASCII as is; anything else (not allowed here, but it turns up) as UTF-8.
List<int> _rawBytes(String text) => [
      for (final rune in text.runes)
        ...(rune < 0x80 ? [rune] : utf8.encode(String.fromCharCode(rune))),
    ];

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
