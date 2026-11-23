import 'dart:convert';

/// The strings of a JSON list column of a projection (e.g. `tagsJson`);
/// empty when it does not parse, non-strings left out.
List<String> stringsFromJson(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return const [];
    return [
      for (final s in decoded)
        if (s is String) s,
    ];
  } on FormatException {
    return const [];
  }
}
