import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:otel_flutter/otel_flutter.dart';
import 'package:otel_flutter/src/core/clock.dart';
import 'package:otel_flutter/src/core/diagnostics.dart';
import 'package:otel_flutter/src/flutter/frames.dart';
import 'package:otel_flutter/src/flutter/screens.dart';
import 'package:otel_flutter/src/metrics/meter.dart';
import 'package:otel_flutter/src/sdk.dart';

import 'support/proto_reader.dart';

void main() {
  final requests = <http.Request>[];
  final client = MockClient((r) async {
    requests.add(r);
    return http.Response('', 200);
  });

  OtelConfig config({bool lifecycle = true}) => OtelConfig(
    serviceName: 'test-app',
    serviceVersion: '9.9.9',
    endpoint: 'http://collector:4318',
    httpClient: client,
    compression: false,
    captureAppStart: false,
    captureLifecycle: lifecycle,
  );

  /// Runs [body] with Otel initialized and always shuts it down inside the
  /// test, so no timers or handlers leak into the next test.
  void otelTest(String name, Future<void> Function(WidgetTester t) body) {
    testWidgets(name, (tester) async {
      requests.clear();
      await Otel.init(config());
      try {
        await body(tester);
      } finally {
        await Otel.shutdown();
        ScreenTracker.instance.reset();
        OtelSdk.globalAttributes.clear();
        MeterRegistry.reset();
        Diagnostics.reset();
        Clock.debugNowMicros = null;
      }
    });
  }

  Iterable<Msg> resourceItems(String path) => requests
      .where((r) => r.url.path == path)
      .expand((r) => Msg.parse(r.bodyBytes).messages(1));

  List<Msg> items(String path) => [
    for (final rs in resourceItems(path))
      for (final scope in rs.messages(2)) ...scope.messages(2),
  ];

  List<Msg> spans() => items('/v1/traces');
  List<Msg> logs() => items('/v1/logs');
  Map<String, Msg> metrics() => {
    for (final m in items('/v1/metrics')) m.string(1): m,
  };
  Msg spanNamed(String name) => spans().lastWhere((s) => s.string(5) == name);
  Iterable<Msg> eventsNamed(String name) =>
      logs().where((l) => l.has(12) && l.string(12) == name);
  num sumOf(Msg metric) =>
      metric.message(7).messages(1).fold<num>(0, (a, p) => a + p.sfixed64(6));

  otelTest('spans, logs and metrics reach the collector', (tester) async {
    final span = Otel.tracer('checkout').startSpan('pay');
    OtelContext.current
        .withSpan(span)
        .run(() => Otel.logger('checkout').info('paid', attributes: {'n': 1}));
    span.end();
    Otel.meter('checkout').counter('orders').add(2);
    await Otel.flush();

    final resource = resourceItems('/v1/traces').first.message(1).attributes(1);
    expect(resource['service.name'], 'test-app');
    expect(resource['service.version'], '9.9.9');
    expect(resource['telemetry.sdk.name'], 'otel_flutter');
    expect(resource['service.instance.id'], isA<String>());

    final pay = spanNamed('pay');
    expect(pay.attributes(9)['session.id'], Otel.sessionId);

    final paid = logs().singleWhere(
      (l) => l.has(5) && Msg.anyValue(l.message(5)) == 'paid',
    );
    expect(paid.bytes(9), pay.bytes(1), reason: 'log linked to trace');
    expect(paid.attributes(6)['n'], 1);

    expect(sumOf(metrics()['orders']!), 2);
    expect(eventsNamed('session.start'), isNotEmpty);
  });

  otelTest('errors are reported and previous handlers still run', (
    tester,
  ) async {
    await Otel.shutdown();
    var previousPlatformCalls = 0;
    final originalPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (e, s) {
      previousPlatformCalls++;
      return true;
    };
    await Otel.init(config());

    FlutterError.reportError(
      FlutterErrorDetails(
        exception: StateError('build failed'),
        stack: StackTrace.current,
        library: 'widgets library',
      ),
    );
    expect(
      tester.takeException(),
      isStateError,
      reason: 'the test framework handler (previous) still ran',
    );

    final handled = PlatformDispatcher.instance.onError!(
      ArgumentError('async boom'),
      StackTrace.current,
    );
    expect(handled, isTrue, reason: 'previous handler result is kept');
    expect(previousPlatformCalls, 1);

    Otel.recordError(const FormatException('manual'), null);
    await Otel.flush();

    final errorLogs = logs().where(
      (l) => l.attributes(6).containsKey('exception.type'),
    );
    final bySource = {
      for (final l in errorLogs) l.attributes(6)['app.error.source']: l,
    };
    expect(
      bySource.keys,
      containsAll(['flutter_framework', 'uncaught', 'manual']),
    );
    expect(bySource['flutter_framework']!.varint(2), 17, reason: 'ERROR');
    expect(bySource['uncaught']!.varint(2), 21, reason: 'FATAL');
    expect(
      bySource['flutter_framework']!.attributes(6)['exception.stacktrace'],
      isNotEmpty,
    );
    expect(sumOf(metrics()['app.errors']!), 3);

    await Otel.shutdown();
    expect(PlatformDispatcher.instance.onError, isNotNull);
    PlatformDispatcher.instance.onError = originalPlatform;
    await Otel.init(config());
  });

  otelTest('navigation creates screen spans and tags telemetry', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [OtelNavigatorObserver()],
        routes: {
          '/': (_) => const Text('home'),
          '/details': (_) => const Text('details'),
        },
      ),
    );
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.pushNamed('/details');
    await tester.pumpAndSettle();
    expect(Otel.currentScreen, '/details');

    Otel.tracer('t').startSpan('on-details').end();

    showDialog<void>(context: nav.context, builder: (_) => const Text('d'));
    await tester.pumpAndSettle();
    expect(Otel.currentScreen, '/details', reason: 'dialogs are not screens');
    nav.pop();
    await tester.pumpAndSettle();

    nav.pop();
    await tester.pumpAndSettle();
    expect(Otel.currentScreen, '/');
    await Otel.flush();

    final names = spans().map((s) => s.string(5)).toList();
    expect(names, containsAllInOrder(['screen /', 'screen /details']));
    final details = spanNamed('screen /details');
    expect(details.attributes(9)['app.screen.name'], '/details');
    expect(details.fixed64(8), greaterThan(details.fixed64(7)));
    expect(
      spanNamed('on-details').attributes(9)['app.screen.name'],
      '/details',
    );
  });

  otelTest('background flushes immediately and long absence rotates session', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [OtelNavigatorObserver()],
        routes: {'/': (_) => const Text('home')},
      ),
    );
    Otel.tracer('t').startSpan('before-pause').end();
    expect(spans(), isEmpty, reason: 'still waiting for the batch delay');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(Otel.debugSdk!.isInBackground, isTrue);
    expect(spans().map((s) => s.string(5)), contains('before-pause'));
    expect(eventsNamed('device.app.lifecycle'), isNotEmpty);

    final firstSession = Otel.sessionId;
    var now = Clock.nowMicros();
    Clock.debugNowMicros = () => now;
    now += const Duration(minutes: 31).inMicroseconds;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(Otel.debugSdk!.isInBackground, isFalse);
    expect(Otel.sessionId, isNot(firstSession));

    await Otel.flush();
    final end = eventsNamed('session.end').single;
    expect(end.attributes(6)['session.id'], firstSession);
    final start = eventsNamed('session.start').last;
    expect(start.attributes(6)['session.previous_id'], firstSession);
    // Screen spans measure foreground time: split at each background.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(spans().where((s) => s.string(5) == 'screen /'), hasLength(2));
  });

  otelTest('frame timings become slow/frozen frame metrics', (tester) async {
    FrameTiming frame(int buildMs, int rasterMs, {int delayMs = 0}) {
      const t0 = 1000000;
      final buildStart = t0 + delayMs * 1000;
      final buildEnd = buildStart + buildMs * 1000;
      return FrameTiming(
        vsyncStart: t0,
        buildStart: buildStart,
        buildFinish: buildEnd,
        rasterStart: buildEnd,
        rasterFinish: buildEnd + rasterMs * 1000,
        rasterFinishWallTime: buildEnd + rasterMs * 1000,
      );
    }

    FrameMonitor().onTimings([
      frame(4, 5),
      frame(25, 3), // slow build
      frame(2, 800), // frozen raster
      // vsyncOverhead is ignored (constant ~1 frame on iOS, not real work).
      frame(3, 3, delayMs: 750),
    ]);
    await Otel.flush();
    final m = metrics();
    expect(sumOf(m['app.frames']!), 4);
    expect(sumOf(m['app.frames.slow']!), 2);
    expect(sumOf(m['app.frames.frozen']!), 1);
    final histogram = m['app.frame.duration']!.message(9).messages(1).single;
    expect(histogram.fixed64(4), 4);
    expect(histogram.float64(12), 800);
    expect(eventsNamed('app.jank'), hasLength(1));
  });

  otelTest('a blocked UI thread is reported as a stall', (tester) async {
    var now = 0;
    final detector = StallDetector(nowMicros: () => now)..start();
    // Normal ticks: on time.
    for (var i = 0; i < 5; i++) {
      now += StallDetector.tickMicros;
      await tester.pump(const Duration(microseconds: StallDetector.tickMicros));
    }
    // The event loop was blocked: the next tick runs 800 ms late.
    now += StallDetector.tickMicros + 800000;
    await tester.pump(const Duration(microseconds: StallDetector.tickMicros));
    // Background stops the timer entirely.
    detector.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(detector.isRunning, isFalse);
    await Otel.flush();
    expect(sumOf(metrics()['app.ui.stalls']!), 1);
    final jank = eventsNamed('app.jank').single.attributes(6);
    expect(jank['flutter.jank.source'], 'ui_stall');
    expect(jank['app.jank.period'], closeTo(0.8, 0.001));
  });

  otelTest('OtelHttpClient traces requests and propagates context', (
    tester,
  ) async {
    final seenHeaders = <Map<String, String>>[];
    final api = OtelHttpClient(
      inner: MockClient((r) async {
        seenHeaders.add(r.headers);
        if (r.url.path == '/fail') throw http.ClientException('reset');
        return http.Response('{}', r.url.path == '/missing' ? 404 : 200);
      }),
    );
    await api.get(
      Uri.parse('https://user:pw@api.example.com/items?token=secret#x'),
    );
    await api.get(Uri.parse('https://api.example.com/missing'));
    await expectLater(
      api.get(Uri.parse('https://api.example.com/fail')),
      throwsA(isA<http.ClientException>()),
    );
    await Otel.flush();

    final http0 = spans().where((s) => s.string(5) == 'GET').toList();
    expect(http0, hasLength(3));
    final ok = http0[0];
    expect(ok.varint(6), 3, reason: 'CLIENT');
    final attrs = ok.attributes(9);
    expect(attrs['url.full'], 'https://api.example.com/items');
    expect(attrs['http.response.status_code'], 200);
    expect(attrs['server.port'], 443);
    final traceparent = seenHeaders[0]['traceparent']!;
    expect(traceparent.split('-')[2], _hex(ok.bytes(2)));

    expect(http0[1].message(15).varint(3), 2, reason: '404 is an error');
    expect(http0[1].attributes(9)['error.type'], '404');
    expect(http0[2].attributes(9)['error.type'], 'ClientException');
    expect(http0[2].messages(11).single.string(2), 'exception');

    final duration = metrics()['http.client.request.duration']!;
    expect(duration.string(3), 's');
  });

  otelTest('global attributes and user id are added everywhere', (
    tester,
  ) async {
    Otel.setUser('u-42');
    Otel.setGlobalAttribute('tenant', 'acme');
    Otel.tracer('t').startSpan('s').end();
    Otel.logger('t').info('l');
    Otel.logger(
      't',
    ).info('earlier run', attributes: {'session.id': null, 'tenant': null});
    Otel.setUser(null);
    Otel.tracer('t').startSpan('after-logout').end();
    await Otel.flush();
    expect(spanNamed('s').attributes(9), containsPair('user.id', 'u-42'));
    expect(spanNamed('s').attributes(9), containsPair('tenant', 'acme'));
    expect(
      spanNamed('after-logout').attributes(9).containsKey('user.id'),
      isFalse,
    );
    Msg log(String body) => logs().singleWhere(
      (l) => l.has(5) && Msg.anyValue(l.message(5)) == body,
    );
    expect(log('l').attributes(6), containsPair('user.id', 'u-42'));
    expect(
      log('earlier run').attributes(6).keys,
      allOf(
        contains('user.id'),
        isNot(contains('session.id')),
        isNot(contains('tenant')),
      ),
      reason: 'an explicit null removes a common attribute',
    );
  });

  testWidgets('everything is a safe no-op before init', (tester) async {
    expect(Otel.isInitialized, isFalse);
    Otel.tracer('x').trace('y', (span) => span.setAttribute('a', 1));
    Otel.logger('x').error('nothing');
    Otel.meter('x').counter('c').add(1);
    Otel.recordError(StateError('x'), null);
    await Otel.flush();
    expect(Otel.activeSpan.isRecording, isFalse);
  });

  testWidgets('invalid endpoint fails fast at init', (tester) async {
    await expectLater(
      Otel.init(const OtelConfig(serviceName: 'x', endpoint: 'not a url')),
      throwsArgumentError,
    );
    expect(Otel.isInitialized, isFalse);
  });
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
