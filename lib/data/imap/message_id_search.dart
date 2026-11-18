/// The `UID SEARCH` criteria that find a message by [messageId], tried in
/// order: some servers (e.g. Exchange) only match the exact header token,
/// so a bare id is also tried in its angle-bracketed form (and vice versa).
/// RFC 3501 SEARCH HEADER takes an astring for the value; quoting is safe
/// for typical Message-ID syntax (no embedded quotes or backslashes).
List<String> messageIdSearchCriteria(String messageId) {
  final bare = messageId.startsWith('<') && messageId.endsWith('>')
      ? messageId.substring(1, messageId.length - 1)
      : messageId;
  return [
    for (final candidate in {messageId, bare, '<$bare>'})
      'HEADER Message-ID '
          '"${candidate.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"',
  ];
}
