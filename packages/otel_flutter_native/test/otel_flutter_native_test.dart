// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:otel_flutter/otel_flutter.dart';
import 'package:otel_flutter/src/metrics/meter.dart';
import 'package:otel_flutter_native/otel_flutter_native.dart';

import '../../../test/support/proto_reader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('otel_flutter_native');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final requests = <http.Request>[];
  final t0 = DateTime(2026, 10, 12, 9);
  final previous = PreviousRunContext(
    sessionId: 'previous-session',
    screenName: '/checkout',
    time: t0,
  );

  void answer(Future<Object?> Function(MethodCall call) handler) =>
      messenger.setMockMethodCallHandler(channel, handler);

  setUp(() async {
    requests.clear();
    await Otel.init(OtelConfig(
      serviceName: 'test-app',
      endpoint: 'http://collector:4318',
      httpClient: MockClient((r) async {
        requests.add(r);
        return http.Response('', 200);
      }),
      compression: false,
      captureAppStart: false,
      captureErrors: false,
      captureFrames: false,
      captureStalls: false,
    ));
    // The current run is on another screen: it must not leak into reports.
    OtelNavigatorObserver().didPush(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/home'),
        builder: (_) => const SizedBox(),
      ),
      null,
    );
  });

  tearDown(() async {
    await Otel.shutdown();
    messenger.setMockMethodCallHandler(channel, null);
    MeterRegistry.reset();
  });

  List<Msg> items(String path) => [
        for (final r in requests.where((r) => r.url.path == path))
          for (final rs in Msg.parse(r.bodyBytes).messages(1))
            for (final scope in rs.messages(2)) ...scope.messages(2),
      ];
  Iterable<Msg> events(String name) =>
      items('/v1/logs').where((l) => l.has(12) && l.string(12) == name);

  /// `app.exits` points as `{reason: count}`.
  Map<Object?, int> exits() => {
        for (final m in items('/v1/metrics').where((m) => m.string(1) == 'app.exits'))
          for (final p in m.message(7).messages(1))
            p.attributes(7)['app.exit.reason']: p.sfixed64(6),
      };

  int millis(Msg log) => log.fixed64(1) ~/ 1000000;

  test('crash and ANR are reported with the previous session and screen',
      () async {
    answer((call) async => [
          {
            'reason': 'crash',
            'time': t0.millisecondsSinceEpoch + 1000,
            'description': 'crash',
            'type': 'java.lang.RuntimeException',
            'message': 'boom',
            'stack': 'java.lang.RuntimeException: boom\n\tat A.b(A.kt:1)',
          },
          {
            'reason': 'anr',
            'time': t0.millisecondsSinceEpoch + 2000,
            'description': 'Input dispatching timed out',
            'message': 'Input dispatching timed out',
            'stack': '"main" prio=5 tid=1 Sleeping',
          },
          {'reason': 'low_memory', 'time': t0.millisecondsSinceEpoch + 3000},
        ]);

    await OtelFlutterNative.report(previous);

    final crash = events('app.crash').single;
    expect(crash.varint(2), 21, reason: 'FATAL');
    expect(millis(crash), t0.millisecondsSinceEpoch + 1000);
    expect(Msg.anyValue(crash.message(5)), 'java.lang.RuntimeException');
    expect(crash.attributes(6), containsPair('session.id', 'previous-session'));
    expect(crash.attributes(6), containsPair('app.screen.name', '/checkout'));
    expect(crash.attributes(6), containsPair('exception.message', 'boom'));
    expect(crash.attributes(6)['exception.stacktrace'], contains('A.kt:1'));

    final anr = events('app.anr').single;
    expect(anr.varint(2), 21);
    expect(millis(anr), t0.millisecondsSinceEpoch + 2000);
    expect(anr.attributes(6), containsPair('session.id', 'previous-session'));
    expect(anr.attributes(6)['exception.stacktrace'], startsWith('"main"'));

    expect([...events('app.crash'), ...events('app.anr')], hasLength(2),
        reason: 'low_memory: metric only');
    expect(exits(), {'crash': 1, 'anr': 1, 'low_memory': 1});
  });

  test('without matching context, no session or screen is attributed',
      () async {
    answer((call) async => [
          // Before the saved context began: an earlier run.
          {'reason': 'native_crash', 'time': t0.millisecondsSinceEpoch - 1, 'type': 'SIGSEGV'},
        ]);
    await OtelFlutterNative.report(previous);
    await OtelFlutterNative.report(null); // nothing saved at all

    expect(Otel.sessionId, isNotNull);
    expect(events('app.crash'), hasLength(2));
    for (final crash in events('app.crash')) {
      expect(crash.attributes(6), isNot(contains('session.id')));
      expect(crash.attributes(6), isNot(contains('app.screen.name')));
      expect(crash.attributes(6), containsPair('exception.type', 'SIGSEGV'));
    }
  });

  test('app.exit.reason stays within the bounded set', () async {
    answer((call) async => [
          for (final reason in [...OtelFlutterNative.exitReasons, 'oem_magic', 7])
            {'reason': reason, 'time': t0.millisecondsSinceEpoch},
          'not a map',
        ]);
    await OtelFlutterNative.report(previous);

    expect(OtelFlutterNative.exitReasons.containsAll(exits().keys), isTrue);
    expect(exits()['other'], 3, reason: 'other, oem_magic and 7');
  });

  test('channel failures are silent no-ops', () async {
    answer((call) async => throw PlatformException(code: 'unavailable'));
    await expectLater(OtelFlutterNative.report(previous), completes);

    messenger.setMockMethodCallHandler(channel, null); // MissingPluginException
    await expectLater(OtelFlutterNative.report(previous), completes);

    answer((call) async => {'not': 'a list'});
    await expectLater(OtelFlutterNative.report(previous), completes);

    await Otel.flush();
    expect([...events('app.crash'), ...events('app.anr')], isEmpty);
    expect(exits(), isEmpty);
  });
}
