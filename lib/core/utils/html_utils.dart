/// Strips HTML tags and decodes common entities to produce plain text.
///
/// Not a full HTML parser — handles the common subset found in email bodies.
String htmlToPlain(String html) => html
    // Drop the *content* of these before stripping tags: an email's <style>
    // block would otherwise turn into a preview full of CSS.
    .replaceAll(
      RegExp(
        r'<(style|script|head)\b[^>]*>.*?</\1>',
        caseSensitive: false,
        dotAll: true,
      ),
      '',
    )
    // A truncated body (the sync preview only sees the first few KB) can end
    // mid-<style>: drop the unclosed remainder too.
    .replaceAll(
      RegExp(
        r'<(style|script|head)\b[^>]*>.*$',
        caseSensitive: false,
        dotAll: true,
      ),
      '',
    )
    .replaceAll(RegExp(r'<br\s*/?>'), '\n')
    .replaceAll(RegExp(r'<p\s*/?>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'</p>', caseSensitive: false), '')
    .replaceAll(RegExp(r'<[^>]+>'), '')
    // A truncated snippet can end inside a tag — an email whose first
    // kilobytes are one long inline-styled <div> would otherwise show its
    // markup as the preview.
    .replaceAll(RegExp(r'<[^>]*$'), '')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&nbsp;', ' ')
    .trim();
