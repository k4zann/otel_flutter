import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:meta/meta.dart';

import '../core/diagnostics.dart';

/// Buffers items (spans, logs) and hands them to [onBatch] in batches.
///
/// Compared with a fixed-interval timer:
/// * a full batch is exported immediately, so throughput isn't capped at one
///   batch per interval;
/// * the timer runs only while items are waiting, so an idle app never
///   wakes up;
/// * only one export runs at a time;
/// * while paused (app in background) nothing is scheduled.
@internal
final class BatchQueue<T> {
  BatchQueue({
    required this.name,
    required this.maxQueueSize,
    required this.maxBatchSize,
    required this.delay,
    required this.onBatch,
  });

  final String name;
  final int maxQueueSize;
  final int maxBatchSize;
  final Duration delay;
  final Future<void> Function(List<T> batch, bool urgent) onBatch;

  final ListQueue<T> _queue = ListQueue<T>();
  Timer? _timer;
  Future<void>? _inFlight;
  bool _paused = false;

  /// Items dropped because the queue was full.
  int dropped = 0;

  int get length => _queue.length;

  void add(T item) {
    if (_queue.length >= maxQueueSize) {
      dropped++;
      Diagnostics.warnOnce(
        'queue-full-$name',
        '$name queue is full ($maxQueueSize); dropping new items. The '
            'endpoint is too slow or unreachable.',
      );
      return;
    }
    _queue.add(item);
    if (_paused) return;
    if (_queue.length >= maxBatchSize) {
      _kick();
    } else {
      _timer ??= Timer(delay, _kick);
    }
  }

  /// Exports what is queued now instead of waiting for [delay].
  void exportSoon() {
    if (!_paused) _kick();
  }

  void pause() {
    _paused = true;
    _timer?.cancel();
    _timer = null;
  }

  void resume() {
    _paused = false;
    if (_queue.isNotEmpty) _timer ??= Timer(delay, _kick);
  }

  /// Exports everything queued, waiting for any export already running.
  Future<void> flush({bool urgent = false}) async {
    while (true) {
      _timer?.cancel();
      _timer = null;
      final running = _inFlight;
      if (running != null) {
        await running;
        continue;
      }
      if (_queue.isEmpty) return;
      await _start(all: true, urgent: urgent);
    }
  }

  void _kick() {
    _timer?.cancel();
    _timer = null;
    if (_inFlight == null && _queue.isNotEmpty) {
      unawaited(_start(all: false, urgent: false));
    }
  }

  Future<void> _start({required bool all, required bool urgent}) =>
      _inFlight = _drain(all: all, urgent: urgent).whenComplete(_onDrained);

  Future<void> _drain({required bool all, required bool urgent}) async {
    do {
      final n = min(_queue.length, maxBatchSize);
      if (n == 0) return;
      final batch = List<T>.generate(n, (_) => _queue.removeFirst());
      try {
        await onBatch(batch, urgent);
      } catch (e) {
        Diagnostics.warnOnce('batch-$name', '$name export failed: $e');
      }
    } while (all || _queue.length >= maxBatchSize);
  }

  void _onDrained() {
    _inFlight = null;
    if (_paused || _queue.isEmpty) return;
    if (_queue.length >= maxBatchSize) {
      _kick();
    } else {
      _timer ??= Timer(delay, _kick);
    }
  }
}
