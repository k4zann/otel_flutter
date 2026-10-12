import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import 'clock.dart';

/// The session and screen the previous run saved last, so a crash that
/// killed that run (reported by the OS on this launch) can be attributed.
/// Passed to the reporter registered with `Otel.registerNativeCrashReporter`.
final class PreviousRunContext {
  const PreviousRunContext({
    required this.sessionId,
    required this.screenName,
    required this.time,
  });

  /// `session.id` that was active.
  final String sessionId;

  /// `app.screen.name` that was shown, if any.
  final String? screenName;

  /// When this state began. A crash of the previous run at or after this
  /// time happened in it.
  final DateTime time;
}

/// Keeps the current session and screen on disk. A native crash kills the
/// process without warning, so the state must already be saved when it
/// happens.
///
/// Changes are rare (session start, navigation), but a burst of route
/// changes must not cause a burst of writes: at most one write per second,
/// always ending with the latest state.
@internal
final class CrashContextWriter {
  CrashContextWriter(this._write);

  /// Persists the encoded state; must not throw.
  final Future<void> Function(String json) _write;

  static const int _minIntervalMicros = 1000000;

  Timer? _timer;
  String? _pending;
  int? _lastWriteMicros;
  Future<void> _writing = Future.value();

  void save(String sessionId, String? screenName) {
    final now = Clock.nowMicros();
    _pending = jsonEncode({
      'session.id': sessionId,
      'app.screen.name': ?screenName,
      'time': now ~/ 1000,
    });
    // An already scheduled write picks up the latest state.
    if (_timer != null) return;
    final last = _lastWriteMicros;
    final wait = last == null ? 0 : last + _minIntervalMicros - now;
    if (wait <= 0) {
      _writeNow();
    } else {
      _timer = Timer(Duration(microseconds: wait), _writeNow);
    }
  }

  /// Writes a pending change now (app going to background, shutdown).
  Future<void> flush() {
    _writeNow();
    return _writing;
  }

  void _writeNow() {
    _timer?.cancel();
    _timer = null;
    final json = _pending;
    if (json == null) return;
    _pending = null;
    _lastWriteMicros = Clock.nowMicros();
    // Sequential, so an older state can never land after a newer one.
    _writing = _writing.then((_) => _write(json));
  }

  /// Parses what [save] wrote in the previous run; null if missing or
  /// unreadable.
  static PreviousRunContext? decode(String? json) {
    if (json == null) return null;
    try {
      final map = jsonDecode(json);
      if (map is! Map) return null;
      final id = map['session.id'];
      final screen = map['app.screen.name'];
      final time = map['time'];
      if (id is! String || time is! int) return null;
      return PreviousRunContext(
        sessionId: id,
        screenName: screen is String ? screen : null,
        time: DateTime.fromMillisecondsSinceEpoch(time),
      );
    } on FormatException {
      return null;
    }
  }
}
