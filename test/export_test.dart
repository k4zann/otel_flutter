import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:otel_flutter/src/core/clock.dart';
import 'package:otel_flutter/src/export/batch_queue.dart';
import 'package:otel_flutter/src/export/offline_store.dart';
import 'package:otel_flutter/src/export/otlp_http_exporter.dart';
import 'package:otel_flutter/src/platform/platform_io.dart';

import 'support/fakes.dart';

void main() {
  group('BatchQueue', () {
    late List<List<int>> batches;
    late BatchQueue<int> queue;
    late Completer<void>? gate;

    BatchQueue<int> make({int maxQueue = 100, int maxBatch = 3}) =>
        BatchQueue<int>(
          name: 'test',
          maxQueueSize: maxQueue,
          maxBatchSize: maxBatch,
          delay: const Duration(seconds: 5),
          onBatch: (batch, urgent) async {
            batches.add(batch);
            await gate?.future;
          },
        );

    setUp(() {
      batches = [];
      gate = null;
    });

    test('waits for the delay, then exports', () {
      fakeAsync((fa) {
        queue = make()..add(1);
        fa.elapse(const Duration(seconds: 4));
        expect(batches, isEmpty);
        fa.elapse(const Duration(seconds: 1));
        expect(batches, [
          [1]
        ]);
      });
    });

    test('a full batch is exported immediately and keeps draining', () {
      fakeAsync((fa) {
        queue = make();
        for (var i = 0; i < 7; i++) {
          queue.add(i);
        }
        fa.flushMicrotasks();
        expect(batches, [
          [0, 1, 2],
          [3, 4, 5],
        ]);
        fa.elapse(const Duration(seconds: 5));
        expect(batches.last, [6]);
      });
    });

    test('no timer is pending when idle', () {
      fakeAsync((fa) {
        queue = make()..add(1);
        fa.elapse(const Duration(seconds: 5));
        expect(fa.pendingTimers, isEmpty);
      });
    });

    test('never runs two exports at once', () {
      fakeAsync((fa) {
        gate = Completer<void>();
        queue = make();
        for (var i = 0; i < 3; i++) {
          queue.add(i);
        }
        fa.flushMicrotasks();
        for (var i = 3; i < 9; i++) {
          queue.add(i);
        }
        fa.elapse(const Duration(seconds: 10));
        expect(batches, hasLength(1), reason: 'first export still running');
        gate!.complete();
        gate = null;
        fa.flushMicrotasks();
        expect(batches, hasLength(3));
      });
    });

    test('drops and counts items when full', () {
      fakeAsync((fa) {
        gate = Completer<void>();
        queue = make(maxQueue: 4, maxBatch: 100);
        for (var i = 0; i < 6; i++) {
          queue.add(i);
        }
        expect(queue.dropped, 2);
        expect(queue.length, 4);
      });
    });

    test('flush exports everything, paused queues schedule nothing', () {
      fakeAsync((fa) {
        queue = make()..pause();
        for (var i = 0; i < 5; i++) {
          queue.add(i);
        }
        fa.elapse(const Duration(minutes: 1));
        expect(batches, isEmpty);
        var done = false;
        queue.flush(urgent: true).then((_) => done = true);
        fa.flushMicrotasks();
        expect(done, isTrue);
        expect(batches.expand((b) => b), [0, 1, 2, 3, 4]);
        expect(fa.pendingTimers, isEmpty);
      });
    });
  });

  group('OtlpHttpExporter', () {
    final body = Uint8List.fromList(List.generate(64, (i) => i));
    final endpoints = {
      for (final s in Signal.values)
        s: Uri.parse('http://collector:4318/${s.path}'),
    };

    OtlpHttpExporter make(
      http.Client client, {
      MemoryStore? store,
      bool compression = false,
      int maxAttempts = 3,
    }) =>
        OtlpHttpExporter(
          endpoints: endpoints,
          headers: {'Authorization': 'Bearer t'},
          client: client,
          timeout: const Duration(seconds: 10),
          compression: compression,
          maxAttempts: maxAttempts,
          store: store,
        );

    tearDown(() => Clock.debugNowMicros = null);

    test('posts protobuf with headers and gzip', () async {
      late http.Request seen;
      final exporter = make(
        MockClient((r) async {
          seen = r;
          return http.Response('', 200);
        }),
        compression: true,
      );
      await exporter.export(Signal.logs, body);
      expect(seen.url.toString(), 'http://collector:4318/v1/logs');
      expect(seen.headers['Content-Type'], 'application/x-protobuf');
      expect(seen.headers['Content-Encoding'], 'gzip');
      expect(seen.headers['Authorization'], 'Bearer t');
      expect(gzip.decode(seen.bodyBytes), body);
    });

    test('retries network errors, then succeeds', () async {
      var calls = 0;
      final exporter = make(MockClient((_) async {
        if (++calls < 3) throw const SocketException('offline');
        return http.Response('', 200);
      }));
      await exporter.export(Signal.traces, body);
      expect(calls, 3);
      expect(exporter.droppedRequests, 0);
    });

    test('honours Retry-After on 429 / 503', () async {
      var calls = 0;
      final exporter = make(MockClient((_) async {
        calls++;
        return calls == 1
            ? http.Response('', 429, headers: {'retry-after': '0'})
            : http.Response('', 200);
      }));
      await exporter.export(Signal.traces, body);
      expect(calls, 2);
    });

    test('permanent errors are not retried', () async {
      var calls = 0;
      final exporter = make(MockClient((_) async {
        calls++;
        return http.Response('bad', 400);
      }));
      await exporter.export(Signal.traces, body);
      expect(calls, 1);
      expect(exporter.droppedRequests, 1);
    });

    test('offline: stores to disk, opens circuit, resends oldest first', () {
      fakeAsync((fa) {
        Clock.debugNowMicros = () => fa.elapsed.inMicroseconds;
        var online = false;
        var calls = 0;
        final sent = <int>[];
        final store = MemoryStore();
        final exporter = make(
          MockClient((r) async {
            calls++;
            if (!online) throw const SocketException('offline');
            sent.add(r.bodyBytes.first);
            return http.Response('', 200);
          }),
          store: store,
        );

        Uint8List payload(int tag) => Uint8List.fromList([tag]);
        exporter.export(Signal.traces, payload(1));
        fa.elapse(const Duration(seconds: 2));
        expect(store.items, hasLength(1));
        expect(calls, 2, reason: 'one quick retry, then disk');

        // Circuit open: no network attempt, straight to disk.
        exporter.export(Signal.logs, payload(2));
        fa.flushMicrotasks();
        expect(store.items, hasLength(2));
        expect(calls, 2);

        // Back online; the circuit's retry timer drains oldest first.
        online = true;
        fa.elapse(const Duration(minutes: 10));
        expect(sent, [1, 2]);
        expect(store.items, isEmpty);
        expect(exporter.droppedRequests, 0);
      });
    });

    test('urgent export writes to disk first, then sends', () async {
      final store = MemoryStore();
      final sent = <Signal>[];
      final exporter = make(
        MockClient((r) async {
          sent.add(Signal.values.firstWhere((s) => r.url.path.endsWith(s.name)));
          return http.Response('', 200);
        }),
        store: store,
      );
      await exporter.export(Signal.metrics, body, urgent: true);
      await exporter.drainStore();
      expect(sent, [Signal.metrics]);
      expect(store.items, isEmpty);
    });

    test('successful export drains a backlog from a previous run', () async {
      final store = MemoryStore()
        ..items.add(Payload(Signal.logs, Uint8List(1), gzipped: false));
      final paths = <String>[];
      final exporter = make(
        MockClient((r) async {
          paths.add(r.url.path);
          return http.Response('', 200);
        }),
        store: store,
      );
      await exporter.export(Signal.traces, body);
      await exporter.drainStore();
      expect(paths, ['/v1/traces', '/v1/logs']);
      expect(store.items, isEmpty);
    });

    test('Retry-After HTTP date is parsed', () {
      final d = HttpDateParser.parse('Wed, 21 Oct 2015 07:28:00 GMT');
      expect(d, DateTime.utc(2015, 10, 21, 7, 28));
    });
  });

  group('file offline store', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('otel_store'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('save / oldest / delete preserves order and flags', () async {
      final store = createOfflineStore(dir.path,
          maxBytes: 1 << 20, maxAge: const Duration(days: 1))!;
      await store.save(Payload(Signal.traces, Uint8List.fromList([1]), gzipped: true));
      await store.save(Payload(Signal.logs, Uint8List.fromList([2]), gzipped: false));
      final first = (await store.oldest())!;
      expect(first.payload.signal, Signal.traces);
      expect(first.payload.gzipped, isTrue);
      expect(first.payload.bytes, [1]);
      await store.delete(first);
      final second = (await store.oldest())!;
      expect(second.payload.signal, Signal.logs);
      await store.delete(second);
      expect(await store.oldest(), isNull);
    });

    test('size cap evicts the oldest files', () async {
      final store = createOfflineStore(dir.path,
          maxBytes: 250, maxAge: const Duration(days: 1))!;
      for (var i = 0; i < 5; i++) {
        await store.save(Payload(
            Signal.traces, Uint8List.fromList(List.filled(100, i)),
            gzipped: false));
      }
      final kept = <int>[];
      for (var s = await store.oldest(); s != null; s = await store.oldest()) {
        kept.add(s.payload.bytes.first);
        await store.delete(s);
      }
      expect(kept, [3, 4]);
    });

    test('expired files are discarded', () async {
      final store = createOfflineStore(dir.path,
          maxBytes: 1 << 20, maxAge: Duration.zero)!;
      await store.save(Payload(Signal.traces, Uint8List(1), gzipped: false));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await store.oldest(), isNull);
    });

    test('installation id is stable across launches', () async {
      final a = await loadOrCreateInstallationId(dir.path);
      final b = await loadOrCreateInstallationId(dir.path);
      expect(a, isNotNull);
      expect(a, b);
    });
  });
}
