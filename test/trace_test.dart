import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otel_flutter/src/core/context.dart';
import 'package:otel_flutter/src/core/ids.dart';
import 'package:otel_flutter/src/core/pipeline.dart';
import 'package:otel_flutter/src/trace/propagation.dart';
import 'package:otel_flutter/src/trace/sampler.dart';
import 'package:otel_flutter/src/trace/span.dart';
import 'package:otel_flutter/src/trace/tracer.dart';

import 'support/fakes.dart';

void main() {
  late FakePipeline pipeline;
  final tracer = Tracer.of('test');

  setUp(() => Pipeline.current = pipeline = FakePipeline());
  tearDown(() => Pipeline.current = null);

  group('Tracer', () {
    test('trace() parents nested spans through the zone', () {
      tracer.trace('outer', (outer) {
        tracer.trace('inner', (inner) {
          expect(inner.spanContext.traceId, outer.spanContext.traceId);
        });
      });
      final inner = pipeline.ended[0];
      final outer = pipeline.ended[1];
      expect(inner.name, 'inner');
      expect(inner.parentSpanId, outer.spanContext.spanId);
      expect(outer.parentSpanId, isNull);
    });

    test('traceAsync keeps the parent across await and timers', () async {
      await tracer.traceAsync('outer', (outer) async {
        await Future<void>.delayed(Duration.zero);
        await Future<void>(() async {
          tracer.startSpan('in-timer').end();
        });
      });
      final child = pipeline.ended.firstWhere((s) => s.name == 'in-timer');
      final outer = pipeline.ended.firstWhere((s) => s.name == 'outer');
      expect(child.parentSpanId, outer.spanContext.spanId);
    });

    test('exceptions are recorded, mark error and are rethrown', () async {
      expect(
        () => tracer.trace('boom', (_) => throw StateError('bad')),
        throwsStateError,
      );
      await expectLater(
        tracer.traceAsync('boom2', (_) async => throw ArgumentError('x')),
        throwsArgumentError,
      );
      for (final s in pipeline.ended) {
        expect(s.statusCode, SpanStatusCode.error);
        expect(s.events.single.name, 'exception');
        expect(s.events.single.attributes.values['exception.type'],
            isNotEmpty);
        expect(s.endMicros, isNotNull);
      }
    });

    test('end() twice exports once', () {
      tracer.startSpan('x')
        ..end()
        ..end();
      expect(pipeline.ended, hasLength(1));
    });

    test('ended spans ignore further changes', () {
      final span = tracer.startSpan('x')..end();
      span
        ..setAttribute('late', 1)
        ..addEvent('late')
        ..updateName('renamed');
      final rec = pipeline.ended.single;
      expect(rec.attributes.values, isNot(contains('late')));
      expect(rec.events, isEmpty);
      expect(rec.name, 'x');
    });

    test('status rules: Ok is final, Unset ignored', () {
      final s = tracer.startSpan('x') as RecordingSpan;
      s.setStatus(SpanStatusCode.unset);
      expect(s.statusCode, SpanStatusCode.unset);
      s.setStatus(SpanStatusCode.error, 'e');
      s.setStatus(SpanStatusCode.ok, 'ignored description');
      expect(s.statusCode, SpanStatusCode.ok);
      expect(s.statusDescription, isNull);
      s.setStatus(SpanStatusCode.error, 'after ok');
      expect(s.statusCode, SpanStatusCode.ok);
    });

    test('caller-owned lists cannot change recorded attributes', () {
      final tags = ['a'];
      final s = tracer.startSpan('x', attributes: {'tags': tags})
          as RecordingSpan;
      tags.add('b');
      expect(s.attributes.values['tags'], ['a']);
      // A const list works too (no UnsupportedError on later appends).
      final c = tracer.startSpan('y', attributes: {'tags': const ['z']});
      c.addEvent('ok');
    });

    test('attribute limit drops extras and counts them', () {
      Pipeline.current = FakePipeline(
        limits: const TelemetryLimits(maxAttributes: 2, maxAttributeLength: 3),
      );
      final s = tracer.startSpan('x',
          attributes: {'a': 'abcdef', 'b': 2, 'c': 3}) as RecordingSpan;
      expect(s.attributes.values, {'a': 'abc', 'b': 2});
      expect(s.attributes.dropped, 1);
      s.setAttribute('a', 'xyz');
      expect(s.attributes.values['a'], 'xyz', reason: 'overwrite allowed');
    });

    test('common attributes are applied before span attributes', () {
      pipeline.common = {'session.id': 's1', 'k': 'common'};
      final s = tracer.startSpan('x', attributes: {'k': 'own'})
          as RecordingSpan;
      expect(s.attributes.values, {'session.id': 's1', 'k': 'own'});
    });

    test('without an SDK spans are no-ops that still propagate', () {
      Pipeline.current = null;
      final remote = SpanContext.fromHex(
        traceId: '0af7651916cd43dd8448eb211c80319c',
        spanId: 'b7ad6b7169203331',
        isRemote: true,
      );
      final ctx = OtelContext.root.withSpan(NonRecordingSpan(remote));
      final span = tracer.startSpan('x', context: ctx);
      expect(span.isRecording, isFalse);
      expect(span.spanContext.traceIdHex, remote.traceIdHex);
      span.end();
      expect(tracer.startSpan('root').spanContext.isValid, isFalse);
    });

    test('a tracer obtained before init records after init', () {
      Pipeline.current = null;
      final early = Tracer.of('early');
      Pipeline.current = pipeline;
      early.startSpan('x').end();
      expect(pipeline.ended.single.scope.name, 'early');
    });

    test('unsampled spans are not recorded but get valid ids', () {
      Pipeline.current = pipeline = FakePipeline(ratio: 0);
      final s = tracer.startSpan('x');
      expect(s.isRecording, isFalse);
      expect(s.spanContext.isValid, isTrue);
      expect(s.spanContext.isSampled, isFalse);
      s.end();
      expect(pipeline.ended, isEmpty);
    });

    test('newRoot ignores the active span', () {
      tracer.trace('outer', (_) {
        tracer.startSpan('root', newRoot: true).end();
      });
      expect(pipeline.ended.first.parentSpanId, isNull);
    });
  });

  group('W3C propagation', () {
    const header = '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01';

    test('extract then inject round-trips', () {
      final ctx = W3CPropagator.extract(
        {'TraceParent': header, 'tracestate': 'a=1', 'baggage': 'user=jo%20e'},
        context: OtelContext.root,
      );
      final sc = ctx.span!.spanContext;
      expect(sc.isRemote, isTrue);
      expect(sc.isSampled, isTrue);
      expect(sc.traceState, 'a=1');
      expect(ctx.baggage, {'user': 'jo e'});

      final out = <String, String>{};
      W3CPropagator.inject(out, context: ctx);
      expect(out['traceparent'], header);
      expect(out['tracestate'], 'a=1');
      expect(out['baggage'], 'user=jo%20e');
    });

    test('child span headers carry the child span id', () {
      final parent = W3CPropagator.extract({'traceparent': header},
          context: OtelContext.root);
      final child = tracer.startSpan('c', context: parent);
      final out = <String, String>{};
      W3CPropagator.inject(out, context: parent.withSpan(child));
      expect(out['traceparent'],
          '00-0af7651916cd43dd8448eb211c80319c-${child.spanContext.spanIdHex}-01');
    });

    test('rejects malformed traceparent values', () {
      for (final bad in [
        '',
        'garbage',
        '00-0AF7651916CD43DD8448EB211C80319C-b7ad6b7169203331-01',
        '00-00000000000000000000000000000000-b7ad6b7169203331-01',
        '00-0af7651916cd43dd8448eb211c80319c-0000000000000000-01',
        'ff-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01',
        '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01-extra',
        '00_0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01',
      ]) {
        expect(W3CPropagator.parseTraceparent(bad), isNull, reason: bad);
      }
    });

    test('accepts a future version with extra fields', () {
      expect(
        W3CPropagator.parseTraceparent(
            '01-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01-future'),
        isNotNull,
      );
    });

    test('baggage ignores properties, bad keys and bad encoding', () {
      final ctx = W3CPropagator.extract(
        {'baggage': 'a=1;prop=x, b = 2 ,bad key=3,c=%zz,=4'},
        context: OtelContext.root,
      );
      expect(ctx.baggage, {'a': '1', 'b': '2'});
    });

    test('nothing is injected for an empty context', () {
      final out = <String, String>{};
      W3CPropagator.inject(out, context: OtelContext.root);
      expect(out, isEmpty);
    });
  });

  group('Sampler', () {
    test('ratio 0 and 1', () {
      final id = Ids.traceId();
      expect(Sampler(1).shouldSample(id), isTrue);
      expect(Sampler(0).shouldSample(id), isFalse);
    });

    test('children follow the parent decision', () {
      final id = Ids.traceId();
      expect(Sampler(0).shouldSample(id, parentSampled: true), isTrue);
      expect(Sampler(1).shouldSample(id, parentSampled: false), isFalse);
    });

    test('ratio is honoured statistically and deterministically', () {
      final sampler = Sampler(0.25);
      var kept = 0;
      for (var i = 0; i < 20000; i++) {
        final id = Ids.traceId();
        final decision = sampler.shouldSample(id);
        expect(sampler.shouldSample(Uint8List.fromList(id)), decision);
        if (decision) kept++;
      }
      expect(kept / 20000, closeTo(0.25, 0.02));
    });
  });

  group('Ids', () {
    test('hex round-trip and validation', () {
      final id = Ids.traceId();
      expect(Ids.fromHex(Ids.toHex(id), 16), id);
      expect(Ids.fromHex('xyz', 16), isNull);
      expect(Ids.isAllZero(Uint8List(8)), isTrue);
    });

    test('ids are unique and uuids are v4', () {
      final seen = <String>{};
      for (var i = 0; i < 10000; i++) {
        expect(seen.add(Ids.toHex(Ids.spanId())), isTrue);
      }
      expect(
        Ids.uuidV4(),
        matches(RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
      );
    });
  });

  test('OtelContext.run is visible in scheduled microtasks', () async {
    final span = tracer.startSpan('s');
    final completer = Completer<Span?>();
    OtelContext.current.withSpan(span).run(() {
      scheduleMicrotask(() => completer.complete(OtelContext.current.span));
    });
    expect(await completer.future, same(span));
    expect(OtelContext.current.span, isNull);
  });
}
