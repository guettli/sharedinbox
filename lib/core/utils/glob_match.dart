/// Returns true if [value] matches the glob [pattern].
///
/// Supports `*` (any number of characters) and `?` (exactly one character).
/// The comparison is case-insensitive, which is appropriate for email addresses.
bool globMatch(String value, String pattern) {
  final regexStr =
      RegExp.escape(pattern).replaceAll(r'\*', '.*').replaceAll(r'\?', '.');
  return RegExp('^$regexStr\$', caseSensitive: false).hasMatch(value);
}
