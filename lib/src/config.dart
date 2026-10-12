import 'package:http/http.dart' as http;

import 'metrics/meter.dart';
import 'trace/span.dart';

/// Everything `Otel.init` needs. Only [serviceName] is required.
///
/// Connection settings can also come from `--dart-define`, using the standard
/// OpenTelemetry names (values set here win):
///
/// ```sh
/// flutter run \
///   --dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=https://otlp.example.com \
///   --dart-define=OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer%20xyz
/// ```
final class OtelConfig {
  const OtelConfig({
    required this.serviceName,
    this.serviceVersion,
    this.environment,
    this.endpoint,
    this.tracesEndpoint,
    this.metricsEndpoint,
    this.logsEndpoint,
    this.headers = const {},
    this.resourceAttributes = const {},
    this.sampleRatio = 1.0,
    this.offlineStorageDirectory,
    this.maxOfflineStorageBytes = 5 * 1024 * 1024,
    this.maxOfflineAge = const Duration(days: 2),
    this.exportDelay = const Duration(seconds: 5),
    this.maxQueueSize = 2048,
    this.maxExportBatchSize = 512,
    this.metricInterval = const Duration(seconds: 60),
    this.metricTemporality = MetricTemporality.cumulative,
    this.exportTimeout = const Duration(seconds: 10),
    this.maxExportAttempts = 4,
    this.compression = true,
    this.limits = const TelemetryLimits(),
    this.sessionTimeout = const Duration(minutes: 30),
    this.captureErrors = true,
    this.captureFrames = true,
    this.captureStalls = true,
    this.captureAppStart = true,
    this.captureLifecycle = true,
    this.captureNativeCrashes = true,
    this.debug = false,
    this.httpClient,
  });

  /// `service.name`: how your app is listed in the backend.
  final String serviceName;

  /// `service.version`, e.g. your app version from pubspec.
  final String? serviceVersion;

  /// `deployment.environment.name`, e.g. `production` or `staging`.
  final String? environment;

  /// OTLP/HTTP base URL, e.g. `https://otlp.example.com` or
  /// `http://10.0.2.2:4318` (Android emulator to your computer).
  /// `/v1/traces`, `/v1/metrics` and `/v1/logs` are appended.
  /// Fallback: `OTEL_EXPORTER_OTLP_ENDPOINT`, then `http://localhost:4318`.
  final String? endpoint;

  /// Full per-signal URLs, used as-is (no path appended).
  final String? tracesEndpoint;
  final String? metricsEndpoint;
  final String? logsEndpoint;

  /// Sent with every request, e.g. `{'Authorization': 'Bearer ...'}`.
  ///
  /// Anything shipped inside an app can be extracted from it. Use a token
  /// that can only *write* telemetry, or point the app at your own collector
  /// and keep the vendor key there.
  final Map<String, String> headers;

  /// Extra resource attributes, e.g. `device.model.name` from
  /// device_info_plus.
  final Map<String, Object> resourceAttributes;

  /// Fraction of traces to keep, 0.0 to 1.0. Child spans follow the parent.
  final double sampleRatio;

  /// Directory for the offline queue (e.g. from
  /// `getApplicationSupportDirectory()`). When set, data that can't be sent
  /// is stored on disk and resent later, even after an app restart. It also
  /// enables `app.installation.id`. Not available on web.
  final String? offlineStorageDirectory;
  final int maxOfflineStorageBytes;
  final Duration maxOfflineAge;

  /// How long spans and logs wait to be batched. A full batch is sent
  /// immediately; errors and app backgrounding also send right away.
  final Duration exportDelay;
  final int maxQueueSize;
  final int maxExportBatchSize;

  /// How often metrics are collected. Nothing is sent if nothing changed.
  final Duration metricInterval;
  final MetricTemporality metricTemporality;

  final Duration exportTimeout;

  /// Attempts per request when there is no offline store.
  final int maxExportAttempts;

  /// gzip request bodies (native platforms only).
  final bool compression;

  final TelemetryLimits limits;

  /// A new `session.id` starts after the app spent this long in background.
  final Duration sessionTimeout;

  /// Report `FlutterError.onError` and uncaught async errors. Existing
  /// handlers (e.g. Crashlytics) keep working: they are chained, not replaced.
  final bool captureErrors;

  /// Slow/frozen frame metrics from the engine's frame timings.
  final bool captureFrames;

  /// Detect the UI thread being blocked >= 500 ms between frames (slow tap
  /// handlers, synchronous parsing). Uses a light 200 ms timer, foreground
  /// only.
  final bool captureStalls;

  /// `app.start` span from `Otel.init` to the first rasterized frame.
  final bool captureAppStart;

  /// Flush on background, background/foreground events, session rotation.
  /// Turning this off is not recommended on mobile: the OS may kill a
  /// backgrounded app before buffered data is sent.
  final bool captureLifecycle;

  /// Report native crashes, Android ANRs and exit reasons of the previous run
  /// on the next launch. Needs the `otel_flutter_native` companion package
  /// (without it this does nothing); set false to turn it off without
  /// removing the package. Crashes are linked to their session and screen
  /// only when [offlineStorageDirectory] is set.
  final bool captureNativeCrashes;

  /// Print one line per export and every problem to the console.
  final bool debug;

  /// HTTP client for the exporter, e.g. an `IOClient` with a custom
  /// `SecurityContext` for self-signed certificates or mTLS.
  final http.Client? httpClient;
}

/// `--dart-define` values with standard OpenTelemetry names.
abstract final class OtelEnvironment {
  static const endpoint = String.fromEnvironment('OTEL_EXPORTER_OTLP_ENDPOINT');
  static const tracesEndpoint = String.fromEnvironment(
    'OTEL_EXPORTER_OTLP_TRACES_ENDPOINT',
  );
  static const metricsEndpoint = String.fromEnvironment(
    'OTEL_EXPORTER_OTLP_METRICS_ENDPOINT',
  );
  static const logsEndpoint = String.fromEnvironment(
    'OTEL_EXPORTER_OTLP_LOGS_ENDPOINT',
  );
  static const headers = String.fromEnvironment('OTEL_EXPORTER_OTLP_HEADERS');
  static const resourceAttributes = String.fromEnvironment(
    'OTEL_RESOURCE_ATTRIBUTES',
  );

  /// Parses `key1=value1,key2=value2` with percent-encoded values.
  static Map<String, String> parseList(String raw) {
    final out = <String, String>{};
    for (final item in raw.split(',')) {
      final eq = item.indexOf('=');
      if (eq <= 0) continue;
      final key = item.substring(0, eq).trim();
      final value = item.substring(eq + 1).trim();
      if (key.isEmpty) continue;
      try {
        out[key] = Uri.decodeComponent(value);
      } catch (_) {
        out[key] = value;
      }
    }
    return out;
  }
}
