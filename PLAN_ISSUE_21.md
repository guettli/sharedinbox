# Implementation Plan: Secure WebView for HTML Emails (#21)

## Goal
Replace the current `flutter_html` based rendering with a hardened WebView-based approach to improve rendering fidelity while strictly enforcing security and privacy.

## 1. Dependency Management
- **Core**: `webview_flutter` (v4+)
- **Linux Platform**: `webview_flutter_linux` (Official community-supported or WebKitGTK based implementation). *Note: I will verify the exact package name during implementation.*
- **Utilities**: `url_launcher` (existing) for opening links in the system browser.

## 2. Secure WebView Component (`lib/ui/widgets/secure_email_webview.dart`)
Create a new widget `SecureEmailWebView` that encapsulates the `WebViewWidget` and its controller.

### Configuration & Hardening
- **Disable JavaScript**: `controller.setJavaScriptMode(JavaScriptMode.disabled)`.
- **Background**: Match the application theme (e.g., transparent or surface color).
- **Security Headers/CSP**: Inject a Content Security Policy via `<meta>` tag in the HTML wrapper:
  - `default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:;` (Blocks all external assets by default).

### Image Blocking Logic
- **Initial State**: Block remote images by injecting a CSP that restricts `img-src` to `data:` and local schemes.
- **Toggle Mechanism**:
  - Provide a "Load Remote Images" button in the Flutter UI.
  - When triggered, re-render the HTML with an updated CSP: `img-src * data:;`.

### Link Interception & Phishing Protection
- Implement `NavigationDelegate.onNavigationRequest`.
- **Process**:
  1. Intercept any URL that doesn't start with `about:blank` or `data:`.
  2. Block the navigation in the WebView.
  3. Trigger a Flutter `showDialog` for confirmation.
- **Phishing Protection Dialog**:
  - Show the full URL.
  - **Bold the FQDN**: Parse the URL using `Uri.parse`.
    - Example: `https://`**`important-bank.com`**`/login`
  - "Open in Browser" button uses `url_launcher`.

## 3. Integration Plan
### Step 1: Initialization
Modify `lib/main.dart` to initialize the Linux WebView platform (using `webview_flutter_linux` or similar) during app startup.

### Step 2: Replace Renderer in Screens
- **EmailDetailScreen**: Replace `Html(...)` with `SecureEmailWebView(html: body.htmlBody!)`.
- **ThreadDetailScreen**: Replace `Html(...)` with `SecureEmailWebView(html: body.htmlBody!)`.
- Remove `flutter_html` imports and dependencies once migration is complete.

## 4. Verification & Security Audit
- **Manual Tests**:
  - Open emails with complex HTML layouts.
  - Verify images are blocked initially.
  - Verify "Load images" works.
  - Click various links (http, https, mailto) and verify the confirmation dialog and FQDN bolding.
- **Security Check**:
  - Verify that `<script>` tags are not executed.
  - Verify no network requests for external images occur before user consent (via DevTools or proxy).

## 5. Potential Challenges
- **Linux WebView Stability**: WebKitGTK on Linux can sometimes have rendering or sizing issues in Flutter.
- **Scrolling**: Ensuring the WebView integrates smoothly into the `ListView` of the email detail screen (might require fixed height or `SizedBox`).
