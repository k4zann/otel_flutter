/// OpenTelemetry for Flutter: traces, metrics and logs over OTLP/HTTP,
/// with automatic error, screen, frame, lifecycle and app-start capture.
library;

export 'src/config.dart' show OtelConfig;
export 'src/core/context.dart' show OtelContext;
export 'src/core/crash_context.dart' show PreviousRunContext;
export 'src/flutter/screens.dart' show OtelNavigatorObserver;
export 'src/http/otel_http_client.dart' show OtelHttpClient;
export 'src/logs/log_record.dart' show Severity;
export 'src/logs/logger.dart' show Logger;
export 'src/metrics/meter.dart'
    show
        Counter,
        Gauge,
        Histogram,
        Instrument,
        Meter,
        MetricTemporality,
        ObservableGauge,
        ObservableResult,
        UpDownCounter;
export 'src/otel.dart' show Otel;
export 'src/trace/propagation.dart' show W3CPropagator;
export 'src/trace/span.dart'
    show Span, SpanContext, SpanKind, SpanStatusCode, TelemetryLimits;
export 'src/trace/tracer.dart' show Tracer;
