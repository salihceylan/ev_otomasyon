import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// `MockClient` ile yapılan istekten kaydedilen özet.
class RecordedRequest {
  RecordedRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
  });

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String body;

  String get path => url.path;

  /// JSON gövde (yoksa/bozuksa `null`).
  Map<String, dynamic>? get json {
    if (body.isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => '$method $path';
}

/// JSON yanıtı üretir (`content-type: application/json; charset=utf-8`).
http.Response jsonResponse(Object? body, {int status = 200, Map<String, String>? headers}) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: <String, String>{
      'content-type': 'application/json; charset=utf-8',
      ...?headers,
    },
  );
}

/// CONTRACTS §1.1 başarı gövdesi: `{ success: true, message, data }`.
http.Response okResponse(Object? data, {int status = 200, String message = 'Islem basarili'}) =>
    jsonResponse(<String, dynamic>{'success': true, 'message': message, 'data': data}, status: status);

/// CONTRACTS §1.1 hata gövdesi: `{ success: false, message, code }`.
http.Response errorResponse(
  int status,
  String message, {
  String? code,
  Map<String, String>? headers,
  Map<String, dynamic>? extra,
}) =>
    jsonResponse(
      <String, dynamic>{'success': false, 'message': message, 'code': ?code, ...?extra},
      status: status,
      headers: headers,
    );

typedef MockHandler = FutureOr<http.Response> Function(RecordedRequest request);

/// Yol tablosuyla çalışan `MockClient` sarmalayıcısı. Tüm istekler [requests]'e kaydedilir;
/// tanımsız yol `404 {success:false}` döner. Aynı yöntem+yol için **son eklenen** `on` geçerlidir.
///
/// ```dart
/// final api = MockApi()
///   ..on('GET', '/api/v1/homes', (r) => okResponse([...]));
/// final service = EvCloudApiService(client: api.client);
/// ```
class MockApi {
  MockApi() {
    client = MockClient(_handle);
  }

  late final MockClient client;
  final List<RecordedRequest> requests = <RecordedRequest>[];
  final List<_Route> _routes = <_Route>[];

  /// [path] tam eşleşme ya da `RegExp` deseni (örn. `r'/api/v1/homes/[^/]+/endpoints'`).
  void on(String method, Pattern path, MockHandler handler) {
    _routes.add(_Route(method.toUpperCase(), path, handler));
  }

  /// Aynı yol için sıradaki yanıtları sırayla döndürür (son yanıt tekrarlanır).
  void onSequence(String method, Pattern path, List<MockHandler> handlers) {
    var index = 0;
    on(method, path, (request) {
      final handler = handlers[index < handlers.length ? index : handlers.length - 1];
      index++;
      return handler(request);
    });
  }

  /// Verilen yöntem + yol desenine yapılan istekler.
  List<RecordedRequest> where(String method, Pattern path) => requests
      .where((r) => r.method == method.toUpperCase() && _matches(path, r.path))
      .toList();

  int count(String method, Pattern path) => where(method, path).length;

  static bool _matches(Pattern pattern, String path) {
    if (pattern is RegExp) return pattern.hasMatch(path);
    return pattern.toString() == path;
  }

  Future<http.Response> _handle(http.Request request) async {
    final recorded = RecordedRequest(
      method: request.method.toUpperCase(),
      url: request.url,
      headers: Map<String, String>.of(request.headers),
      body: request.body,
    );
    requests.add(recorded);
    // Sonradan eklenen yol, aynı yolun öncekini geçersiz kılar (testte yanıtı değiştirmek için).
    for (final route in _routes.reversed) {
      if (route.method == recorded.method && _matches(route.path, recorded.path)) {
        return await route.handler(recorded);
      }
    }
    return errorResponse(404, 'Kayıt bulunamadı.', code: 'NOT_FOUND');
  }
}

class _Route {
  _Route(this.method, this.path, this.handler);

  final String method;
  final Pattern path;
  final MockHandler handler;
}
