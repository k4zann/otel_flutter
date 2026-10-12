import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../core/clock.dart';
import '../core/diagnostics.dart';
import '../logs/log_record.dart';
import '../logs/logger.dart';
import '../metrics/meter.dart';
import '../sdk.dart';

/// Reports errors as logs (with stack traces, linked to session and screen)
/// plus an `app.errors` counter.
///
/// [install] chains onto the existing `FlutterError.onError` and
/// `PlatformDispatcher.onError` handlers instead of replacing them, so other
/// crash reporters and the red error screen keep working.
@internal
final class ErrorReporter {
  ErrorReporter(this._sdk);

  final OtelSdk _sdk;
  final Logger _logger = Logger.of('otel_flutter.errors');
  final Counter _errors = Meter.of('otel_flutter.errors').counter(
    'app.errors',
    unit: '{error}',
    description: 'Errors reported by the app.',
  );

  /// An error thrown in `build` can repeat every frame; cap the logs.
  static const int _maxLogsPerMinute = 60;
  int _windowStartMicros = 0;
  int _inWindow = 0;

  FlutterExceptionHandler? _previousFlutter;
  ErrorCallback? _previousPlatform;
  FlutterExceptionHandler? _ownFlutter;
  ErrorCallback? _ownPlatform;

  void install() {
    _previousFlutter = FlutterError.onError;
    FlutterError.onError = _ownFlutter = (details) {
      report(
        details.exception,
        details.stack,
        source: 'flutter_framework',
        attributes: {
          'flutter.error.library': details.library,
          'flutter.error.context': details.context?.toString(),
        },
      );
      _previousFlutter?.call(details);
    };

    final dispatcher = PlatformDispatcher.instance;
    _previousPlatform = dispatcher.onError;
    dispatcher.onError = _ownPlatform = (error, stack) {
      report(error, stack, source: 'uncaught', fatal: true);
      return _previousPlatform?.call(error, stack) ?? false;
    };
  }

  /// Restores the previous handlers if nobody replaced ours since.
  void uninstall() {
    if (identical(FlutterError.onError, _ownFlutter)) {
      FlutterError.onError = _previousFlutter;
    }
    final dispatcher = PlatformDispatcher.instance;
    if (identical(dispatcher.onError, _ownPlatform)) {
      dispatcher.onError = _previousPlatform;
    }
  }

  void report(
    Object error,
    StackTrace? stackTrace, {
    required String source,
    bool fatal = false,
    Map<String, Object?>? attributes,
  }) {
    final screen = OtelSdk.currentScreen;
    _errors.add(1, {
      'error.type': error.runtimeType.toString(),
      'app.error.source': source,
      'app.screen.name': ?screen,
    });

    final now = Clock.nowMicros();
    if (now - _windowStartMicros > 60000000) {
      _windowStartMicros = now;
      _inWindow = 0;
    }
    if (++_inWindow > _maxLogsPerMinute) {
      Diagnostics.warnOnce('error-flood',
          'More than $_maxLogsPerMinute errors/minute; extra error logs are '
          'skipped (still counted in app.errors).');
      return;
    }

    _logger.emit(
      severity: fatal ? Severity.fatal : Severity.error,
      body: _summary(error),
      error: error,
      stackTrace: stackTrace,
      attributes: {'app.error.source': source, ...?attributes},
    );
    // Don't wait for the batch delay: the app may be about to die.
    _sdk.logs.exportSoon();
  }

  /// First line of the message, short enough for a log list view. The full
  /// text is in `exception.message`.
  static String _summary(Object error) {
    final text = error.toString().trimLeft();
    final newline = text.indexOf('\n');
    final line = newline < 0 ? text : text.substring(0, newline);
    return line.length > 300 ? '${line.substring(0, 300)}...' : line;
  }
}
