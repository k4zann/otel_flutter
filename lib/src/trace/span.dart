import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../core/attributes.dart';
import '../core/clock.dart';
import '../core/ids.dart';
import '../core/scope.dart';

enum SpanKind { internal, server, client, producer, consumer }

enum SpanStatusCode { unset, ok, error }

/// Caps that keep one runaway span or log from using unbounded memory.
final class TelemetryLimits {
  const TelemetryLimits({
    this.maxAttributes = 128,
    this.maxEvents = 128,
    this.maxLinks = 128,
    this.maxAttributeLength,
  });

  final int maxAttributes;
  final int maxEvents;
  final int maxLinks;

  /// Longer string values are truncated. Null means unlimited.
  final int? maxAttributeLength;
}

/// The propagated identity of a span (W3C trace-context fields).
final class SpanContext {
  @internal
  SpanContext.raw({
    required this.traceId,
    required this.spanId,
    this.traceFlags = 0,
    this.traceState,
    this.isRemote = false,
  });

  /// Builds a context from lowercase hex ids; returns [invalid] if malformed.
  factory SpanContext.fromHex({
    required String traceId,
    required String spanId,
    bool sampled = true,
    String? traceState,
    bool isRemote = false,
  }) {
    final t = Ids.fromHex(traceId, 16);
    final s = Ids.fromHex(spanId, 8);
    if (t == null || s == null || Ids.isAllZero(t) || Ids.isAllZero(s)) {
      return invalid;
    }
    return SpanContext.raw(
      traceId: t,
      spanId: s,
      traceFlags: sampled ? 1 : 0,
      traceState: traceState,
      isRemote: isRemote,
    );
  }

  static final SpanContext invalid = SpanContext.raw(
    traceId: Uint8List(16),
    spanId: Uint8List(8),
  );

  final Uint8List traceId;
  final Uint8List spanId;
  final int traceFlags;
  final String? traceState;
  final bool isRemote;

  bool get isValid => !Ids.isAllZero(traceId) && !Ids.isAllZero(spanId);
  bool get isSampled => (traceFlags & 0x01) == 0x01;

  late final String traceIdHex = Ids.toHex(traceId);
  late final String spanIdHex = Ids.toHex(spanId);

  @override
  String toString() =>
      'SpanContext($traceIdHex/$spanIdHex, '
      'sampled: $isSampled, remote: $isRemote)';
}

/// A unit of work. Get one from `Tracer.startSpan` and always call [end].
abstract interface class Span {
  SpanContext get spanContext;

  /// False once ended, and always false for spans that were not sampled.
  bool get isRecording;

  void setAttribute(String key, Object? value);
  void setAttributes(Map<String, Object?> attributes);
  void addEvent(
    String name, {
    Map<String, Object?>? attributes,
    DateTime? timestamp,
  });
  void addLink(SpanContext context, {Map<String, Object?>? attributes});

  /// Adds an `exception` event. Does not change the status; call
  /// [setStatus] with [SpanStatusCode.error] if the operation failed.
  void recordException(
    Object exception, {
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  });

  void setStatus(SpanStatusCode code, [String? description]);
  void updateName(String name);

  /// Ends the span. Calls after the first are ignored.
  void end({DateTime? endTime});
}

/// Span that only carries a context: used when not sampled, when the SDK is
/// not initialized, and for remote parents extracted from headers.
final class NonRecordingSpan implements Span {
  NonRecordingSpan(this.spanContext);

  @override
  final SpanContext spanContext;

  @override
  bool get isRecording => false;
  @override
  void setAttribute(String key, Object? value) {}
  @override
  void setAttributes(Map<String, Object?> attributes) {}
  @override
  void addEvent(
    String name, {
    Map<String, Object?>? attributes,
    DateTime? timestamp,
  }) {}
  @override
  void addLink(SpanContext context, {Map<String, Object?>? attributes}) {}
  @override
  void recordException(
    Object exception, {
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) {}
  @override
  void setStatus(SpanStatusCode code, [String? description]) {}
  @override
  void updateName(String name) {}
  @override
  void end({DateTime? endTime}) {}
}

@internal
final class SpanEvent {
  SpanEvent(this.name, this.timeMicros, this.attributes);
  final String name;
  final int timeMicros;
  final AttributeMap attributes;
}

@internal
final class SpanLink {
  SpanLink(this.context, this.attributes);
  final SpanContext context;
  final AttributeMap attributes;
}

/// Span recorded by the SDK and exported after [end].
@internal
final class RecordingSpan implements Span {
  RecordingSpan({
    required this.name,
    required this.kind,
    required this.spanContext,
    required this.parentSpanId,
    required this.parentIsRemote,
    required this.scope,
    required this.startMicros,
    required this.limits,
    required void Function(RecordingSpan span) onEnd,
  }) : _onEnd = onEnd,
       attributes = AttributeMap(
         limits.maxAttributes,
         limits.maxAttributeLength,
       );

  @override
  final SpanContext spanContext;
  final SpanKind kind;
  final Uint8List? parentSpanId;
  final bool parentIsRemote;
  final InstrumentationScope scope;
  final int startMicros;
  final TelemetryLimits limits;
  final void Function(RecordingSpan span) _onEnd;

  String name;
  int? endMicros;
  final AttributeMap attributes;
  final List<SpanEvent> events = [];
  int droppedEvents = 0;
  final List<SpanLink> links = [];
  int droppedLinks = 0;
  SpanStatusCode statusCode = SpanStatusCode.unset;
  String? statusDescription;

  @override
  bool get isRecording => endMicros == null;

  @override
  void setAttribute(String key, Object? value) {
    if (isRecording) attributes.set(key, value);
  }

  @override
  void setAttributes(Map<String, Object?> attributes) {
    if (isRecording) this.attributes.setAll(attributes);
  }

  @override
  void addEvent(
    String name, {
    Map<String, Object?>? attributes,
    DateTime? timestamp,
  }) {
    if (!isRecording) return;
    if (events.length >= limits.maxEvents) {
      droppedEvents++;
      return;
    }
    events.add(
      SpanEvent(
        name,
        timestamp?.microsecondsSinceEpoch ?? Clock.nowMicros(),
        AttributeMap(limits.maxAttributes, limits.maxAttributeLength)
          ..setAll(attributes),
      ),
    );
  }

  @override
  void addLink(SpanContext context, {Map<String, Object?>? attributes}) {
    if (!isRecording || !context.isValid) return;
    if (links.length >= limits.maxLinks) {
      droppedLinks++;
      return;
    }
    links.add(
      SpanLink(
        context,
        AttributeMap(limits.maxAttributes, limits.maxAttributeLength)
          ..setAll(attributes),
      ),
    );
  }

  @override
  void recordException(
    Object exception, {
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) {
    addEvent(
      'exception',
      attributes: {
        'exception.type': exception.runtimeType.toString(),
        'exception.message': exception.toString(),
        if (stackTrace != null) 'exception.stacktrace': stackTrace.toString(),
        ...?attributes,
      },
    );
  }

  @override
  void setStatus(SpanStatusCode code, [String? description]) {
    // Per spec: Ok is final, Unset is ignored, description only for Error.
    if (!isRecording ||
        statusCode == SpanStatusCode.ok ||
        code == SpanStatusCode.unset) {
      return;
    }
    statusCode = code;
    statusDescription = code == SpanStatusCode.error ? description : null;
  }

  @override
  void updateName(String name) {
    if (isRecording) this.name = name;
  }

  @override
  void end({DateTime? endTime}) {
    if (endMicros != null) return;
    final end = endTime?.microsecondsSinceEpoch ?? Clock.nowMicros();
    endMicros = end < startMicros ? startMicros : end;
    _onEnd(this);
  }
}
