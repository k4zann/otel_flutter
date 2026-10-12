import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../logs/logger.dart';
import '../sdk.dart';
import 'screens.dart';

/// Reacts to the app moving between foreground and background.
///
/// Mobile OSes suspend a backgrounded app within seconds and may kill it
/// without warning, so leaving the foreground is the moment to export (or
/// persist) everything buffered and to stop all timers.
@internal
final class LifecycleObserver with WidgetsBindingObserver {
  LifecycleObserver(this._sdk);

  final OtelSdk _sdk;
  final Logger _logger = Logger.of('otel_flutter.lifecycle');

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        toBackground();
      case AppLifecycleState.resumed:
        toForeground();
      case AppLifecycleState.inactive:
        // Transient (incoming call banner, app switcher): not background yet.
        break;
    }
  }

  void toBackground() {
    if (_sdk.isInBackground) return;
    ScreenTracker.instance.suspend();
    _event('background');
    unawaited(_sdk.onBackground());
  }

  void toForeground() {
    if (!_sdk.isInBackground) return;
    _sdk.onForeground();
    ScreenTracker.instance.resume();
    _event('foreground');
  }

  /// `device.app.lifecycle` event (semantic conventions, iOS/Android only).
  void _event(String state) {
    if (kIsWeb) return;
    final key = switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'ios.app.state',
      TargetPlatform.android => 'android.app.state',
      _ => null,
    };
    if (key != null) {
      _logger.emit(eventName: 'device.app.lifecycle', attributes: {key: state});
    }
  }
}
