/// The entries of a typed recipient field (To, Cc) that are not an email
/// address, in the order typed.
///
/// Entries are separated by `,` or `;` and may be a bare address or a
/// `Name <address>` form. An address needs text on both sides of a single
/// `@` and no spaces or angle brackets. Without this check, sending dropped
/// such an entry with only a log warning, so a typo ("bob", "bob@") meant
/// that person silently never got the mail.
List<String> invalidRecipients(String field) {
  final invalid = <String>[];
  for (final raw in field.split(RegExp('[,;]'))) {
    final entry = raw.trim();
    if (entry.isEmpty) continue;
    final open = entry.lastIndexOf('<');
    final address = open >= 0 && entry.endsWith('>')
        ? entry.substring(open + 1, entry.length - 1).trim()
        : entry;
    if (!_address.hasMatch(address)) invalid.add(entry);
  }
  return invalid;
}

final _address = RegExp(r'^[^\s@<>]+@[^\s@<>]+$');
