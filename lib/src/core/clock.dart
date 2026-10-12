import 'package:meta/meta.dart';

/// Monotonic clock anchored to wall-clock time.
///
/// Span durations come from a [Stopwatch], so NTP adjustments can never make
/// a span negative. The anchor is re-synced whenever the monotonic time drifts
/// more than a second from wall time, which happens after the OS suspends the
/// app (Stopwatch stops while the device sleeps on iOS and Android).
abstract final class Clock {
  static final Stopwatch _stopwatch = Stopwatch()..start();
  static int _anchorMicros = DateTime.now().microsecondsSinceEpoch;

  static const int _maxDriftMicros = 1000000;

  @visibleForTesting
  static int Function()? debugNowMicros;

  /// Microseconds since the Unix epoch.
  static int nowMicros() {
    final debug = debugNowMicros;
    if (debug != null) return debug();
    final mono = _anchorMicros + _stopwatch.elapsedMicroseconds;
    final wall = DateTime.now().microsecondsSinceEpoch;
    final drift = wall - mono;
    if (drift > _maxDriftMicros || drift < -_maxDriftMicros) {
      _anchorMicros = wall - _stopwatch.elapsedMicroseconds;
      return wall;
    }
    return mono;
  }
}
