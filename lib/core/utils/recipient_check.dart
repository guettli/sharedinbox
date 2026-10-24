import 'package:sharedinbox/core/models/email.dart';

/// One entry of a typed recipient field (To, Cc).
class TypedRecipient {
  const TypedRecipient(this.raw, this.address, {required this.isValid});

  /// The entry as typed, trimmed.
  final String raw;

  /// The parsed name and address. Only meaningful when [isValid].
  final EmailAddress address;

  /// Whether [address] is an email address at all.
  final bool isValid;
}

/// Splits a typed recipient field into its entries.
///
/// Entries are separated by `,` or `;`, except inside double quotes or
/// angle brackets, so `"Doe, John" <john@example.com>` stays one entry. An
/// entry is a bare address or a `Name <address>` form. An address needs text
/// on both sides of a single `@` and no spaces or angle brackets.
List<TypedRecipient> parseRecipients(String field) {
  final entries = <String>[];
  final current = StringBuffer();
  var inQuotes = false;
  var inAngle = false;
  for (var i = 0; i < field.length; i++) {
    final c = field[i];
    if (c == r'\' && inQuotes && i + 1 < field.length) {
      current.write(c + field[++i]);
      continue;
    }
    if (c == '"' && !inAngle) inQuotes = !inQuotes;
    if (c == '<' && !inQuotes) inAngle = true;
    if (c == '>' && !inQuotes) inAngle = false;
    if ((c == ',' || c == ';') && !inQuotes && !inAngle) {
      entries.add(current.toString());
      current.clear();
    } else {
      current.write(c);
    }
  }
  entries.add(current.toString());

  return [
    for (final entry in entries.map((e) => e.trim()))
      if (entry.isNotEmpty) _parseEntry(entry),
  ];
}

TypedRecipient _parseEntry(String entry) {
  final open = entry.lastIndexOf('<');
  if (open >= 0 && entry.endsWith('>')) {
    final email = entry.substring(open + 1, entry.length - 1).trim();
    var name = entry.substring(0, open).trim();
    final quoted =
        name.length >= 2 && name.startsWith('"') && name.endsWith('"');
    // "<a@x> <b@y>" would otherwise send to b@y only, with a@x taken for
    // the name.
    final nameHasBracket =
        !quoted && (name.contains('<') || name.contains('>'));
    if (quoted) {
      // Undo the quoted-string escapes: `\"` → `"`, `\\` → `\`.
      name = name
          .substring(1, name.length - 1)
          .replaceAllMapped(_quotedPair, (m) => m[1]!);
    } else if (name.startsWith('"')) {
      name = name.substring(1).trim(); // an unbalanced opening quote
    }
    return TypedRecipient(
      entry,
      EmailAddress(name: name.isEmpty ? null : name, email: email),
      isValid: !nameHasBracket && _address.hasMatch(email),
    );
  }
  return TypedRecipient(
    entry,
    EmailAddress(email: entry),
    isValid: _address.hasMatch(entry),
  );
}

/// The addresses of a typed recipient field, skipping entries that are not
/// an address. Sending checks [invalidRecipients] first, so nothing is
/// dropped there without the user being told.
List<EmailAddress> recipientAddresses(String field) => [
      for (final r in parseRecipients(field))
        if (r.isValid) r.address,
    ];

/// The entries of a typed recipient field that are not an email address, as
/// typed. Without this check, sending dropped such an entry with only a log
/// warning, so a typo ("bob", "bob@") meant that person silently never got
/// the mail.
List<String> invalidRecipients(String field) => [
      for (final r in parseRecipients(field))
        if (!r.isValid) r.raw,
    ];

final _address = RegExp(r'^[^\s@<>]+@[^\s@<>]+$');

/// [addresses] as a typed recipient field, the inverse of
/// [recipientAddresses]: `Name <address>` entries joined by `, `. A name
/// with a separator, quote or angle bracket is quoted, so
/// [parseRecipients] reads it back as one entry.
String formatRecipients(List<EmailAddress> addresses) => [
      for (final a in addresses)
        if (a.name == null || a.name!.trim().isEmpty)
          a.email
        else if (_needsQuoting.hasMatch(a.name!))
          '"${a.name!.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}" '
              '<${a.email}>'
        else
          '${a.name} <${a.email}>',
    ].join(', ');

final _needsQuoting = RegExp(r'[,;"<>\\]');

final _quotedPair = RegExp(r'\\(.)');
