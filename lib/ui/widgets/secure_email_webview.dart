import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sharedinbox/core/utils/html_utils.dart';
import 'package:sharedinbox/core/utils/mailto_parser.dart';
import 'package:sharedinbox/di.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Builds the full HTML document string for rendering an email body.
///
/// Forces `color-scheme: light` so that emails with black text remain readable
/// when the device is in dark mode — the WebView would otherwise apply a dark
/// background while leaving the email's own text colours unchanged.
@visibleForTesting
String buildEmailHtml(String htmlBody, {bool loadRemoteImages = false}) {
  final imgSrc = loadRemoteImages ? 'https: http: data: blob:' : 'data: blob:';
  // script-src 'none' blocks page scripts; JS mode stays unrestricted so the
  // controller can call runJavaScriptReturningResult for height measurement.
  const cspBase = "default-src 'none'; "
      "style-src 'unsafe-inline'; "
      "script-src 'none'; "
      "object-src 'none'; "
      "font-src 'none'";
  final csp = '$cspBase; img-src $imgSrc';

  return '''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light">
<meta http-equiv="Content-Security-Policy" content="$csp">
<style>
body { margin: 0; padding: 0; font-family: sans-serif; word-break: break-word; overflow-x: hidden; color-scheme: light; background-color: #ffffff; color: #000000; }
img { max-width: 100%; height: auto; }
a { color: #1976D2; }
* { box-sizing: border-box; max-width: 100%; }
table { width: 100%; border-collapse: collapse; }
td, th { overflow-wrap: break-word; word-break: break-word; }
pre { white-space: pre-wrap; word-break: break-word; overflow-x: auto; }
</style>
</head>
<body>
$htmlBody
</body>
</html>''';
}

/// Renders an HTML email body securely.
///
/// On Android the content is displayed in a WebView with JavaScript blocked
/// via CSP and remote images blocked until the user opts in.  Link taps show
/// a confirmation dialog that highlights the registered domain to aid phishing
/// detection.
///
/// On Linux (where webview_flutter has no platform support) the HTML is
/// converted to plain text and shown in a [SelectableText] widget.
class SecureEmailWebView extends ConsumerStatefulWidget {
  const SecureEmailWebView({
    super.key,
    required this.htmlBody,
    this.loadRemoteImages = false,
  });

  final String htmlBody;
  final bool loadRemoteImages;

  @override
  ConsumerState<SecureEmailWebView> createState() => _SecureEmailWebViewState();
}

class _SecureEmailWebViewState extends ConsumerState<SecureEmailWebView> {
  // Null on Linux where WebView is unavailable.
  WebViewController? _controller;
  double _height = 300;

  @override
  void initState() {
    super.initState();
    if (!Platform.isLinux) {
      final c = WebViewController();
      unawaited(c.setJavaScriptMode(JavaScriptMode.unrestricted));
      unawaited(c.setBackgroundColor(Colors.transparent));
      unawaited(
        c.setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: _handleNavigation,
            onPageFinished: _measureHeight,
          ),
        ),
      );
      unawaited(c.loadHtmlString(_buildHtml()));
      _controller = c;
    }
  }

  @override
  void didUpdateWidget(SecureEmailWebView old) {
    super.didUpdateWidget(old);
    if (old.htmlBody != widget.htmlBody ||
        old.loadRemoteImages != widget.loadRemoteImages) {
      if (_controller != null) {
        unawaited(_controller!.loadHtmlString(_buildHtml()));
      }
    }
  }

  String _buildHtml() => buildEmailHtml(
        widget.htmlBody,
        loadRemoteImages: widget.loadRemoteImages,
      );

  Future<void> _measureHeight(String _) async {
    try {
      final result = await _controller!.runJavaScriptReturningResult(
        'document.documentElement.scrollHeight',
      );
      final h = double.tryParse(result.toString());
      if (h != null && h > 0 && mounted) {
        setState(() => _height = h);
      }
    } catch (_) {
      // WebView not ready yet; height stays at default
    }
  }

  NavigationDecision _handleNavigation(NavigationRequest req) {
    final url = req.url;
    if (url == 'about:blank' || url.startsWith('data:')) {
      return NavigationDecision.navigate;
    }
    if (isMailtoUrl(url)) {
      if (mounted) unawaited(openMailtoInApp(context, url));
      return NavigationDecision.prevent;
    }
    unawaited(_showLinkDialog(url));
    return NavigationDecision.prevent;
  }

  Future<void> _showLinkDialog(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Open link?'),
        content: SingleChildScrollView(
          child: Text.rich(
            TextSpan(
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              children: buildLinkDialogSpans(url, uri),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Open in browser'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        unawaited(
          ref.read(appLoggerProvider).warn(
            'webview.open_url_failed',
            'Browser refused to open URL from webview',
            data: {'url': url},
          ),
        );
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Could not open: $url')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Linux has no webview_flutter platform implementation — show plain text.
    if (Platform.isLinux) {
      return SelectableText(
        htmlToPlain(widget.htmlBody),
        style: Theme.of(context).textTheme.bodyMedium,
      );
    }
    return SizedBox(
      height: _height,
      child: WebViewWidget(
        controller: _controller!,
        gestureRecognizers: emailWebViewGestureRecognizers(),
      ),
    );
  }
}

/// Gesture recognizers registered on the email [WebViewWidget].
///
/// Without a long-press recognizer the surrounding scrollable detail screen
/// wins the gesture arena, so the WebView never receives the long-press that
/// starts a text selection and HTML email text cannot be selected (issue
/// #462). Only the long-press is claimed here — vertical scroll drags still
/// bubble up to the parent scroll view.
@visibleForTesting
Set<Factory<OneSequenceGestureRecognizer>> emailWebViewGestureRecognizers() {
  return {
    Factory<OneSequenceGestureRecognizer>(LongPressGestureRecognizer.new),
  };
}

/// Whether [url] begins with the `mailto:` scheme. Case-insensitive, matching
/// the scheme-comparison rules from RFC 3986 §3.1.
bool isMailtoUrl(String url) => url.toLowerCase().startsWith('mailto:');

/// Routes a `mailto:` link to the in-app compose screen (via `/compose`)
/// instead of handing it off to another mail app.
///
/// Falls back to launching the URI externally when [url] cannot be parsed as
/// a `mailto:` URI — a defensive path that should not normally be reached
/// because callers gate on [isMailtoUrl] first.
Future<void> openMailtoInApp(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  final fields = uri == null ? null : parseMailto(uri);
  if (fields == null) {
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    return;
  }
  unawaited(
    context.push(
      '/compose',
      extra: <String, dynamic>{
        if (fields.to != null) 'prefillTo': fields.to,
        if (fields.cc != null) 'prefillCc': fields.cc,
        if (fields.subject != null) 'prefillSubject': fields.subject,
        if (fields.body != null) 'prefillBody': fields.body,
      },
    ),
  );
}

/// Splits [url] into text spans so the registered domain (last two DNS labels
/// of [uri]'s host) can be rendered in bold to aid phishing detection.
///
/// Returns the URL as a single plain span when [uri] has no host or the host
/// cannot be located in the URL string.
@visibleForTesting
List<TextSpan> buildLinkDialogSpans(String url, Uri uri) {
  final host = uri.host;
  if (host.isEmpty) return [TextSpan(text: url)];

  final hostStart = url.toLowerCase().indexOf(host.toLowerCase());
  if (hostStart < 0) return [TextSpan(text: url)];

  final parts = host.split('.');
  final registeredLen = parts.length >= 2
      ? parts.last.length + 1 + parts[parts.length - 2].length
      : host.length;

  final domainStart = hostStart + host.length - registeredLen;
  final domainEnd = hostStart + host.length;

  return [
    TextSpan(text: url.substring(0, domainStart)),
    TextSpan(
      text: url.substring(domainStart, domainEnd),
      style: const TextStyle(fontWeight: FontWeight.bold),
    ),
    TextSpan(text: url.substring(domainEnd)),
  ];
}
