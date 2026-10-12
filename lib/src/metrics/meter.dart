import 'package:meta/meta.dart';

import '../core/attributes.dart';
import '../core/clock.dart';
import '../core/diagnostics.dart';
import '../core/scope.dart';

/// How sums and histograms are reported: running totals since start
/// (Prometheus/Grafana style) or per-interval changes (Datadog style).
enum MetricTemporality { cumulative, delta }

/// Creates instruments for one instrumentation scope. Get it via `Otel.meter`.
///
/// Instruments are cached by name: calling `counter('x')` in a hot path
/// returns the same object instead of leaking a new one each time.
final class Meter {
  Meter._(this.scope);

  final InstrumentationScope scope;
  final Map<String, Instrument> _instruments = {};

  factory Meter.of(String name, [String? version]) {
    final scope = InstrumentationScope.of(name, version);
    return MeterRegistry.meters.putIfAbsent(scope, () => Meter._(scope));
  }

  /// Monotonic sum, e.g. requests sent. Negative values are ignored.
  Counter counter(String name, {String? unit, String? description}) =>
      _get(name, () => Counter._(this, name, unit, description));

  /// Sum that can go down, e.g. items in a cart.
  UpDownCounter upDownCounter(
    String name, {
    String? unit,
    String? description,
  }) => _get(name, () => UpDownCounter._(this, name, unit, description));

  /// Distribution of values, e.g. latency. [boundaries] are bucket upper
  /// bounds; the default suits milliseconds.
  Histogram histogram(
    String name, {
    String? unit,
    String? description,
    List<double>? boundaries,
  }) => _get(
    name,
    () => Histogram._(
      this,
      name,
      unit,
      description,
      boundaries ?? Histogram.defaultBoundaries,
    ),
  );

  /// Last recorded value, e.g. current screen brightness.
  Gauge gauge(String name, {String? unit, String? description}) =>
      _get(name, () => Gauge._(this, name, unit, description));

  /// Gauge read on each export by calling [callback], e.g. memory usage.
  ObservableGauge observableGauge(
    String name,
    void Function(ObservableResult result) callback, {
    String? unit,
    String? description,
  }) => _get(
    name,
    () => ObservableGauge._(this, name, unit, description, callback),
  );

  T _get<T extends Instrument>(String name, T Function() create) {
    final key = name.toLowerCase();
    final existing = _instruments[key];
    if (existing is T) return existing;
    if (existing != null) {
      Diagnostics.warnOnce(
        'instrument-kind-$key',
        'Instrument "$name" already exists as ${existing.runtimeType}; '
            'creating a separate $T with the same name.',
      );
      return (_instruments['$key#$T'] ??= create()) as T;
    }
    return _instruments[key] = create();
  }
}

/// Holds every meter so instruments created before `Otel.init` are exported.
@internal
abstract final class MeterRegistry {
  static final Map<InstrumentationScope, Meter> meters = {};

  /// Set by the SDK; while false, recording is a no-op.
  static bool enabled = false;

  /// Max distinct attribute sets per instrument (OpenTelemetry default).
  static int cardinalityLimit = 2000;

  static MetricTemporality temporality = MetricTemporality.cumulative;

  /// Returns nothing when no instrument changed since the last collection,
  /// so an idle app makes no metric requests at all.
  static List<MetricData> collect() {
    final instruments = [
      for (final m in meters.values) ...m._instruments.values,
    ];
    final changed = instruments.any((i) => i._dirty || i is ObservableGauge);
    if (!changed) return const [];
    final now = Clock.nowMicros();
    final out = <MetricData>[];
    for (final i in instruments) {
      final data = i._collect(now);
      if (data != null) out.add(data);
    }
    return out;
  }

  @visibleForTesting
  static void reset() {
    meters.clear();
    enabled = false;
    cardinalityLimit = 2000;
    temporality = MetricTemporality.cumulative;
  }
}

enum MetricKind { sum, gauge, histogram }

@internal
final class MetricData {
  MetricData({
    required this.scope,
    required this.name,
    required this.unit,
    required this.description,
    required this.kind,
    required this.isMonotonic,
    required this.temporality,
    required this.points,
  });

  final InstrumentationScope scope;
  final String name;
  final String? unit;
  final String? description;
  final MetricKind kind;
  final bool isMonotonic;
  final MetricTemporality temporality;
  final List<MetricPoint> points;
}

@internal
final class MetricPoint {
  MetricPoint({
    required this.attributes,
    required this.startMicros,
    required this.timeMicros,
    this.value,
    this.bucketCounts,
    this.boundaries,
    this.count = 0,
    this.sum = 0,
    this.min,
    this.max,
  });

  final Map<String, Object> attributes;
  final int? startMicros;
  final int timeMicros;
  final num? value;
  final List<int>? bucketCounts;
  final List<double>? boundaries;
  final int count;
  final double sum;
  final double? min;
  final double? max;
}

/// Base class for all instruments.
sealed class Instrument {
  Instrument._(this.meter, this.name, this.unit, this.description);

  final Meter meter;
  final String name;
  final String? unit;
  final String? description;

  final Map<String, _Point> _points = {};
  bool _dirty = false;
  int _intervalStart = Clock.nowMicros();

  static const _overflowKey = '\u0000overflow';
  static const _overflowAttributes = <String, Object>{
    'otel.metric.overflow': true,
  };

  _Point _newPoint(Map<String, Object> attributes, int startMicros);
  MetricData? _collect(int now);

  _Point? _pointFor(Map<String, Object?>? attributes) {
    if (!MeterRegistry.enabled) return null;
    final key = _keyOf(attributes);
    final existing = _points[key];
    if (existing != null) return existing;
    final start = MeterRegistry.temporality == MetricTemporality.delta
        ? _intervalStart
        : Clock.nowMicros();
    if (_points.length >= MeterRegistry.cardinalityLimit - 1) {
      Diagnostics.warnOnce(
        'cardinality-$name',
        'Metric "$name" exceeded ${MeterRegistry.cardinalityLimit} '
            'attribute sets; extra values go to otel.metric.overflow. Avoid '
            'unbounded attribute values such as ids or URLs.',
      );
      return _points[_overflowKey] ??= _newPoint(_overflowAttributes, start);
    }
    return _points[key] = _newPoint(_normalized(attributes), start);
  }

  static Map<String, Object> _normalized(Map<String, Object?>? attributes) {
    if (attributes == null || attributes.isEmpty) return const {};
    final out = <String, Object>{};
    attributes.forEach((k, v) {
      final n = AttributeValues.normalize(v, null);
      if (n != null && k.isNotEmpty) out[k] = n;
    });
    return Map.unmodifiable(out);
  }

  static String _keyOf(Map<String, Object?>? attributes) {
    if (attributes == null || attributes.isEmpty) return '';
    final keys = attributes.keys.toList(growable: false);
    if (keys.length > 1) keys.sort();
    final sb = StringBuffer();
    for (final k in keys) {
      final v = attributes[k];
      if (v == null) continue;
      sb
        ..write(k)
        ..write(
          v is String
              ? '\u0001s'
              : v is int
              ? '\u0001i'
              : '\u0001o',
        )
        ..write(v)
        ..write('\u0002');
    }
    return sb.toString();
  }

  /// Shared collection for sums and histograms.
  MetricData? _collectPoints(
    int now,
    MetricKind kind,
    bool isMonotonic,
    MetricPoint Function(_Point p, int now) toPoint,
  ) {
    final delta = MeterRegistry.temporality == MetricTemporality.delta;
    final selected = delta
        ? _points.values.where((p) => p.updated)
        : _points.values;
    final points = [for (final p in selected) toPoint(p, now)];
    for (final p in _points.values) {
      p.updated = false;
    }
    if (delta) {
      _points.clear();
      _intervalStart = now;
    }
    _dirty = false;
    if (points.isEmpty) return null;
    return MetricData(
      scope: meter.scope,
      name: name,
      unit: unit,
      description: description,
      kind: kind,
      isMonotonic: isMonotonic,
      temporality: MeterRegistry.temporality,
      points: points,
    );
  }
}

sealed class _Point {
  _Point(this.attributes, this.startMicros);
  final Map<String, Object> attributes;
  final int startMicros;
  bool updated = false;
}

final class _SumPoint extends _Point {
  _SumPoint(super.attributes, super.startMicros);
  num value = 0;
}

final class _HistogramPoint extends _Point {
  _HistogramPoint(super.attributes, super.startMicros, int buckets)
    : counts = List<int>.filled(buckets, 0);
  final List<int> counts;
  int count = 0;
  double sum = 0;
  double min = double.infinity;
  double max = double.negativeInfinity;
}

final class _GaugePoint extends _Point {
  _GaugePoint(super.attributes, super.startMicros);
  num value = 0;
  int timeMicros = 0;
}

abstract class _SumInstrument extends Instrument {
  _SumInstrument(super.meter, super.name, super.unit, super.description)
    : super._();

  bool get _isMonotonic;

  void _add(num value, Map<String, Object?>? attributes) {
    final p = _pointFor(attributes) as _SumPoint?;
    if (p == null) return;
    p
      ..value += value
      ..updated = true;
    _dirty = true;
  }

  @override
  _Point _newPoint(Map<String, Object> attributes, int startMicros) =>
      _SumPoint(attributes, startMicros);

  @override
  MetricData? _collect(int now) => _collectPoints(
    now,
    MetricKind.sum,
    _isMonotonic,
    (p, now) => MetricPoint(
      attributes: p.attributes,
      startMicros: p.startMicros,
      timeMicros: now,
      value: (p as _SumPoint).value,
    ),
  );
}

final class Counter extends _SumInstrument {
  Counter._(super.meter, super.name, super.unit, super.description);

  @override
  bool get _isMonotonic => true;

  void add(num value, [Map<String, Object?>? attributes]) {
    if (value < 0) {
      Diagnostics.warnOnce(
        'counter-negative-$name',
        'Counter "$name" got a negative value; use an UpDownCounter.',
      );
      return;
    }
    _add(value, attributes);
  }
}

final class UpDownCounter extends _SumInstrument {
  UpDownCounter._(super.meter, super.name, super.unit, super.description);

  @override
  bool get _isMonotonic => false;

  void add(num value, [Map<String, Object?>? attributes]) =>
      _add(value, attributes);
}

final class Histogram extends Instrument {
  Histogram._(
    super.meter,
    super.name,
    super.unit,
    super.description,
    List<double> boundaries,
  ) : boundaries = List.unmodifiable(boundaries.toList()..sort()),
      super._();

  /// OpenTelemetry's default explicit bucket bounds.
  static const defaultBoundaries = <double>[
    0,
    5,
    10,
    25,
    50,
    75,
    100,
    250,
    500,
    750,
    1000,
    2500,
    5000,
    7500,
    10000,
  ];

  final List<double> boundaries;

  void record(num value, [Map<String, Object?>? attributes]) {
    final p = _pointFor(attributes) as _HistogramPoint?;
    if (p == null) return;
    final v = value.toDouble();
    var i = 0;
    while (i < boundaries.length && v > boundaries[i]) {
      i++;
    }
    p
      ..counts[i] += 1
      ..count += 1
      ..sum += v
      ..updated = true;
    if (v < p.min) p.min = v;
    if (v > p.max) p.max = v;
    _dirty = true;
  }

  @override
  _Point _newPoint(Map<String, Object> attributes, int startMicros) =>
      _HistogramPoint(attributes, startMicros, boundaries.length + 1);

  @override
  MetricData? _collect(int now) =>
      _collectPoints(now, MetricKind.histogram, false, (point, now) {
        final p = point as _HistogramPoint;
        return MetricPoint(
          attributes: p.attributes,
          startMicros: p.startMicros,
          timeMicros: now,
          bucketCounts: List.of(p.counts),
          boundaries: boundaries,
          count: p.count,
          sum: p.sum,
          min: p.count > 0 ? p.min : null,
          max: p.count > 0 ? p.max : null,
        );
      });
}

final class Gauge extends Instrument {
  Gauge._(super.meter, super.name, super.unit, super.description) : super._();

  void record(num value, [Map<String, Object?>? attributes]) {
    final p = _pointFor(attributes) as _GaugePoint?;
    if (p == null) return;
    p
      ..value = value
      ..timeMicros = Clock.nowMicros()
      ..updated = true;
    _dirty = true;
  }

  @override
  _Point _newPoint(Map<String, Object> attributes, int startMicros) =>
      _GaugePoint(attributes, startMicros);

  @override
  MetricData? _collect(int now) {
    final delta = MeterRegistry.temporality == MetricTemporality.delta;
    final points = [
      for (final p in _points.values.cast<_GaugePoint>())
        if (!delta || p.updated)
          MetricPoint(
            attributes: p.attributes,
            startMicros: null,
            timeMicros: p.timeMicros,
            value: p.value,
          ),
    ];
    for (final p in _points.values) {
      p.updated = false;
    }
    _dirty = false;
    if (points.isEmpty) return null;
    return MetricData(
      scope: meter.scope,
      name: name,
      unit: unit,
      description: description,
      kind: MetricKind.gauge,
      isMonotonic: false,
      temporality: MeterRegistry.temporality,
      points: points,
    );
  }
}

/// Receives values inside an [ObservableGauge] callback.
final class ObservableResult {
  ObservableResult._();
  final List<(num, Map<String, Object?>?)> _observations = [];

  void observe(num value, [Map<String, Object?>? attributes]) =>
      _observations.add((value, attributes));
}

final class ObservableGauge extends Instrument {
  ObservableGauge._(
    super.meter,
    super.name,
    super.unit,
    super.description,
    this._callback,
  ) : super._();

  final void Function(ObservableResult result) _callback;

  @override
  _Point _newPoint(Map<String, Object> attributes, int startMicros) =>
      _GaugePoint(attributes, startMicros);

  @override
  MetricData? _collect(int now) {
    if (!MeterRegistry.enabled) return null;
    final result = ObservableResult._();
    try {
      _callback(result);
    } catch (e) {
      Diagnostics.warnOnce(
        'observable-$name',
        'Callback of observable gauge "$name" threw: $e',
      );
      return null;
    }
    if (result._observations.isEmpty) return null;
    final seen = <String>{};
    final points = <MetricPoint>[];
    // Iterate newest first so a repeated attribute set keeps its last value.
    for (final (value, attrs) in result._observations.reversed) {
      if (!seen.add(Instrument._keyOf(attrs))) continue;
      points.add(
        MetricPoint(
          attributes: Instrument._normalized(attrs),
          startMicros: null,
          timeMicros: now,
          value: value,
        ),
      );
    }
    return MetricData(
      scope: meter.scope,
      name: name,
      unit: unit,
      description: description,
      kind: MetricKind.gauge,
      isMonotonic: false,
      temporality: MeterRegistry.temporality,
      points: points,
    );
  }
}
