/// Parsed fields from a `mailto:` URI (RFC 6068).
class MailtoFields {
  const MailtoFields({this.to, this.cc, this.bcc, this.subject, this.body});

  final String? to;
  final String? cc;
  final String? bcc;
  final String? subject;
  final String? body;
}

/// Parses a `mailto:` URI into compose-screen fields.
///
/// - The path is treated as a comma-separated recipient list.
/// - Query keys `cc`, `bcc`, `subject`, `body` (case-insensitive) populate
///   the corresponding fields. Multiple values for the same key are joined
///   with `, ` (or `\n` for `body`, matching how mail clients usually expand
///   multi-line bodies in a `mailto:` link).
/// - Unknown query keys are ignored.
///
/// Returns null when the URI is not a `mailto:` URI.
MailtoFields? parseMailto(Uri uri) {
  if (uri.scheme != 'mailto') return null;

  final ssp = uri.path;
  final to = ssp.isEmpty ? null : ssp;

  // Uri.queryParameters lowercases nothing and only returns the first value
  // per key, but mailto query params are normally lowercase per RFC 6068 and
  // we want to collect every value. Use queryParametersAll and normalise the
  // key case ourselves to be tolerant of `Subject=...` etc.
  final cc = <String>[];
  final bcc = <String>[];
  final subject = <String>[];
  final body = <String>[];
  uri.queryParametersAll.forEach((k, vs) {
    switch (k.toLowerCase()) {
      case 'cc':
        cc.addAll(vs);
      case 'bcc':
        bcc.addAll(vs);
      case 'subject':
        subject.addAll(vs);
      case 'body':
        body.addAll(vs);
    }
  });

  return MailtoFields(
    to: to,
    cc: cc.isEmpty ? null : cc.join(', '),
    bcc: bcc.isEmpty ? null : bcc.join(', '),
    subject: subject.isEmpty ? null : subject.join(', '),
    body: body.isEmpty ? null : body.join('\n'),
  );
}
