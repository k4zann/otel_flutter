import 'package:flutter_test/flutter_test.dart';
import 'package:otel_flutter/src/metrics/meter.dart';

void main() {
  setUp(() {
    MeterRegistry.reset();
    MeterRegistry.enabled = true;
  });
  tearDown(MeterRegistry.reset);

  MetricData only(String name) =>
      MeterRegistry.collect().singleWhere((m) => m.name == name);

  test('instruments are cached by name (no leak in hot paths)', () {
    final meter = Meter.of('m');
    expect(identical(meter.counter('c'), meter.counter('C')), isTrue);
    expect(identical(Meter.of('m'), meter), isTrue);
    // Same name, different kind: separate instrument, no crash.
    expect(meter.histogram('c'), isA<Histogram>());
  });

  test('counter sums per attribute set, independent of key order', () {
    final c = Meter.of('m').counter('c');
    c.add(1, {'a': 1, 'b': 'x'});
    c.add(2, {'b': 'x', 'a': 1});
    c.add(5, {'a': 2});
    c.add(-3, {'a': 2}); // ignored
    final points = only('c').points;
    expect(points, hasLength(2));
    expect(points.firstWhere((p) => p.attributes['a'] == 1).value, 3);
    expect(points.firstWhere((p) => p.attributes['a'] == 2).value, 5);
  });

  test('string "1" and int 1 are different series', () {
    final c = Meter.of('m').counter('c');
    c.add(1, {'k': 1});
    c.add(1, {'k': '1'});
    expect(only('c').points, hasLength(2));
  });

  test('int sums stay int, double makes them double', () {
    final c = Meter.of('m').upDownCounter('u');
    c.add(2);
    expect(only('u').points.single.value, isA<int>());
    c.add(0.5);
    expect(only('u').points.single.value, 2.5);
  });

  test('cumulative keeps totals; nothing is exported when idle', () {
    final c = Meter.of('m').counter('c');
    c.add(1);
    expect(only('c').points.single.value, 1);
    expect(MeterRegistry.collect(), isEmpty, reason: 'no change -> no export');
    c.add(1);
    final p = only('c').points.single;
    expect(p.value, 2);
    expect(p.startMicros, isNotNull);
  });

  test('delta resets each interval and exports only changed series', () {
    MeterRegistry.temporality = MetricTemporality.delta;
    final c = Meter.of('m').counter('c');
    c.add(1, {'k': 'a'});
    c.add(1, {'k': 'b'});
    expect(only('c').points, hasLength(2));
    c.add(4, {'k': 'a'});
    final p = only('c').points.single;
    expect(p.value, 4);
    expect(p.startMicros, isNotNull);
  });

  test('histogram buckets use inclusive upper bounds', () {
    final h = Meter.of('m').histogram('h', boundaries: [10, 20]);
    for (final v in [0, 10, 10.5, 20, 21, 1000]) {
      h.record(v);
    }
    final p = only('h').points.single;
    expect(p.bucketCounts, [2, 2, 2]);
    expect(p.count, 6);
    expect(p.sum, 1061.5);
    expect(p.min, 0);
    expect(p.max, 1000);
  });

  test('gauge keeps the last value', () {
    final g = Meter.of('m').gauge('g');
    g.record(1);
    g.record(7);
    expect(only('g').points.single.value, 7);
  });

  test('observable gauge is read at collection time', () {
    var calls = 0;
    Meter.of('m').observableGauge('mem', (r) {
      calls++;
      r.observe(calls * 10, {'kind': 'heap'});
      r.observe(99, {'kind': 'heap'}); // last value wins
    });
    expect(only('mem').points.single.value, 99);
    expect(calls, 1);
  });

  test('a throwing observable callback does not break collection', () {
    Meter.of('m').observableGauge('bad', (_) => throw StateError('x'));
    Meter.of('m').counter('ok').add(1);
    expect(MeterRegistry.collect().map((m) => m.name), ['ok']);
  });

  test('cardinality limit routes extra series to overflow', () {
    MeterRegistry.cardinalityLimit = 5;
    final c = Meter.of('m').counter('c');
    for (var i = 0; i < 20; i++) {
      c.add(1, {'user': '$i'});
    }
    final points = only('c').points;
    expect(points, hasLength(5));
    final overflow =
        points.singleWhere((p) => p.attributes['otel.metric.overflow'] == true);
    expect(overflow.value, 16);
  });

  test('recording before the SDK is enabled is a no-op', () {
    MeterRegistry.enabled = false;
    final c = Meter.of('m').counter('c')..add(1);
    MeterRegistry.enabled = true;
    expect(MeterRegistry.collect(), isEmpty);
    c.add(2);
    expect(only('c').points.single.value, 2);
  });
}

