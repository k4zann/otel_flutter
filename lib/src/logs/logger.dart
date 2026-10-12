import '../core/attributes.dart';
import '../core/clock.dart';
import '../core/context.dart';
import '../core/pipeline.dart';
import '../core/scope.dart';
import 'log_record.dart';

/// Emits structured logs and events. Get it via `Otel.logger`.
///
/// Every record is linked to the active span (trace id / span id), so in the
/// backend you can jump from a log line to the trace it happened in.
final class Logger {
  Logger._(this.scope);

  static final Map<InstrumentationScope, Logger> _cache = {};

  factory Logger.of(String name, [String? version]) {
    final scope = InstrumentationScope.of(name, version);
    return _cache.putIfAbsent(scope, () => Logger._(scope));
  }

  final InstrumentationScope scope;

  void emit({
    Severity severity = Severity.info,
    Object? body,
    Map<String, Object?>? attributes,
    String? eventName,
    Object? error,
    StackTrace? stackTrace,
    DateTime? timestamp,
    OtelContext? context,
  }) {
    final pipeline = Pipeline.current;
    if (pipeline == null) return;

    final limits = pipeline.limits;
    final attrs = AttributeMap(limits.maxAttributes, limits.maxAttributeLength);
    pipeline.applyCommonAttributes(attrs);
    attrs.setAll(attributes);
    if (error != null) {
      attrs
        ..set('exception.type', error.runtimeType.toString())
        ..set('exception.message', error.toString());
      if (stackTrace != null) {
        attrs.set('exception.stacktrace', stackTrace.toString());
      }
    }

    final now = Clock.nowMicros();
    final spanContext = (context ?? OtelContext.current).span?.spanContext;
    pipeline.onLogRecord(LogRecordData(
      scope: scope,
      timeMicros: timestamp?.microsecondsSinceEpoch ?? now,
      observedMicros: now,
      severity: severity,
      body: _normalizeBody(body, limits.maxAttributeLength, 0),
      attributes: attrs,
      eventName: eventName,
      spanContext: spanContext != null && spanContext.isValid
          ? spanContext
          : null,
    ));
  }

  void trace(String message, {Map<String, Object?>? attributes}) =>
      emit(severity: Severity.trace, body: message, attributes: attributes);

  void debug(String message, {Map<String, Object?>? attributes}) =>
      emit(severity: Severity.debug, body: message, attributes: attributes);

  void info(String message, {Map<String, Object?>? attributes}) =>
      emit(severity: Severity.info, body: message, attributes: attributes);

  void warn(
    String message, {
    Map<String, Object?>? attributes,
    Object? error,
    StackTrace? stackTrace,
  }) =>
      emit(
        severity: Severity.warn,
        body: message,
        attributes: attributes,
        error: error,
        stackTrace: stackTrace,
      );

  void error(
    String message, {
    Map<String, Object?>? attributes,
    Object? error,
    StackTrace? stackTrace,
  }) =>
      emit(
        severity: Severity.error,
        body: message,
        attributes: attributes,
        error: error,
        stackTrace: stackTrace,
      );

  void fatal(
    String message, {
    Map<String, Object?>? attributes,
    Object? error,
    StackTrace? stackTrace,
  }) =>
      emit(
        severity: Severity.fatal,
        body: message,
        attributes: attributes,
        error: error,
        stackTrace: stackTrace,
      );

  static Object? _normalizeBody(Object? body, int? maxLength, int depth) {
    if (body is Map && depth < 8) {
      return <String, Object?>{
        for (final e in body.entries)
          e.key.toString(): _normalizeBody(e.value, maxLength, depth + 1),
      };
    }
    return AttributeValues.normalize(body, maxLength);
  }
}
