import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../core/clock.dart';
import '../core/diagnostics.dart';
import '../platform/platform.dart';
import 'offline_store.dart';

enum _Outcome { success, retryable, fatal }

/// Sends OTLP/HTTP protobuf requests for all three signals.
///
/// Reliability rules:
/// * Network errors, timeouts and 429/502/503/504 are retried with jittered
///   exponential backoff; `Retry-After` is honoured.
/// * With an [OfflineStore], a failed request goes to disk and a circuit
///   breaker stops further network attempts until the backoff expires, so an
///   offline phone doesn't keep waking the radio. Stored requests are resent
///   oldest-first as soon as one request succeeds.
/// * Other 4xx/5xx responses are permanent: the data is dropped and the
///   reason is printed once (wrong path, missing auth header, ...).
@internal
final class OtlpHttpExporter {
  OtlpHttpExporter({
    required Map<Signal, Uri> endpoints,
    required Map<String, String> headers,
    required http.Client client,
    required Duration timeout,
    required bool compression,
    required int maxAttempts,
    OfflineStore? store,
  }) : _endpoints = endpoints,
       _headers = headers,
       _client = client,
       _timeout = timeout,
       _compression = compression,
       _maxAttempts = max(1, maxAttempts),
       _store = store;

  final Map<Signal, Uri> _endpoints;
  final Map<String, String> _headers;
  final http.Client _client;
  final Duration _timeout;
  final bool _compression;
  final int _maxAttempts;
  final OfflineStore? _store;
  final Random _random = Random();

  /// Requests dropped after all retries (no offline store, or permanent
  /// failure). Exposed for diagnostics and tests.
  int droppedRequests = 0;

  int _consecutiveFailures = 0;
  int _blockedUntilMicros = 0;
  Timer? _retryTimer;
  Future<void>? _draining;
  bool _closed = false;

  static const _retryableStatus = {429, 502, 503, 504};
  static const _maxRetryAfter = Duration(minutes: 5);

  bool get _circuitOpen => Clock.nowMicros() < _blockedUntilMicros;

  /// Sends [body]. With [urgent] (app going to background) the request is
  /// written to disk first when a store exists, so it survives the OS
  /// suspending or killing the app mid-request.
  Future<void> export(
    Signal signal,
    Uint8List body, {
    bool urgent = false,
    int items = 0,
  }) async {
    if (_closed) return;
    final payload = await _encode(signal, body);
    final store = _store;

    if (store != null && (urgent || _circuitOpen)) {
      await store.save(payload);
      Diagnostics.debug(
        '${signal.name}: $items item(s) queued on disk'
        '${urgent ? ' (app backgrounded)' : ' (offline)'}',
      );
      if (!_circuitOpen) unawaited(drainStore());
      return;
    }

    final (outcome, retryAfter) = await _sendWithRetry(
      payload,
      items,
      // With a store a quick second try is enough: disk is the safety net.
      attempts: store != null
          ? min(2, _maxAttempts)
          : (urgent ? 1 : _maxAttempts),
    );
    switch (outcome) {
      case _Outcome.success:
        _closeCircuit();
        if (store != null) unawaited(drainStore());
      case _Outcome.retryable when store != null:
        await store.save(payload);
        _openCircuit(retryAfter);
      case _Outcome.retryable:
      case _Outcome.fatal:
        droppedRequests++;
    }
  }

  /// Resends stored requests, oldest first, until one fails.
  Future<void> drainStore({bool force = false}) {
    final store = _store;
    if (store == null || _closed) return Future.value();
    if (force) _closeCircuit();
    if (_circuitOpen) return Future.value();
    return _draining ??= _drain(store).whenComplete(() => _draining = null);
  }

  Future<void> _drain(OfflineStore store) async {
    while (!_closed) {
      final stored = await store.oldest();
      if (stored == null) return;
      final (outcome, retryAfter) = await _send(stored.payload);
      switch (outcome) {
        case _Outcome.success:
          _closeCircuit();
          await store.delete(stored);
          Diagnostics.debug('${stored.payload.signal.name}: resent from disk');
        case _Outcome.retryable:
          _openCircuit(retryAfter);
          return;
        case _Outcome.fatal:
          await store.delete(stored);
      }
    }
  }

  /// Network came back or app resumed: retry the backlog right away.
  void resume() => unawaited(drainStore(force: true));

  void close() {
    _closed = true;
    _retryTimer?.cancel();
  }

  void _openCircuit(Duration? retryAfter) {
    _consecutiveFailures++;
    final exp = min(_consecutiveFailures - 1, 6); // 5s .. 320s
    final backoffMs = (5000 << exp) * (0.5 + _random.nextDouble() / 2);
    var wait = Duration(milliseconds: backoffMs.round());
    if (retryAfter != null && retryAfter > wait) wait = retryAfter;
    if (wait > _maxRetryAfter) wait = _maxRetryAfter;
    _blockedUntilMicros = Clock.nowMicros() + wait.inMicroseconds;
    _retryTimer?.cancel();
    _retryTimer = Timer(wait, () => unawaited(drainStore()));
    Diagnostics.debug('export failing; next attempt in ${wait.inSeconds}s');
  }

  void _closeCircuit() {
    _consecutiveFailures = 0;
    _blockedUntilMicros = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  Future<Payload> _encode(Signal signal, Uint8List body) async {
    if (_compression) {
      final zipped = await gzipBytes(body);
      if (zipped != null) return Payload(signal, zipped, gzipped: true);
    }
    return Payload(signal, body, gzipped: false);
  }

  Future<(_Outcome, Duration?)> _sendWithRetry(
    Payload payload,
    int items, {
    required int attempts,
  }) async {
    for (var attempt = 1; ; attempt++) {
      final sw = Stopwatch()..start();
      final (outcome, retryAfter) = await _send(payload);
      if (outcome == _Outcome.success) {
        Diagnostics.debug(
          '${payload.signal.name}: exported $items item(s), '
          '${(payload.bytes.length / 1024).toStringAsFixed(1)} KB'
          '${payload.gzipped ? ' gzip' : ''} in ${sw.elapsedMilliseconds} ms',
        );
      }
      if (outcome != _Outcome.retryable || attempt >= attempts || _closed) {
        return (outcome, retryAfter);
      }
      final backoffMs = (500 << (attempt - 1)) * (0.5 + _random.nextDouble());
      var wait = Duration(milliseconds: backoffMs.round());
      if (retryAfter != null && retryAfter > wait) {
        wait = retryAfter > const Duration(seconds: 30)
            ? const Duration(seconds: 30)
            : retryAfter;
      }
      await Future<void>.delayed(wait);
    }
  }

  Future<(_Outcome, Duration?)> _send(Payload payload) async {
    final uri = _endpoints[payload.signal]!;
    final http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: {
              ..._headers,
              'Content-Type': 'application/x-protobuf',
              if (payload.gzipped) 'Content-Encoding': 'gzip',
            },
            body: payload.bytes,
          )
          .timeout(_timeout);
    } catch (e) {
      Diagnostics.warnOnce(
        'network-${e.runtimeType}',
        'Cannot reach $uri ($e). Data is kept and retried. On an Android '
            'emulator use 10.0.2.2 instead of localhost; on a real device use '
            "your computer's LAN IP.",
      );
      return (_Outcome.retryable, null);
    }

    final code = response.statusCode;
    if (code >= 200 && code < 300) return (_Outcome.success, null);
    if (_retryableStatus.contains(code)) {
      return (
        _Outcome.retryable,
        _parseRetryAfter(response.headers['retry-after']),
      );
    }
    final hint = switch (code) {
      401 || 403 => 'check the auth headers (OtelConfig.headers)',
      404 =>
        'wrong URL: OTLP/HTTP expects <base>/v1/${payload.signal.name} '
            'on port 4318 (4317 is gRPC)',
      413 => 'request too large; lower OtelConfig.maxExportBatchSize',
      415 => 'the endpoint does not accept OTLP protobuf',
      _ => 'permanent error',
    };
    // Collectors answer protobuf requests with a binary Status; only show
    // human-readable bodies.
    final type = response.headers['content-type'] ?? '';
    final readable = type.contains('text') || type.contains('json');
    final body = readable ? response.body : '';
    final snippet = body.length > 200 ? '${body.substring(0, 200)}...' : body;
    Diagnostics.warnOnce(
      'http-$code-${payload.signal.name}',
      'Export to $uri failed with HTTP $code: $hint. $snippet',
    );
    return (_Outcome.fatal, null);
  }

  static Duration? _parseRetryAfter(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) return Duration(seconds: max(0, seconds));
    try {
      final at = HttpDateParser.parse(value.trim());
      final diff = at.difference(DateTime.now());
      return diff.isNegative ? Duration.zero : diff;
    } catch (_) {
      return null;
    }
  }
}

/// Parses the IMF-fixdate form of `Retry-After` without dart:io.
@internal
abstract final class HttpDateParser {
  static const _months = {
    'Jan': 1,
    'Feb': 2,
    'Mar': 3,
    'Apr': 4,
    'May': 5,
    'Jun': 6,
    'Jul': 7,
    'Aug': 8,
    'Sep': 9,
    'Oct': 10,
    'Nov': 11,
    'Dec': 12,
  };

  /// e.g. `Wed, 21 Oct 2015 07:28:00 GMT`.
  static DateTime parse(String value) {
    final parts = value.split(RegExp(r'[ ,:]+'));
    if (parts.length < 8) throw FormatException('Bad HTTP date', value);
    final month = _months[parts[2]];
    if (month == null) throw FormatException('Bad HTTP date', value);
    return DateTime.utc(
      int.parse(parts[3]),
      month,
      int.parse(parts[1]),
      int.parse(parts[4]),
      int.parse(parts[5]),
      int.parse(parts[6]),
    );
  }
}
