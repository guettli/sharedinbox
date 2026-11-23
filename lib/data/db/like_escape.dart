/// Escapes the SQL LIKE meta-characters of [s] with `\` (use
/// `ESCAPE '\'`).
String likeEscape(String s) =>
    s.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
