bool isLocalhost(String host) {
  final h = host.trim().toLowerCase();
  return h == 'localhost' || h == '127.0.0.1' || h == '::1';
}

String? validateHostname(String? value) {
  if (value == null || value.trim().isEmpty) return 'Required';
  return _checkHostChars(value.trim());
}

String? validateOptionalHostname(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  return _checkHostChars(value.trim());
}

String? _checkHostChars(String h) {
  if (h.contains(RegExp(r'[@/\\]')) ||
      h.codeUnits.any((c) => c < 32 || c == 127)) {
    return 'Invalid hostname';
  }
  return null;
}
