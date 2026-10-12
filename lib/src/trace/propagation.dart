import '../core/context.dart';
import '../core/ids.dart';
import 'span.dart';

/// W3C Trace Context (`traceparent`, `tracestate`) and W3C Baggage headers.
abstract final class W3CPropagator {
  static const traceparentHeader = 'traceparent';
  static const tracestateHeader = 'tracestate';
  static const baggageHeader = 'baggage';

  static const _maxBaggageEntries = 180;
  static const _maxBaggageBytes = 8192;

  /// Writes the headers for [context] (default: current) into [headers].
  static void inject(Map<String, String> headers, {OtelContext? context}) {
    final ctx = context ?? OtelContext.current;
    final sc = ctx.span?.spanContext;
    if (sc != null && sc.isValid) {
      final flags = (sc.traceFlags & 0xFF).toRadixString(16).padLeft(2, '0');
      headers[traceparentHeader] = '00-${sc.traceIdHex}-${sc.spanIdHex}-$flags';
      final state = sc.traceState;
      if (state != null && state.isNotEmpty) {
        headers[tracestateHeader] = state;
      }
    }
    if (ctx.baggage.isNotEmpty) {
      final value = _encodeBaggage(ctx.baggage);
      if (value.isNotEmpty) headers[baggageHeader] = value;
    }
  }

  /// Reads headers (any letter case) into a context derived from [context].
  /// Malformed headers are ignored rather than throwing.
  static OtelContext extract(
    Map<String, String> headers, {
    OtelContext? context,
  }) {
    var ctx = context ?? OtelContext.current;
    String? find(String name) {
      final direct = headers[name];
      if (direct != null) return direct;
      for (final e in headers.entries) {
        if (e.key.toLowerCase() == name) return e.value;
      }
      return null;
    }

    final parent = parseTraceparent(
      find(traceparentHeader),
      find(tracestateHeader),
    );
    if (parent != null) ctx = ctx.withSpan(NonRecordingSpan(parent));

    final baggage = find(baggageHeader);
    if (baggage != null) {
      final parsed = _decodeBaggage(baggage);
      if (parsed.isNotEmpty) {
        ctx = ctx.withBaggage({...ctx.baggage, ...parsed});
      }
    }
    return ctx;
  }

  /// Parses `version-traceid-spanid-flags`. Future versions are accepted as
  /// long as the first four fields keep the version-00 layout.
  static SpanContext? parseTraceparent(String? value, [String? tracestate]) {
    if (value == null) return null;
    final v = value.trim();
    if (v.length < 55) return null;
    final version = v.substring(0, 2);
    if (version == 'ff' || Ids.fromHex(version, 1) == null) return null;
    if (version == '00' && v.length != 55) return null;
    if (v.length > 55 && v[55] != '-') return null;
    if (v[2] != '-' || v[35] != '-' || v[52] != '-') return null;

    final traceId = Ids.fromHex(v.substring(3, 35), 16);
    final spanId = Ids.fromHex(v.substring(36, 52), 8);
    final flags = Ids.fromHex(v.substring(53, 55), 1);
    if (traceId == null || spanId == null || flags == null) return null;
    if (Ids.isAllZero(traceId) || Ids.isAllZero(spanId)) return null;

    final state = tracestate?.trim();
    return SpanContext.raw(
      traceId: traceId,
      spanId: spanId,
      traceFlags: flags[0],
      traceState: state == null || state.isEmpty ? null : state,
      isRemote: true,
    );
  }

  static String _encodeBaggage(Map<String, String> baggage) {
    final buf = StringBuffer();
    var count = 0;
    for (final e in baggage.entries) {
      if (count >= _maxBaggageEntries) break;
      if (!_isToken(e.key)) continue;
      final entry = '${e.key}=${Uri.encodeComponent(e.value)}';
      if (buf.length + entry.length + 1 > _maxBaggageBytes) break;
      if (count > 0) buf.write(',');
      buf.write(entry);
      count++;
    }
    return buf.toString();
  }

  static Map<String, String> _decodeBaggage(String header) {
    final out = <String, String>{};
    for (final member in header.split(',')) {
      if (out.length >= _maxBaggageEntries) break;
      // Drop W3C baggage properties (";prop=x"): only key/value is kept.
      final kv = member.split(';').first;
      final eq = kv.indexOf('=');
      if (eq <= 0) continue;
      final key = kv.substring(0, eq).trim();
      if (!_isToken(key)) continue;
      try {
        out[key] = Uri.decodeComponent(kv.substring(eq + 1).trim());
      } catch (_) {
        continue; // Invalid percent-encoding.
      }
    }
    return out;
  }

  // RFC 7230 token characters.
  static final RegExp _token = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");
  static bool _isToken(String s) => _token.hasMatch(s);
}
