import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'config.dart';
import 'core/attributes.dart';
import 'core/clock.dart';
import 'core/crash_context.dart';
import 'core/diagnostics.dart';
import 'core/ids.dart';
import 'core/pipeline.dart';
import 'export/batch_queue.dart';
import 'export/offline_store.dart';
import 'export/otlp_encoder.dart';
import 'export/otlp_http_exporter.dart';
import 'logs/log_record.dart';
import 'logs/logger.dart';
import 'metrics/meter.dart';
import 'platform/platform.dart';
import 'trace/sampler.dart';
import 'trace/span.dart';

/// The running SDK: owns the queues, the exporter and the session.
/// Flutter-independent; the Flutter integration drives it.
@internal
final class OtelSdk implements Pipeline {
  OtelSdk._(this.config, this.resource, this._exporter, this._client,
      this._ownsClient)
      : _resourceBytes = OtlpEncoder.encodeResource(resource),
        sampler = Sampler(config.sampleRatio),
        limits = config.limits,
        session = Session(config.sessionTimeout) {
    spans = BatchQueue<RecordingSpan>(
      name: 'span',
      maxQueueSize: config.maxQueueSize,
      maxBatchSize: config.maxExportBatchSize,
      delay: config.exportDelay,
      onBatch: (batch, urgent) => _exporter.export(
        Signal.traces,
        OtlpEncoder.encodeSpans(_resourceBytes, batch),
        urgent: urgent,
        items: batch.length,
      ),
    );
    logs = BatchQueue<LogRecordData>(
      name: 'log',
      maxQueueSize: config.maxQueueSize,
      maxBatchSize: config.maxExportBatchSize,
      delay: config.exportDelay,
      onBatch: (batch, urgent) => _exporter.export(
        Signal.logs,
        OtlpEncoder.encodeLogs(_resourceBytes, batch),
        urgent: urgent,
        items: batch.length,
      ),
    );
  }

  static const String sdkVersion = '0.1.0';

  /// Name of the screen currently shown; set by the navigator observer.
  /// Static so it works before init and is read by every span and log.
  static String? currentScreen;

  /// [keepCrashContext]: keep session and screen on disk for a native crash
  /// reporter (needs [OtelConfig.offlineStorageDirectory]).
  static Future<OtelSdk> start(
    OtelConfig config, {
    bool keepCrashContext = false,
  }) async {
    Diagnostics.verbose = config.debug;
    final endpoints = {
      for (final s in Signal.values) s: _endpointFor(config, s),
    };
    if (endpoints.values.any((u) => u.port == 4317)) {
      Diagnostics.warnOnce('grpc-port',
          'Port 4317 is OTLP/gRPC. This SDK sends OTLP/HTTP, which collectors '
          'serve on port 4318.');
    }
    final headers = {
      ...OtelEnvironment.parseList(OtelEnvironment.headers),
      ...config.headers,
    };
    final dir = config.offlineStorageDirectory;
    final installationId = await loadOrCreateInstallationId(dir);

    final resource = <String, Object>{
      'telemetry.sdk.name': 'otel_flutter',
      'telemetry.sdk.language': 'dart',
      'telemetry.sdk.version': sdkVersion,
      ...platformResourceAttributes(),
      'service.instance.id': Ids.uuidV4(),
      'app.installation.id': ?installationId,
      ...OtelEnvironment.parseList(OtelEnvironment.resourceAttributes),
    };
    config.resourceAttributes.forEach((key, value) {
      final v = AttributeValues.normalize(value, null);
      if (v != null && key.isNotEmpty) resource[key] = v;
    });
    resource['service.name'] = config.serviceName;
    if (config.serviceVersion != null) {
      resource['service.version'] = config.serviceVersion!;
    }
    if (config.environment != null) {
      resource['deployment.environment.name'] = config.environment!;
    }

    final client = config.httpClient ?? http.Client();
    final exporter = OtlpHttpExporter(
      endpoints: endpoints,
      headers: headers,
      client: client,
      timeout: config.exportTimeout,
      compression: config.compression,
      maxAttempts: config.maxExportAttempts,
      store: dir == null
          ? null
          : createOfflineStore(dir,
              maxBytes: config.maxOfflineStorageBytes,
              maxAge: config.maxOfflineAge),
    );

    final sdk = OtelSdk._(
        config, resource, exporter, client, config.httpClient == null);
    if (keepCrashContext && dir != null) {
      sdk._previousRun =
          CrashContextWriter.decode(await rotateCrashContext(dir));
      sdk._crashContext =
          CrashContextWriter((json) => writeCrashContext(dir, json));
    }
    Pipeline.current = sdk;
    MeterRegistry.temporality = config.metricTemporality;
    MeterRegistry.enabled = true;
    sdk._startMetricTimer();
    sdk._emitSessionStart(null);
    sdk.saveCrashContext();
    // Send whatever a previous run left in the offline queue.
    unawaited(exporter.drainStore(force: true));
    Diagnostics.debug('started: traces -> ${endpoints[Signal.traces]}');
    return sdk;
  }

  final OtelConfig config;
  final Map<String, Object> resource;
  final Uint8List _resourceBytes;
  final OtlpHttpExporter _exporter;
  final http.Client _client;
  final bool _ownsClient;
  final Session session;

  /// What the previous run saved last, for native crash attribution.
  PreviousRunContext? get previousRun => _previousRun;
  PreviousRunContext? _previousRun;
  CrashContextWriter? _crashContext;

  @override
  final Sampler sampler;
  @override
  final TelemetryLimits limits;

  late final BatchQueue<RecordingSpan> spans;
  late final BatchQueue<LogRecordData> logs;

  /// Attributes added to every span and log (e.g. `user.id`). Static so they
  /// can be set before init.
  static final Map<String, Object> globalAttributes = {};

  final Logger _logger = Logger.of('otel_flutter', sdkVersion);
  Timer? _metricTimer;
  Future<void>? _metricExport;
  bool _background = false;
  bool _shutdown = false;

  @visibleForTesting
  OtlpHttpExporter get exporter => _exporter;

  @override
  void onSpanEnd(RecordingSpan span) {
    if (!_shutdown && span.spanContext.isSampled) spans.add(span);
  }

  @override
  void onLogRecord(LogRecordData record) {
    if (!_shutdown) logs.add(record);
  }

  @override
  void applyCommonAttributes(AttributeMap target) {
    target.set('session.id', session.id);
    final screen = currentScreen;
    if (screen != null) target.set('app.screen.name', screen);
    if (globalAttributes.isNotEmpty) globalAttributes.forEach(target.set);
  }

  bool get isInBackground => _background;

  /// Called on session start and screen change.
  void saveCrashContext() => _crashContext?.save(session.id, currentScreen);

  /// App left the foreground: stop all timers and get buffered data out
  /// (or onto disk) before the OS suspends or kills the process.
  Future<void> onBackground() async {
    if (_background || _shutdown) return;
    _background = true;
    session.markBackground();
    spans.pause();
    logs.pause();
    _metricTimer?.cancel();
    _metricTimer = null;
    unawaited(_crashContext?.flush());
    await flush(urgent: true);
  }

  void onForeground() {
    if (!_background || _shutdown) return;
    _background = false;
    final previous = session.markForeground();
    if (previous != null) {
      _logger.emit(
        eventName: 'session.end',
        attributes: {'session.id': previous},
      );
      _emitSessionStart(previous);
      saveCrashContext();
    }
    spans.resume();
    logs.resume();
    _startMetricTimer();
    _exporter.resume();
  }

  Future<void> flush({bool urgent = false, Duration? timeout}) {
    final all = Future.wait([
      spans.flush(urgent: urgent),
      logs.flush(urgent: urgent),
      exportMetrics(urgent: urgent),
    ]);
    if (timeout == null) return all;
    return all.timeout(timeout, onTimeout: () {
      Diagnostics.debug('flush timed out after ${timeout.inSeconds}s');
      return const [];
    });
  }

  /// Collects metrics and exports them if anything changed.
  Future<void> exportMetrics({bool urgent = false}) async {
    final running = _metricExport;
    if (running != null) await running;
    final data = MeterRegistry.collect();
    if (data.isEmpty) return;
    final export = _exporter.export(
      Signal.metrics,
      OtlpEncoder.encodeMetrics(_resourceBytes, data),
      urgent: urgent,
      items: data.length,
    );
    _metricExport = export;
    try {
      await export;
    } finally {
      if (identical(_metricExport, export)) _metricExport = null;
    }
  }

  Future<void> shutdown({Duration timeout = const Duration(seconds: 10)}) async {
    if (_shutdown) return;
    _metricTimer?.cancel();
    _metricTimer = null;
    await flush(timeout: timeout);
    await _crashContext?.flush();
    _shutdown = true;
    spans.pause();
    logs.pause();
    _exporter.close();
    if (identical(Pipeline.current, this)) Pipeline.current = null;
    MeterRegistry.enabled = false;
    if (_ownsClient) _client.close();
  }

  void _startMetricTimer() {
    _metricTimer?.cancel();
    _metricTimer = Timer.periodic(
      config.metricInterval,
      (_) => unawaited(exportMetrics()),
    );
  }

  void _emitSessionStart(String? previousId) {
    _logger.emit(
      eventName: 'session.start',
      attributes: {
        'session.previous_id': ?previousId,
      },
    );
  }

  static Uri _endpointFor(OtelConfig c, Signal s) {
    String? nonEmpty(String v) => v.isEmpty ? null : v;
    final specific = switch (s) {
      Signal.traces =>
        c.tracesEndpoint ?? nonEmpty(OtelEnvironment.tracesEndpoint),
      Signal.metrics =>
        c.metricsEndpoint ?? nonEmpty(OtelEnvironment.metricsEndpoint),
      Signal.logs => c.logsEndpoint ?? nonEmpty(OtelEnvironment.logsEndpoint),
    };
    if (specific != null) return _parseEndpoint(specific);
    var base = c.endpoint ??
        nonEmpty(OtelEnvironment.endpoint) ??
        'http://localhost:4318';
    if (!base.endsWith('/')) base = '$base/';
    return _parseEndpoint('$base${s.path}');
  }

  static Uri _parseEndpoint(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw ArgumentError.value(url, 'endpoint',
          'must be an http(s) URL such as https://otlp.example.com');
    }
    return uri;
  }
}

/// `session.id`: a new session starts at launch and after the app spent
/// longer than [timeout] in the background.
@internal
final class Session {
  Session(this.timeout) : id = Ids.uuidV4();

  final Duration timeout;
  String id;
  int? _backgroundSinceMicros;

  void markBackground() => _backgroundSinceMicros = Clock.nowMicros();

  /// Returns the previous id if the session rotated.
  String? markForeground() {
    final since = _backgroundSinceMicros;
    _backgroundSinceMicros = null;
    if (since == null || Clock.nowMicros() - since < timeout.inMicroseconds) {
      return null;
    }
    final previous = id;
    id = Ids.uuidV4();
    return previous;
  }
}
