/// The result of [splitTrailingQuote]: the [visible] reply text and, when a
/// foldable trailing quote was found, the [quoted] region to hide by default.
typedef QuoteSplit = ({String visible, String? quoted});

final RegExp _quotePrefix = RegExp(r'^\s*>');

// A line ending with "wrote:"/"schrieb:", e.g.
//   "On Tue, 1 Jan 2024 at 10:00, Jane Doe <jane@x> wrote:"  (English)
final RegExp _attributionVerb =
    RegExp(r'(wrote|schrieb):\s*$', caseSensitive: false);

// A self-contained separator that both opens and closes an attribution block.
final RegExp _originalMessage = RegExp(
  r'^\s*-{2,}\s*(original message|ursprüngliche nachricht)\s*-{2,}\s*$',
  caseSensitive: false,
);

// Openers that begin an attribution sentence. Used to stop absorbing wrapped
// attribution lines once the first line of the sentence is reached.
final RegExp _attributionStart = RegExp(
  r'^\s*(On|Am|Le|El|Il|Op|W dniu)\b',
  caseSensitive: false,
);

bool _isBlank(String line) => line.trim().isEmpty;

bool _isQuoted(String line) => _quotePrefix.hasMatch(line);

// Whether [line] ends an attribution that introduces a quote. Handles both the
// English "On … wrote:" shape and the German "Am … schrieb <name>:" shape,
// where the name (and colon) follow the verb — so any opener line ending in a
// colon counts, not just one ending in the verb itself.
bool _endsAttribution(String line) {
  if (_originalMessage.hasMatch(line)) return true;
  if (!line.trimRight().endsWith(':')) return false;
  return _attributionVerb.hasMatch(line) || _attributionStart.hasMatch(line);
}

bool _startsAttribution(String line) =>
    _attributionStart.hasMatch(line) || _originalMessage.hasMatch(line);

/// Splits [text] into the [visible] reply and an optional [quoted] trailing
/// block that a reader is likely to want folded away.
///
/// A trailing quote is the maximal run of blank or `>`-prefixed lines that
/// reaches the end of the message, extended upward to absorb the attribution
/// line that introduces it ("On … wrote:", "Am … schrieb:",
/// "-----Original Message-----"). This targets the classic top-post shape —
/// a short reply followed by the whole original message quoted below.
///
/// The split is returned (`quoted != null`) only when the trailing quote holds
/// at least [minQuotedLines] quoted lines **and** some non-blank reply text
/// remains visible above it. Interleaved/inline quoting — where reply text
/// follows the quote — leaves a non-quoted line at the end, so no trailing
/// quote is found and everything stays expanded. Likewise a fully-quoted body
/// (no reply text) is returned unchanged so folding never hides everything.
QuoteSplit splitTrailingQuote(String text, {int minQuotedLines = 6}) {
  if (text.isEmpty) return (visible: text, quoted: null);

  final lines = text.split('\n');

  // Walk up from the end across the maximal run of blank/quoted lines.
  var regionStart = lines.length;
  var quotedCount = 0;
  for (var j = lines.length - 1; j >= 0; j--) {
    final line = lines[j];
    if (_isBlank(line)) {
      regionStart = j;
      continue;
    }
    if (_isQuoted(line)) {
      regionStart = j;
      quotedCount++;
      continue;
    }
    break;
  }

  if (quotedCount < minQuotedLines) return (visible: text, quoted: null);

  // Absorb the attribution line (and any wrapped continuation) that sits
  // immediately above the quoted run, past a single blank separator.
  var above = regionStart - 1;
  while (above >= 0 && _isBlank(lines[above])) {
    above--;
  }
  if (above >= 0 && _endsAttribution(lines[above])) {
    var top = above;
    while (top - 1 >= 0 &&
        !_isBlank(lines[top - 1]) &&
        !_startsAttribution(lines[top])) {
      top--;
    }
    regionStart = top;
  }

  final visible = lines.sublist(0, regionStart).join('\n').trimRight();

  // Never fold when nothing readable would remain — that would hide the whole
  // message behind an expand affordance.
  if (visible.trim().isEmpty) return (visible: text, quoted: null);

  final quoted = lines.sublist(regionStart).join('\n').trim();
  return (visible: visible, quoted: quoted);
}
