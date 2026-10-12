import 'dart:async';

import '../core/clock.dart';
import '../core/context.dart';
import '../core/diagnostics.dart';
import '../core/ids.dart';
import '../core/pipeline.dart';
import '../core/scope.dart';
import 'span.dart';

/// Creates spans for one instrumentation scope. Get it via `Otel.tracer`.
final class Tracer {
  Tracer._(this.scope);

  static final Map<InstrumentationScope, Tracer> _cache = {};

  factory Tracer.of(String name, [String? version]) {
    final scope = InstrumentationScope.of(name, version);
    return _cache.putIfAbsent(scope, () => Tracer._(scope));
  }

  final InstrumentationScope scope;

  /// Starts a span. It is NOT made active: pass it to [OtelContext.withSpan]
  /// or use [trace]/[traceAsync] so child spans pick it up automatically.
  ///
  /// The parent is the active span of [context] (default: current context)
  /// unless [newRoot] is true.
  Span startSpan(
    String name, {
    SpanKind kind = SpanKind.internal,
    Map<String, Object?>? attributes,
    OtelContext? context,
    List<SpanContext>? links,
    DateTime? startTime,
    bool newRoot = false,
  }) {
    final parent = newRoot
        ? null
        : (context ?? OtelContext.current).span?.spanContext;
    final validParent = parent != null && parent.isValid ? parent : null;

    final pipeline = Pipeline.current;
    if (pipeline == null) {
      // Not initialized: record nothing but keep propagating the parent.
      return NonRecordingSpan(validParent ?? SpanContext.invalid);
    }

    final traceId = validParent?.traceId ?? Ids.traceId();
    final sampled = pipeline.sampler.shouldSample(
      traceId,
      parentSampled: validParent?.isSampled,
    );
    final spanContext = SpanContext.raw(
      traceId: traceId,
      spanId: Ids.spanId(),
      traceFlags: validParent?.traceFlags ?? (sampled ? 0x01 : 0x00),
      traceState: validParent?.traceState,
    );
    if (!sampled) return NonRecordingSpan(spanContext);

    final span = RecordingSpan(
      name: name,
      kind: kind,
      spanContext: spanContext,
      parentSpanId: validParent?.spanId,
      parentIsRemote: validParent?.isRemote ?? false,
      scope: scope,
      startMicros: startTime?.microsecondsSinceEpoch ?? Clock.nowMicros(),
      limits: pipeline.limits,
      onEnd: pipeline.onSpanEnd,
    );
    pipeline.applyCommonAttributes(span.attributes);
    span.attributes.setAll(attributes);
    links?.forEach(span.addLink);
    return span;
  }

  /// Runs synchronous [fn] inside an active span. Exceptions are recorded,
  /// mark the span as error, and are rethrown. The span always ends.
  R trace<R>(
    String name,
    R Function(Span span) fn, {
    SpanKind kind = SpanKind.internal,
    Map<String, Object?>? attributes,
    OtelContext? context,
  }) {
    final parent = context ?? OtelContext.current;
    final span = startSpan(
      name,
      kind: kind,
      attributes: attributes,
      context: parent,
    );
    try {
      final result = parent.withSpan(span).run(() => fn(span));
      if (result is Future) {
        Diagnostics.warnOnce(
          'trace-future',
          'Tracer.trace("$name") returned a Future; use traceAsync so the '
              'span covers the async work.',
        );
      }
      return result;
    } catch (e, st) {
      _fail(span, e, st);
      rethrow;
    } finally {
      span.end();
    }
  }

  /// Async version of [trace]: the span ends when the returned future does.
  Future<R> traceAsync<R>(
    String name,
    Future<R> Function(Span span) fn, {
    SpanKind kind = SpanKind.internal,
    Map<String, Object?>? attributes,
    OtelContext? context,
  }) async {
    final parent = context ?? OtelContext.current;
    final span = startSpan(
      name,
      kind: kind,
      attributes: attributes,
      context: parent,
    );
    try {
      return await parent.withSpan(span).run(() => fn(span));
    } catch (e, st) {
      _fail(span, e, st);
      rethrow;
    } finally {
      span.end();
    }
  }

  static void _fail(Span span, Object e, StackTrace st) {
    span
      ..recordException(e, stackTrace: st)
      ..setStatus(SpanStatusCode.error, e.toString());
  }
}
