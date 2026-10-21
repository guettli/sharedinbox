import 'dart:convert';

/// Longest UTF-8 run per encoded-word: 30 bytes are 40 base64 characters, so
/// a word is 52 characters long. enough_mail folds a long header only at
/// spaces (and `;)]>`) and cuts a line without one mid-word, so every word
/// plus the header name has to fit in its 76-character line.
const _maxBytesPerWord = 30;

/// Longest ASCII run without a space that can stay plain: `Subject: ` plus
/// the run must fit in one 76-character line.
final _unfoldableRun = RegExp(r'[^ ]{61,}');

/// CR, LF and the other control characters (TAB aside). Raw in a header they
/// would end it: a subject from a mailto link or a reply could add headers.
final _controlChars = RegExp(r'[\x00-\x08\x0A-\x1F\x7F]+');

/// Encodes [text] for an unstructured header such as Subject (RFC 2047).
///
/// ASCII text is returned unchanged. Otherwise the whole value becomes
/// `=?UTF-8?B?…?=` words separated by spaces. enough_mail encodes only the
/// span from the first to the last non-ASCII character and glues it to the
/// text around it ("Gr=?utf8?Q?…?="), which RFC 2047 does not allow: strict
/// readers then show the raw word or insert spaces ("Gr üße"). Decoders
/// drop the spaces between adjacent encoded-words, and a word never splits
/// a character.
///
/// Control characters (CR, LF, …) become a space first. Plain ASCII with a
/// run of more than 60 characters without a space is encoded too, since the
/// renderer could only cut it mid-token.
String encodeUnstructuredHeader(String text) {
  text = text.replaceAll(_controlChars, ' ');
  if (text.codeUnits.every((c) => c < 0x80) && !_unfoldableRun.hasMatch(text)) {
    return text;
  }
  return _encodedWords(text);
}

/// Encodes a display name for an address header (an RFC 5322 phrase).
///
/// ASCII becomes a quoted string with `"` and `\` escaped; anything else
/// becomes encoded-words, which must not stand inside quotes (RFC 2047 §5).
/// enough_mail writes `"=?utf8?Q?…?="` and leaves ASCII names unescaped.
/// Control characters become a space, as in [encodeUnstructuredHeader].
/// Returns '' for a blank name.
String encodeDisplayName(String name) {
  final clean = name.replaceAll(_controlChars, ' ').trim();
  if (clean.isEmpty) return '';
  if (clean.codeUnits.every((c) => c < 0x80)) {
    return '"${clean.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  }
  return _encodedWords(clean);
}

/// [text] as space-separated `=?UTF-8?B?…?=` words that never split a
/// character.
String _encodedWords(String text) {
  final words = <String>[];
  var chunk = <int>[];
  void flush() {
    words.add('=?UTF-8?B?${base64.encode(chunk)}?=');
    chunk = <int>[];
  }

  for (final rune in text.runes) {
    final bytes = utf8.encode(String.fromCharCode(rune));
    if (chunk.length + bytes.length > _maxBytesPerWord) flush();
    chunk.addAll(bytes);
  }
  if (chunk.isNotEmpty) flush();
  return words.join(' ');
}
