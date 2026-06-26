import 'package:http/http.dart' as http;

class LocalhostMappingClient extends http.BaseClient {
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.host == 'stalwart') {
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
    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
