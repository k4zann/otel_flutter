import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:otel_flutter/otel_flutter.dart';
import 'package:otel_flutter/src/core/clock.dart';
import 'package:otel_flutter/src/core/crash_context.dart';
import 'package:otel_flutter/src/core/diagnostics.dart';
import 'package:otel_flutter/src/flutter/screens.dart';
import 'package:otel_flutter/src/metrics/meter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final client = MockClient((_) async => http.Response('', 200));

  OtelConfig config({bool captureNativeCrashes = true, String? dir}) =>
      OtelConfig(
        serviceName: 'test-app',
        endpoint: 'http://collector:4318',
        httpClient: client,
        offlineStorageDirectory: dir,
        captureAppStart: false,
        captureErrors: false,
        captureFrames: false,
        captureStalls: false,
        captureNativeCrashes: captureNativeCrashes,
      );

  tearDown(() {
    Otel.debugResetNativeCrashReporter();
    ScreenTracker.instance.reset();
    MeterRegistry.reset();
    Diagnostics.reset();
    Clock.debugNowMicros = null;
  });

  group('reporter hook', () {
    testWidgets('a registered reporter runs after init unless disabled',
        (tester) async {
      var calls = 0;
      Otel.registerNativeCrashReporter((_) async => calls++);

      await Otel.init(config());
      await tester.pump();
      expect(calls, 1);
      await Otel.shutdown();

      await Otel.init(config(captureNativeCrashes: false));
      await tester.pump();
      expect(calls, 1, reason: 'disabled in config');
      await Otel.shutdown();
    });

    testWidgets('a failing reporter never throws into the app',
        (tester) async {
      Otel.registerNativeCrashReporter(
          (_) => throw StateError('channel gone'));
      await Otel.init(config());
      await tester.pump();
      expect(Otel.isInitialized, isTrue);
      expect(tester.takeException(), isNull);
      await Otel.shutdown();
    });
  });

  group('crash context', () {
    late Directory dir;
    late File current;
    late File previous;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('otel_crash_context');
      current = File('${dir.path}/otel_flutter_context.json');
      previous = File('${dir.path}/otel_flutter_context.json.prev');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    void navigateTo(String name) => OtelNavigatorObserver().didPush(
          MaterialPageRoute<void>(
            settings: RouteSettings(name: name),
            builder: (_) => const SizedBox(),
          ),
          null,
        );

    Map<String, Object?> read(File f) =>
        jsonDecode(f.readAsStringSync()) as Map<String, Object?>;

    test('writes at most once per second, ending with the latest state', () {
      fakeAsync((async) {
        Clock.debugNowMicros = () => async.elapsed.inMicroseconds;
        final written = <Object?>[];
        final writer =
            CrashContextWriter((json) async => written.add(jsonDecode(json)));

        writer.save('s1', '/');
        async.flushMicrotasks();
        expect(written, [
          {'session.id': 's1', 'app.screen.name': '/', 'time': 0},
        ]);

        async.elapse(const Duration(milliseconds: 200));
        writer
          ..save('s1', '/a')
          ..save('s1', '/b');
        async.flushMicrotasks();
        expect(written, hasLength(1), reason: 'throttled');
        async.elapse(const Duration(milliseconds: 800));
        expect(written, hasLength(2), reason: 'one write for the burst');
        expect(written.last,
            {'session.id': 's1', 'app.screen.name': '/b', 'time': 200});

        async.elapse(const Duration(seconds: 5));
        writer.save('s2', null);
        async.flushMicrotasks();
        expect(written.last, {'session.id': 's2', 'time': 6000});

        writer.save('s2', '/c');
        writer.flush();
        async.flushMicrotasks();
        expect(written, hasLength(4), reason: 'flush skips the wait');
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('navigation saves session and screen to the storage directory',
        () async {
      Otel.registerNativeCrashReporter((_) async {});
      await Otel.init(config(dir: dir.path));
      final session = Otel.sessionId;
      navigateTo('/details');
      await Otel.shutdown(); // writes the throttled change

      final saved = read(current);
      expect(saved['session.id'], session);
      expect(saved['app.screen.name'], '/details');
      expect(saved['time'], closeTo(DateTime.now().millisecondsSinceEpoch, 5000));
    });

    test('nothing is saved without a reporter or when disabled', () async {
      await Otel.init(config(dir: dir.path));
      navigateTo('/details');
      await Otel.shutdown();
      expect(current.existsSync(), isFalse, reason: 'no plugin registered');

      Otel.registerNativeCrashReporter((_) async {});
      await Otel.init(config(dir: dir.path, captureNativeCrashes: false));
      navigateTo('/details');
      await Otel.shutdown();
      expect(current.existsSync(), isFalse, reason: 'disabled in config');
    });

    test('init rotates the previous run to .prev and hands it over',
        () async {
      final received = <PreviousRunContext?>[];
      Otel.registerNativeCrashReporter((p) async => received.add(p));

      await Otel.init(config(dir: dir.path));
      final firstSession = Otel.sessionId;
      navigateTo('/checkout');
      await Otel.shutdown();
      expect(received.single, isNull, reason: 'first run: nothing before');

      await Otel.init(config(dir: dir.path));
      final secondSession = Otel.sessionId;
      await Otel.shutdown();

      final previousRun = received.last!;
      expect(previousRun.sessionId, firstSession);
      expect(previousRun.screenName, '/checkout');
      expect(read(previous)['session.id'], firstSession);
      expect(read(current)['session.id'], secondSession);
    });

    test('a stale .prev from an older run is dropped', () async {
      previous.writeAsStringSync(
          '{"session.id":"old","time":${DateTime.now().millisecondsSinceEpoch}}');
      final received = <PreviousRunContext?>[];
      Otel.registerNativeCrashReporter((p) async => received.add(p));

      await Otel.init(config(dir: dir.path));
      await Otel.shutdown();

      expect(received.single, isNull);
      expect(previous.existsSync(), isFalse);
    });

    test('unreadable context is ignored', () {
      expect(CrashContextWriter.decode('not json'), isNull);
      expect(CrashContextWriter.decode('[1]'), isNull);
      expect(CrashContextWriter.decode('{"session.id":"s"}'), isNull);
      final ok = CrashContextWriter.decode('{"session.id":"s","time":5}')!;
      expect(ok.screenName, isNull);
      expect(ok.time.millisecondsSinceEpoch, 5);
    });
  });
}
