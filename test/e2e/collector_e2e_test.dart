// Sends real telemetry to a running OTLP/HTTP endpoint.
//
//   OTEL_E2E_ENDPOINT=http://localhost:4318 flutter test test/e2e
//
// Skipped when OTEL_E2E_ENDPOINT is not set.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otel_flutter/otel_flutter.dart';
import 'package:otel_flutter/src/core/diagnostics.dart';
import 'package:otel_flutter/src/sdk.dart';

void main() {
  final endpoint = Platform.environment['OTEL_E2E_ENDPOINT'];

  test('collector accepts traces, metrics and logs', () async {
    Diagnostics.printer = (m) => stdout.writeln(m);
    final sdk = await OtelSdk.start(OtelConfig(
      serviceName: 'otel-flutter-e2e',
      serviceVersion: '1.0.0',
      environment: 'test',
      endpoint: endpoint,
      debug: true,
    ));

    final tracer = Tracer.of('e2e', '1.0');
    await tracer.traceAsync('e2e-root', (root) async {
      root
        ..setAttributes({
          'str': 'text',
          'utf8': 'Привет 👋',
          'int': -42,
          'big': 9007199254740993,
          'double': 3.25,
          'bool': false,
          'zero': 0,
          'list.str': ['a', 'b'],
          'list.int': [1, 2, 3],
        })
        ..addEvent('checkpoint', attributes: {'step': 1});
      tracer.startSpan('e2e-child', kind: SpanKind.client).end();
      Logger.of('e2e').warn(
        'e2e-log',
        attributes: {'utf8': 'Привет 👋'},
        error: StateError('e2e failure'),
        stackTrace: StackTrace.current,
      );
    });
    tracer.startSpan('e2e-error')
      ..setStatus(SpanStatusCode.error, 'boom')
      ..end();

    final meter = Meter.of('e2e');
    meter.counter('e2e.counter', unit: '{item}').add(5, {'kind': 'a'});
    meter.histogram('e2e.histogram', unit: 'ms').record(42);
    meter.gauge('e2e.gauge').record(-3);
    meter.upDownCounter('e2e.updown').add(-2.5);

    // >64 KB request: exercises gzip on a background isolate.
    for (var i = 0; i < 2000; i++) {
      tracer.startSpan('bulk', attributes: {'i': i, 'pad': 'x' * 200}).end();
    }

    await sdk.flush();
    expect(sdk.exporter.droppedRequests, 0);
    await sdk.shutdown();
  }, skip: endpoint == null ? 'set OTEL_E2E_ENDPOINT to run' : false);

  test('offline data survives a restart and is delivered later', () async {
    final dir = Directory.systemTemp.createTempSync('otel_e2e_offline');
    addTearDown(() => dir.deleteSync(recursive: true));
    Diagnostics.printer = (m) => stdout.writeln(m);

    // 1. "Offline": nothing listens on this port.
    final offline = await OtelSdk.start(OtelConfig(
      serviceName: 'otel-flutter-e2e',
      endpoint: 'http://127.0.0.1:9',
      offlineStorageDirectory: dir.path,
      debug: true,
    ));
    Tracer.of('e2e').startSpan('offline-span').end();
    await offline.flush();
    await offline.shutdown();
    final queued = Directory('${dir.path}/otel_flutter_queue')
        .listSync()
        .whereType<File>()
        .toList();
    expect(queued, isNotEmpty, reason: 'request kept on disk');

    // 2. "Next launch, back online": the backlog is sent at start.
    final online = await OtelSdk.start(OtelConfig(
      serviceName: 'otel-flutter-e2e',
      endpoint: endpoint,
      offlineStorageDirectory: dir.path,
      debug: true,
    ));
    for (var i = 0; i < 50; i++) {
      final left = Directory('${dir.path}/otel_flutter_queue')
          .listSync()
          .whereType<File>()
          .length;
      if (left == 0) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(
      Directory('${dir.path}/otel_flutter_queue').listSync(),
      isEmpty,
      reason: 'backlog delivered and deleted',
    );
    await online.shutdown();
  }, skip: endpoint == null ? 'set OTEL_E2E_ENDPOINT to run' : false);
}
