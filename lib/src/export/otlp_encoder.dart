import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../core/attributes.dart';
import '../core/scope.dart';
import '../logs/log_record.dart';
import '../metrics/meter.dart';
import '../trace/span.dart';
import 'proto_writer.dart';

/// Encodes telemetry as OTLP protobuf export requests
/// (opentelemetry-proto: collector/{trace,metrics,logs}/v1).
@internal
abstract final class OtlpEncoder {
  /// Resource message body. The resource never changes, so the SDK encodes it
  /// once and copies the bytes into every request.
  static Uint8List encodeResource(Map<String, Object> attributes) {
    final w = ProtoWriter(1024);
    _attributes(w, 1, attributes);
    return w.toBytes();
  }

  static Uint8List encodeSpans(Uint8List resource, List<RecordingSpan> spans) {
    final w = ProtoWriter();
    final resourceSpans = w.begin(1);
    w.messageBytesField(1, resource);
    _byScope(spans, (s) => s.scope).forEach((scope, list) {
      final scopeSpans = w.begin(2);
      _scope(w, 1, scope);
      for (final span in list) {
        _span(w, 2, span);
      }
      w.end(scopeSpans);
    });
    w.end(resourceSpans);
    return w.toBytes();
  }

  static Uint8List encodeMetrics(Uint8List resource, List<MetricData> metrics) {
    final w = ProtoWriter();
    final resourceMetrics = w.begin(1);
    w.messageBytesField(1, resource);
    _byScope(metrics, (m) => m.scope).forEach((scope, list) {
      final scopeMetrics = w.begin(2);
      _scope(w, 1, scope);
      for (final metric in list) {
        _metric(w, 2, metric);
      }
      w.end(scopeMetrics);
    });
    w.end(resourceMetrics);
    return w.toBytes();
  }

  static Uint8List encodeLogs(Uint8List resource, List<LogRecordData> logs) {
    final w = ProtoWriter();
    final resourceLogs = w.begin(1);
    w.messageBytesField(1, resource);
    _byScope(logs, (l) => l.scope).forEach((scope, list) {
      final scopeLogs = w.begin(2);
      _scope(w, 1, scope);
      for (final record in list) {
        _log(w, 2, record);
      }
      w.end(scopeLogs);
    });
    w.end(resourceLogs);
    return w.toBytes();
  }

  static Map<InstrumentationScope, List<T>> _byScope<T>(
    List<T> items,
    InstrumentationScope Function(T) scopeOf,
  ) {
    final out = <InstrumentationScope, List<T>>{};
    for (final item in items) {
      (out[scopeOf(item)] ??= <T>[]).add(item);
    }
    return out;
  }

  static void _scope(ProtoWriter w, int field, InstrumentationScope scope) {
    final m = w.begin(field);
    if (scope.name.isNotEmpty) w.stringField(1, scope.name);
    final version = scope.version;
    if (version != null && version.isNotEmpty) w.stringField(2, version);
    w.end(m);
  }

  static void _span(ProtoWriter w, int field, RecordingSpan span) {
    final ctx = span.spanContext;
    final m = w.begin(field);
    w
      ..bytesField(1, ctx.traceId)
      ..bytesField(2, ctx.spanId);
    final traceState = ctx.traceState;
    if (traceState != null && traceState.isNotEmpty) {
      w.stringField(3, traceState);
    }
    final parent = span.parentSpanId;
    if (parent != null) w.bytesField(4, parent);
    if (span.name.isNotEmpty) w.stringField(5, span.name);
    w
      ..varintField(6, span.kind.index + 1)
      ..timeField(7, span.startMicros)
      ..timeField(8, span.endMicros ?? span.startMicros);
    _attributes(w, 9, span.attributes.values);
    if (span.attributes.dropped > 0) {
      w.varintField(10, span.attributes.dropped);
    }
    for (final event in span.events) {
      final e = w.begin(11);
      w.timeField(1, event.timeMicros);
      if (event.name.isNotEmpty) w.stringField(2, event.name);
      _attributes(w, 3, event.attributes.values);
      if (event.attributes.dropped > 0) {
        w.varintField(4, event.attributes.dropped);
      }
      w.end(e);
    }
    if (span.droppedEvents > 0) w.varintField(12, span.droppedEvents);
    for (final link in span.links) {
      final l = w.begin(13);
      w
        ..bytesField(1, link.context.traceId)
        ..bytesField(2, link.context.spanId);
      final linkState = link.context.traceState;
      if (linkState != null && linkState.isNotEmpty) {
        w.stringField(3, linkState);
      }
      _attributes(w, 4, link.attributes.values);
      if (link.attributes.dropped > 0) {
        w.varintField(5, link.attributes.dropped);
      }
      w.fixed32Field(6, _spanFlags(link.context.traceFlags, link.context.isRemote));
      w.end(l);
    }
    if (span.droppedLinks > 0) w.varintField(14, span.droppedLinks);
    if (span.statusCode != SpanStatusCode.unset) {
      final s = w.begin(15);
      final description = span.statusDescription;
      if (description != null && description.isNotEmpty) {
        w.stringField(2, description);
      }
      w
        ..varintField(3, span.statusCode.index)
        ..end(s);
    }
    w
      ..fixed32Field(16, _spanFlags(ctx.traceFlags, span.parentIsRemote))
      ..end(m);
  }

  /// W3C trace flags plus the OTLP "is remote" bits (SpanFlags).
  static int _spanFlags(int traceFlags, bool isRemote) =>
      (traceFlags & 0xFF) | 0x100 | (isRemote ? 0x200 : 0);

  static void _metric(ProtoWriter w, int field, MetricData metric) {
    final m = w.begin(field);
    w.stringField(1, metric.name);
    final description = metric.description;
    if (description != null && description.isNotEmpty) {
      w.stringField(2, description);
    }
    final unit = metric.unit;
    if (unit != null && unit.isNotEmpty) w.stringField(3, unit);
    final temporality =
        metric.temporality == MetricTemporality.delta ? 1 : 2;
    switch (metric.kind) {
      case MetricKind.sum:
        final sum = w.begin(7);
        for (final p in metric.points) {
          _numberPoint(w, 1, p);
        }
        w
          ..varintField(2, temporality)
          ..boolField(3, metric.isMonotonic)
          ..end(sum);
      case MetricKind.gauge:
        final gauge = w.begin(5);
        for (final p in metric.points) {
          _numberPoint(w, 1, p);
        }
        w.end(gauge);
      case MetricKind.histogram:
        final histogram = w.begin(9);
        for (final p in metric.points) {
          _histogramPoint(w, 1, p);
        }
        w
          ..varintField(2, temporality)
          ..end(histogram);
    }
    w.end(m);
  }

  static void _numberPoint(ProtoWriter w, int field, MetricPoint p) {
    final m = w.begin(field);
    _attributes(w, 7, p.attributes);
    final start = p.startMicros;
    if (start != null) w.timeField(2, start);
    w.timeField(3, p.timeMicros);
    final value = p.value ?? 0;
    if (value is int) {
      w.sfixed64Field(6, value);
    } else {
      w.doubleField(4, value.toDouble());
    }
    w.end(m);
  }

  static void _histogramPoint(ProtoWriter w, int field, MetricPoint p) {
    final m = w.begin(field);
    _attributes(w, 9, p.attributes);
    w
      ..timeField(2, p.startMicros ?? p.timeMicros)
      ..timeField(3, p.timeMicros)
      ..fixed64Field(4, p.count)
      ..doubleField(5, p.sum);
    final counts = w.begin(6); // packed repeated fixed64
    for (final c in p.bucketCounts ?? const <int>[]) {
      w.fixed64Raw(c);
    }
    w.end(counts);
    final bounds = w.begin(7); // packed repeated double
    for (final b in p.boundaries ?? const <double>[]) {
      w.doubleRaw(b);
    }
    w.end(bounds);
    final min = p.min;
    if (min != null) w.doubleField(11, min);
    final max = p.max;
    if (max != null) w.doubleField(12, max);
    w.end(m);
  }

  static void _log(ProtoWriter w, int field, LogRecordData r) {
    final m = w.begin(field);
    w
      ..timeField(1, r.timeMicros)
      ..timeField(11, r.observedMicros)
      ..varintField(2, r.severity.number)
      ..stringField(3, r.severity.name.toUpperCase());
    final body = r.body;
    if (body != null) {
      final b = w.begin(5);
      _anyValue(w, body);
      w.end(b);
    }
    _attributes(w, 6, r.attributes.values);
    if (r.attributes.dropped > 0) w.varintField(7, r.attributes.dropped);
    final ctx = r.spanContext;
    if (ctx != null) {
      w
        ..fixed32Field(8, ctx.traceFlags & 0xFF)
        ..bytesField(9, ctx.traceId)
        ..bytesField(10, ctx.spanId);
    }
    final eventName = r.eventName;
    if (eventName != null && eventName.isNotEmpty) w.stringField(12, eventName);
    w.end(m);
  }

  static void _attributes(
    ProtoWriter w,
    int field,
    Map<String, Object?> attributes,
  ) {
    attributes.forEach((key, value) {
      final kv = w.begin(field);
      w.stringField(1, key);
      final av = w.begin(2);
      _anyValue(w, value);
      w
        ..end(av)
        ..end(kv);
    });
  }

  /// Writes the AnyValue oneof. Default values (0, false, "") are written
  /// explicitly: inside a oneof, omitting them would erase the value.
  static void _anyValue(ProtoWriter w, Object? value) {
    switch (value) {
      case null:
        return;
      case String v:
        w.stringField(1, v);
      case bool v:
        w.boolField(2, v);
      case int v:
        w.varintField(3, v);
      case double v:
        w.doubleField(4, v);
      case Uint8List v:
        w.bytesField(7, v);
      case List<Object?> v:
        final array = w.begin(5);
        for (final item in v) {
          final av = w.begin(1);
          _anyValue(w, item);
          w.end(av);
        }
        w.end(array);
      case Map<String, Object?> v:
        final kvList = w.begin(6);
        _attributes(w, 1, v);
        w.end(kvList);
      default:
        w.stringField(1, AttributeValues.normalize(value, null).toString());
    }
  }
}
