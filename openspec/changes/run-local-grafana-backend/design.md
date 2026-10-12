## Context

The stack uses the all-in-one `grafana/otel-lgtm:0.36.0` image (collector +
Tempo + Loki + Prometheus/Mimir + Grafana). Homebrew is installed; Docker,
Colima and OrbStack are not.

## Goals / Non-Goals

**Goals:** one command brings up a backend with a ready-made dashboard; every
SDK signal is visible and cross-linked.

**Non-Goals:** production hosting (see `production-collector-deployment`),
alerting, long-term retention.

## Decisions

- **Runtime: Colima + docker CLI + compose plugin** (`brew install colima
  docker docker-compose`). Free and open source, no license terms.
  Alternatives: Docker Desktop (paid for larger companies), OrbStack (paid for
  commercial use). Either still works with the same compose file.
- **Dashboard as provisioned JSON in the repo**, mounted read-only into the
  image's Grafana provisioning directory. Find the exact path in the
  otel-lgtm image docs for 0.36.0. Rejected: building it by hand in the UI
  (not reproducible).
- **Metric names as Prometheus sees them**: OTLP → Prometheus translation adds
  unit and type suffixes, for example `app.frames` → `app_frames_total`,
  `app.frame.duration` (ms) → `app_frame_duration_milliseconds_bucket`,
  `http.client.request.duration` (s) →
  `http_client_request_duration_seconds_bucket`. Panels must use the
  translated names; confirm them against real data before writing panels.
- **Sessions from logs**: count `session.start` events in Loki (event name
  attribute) rather than adding a session metric to the SDK.
- **Event names copied in the collector** (found while verifying): Loki 3.7.8
  drops the OTLP `LogRecord.event_name` field, so events arrive nameless.
  `backend/lgtm/otelcol-config.yaml` is a copy of the image's collector config
  plus one OTTL rule that copies `event_name` into the `event.name` attribute
  (Loki label `event_name`), mounted over the image's file. Rejected: counting
  distinct `session_id` values (a different metric, and every other event would
  stay unnamed); emitting an `event.name` attribute from the SDK (the semantic
  conventions moved event names to the dedicated field).
- **Start-time zero samples in Prometheus** (found while verifying): the SDK
  sends cumulative series whose first export already holds the first value, so
  `rate()`/`increase()` ignored a single error or app start. Prometheus runs
  with `--enable-feature=created-timestamp-zero-ingestion` (via the image's
  `PROMETHEUS_EXTRA_ARGS`), which adds a 0 sample at each series' start time.

## Risks / Trade-offs

- [Translation rules differ between image versions] → panels are written from
  names observed in Prometheus, and the image version is pinned.
- [Log→trace link needs a Loki derived field] → if not preconfigured by the
  image, provision the Loki datasource with a `trace_id` derived field.
- [The copied collector config drifts from a newer image] → refresh it from
  `/otel-lgtm/otelcol-config.yaml` whenever the image tag changes.
