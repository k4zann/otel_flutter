import 'package:meta/meta.dart';

import '../logs/log_record.dart';
import '../trace/sampler.dart';
import '../trace/span.dart';
import 'attributes.dart';

/// What the API classes (Tracer, Meter, Logger) need from the running SDK.
///
/// While [current] is null every API call is a cheap no-op, so libraries can
/// be instrumented without forcing the app to initialize telemetry, and
/// tracers/instruments obtained before `Otel.init` start working after it.
@internal
abstract interface class Pipeline {
  static Pipeline? current;

  Sampler get sampler;
  TelemetryLimits get limits;

  void onSpanEnd(RecordingSpan span);
  void onLogRecord(LogRecordData record);

  /// Adds session id, current screen and global attributes.
  void applyCommonAttributes(AttributeMap target);
}
