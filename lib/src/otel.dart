import 'dart:async';

import 'package:flutter/widgets.dart';

import 'config.dart';
import 'core/attributes.dart';
import 'core/clock.dart';
import 'core/context.dart';
import 'core/crash_context.dart';
import 'core/diagnostics.dart';
import 'flutter/errors.dart';
import 'flutter/frames.dart';
import 'flutter/lifecycle.dart';
import 'logs/logger.dart';
import 'metrics/meter.dart';
import 'sdk.dart';
import 'trace/propagation.dart';
import 'trace/span.dart';
import 'trace/tracer.dart';

/// Entry point for OpenTelemetry in a Flutter app.
///
/// ```dart
/// Future<void> main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await Otel.init(const OtelConfig(
///     serviceName: 'my_app',
///     endpoint: 'https://otlp.example.com',
///   ));
///   runApp(const MyApp());
/// }
/// ```
///
/// Everything works before [init] too, as a no-op, so libraries can be
/// instrumented unconditionally.
abstract final class Otel {
  static OtelSdk? _sdk;
  static ErrorReporter? _errors;
  static LifecycleObserver? _lifecycle;
  static FrameMonitor? _frames;
  static StallDetector? _stalls;
  static Future<void> Function(PreviousRunContext? previous)?
  _nativeCrashReporter;

  static final Span _noSpan = NonRecordingSpan(SpanContext.invalid);

  static bool get isInitialized => _sdk != null;

  /// Starts telemetry. Call once, before `runApp`.
  ///
  /// Throws [ArgumentError] if the endpoint is not an http(s) URL.
  static Future<void> init(OtelConfig config) async {
    if (_sdk != null) {
      Diagnostics.warnOnce('init-twice', 'Otel.init was already called.');
      return;
    }
    final binding = WidgetsFlutterBinding.ensureInitialized();
    final initMicros = Clock.nowMicros();
    Diagnostics.printer = debugPrint;

    final sdk = await OtelSdk.start(
      config,
      keepCrashContext:
          _nativeCrashReporter != null && config.captureNativeCrashes,
    );
    _sdk = sdk;

    _errors = ErrorReporter(sdk);
    if (config.captureErrors) _errors!.install();
    if (config.captureLifecycle) {
      binding.addObserver(_lifecycle = LifecycleObserver(sdk));
    }
    if (config.captureFrames) _frames = FrameMonitor()..install();
    if (config.captureStalls) {
      final stalls = _stalls = StallDetector();
      binding.addObserver(stalls);
      final state = binding.lifecycleState;
      if (state == null || state == AppLifecycleState.resumed) stalls.start();
    }
    if (config.captureAppStart && !binding.firstFrameRasterized) {
      unawaited(_trackAppStart(binding, initMicros));
    }
    final crashReporter = _nativeCrashReporter;
    if (crashReporter != null && config.captureNativeCrashes) {
      // Not awaited: reading OS crash records must not delay app start.
      unawaited(_reportNativeCrashes(crashReporter, sdk.previousRun));
    }
  }

  /// For companion packages such as `otel_flutter_native`, which call it
  /// when their plugin registers; apps don't need it.
  ///
  /// [onInit] runs after every [init] unless
  /// [OtelConfig.captureNativeCrashes] is false. While one is registered,
  /// the current session and screen are saved in
  /// [OtelConfig.offlineStorageDirectory], and [onInit] receives what the
  /// previous run saved last (null when unknown). A later registration
  /// replaces an earlier one.
  static void registerNativeCrashReporter(
    Future<void> Function(PreviousRunContext? previous) onInit,
  ) => _nativeCrashReporter = onInit;

  static Tracer tracer(String name, {String? version}) =>
      Tracer.of(name, version);

  static Meter meter(String name, {String? version}) => Meter.of(name, version);

  static Logger logger(String name, {String? version}) =>
      Logger.of(name, version);

  /// The span active in the current zone (a no-op span if none).
  static Span get activeSpan => OtelContext.current.span ?? _noSpan;

  /// Current `session.id`, e.g. to show in a support screen.
  static String? get sessionId => _sdk?.session.id;

  /// Name of the screen currently shown (from [OtelNavigatorObserver]).
  static String? get currentScreen => OtelSdk.currentScreen;

  /// Adds an attribute to every span and log from now on; null removes it.
  static void setGlobalAttribute(String key, Object? value) {
    final v = AttributeValues.normalize(value, null);
    if (v == null) {
      OtelSdk.globalAttributes.remove(key);
    } else {
      OtelSdk.globalAttributes[key] = v;
    }
  }

  /// Sets `user.id` on all telemetry (null on logout). Prefer an opaque id
  /// over an email address.
  static void setUser(String? id) => setGlobalAttribute('user.id', id);

  /// Reports a caught error (e.g. from a `try/catch` you handle yourself).
  static void recordError(
    Object error,
    StackTrace? stackTrace, {
    bool fatal = false,
    Map<String, Object?>? attributes,
  }) => _errors?.report(
    error,
    stackTrace,
    source: 'manual',
    fatal: fatal,
    attributes: attributes,
  );

  /// Adds W3C `traceparent`/`baggage` headers for the active span, for HTTP
  /// clients other than [OtelHttpClient] (e.g. a Dio interceptor).
  static void injectTraceHeaders(
    Map<String, String> headers, {
    OtelContext? context,
  }) => W3CPropagator.inject(headers, context: context);

  /// Exports everything buffered. Useful before a planned exit.
  static Future<void> flush({Duration timeout = const Duration(seconds: 10)}) =>
      _sdk?.flush(timeout: timeout) ?? Future.value();

  /// Flushes, removes all hooks and stops. [init] may be called again.
  static Future<void> shutdown() async {
    final sdk = _sdk;
    if (sdk == null) return;
    _errors?.uninstall();
    _frames?.uninstall();
    final lifecycle = _lifecycle;
    if (lifecycle != null) WidgetsBinding.instance.removeObserver(lifecycle);
    final stalls = _stalls;
    if (stalls != null) {
      stalls.stop();
      WidgetsBinding.instance.removeObserver(stalls);
    }
    _errors = null;
    _frames = null;
    _stalls = null;
    _lifecycle = null;
    _sdk = null;
    await sdk.shutdown();
  }

  @visibleForTesting
  static OtelSdk? get debugSdk => _sdk;

  @visibleForTesting
  static void debugResetNativeCrashReporter() => _nativeCrashReporter = null;

  static Future<void> _reportNativeCrashes(
    Future<void> Function(PreviousRunContext? previous) reporter,
    PreviousRunContext? previous,
  ) async {
    try {
      await reporter(previous);
    } catch (e) {
      Diagnostics.warnOnce(
        'native-crashes',
        'Native crash reporting failed: $e',
      );
    }
  }

  static Future<void> _trackAppStart(
    WidgetsBinding binding,
    int initMicros,
  ) async {
    await binding.waitUntilFirstFrameRasterized;
    if (_sdk == null) return;
    final durationMs = (Clock.nowMicros() - initMicros) / 1000;
    Tracer.of('otel_flutter')
        .startSpan(
          'app.start',
          newRoot: true,
          startTime: DateTime.fromMicrosecondsSinceEpoch(initMicros),
          attributes: {'app.start.type': 'cold'},
        )
        .end();
    Meter.of('otel_flutter')
        .histogram(
          'app.start.duration',
          unit: 'ms',
          description: 'Time from Otel.init to the first rasterized frame.',
          boundaries: const [
            100,
            250,
            500,
            750,
            1000,
            1500,
            2000,
            3000,
            5000,
            10000,
          ],
        )
        .record(durationMs);
  }
}
