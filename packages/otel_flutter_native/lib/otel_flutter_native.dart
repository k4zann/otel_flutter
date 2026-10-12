/// Native crash, ANR and exit-reason reporting for `otel_flutter`.
///
/// Native crashes (Kotlin/Swift/C++, signals), Android ANRs and low-memory
/// kills end the process before any Dart code runs. This plugin reads the
/// records the OS keeps about them (Android `ApplicationExitInfo`, iOS
/// MetricKit) on the next launch.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:otel_flutter/otel_flutter.dart';

/// Registered automatically on Android and iOS (`dartPluginClass`); apps
/// only add the dependency.
abstract final class OtelFlutterNative {
  static const MethodChannel _channel = MethodChannel('otel_flutter_native');

  /// The bounded `app.exit.reason` values; anything else is `other`.
  static const Set<String> exitReasons = {
    'crash',
    'native_crash',
    'anr',
    'low_memory',
    'user_request',
    'os_update',
    'other',
  };

  /// Called by Flutter's plugin registrant before `main`.
  static void registerWith() => Otel.registerNativeCrashReporter(report);

  /// Reports how previous processes ended. Each record is handed over once
  /// by the platform side, so it goes straight into the normal (offline-safe)
  /// export path.
  @visibleForTesting
  static Future<void> report(PreviousRunContext? previous) async {
    final List<Object?>? records;
    try {
      records = await _channel.invokeListMethod<Object?>('getPendingCrashes');
    } catch (_) {
      // No plugin (tests, add-to-app without it) or the OS refused: nothing
      // to report, and telemetry must never throw into the app.
      return;
    }
    if (records == null || records.isEmpty) return;
    for (final record in records) {
      if (record is Map) _emit(record, previous);
    }
    // A crash loop at startup could kill this run before the batch delay.
    await Otel.flush();
  }

  static void _emit(
    Map<Object?, Object?> record,
    PreviousRunContext? previous,
  ) {
    final raw = record['reason'];
    final reason = exitReasons.contains(raw) ? raw as String : 'other';
    Otel.meter('otel_flutter_native')
        .counter(
          'app.exits',
          unit: '{exit}',
          description: 'How previous processes ended.',
        )
        .add(1, {'app.exit.reason': reason});

    final event = switch (reason) {
      'crash' || 'native_crash' => 'app.crash',
      'anr' => 'app.anr',
      _ => null,
    };
    if (event == null) return;

    final millis = record['time'];
    final time = millis is int
        ? DateTime.fromMillisecondsSinceEpoch(millis)
        : null;
    // The saved context covers the previous run from its time on; an older
    // record belongs to a run nothing was saved for.
    final context =
        previous != null && time != null && !time.isBefore(previous.time)
        ? previous
        : null;
    final type = _string(record['type']);
    final message =
        _string(record['message']) ?? _string(record['description']);

    Otel.logger('otel_flutter_native').emit(
      eventName: event,
      severity: Severity.fatal,
      body: type ?? message,
      timestamp: time,
      attributes: {
        'app.exit.reason': reason,
        'exception.type': type,
        'exception.message': message,
        'exception.stacktrace': _string(record['stack']),
        // Null removes this run's values: the crash happened in an earlier one.
        'session.id': context?.sessionId,
        'app.screen.name': context?.screenName,
      },
    );
  }

  static String? _string(Object? value) => value is String ? value : null;
}
