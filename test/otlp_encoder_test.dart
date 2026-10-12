import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otel_flutter/src/core/attributes.dart';
import 'package:otel_flutter/src/core/clock.dart';
import 'package:otel_flutter/src/core/context.dart';
import 'package:otel_flutter/src/core/pipeline.dart';
import 'package:otel_flutter/src/core/scope.dart';
import 'package:otel_flutter/src/export/otlp_encoder.dart';
import 'package:otel_flutter/src/logs/log_record.dart';
import 'package:otel_flutter/src/logs/logger.dart';
import 'package:otel_flutter/src/metrics/meter.dart';
import 'package:otel_flutter/src/trace/propagation.dart';
import 'package:otel_flutter/src/trace/span.dart';
import 'package:otel_flutter/src/trace/tracer.dart';

import 'support/fakes.dart';
import 'support/proto_reader.dart';

void main() {
  late FakePipeline pipeline;
  final resource = OtlpEncoder.encodeResource({
    'service.name': 'shop',
    'service.version': '1.2.3',
  });

  setUp(() {
    pipeline = FakePipeline();
    Pipeline.current = pipeline;
    MeterRegistry.reset();
    var now = 1760000000000000;
    Clock.debugNowMicros = () => now += 1000;
  });

  tearDown(() {
    Pipeline.current = null;
    Clock.debugNowMicros = null;
    MeterRegistry.reset();
  });

  test('spans: every OTLP field is encoded', () {
    final tracer = Tracer.of('checkout', '2.0');
    final remote = W3CPropagator.parseTraceparent(
        '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01',
        'vendor=abc')!;
    final linked = Tracer.of('other').startSpan('linked');
    final span = tracer.startSpan(
      'pay',
      kind: SpanKind.client,
      context: OtelContext.root.withSpan(NonRecordingSpan(remote)),
      attributes: {
        's': 'text',
        'b': false,
        'i': 0,
        'neg': -7,
        'd': 0.5,
        'ls': ['a', 'b'],
        'li': [1, 2],
        'empty': '',
      },
      links: [linked.spanContext],
    );
    span
      ..addEvent('step', attributes: {'n': 1})
      ..setStatus(SpanStatusCode.error, 'card declined')
      ..end();

    final req = Msg.parse(OtlpEncoder.encodeSpans(resource, pipeline.ended));
    final rs = req.messages(1).single;
    expect(rs.message(1).attributes(1),
        {'service.name': 'shop', 'service.version': '1.2.3'});
    final ss = rs.messages(2).single;
    expect(ss.message(1).string(1), 'checkout');
    expect(ss.message(1).string(2), '2.0');

    final s = ss.messages(2).single;
    expect(s.bytes(1), remote.traceId, reason: 'child keeps the trace id');
    expect(s.bytes(4), remote.spanId, reason: 'parent span id');
    expect(s.bytes(2), span.spanContext.spanId);
    expect(s.string(3), 'vendor=abc');
    expect(s.string(5), 'pay');
    expect(s.varint(6), 3, reason: 'SPAN_KIND_CLIENT');
    expect(s.fixed64(8) - s.fixed64(7), greaterThan(0));
    expect(s.attributes(9), {
      's': 'text',
      'b': false,
      'i': 0,
      'neg': -7,
      'd': 0.5,
      'ls': ['a', 'b'],
      'li': [1, 2],
      'empty': '',
    });
    final event = s.messages(11).single;
    expect(event.string(2), 'step');
    expect(event.attributes(3), {'n': 1});
    final link = s.messages(13).single;
    expect(link.bytes(2), linked.spanContext.spanId);
    final status = s.message(15);
    expect(status.string(2), 'card declined');
    expect(status.varint(3), 2, reason: 'STATUS_CODE_ERROR');
    // sampled + has_is_remote + is_remote (parent was remote)
    expect(s.fixed32(16), 0x01 | 0x100 | 0x200);
  });

  test('spans are grouped by instrumentation scope', () {
    Tracer.of('a').startSpan('1').end();
    Tracer.of('b').startSpan('2').end();
    Tracer.of('a').startSpan('3').end();
    final rs = Msg.parse(OtlpEncoder.encodeSpans(resource, pipeline.ended))
        .messages(1)
        .single;
    final scopes = rs.messages(2);
    expect(scopes.map((s) => s.message(1).string(1)), ['a', 'b']);
    expect(scopes.first.messages(2).map((s) => s.string(5)), ['1', '3']);
  });

  test('metrics: sum, gauge and histogram', () {
    MeterRegistry.enabled = true;
    final meter = Meter.of('cart');
    meter.counter('orders', unit: '{order}').add(2, {'method': 'card'});
    meter.counter('orders').add(3, {'method': 'card'});
    meter.upDownCounter('items').add(-1.5);
    meter.gauge('temp').record(21);
    meter
        .histogram('latency', unit: 'ms', boundaries: [10, 100])
        .record(50, {'route': '/a'});

    final req = Msg.parse(
        OtlpEncoder.encodeMetrics(resource, MeterRegistry.collect()));
    final metrics = req.messages(1).single.messages(2).single.messages(2);
    final byName = {for (final m in metrics) m.string(1): m};

    final orders = byName['orders']!;
    expect(orders.string(3), '{order}');
    final sum = orders.message(7);
    expect(sum.varint(2), 2, reason: 'CUMULATIVE');
    expect(sum.boolean(3), isTrue);
    final point = sum.messages(1).single;
    expect(point.sfixed64(6), 5);
    expect(point.attributes(7), {'method': 'card'});
    expect(point.has(2), isTrue, reason: 'start time');

    final items = byName['items']!.message(7);
    expect(items.has(3), isTrue);
    expect(items.boolean(3), isFalse);
    expect(items.messages(1).single.float64(4), -1.5);

    expect(byName['temp']!.message(5).messages(1).single.sfixed64(6), 21);

    final h = byName['latency']!.message(9).messages(1).single;
    expect(h.fixed64(4), 1);
    expect(h.float64(5), 50);
    expect(h.packedFixed64(6), [0, 1, 0]);
    expect(h.packedDouble(7), [10, 100]);
    expect(h.float64(11), 50);
    expect(h.float64(12), 50);
    expect(h.attributes(9), {'route': '/a'});
  });

  test('logs: body, severity, trace correlation and event name', () {
    final tracer = Tracer.of('t');
    final span = tracer.startSpan('op');
    OtelContext.current.withSpan(span).run(() {
      Logger.of('app').emit(
        severity: Severity.warn,
        body: {'msg': 'hi', 'n': 2},
        attributes: {'k': 'v'},
        eventName: 'app.thing',
      );
    });
    span.end();
    final req =
        Msg.parse(OtlpEncoder.encodeLogs(resource, pipeline.logs));
    final log = req.messages(1).single.messages(2).single.messages(2).single;
    expect(log.varint(2), 13);
    expect(log.string(3), 'WARN');
    expect(Msg.anyValue(log.message(5)), {'msg': 'hi', 'n': 2});
    expect(log.attributes(6), {'k': 'v'});
    expect(log.bytes(9), span.spanContext.traceId);
    expect(log.bytes(10), span.spanContext.spanId);
    expect(log.fixed32(8), 1);
    expect(log.string(12), 'app.thing');
    expect(log.fixed64(1), greaterThan(0));
  });

  test('dropped counts are reported', () {
    Pipeline.current = FakePipeline(
        limits: const TelemetryLimits(maxAttributes: 1, maxEvents: 1));
    final span = Tracer.of('x').startSpan('y', attributes: {'a': 1, 'b': 2})
      ..addEvent('e1')
      ..addEvent('e2')
      ..end();
    final rec = span as RecordingSpan;
    final s = Msg.parse(OtlpEncoder.encodeSpans(resource, [rec]))
        .messages(1)
        .single
        .messages(2)
        .single
        .messages(2)
        .single;
    expect(s.varint(10), 1);
    expect(s.varint(12), 1);
  });

  test('a large batch encodes and decodes intact', () {
    for (var i = 0; i < 2000; i++) {
      Tracer.of('bulk').startSpan('span $i', attributes: {'i': i}).end();
    }
    final bytes = OtlpEncoder.encodeSpans(resource, pipeline.ended);
    final spans = Msg.parse(bytes)
        .messages(1)
        .single
        .messages(2)
        .single
        .messages(2);
    expect(spans, hasLength(2000));
    expect(spans.last.attributes(9), {'i': 1999});
  });

  test('unsupported attribute values become strings', () {
    final map = AttributeMap(10, null)
      ..set('uri', Uri.parse('https://x.y'))
      ..set('enum', SpanKind.client)
      ..set('null', null);
    expect(map.values, {'uri': 'https://x.y', 'enum': 'client'});
  });

  test('resource bytes are a valid Resource message', () {
    final r = Msg.parse(Uint8List.fromList(resource));
    expect(r.attributes(1)['service.name'], 'shop');
  });

  test('scope cache returns identical objects', () {
    expect(identical(InstrumentationScope.of('a', '1'),
        InstrumentationScope.of('a', '1')), isTrue);
  });
}
