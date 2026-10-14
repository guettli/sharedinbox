import 'dart:async';

import 'package:http/http.dart' as http;

/// An [http.Client] whose underlying delegate can be swapped out at runtime.
///
/// The app shares one long-lived client across every repository (see
/// `httpClientProvider`). On mobile, after the radio sleeps or the network
/// transitions (wifi <-> cellular), a keep-alive socket the OS pooled can be
/// silently half-open; the next request is written onto it and hangs until the
/// caller's timeout rather than failing fast (issue #1012).
///
/// Calling [reset] on a connectivity change closes the current delegate —
/// discarding its pooled connections — and installs a fresh one, so the next
/// request opens a new socket instead of reusing a dead one. The wrapper's
/// identity is stable, so every holder of the shared client transparently picks
/// up the new delegate.
class ResettableClient extends http.BaseClient {
  ResettableClient(this._create) : _inner = _create();

  /// Builds a fresh delegate. Injected so platform selection stays with
  /// `http.Client()` (IOClient on mobile/desktop, BrowserClient on web) and so
  /// tests can supply a fake.
  final http.Client Function() _create;

  http.Client _inner;
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _inner.send(request);
  }

  /// Swaps in a fresh delegate and closes the old one, dropping its pooled
  /// connections. In-flight requests on the old delegate are left to finish
  /// (the close is not forced); new requests use the fresh delegate. A no-op
  /// once [close] has been called.
  void reset() {
    if (_closed) return;
    final old = _inner;
    _inner = _create();
    old.close();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _inner.close();
  }
}
