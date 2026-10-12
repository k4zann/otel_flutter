import 'package:otel_flutter/src/core/attributes.dart';
import 'package:otel_flutter/src/core/pipeline.dart';
import 'package:otel_flutter/src/export/offline_store.dart';
import 'package:otel_flutter/src/logs/log_record.dart';
import 'package:otel_flutter/src/trace/sampler.dart';
import 'package:otel_flutter/src/trace/span.dart';

/// Records what the API layer hands to the SDK.
final class FakePipeline implements Pipeline {
  FakePipeline({double ratio = 1.0, this.limits = const TelemetryLimits()})
    : sampler = Sampler(ratio);

  @override
  final Sampler sampler;
  @override
  final TelemetryLimits limits;

  final List<RecordingSpan> ended = [];
  final List<LogRecordData> logs = [];
  Map<String, Object> common = const {};

  @override
  void onSpanEnd(RecordingSpan span) => ended.add(span);

  @override
  void onLogRecord(LogRecordData record) => logs.add(record);

  @override
  void applyCommonAttributes(AttributeMap target) => common.forEach(target.set);
}

/// In-memory offline store.
final class MemoryStore implements OfflineStore {
  final List<Payload> items = [];

  @override
  Future<void> save(Payload payload) async => items.add(payload);

  @override
  Future<StoredPayload?> oldest() async =>
      items.isEmpty ? null : StoredPayload(items.first, items.first);

  @override
  Future<void> delete(StoredPayload stored) async =>
      items.remove(stored.handle);
}
