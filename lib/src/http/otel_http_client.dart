import 'package:http/http.dart' as http;

import '../core/clock.dart';
import '../core/context.dart';
import '../metrics/meter.dart';
import '../trace/propagation.dart';
import '../trace/span.dart';
import '../trace/tracer.dart';

/// A `package:http` client that traces every request.
///
/// * one CLIENT span per request (semantic conventions for HTTP);
/// * adds the `traceparent` header so your backend's spans join the same
///   trace;
/// * records the `http.client.request.duration` histogram.
///
/// ```dart
/// final client = OtelHttpClient();
/// await client.get(Uri.parse('https://api.example.com/items'));
/// ```
class OtelHttpClient extends http.BaseClient {
  OtelHttpClient({
    http.Client? inner,
    bool Function(Uri url)? propagateTo,
    this.captureQuery = false,
  }) : _inner = inner ?? http.Client(),
       _propagateTo = propagateTo;

  final http.Client _inner;
  final bool Function(Uri url)? _propagateTo;

  /// Include the query string in `url.full`. Off by default because query
  /// strings often carry tokens or personal data.
  final bool captureQuery;

  static final Tracer _tracer = Tracer.of('otel_flutter.http');
  static final Histogram _duration = Meter.of('otel_flutter.http').histogram(
    'http.client.request.duration',
    unit: 's',
    description: 'Duration of HTTP client requests.',
    boundaries: const [
      0.005,
      0.01,
      0.025,
      0.05,
      0.075,
      0.1,
      0.25,
      0.5,
      0.75,
      1,
      2.5,
      5,
      7.5,
      10,
    ],
  );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url;
    final method = request.method.toUpperCase();
    final port = url.hasPort ? url.port : (url.scheme == 'https' ? 443 : 80);
    final span = _tracer.startSpan(
      method,
      kind: SpanKind.client,
      attributes: {
        'http.request.method': method,
        'url.full': _redact(url),
        'url.scheme': url.scheme,
        'server.address': url.host,
        'server.port': port,
      },
    );
    // Third parties may reject unknown headers (CORS on web), so callers
    // can limit which hosts get `traceparent`.
    if (_propagateTo?.call(url) ?? true) {
      W3CPropagator.inject(
        request.headers,
        context: OtelContext.current.withSpan(span),
      );
    }

    final start = Clock.nowMicros();
    final metricAttributes = <String, Object?>{
      'http.request.method': method,
      'server.address': url.host,
      'server.port': port,
    };
    try {
      final response = await _inner.send(request);
      final status = response.statusCode;
      span.setAttribute('http.response.status_code', status);
      metricAttributes['http.response.status_code'] = status;
      if (status >= 400) {
        span
          ..setAttribute('error.type', '$status')
          ..setStatus(SpanStatusCode.error);
        metricAttributes['error.type'] = '$status';
      }
      return response;
    } catch (e, st) {
      final type = e.runtimeType.toString();
      span
        ..recordException(e, stackTrace: st)
        ..setAttribute('error.type', type)
        ..setStatus(SpanStatusCode.error, e.toString());
      metricAttributes['error.type'] = type;
      rethrow;
    } finally {
      _duration.record((Clock.nowMicros() - start) / 1e6, metricAttributes);
      span.end();
    }
  }

  /// Drops credentials, fragment and (by default) the query string.
  String _redact(Uri url) => Uri(
    scheme: url.scheme,
    host: url.host,
    port: url.hasPort ? url.port : null,
    path: url.path,
    query: captureQuery && url.hasQuery ? url.query : null,
  ).toString();

  @override
  void close() => _inner.close();
}
