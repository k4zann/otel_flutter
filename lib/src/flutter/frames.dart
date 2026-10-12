import 'dart:async';
import 'dart:ui';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart' show internal;

import '../core/pipeline.dart';
import '../logs/log_record.dart';
import '../logs/logger.dart';
import '../metrics/meter.dart';
import '../sdk.dart';

/// Frame performance from the engine's own frame timings.
///
/// Costs nothing per frame on the UI thread: the engine delivers timings in
/// batches (about once a second in release builds) and only while frames are
/// actually being drawn.
///
/// A frame is slow when its build (UI thread) or raster (GPU thread) time
/// exceeds the display's budget (16.7 ms at 60 Hz, 8.3 ms at 120 Hz) and
/// frozen at 700 ms or more (Android vitals definition). The engine's
/// `vsyncOverhead` is deliberately ignored: on iOS it is a constant ~1 frame
/// offset, not real delay. Freezes *between* frames are caught by
/// [StallDetector] instead.
@internal
final class FrameMonitor {
  final Meter _meter = Meter.of('otel_flutter.frames');
  late final Counter _frames = _meter.counter(
    'app.frames',
    unit: '{frame}',
    description: 'Rendered frames.',
  );
  late final Counter _slow = _meter.counter(
    'app.frames.slow',
    unit: '{frame}',
    description: 'Frames whose build or raster time exceeded the budget.',
  );
  late final Counter _frozen = _meter.counter(
    'app.frames.frozen',
    unit: '{frame}',
    description: 'Frames that took 700 ms or longer.',
  );
  late final Histogram _duration = _meter.histogram(
    'app.frame.duration',
    unit: 'ms',
    description: 'Per-frame max(build, raster) time.',
    boundaries: const [2, 4, 8, 12, 16, 24, 33, 50, 100, 250, 700, 2000],
  );
  final Logger _logger = Logger.of('otel_flutter.frames');

  static const int _frozenMicros = 700000;

  void install() => SchedulerBinding.instance.addTimingsCallback(onTimings);

  void uninstall() =>
      SchedulerBinding.instance.removeTimingsCallback(onTimings);

  void onTimings(List<FrameTiming> timings) {
    if (Pipeline.current == null || timings.isEmpty) return;
    final budget = _budgetMicros();
    final screen = OtelSdk.currentScreen;
    final attributes = screen == null ? null : {'app.screen.name': screen};
    var slow = 0;
    var frozen = 0;
    for (final t in timings) {
      final build = t.buildDuration.inMicroseconds;
      final raster = t.rasterDuration.inMicroseconds;
      final work = build > raster ? build : raster;
      _duration.record(work / 1000, attributes);
      if (work > budget) slow++;
      if (work >= _frozenMicros) {
        frozen++;
        _logger.emit(
          severity: Severity.warn,
          eventName: 'app.jank',
          attributes: {
            'app.jank.frame_count': 1,
            'app.jank.period': work / 1e6,
            'app.jank.threshold': _frozenMicros / 1e6,
            'flutter.jank.source': 'frame',
            'flutter.frame.build_ms': build / 1000,
            'flutter.frame.raster_ms': raster / 1000,
          },
        );
      }
    }
    _frames.add(timings.length, attributes);
    if (slow > 0) _slow.add(slow, attributes);
    if (frozen > 0) _frozen.add(frozen, attributes);
  }

  static int _budgetMicros() {
    var rate = 60.0;
    try {
      final views = PlatformDispatcher.instance.views;
      if (views.isNotEmpty) {
        final r = views.first.display.refreshRate;
        if (r > 0) rate = r;
      }
    } catch (_) {
      // Display info unavailable (e.g. some test environments): assume 60 Hz.
    }
    return (1e6 / rate).round();
  }
}

/// Detects the UI thread being blocked, e.g. by a slow tap handler or
/// synchronous JSON parsing. Such work runs between frames, so it never shows
/// up in frame timings: the app simply stops drawing and ignores input.
///
/// A one-shot timer re-armed every [tickMicros] measures how late the event
/// loop runs it. It runs only while the app is in the foreground (5 cheap
/// wake-ups per second) and stops in the background.
@internal
final class StallDetector with WidgetsBindingObserver {
  StallDetector({int Function()? nowMicros})
    : _now = nowMicros ?? _stopwatchMicros;

  static final Stopwatch _stopwatch = Stopwatch()..start();
  static int _stopwatchMicros() => _stopwatch.elapsedMicroseconds;

  static const int tickMicros = 200000;

  /// Report when the event loop was blocked at least this long.
  static const int thresholdMicros = 500000;

  final int Function() _now;
  final Counter _stalls = Meter.of('otel_flutter.frames').counter(
    'app.ui.stalls',
    unit: '{stall}',
    description: 'Times the UI thread was blocked for 500 ms or more.',
  );
  final Logger _logger = Logger.of('otel_flutter.frames');
  Timer? _timer;
  int _expected = 0;

  bool get isRunning => _timer != null;

  void start() {
    if (_timer == null) _arm();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        start();
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        stop();
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _arm() {
    _expected = _now() + tickMicros;
    _timer = Timer(const Duration(microseconds: tickMicros), _onTick);
  }

  void _onTick() {
    // The timer fired this late because the event loop was busy; the block
    // lasted at least this long.
    final blocked = _now() - _expected;
    if (blocked >= thresholdMicros && Pipeline.current != null) {
      final screen = OtelSdk.currentScreen;
      _stalls.add(1, {'app.screen.name': ?screen});
      _logger.emit(
        severity: Severity.warn,
        eventName: 'app.jank',
        attributes: {
          'app.jank.period': blocked / 1e6,
          'app.jank.threshold': thresholdMicros / 1e6,
          'flutter.jank.source': 'ui_stall',
        },
      );
    }
    _arm();
  }
}
