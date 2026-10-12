import 'package:meta/meta.dart';

import '../core/attributes.dart';
import '../core/scope.dart';
import '../trace/span.dart';

/// Log severity; [number] is the OpenTelemetry SeverityNumber.
enum Severity {
  trace(1),
  debug(5),
  info(9),
  warn(13),
  error(17),
  fatal(21);

  const Severity(this.number);
  final int number;
}

@internal
final class LogRecordData {
  LogRecordData({
    required this.scope,
    required this.timeMicros,
    required this.observedMicros,
    required this.severity,
    required this.body,
    required this.attributes,
    required this.eventName,
    required this.spanContext,
  });

  final InstrumentationScope scope;
  final int timeMicros;
  final int observedMicros;
  final Severity severity;

  /// String, bool, int, double, `List` or `Map<String, Object?>` (nested).
  final Object? body;
  final AttributeMap attributes;
  final String? eventName;

  /// Context of the span active when the log was emitted, for correlation.
  final SpanContext? spanContext;
}
