import 'dart:io';
import 'package:http/http.dart' as http;

class LocalhostMappingClient extends http.BaseClient {
  final http.Client _inner = http.Client();

  static bool? _useLocalhostFallback;

  Future<bool> _shouldMapToLocalhost() async {
    if (_useLocalhostFallback != null) return _useLocalhostFallback!;
    try {
      final addrs = await InternetAddress.lookup('stalwart');
      if (addrs.isNotEmpty) {
        _useLocalhostFallback = false;
        return false;
      }
    } catch (_) {
      // Lookup failed
    }
    _useLocalhostFallback = true;
    return true;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.host == 'stalwart') {
      if (await _shouldMapToLocalhost()) {
        final newUrl = request.url.replace(host: '127.0.0.1');
        final newRequest = http.Request(request.method, newUrl)
          ..headers.addAll(request.headers)
          ..followRedirects = request.followRedirects
          ..maxRedirects = request.maxRedirects
          ..persistentConnection = request.persistentConnection;

        if (request is http.Request) {
          newRequest.bodyBytes = request.bodyBytes;
        }
        return _inner.send(newRequest);
      }
    }
    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
