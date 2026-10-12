# Analysis of the Dartastic OpenTelemetry packages

Reviewed on 2026-10-12, from `main` of:

| Package | Version | Lines (lib) | Role |
|---|---|---|---|
| [dartastic_opentelemetry_api](https://github.com/MindfulSoftwareLLC/dartastic_opentelemetry_api) | 1.0.0-rc.5-wip | 32.7k (23.6k generated) | API: interfaces + no-op |
| [dartastic_opentelemetry](https://github.com/MindfulSoftwareLLC/dartastic_opentelemetry) | 1.1.0-beta.18-wip | 29.8k (7.4k generated protobuf) | SDK: processing + export |
| [flutterrific_opentelemetry](https://github.com/MindfulSoftwareLLC/flutterrific_opentelemetry) | 0.4.0 | 6.6k | Flutter integration |

## 1. Is it free?

**Yes.** All three are **Apache License 2.0**: free to use commercially, modify
and fork. A fork must keep their `LICENSE` and `NOTICE` and mark changed files.

There is no license key, trial or paywall in the code. The only paid
connection is the optional `dartasticApiKey` in the Flutter package, which
sets the endpoint to `https://otel.dartastic.io`, their hosted backend. What
Dartastic sells is the backend ("Observatory"), session replay, AI features, a
"Pro" native runtime, and support. None of it is needed to use the libraries
with any other OpenTelemetry backend.

`otel_flutter` is a **new implementation** written from the OpenTelemetry
specification and the official `opentelemetry-proto` definitions, not a copy
of their code, so it carries no obligations to them.

## 2. How their stack works

```
App ─► flutterrific_opentelemetry (FlutterOTel.initialize, observers)
         └► dartastic_opentelemetry (OTel SDK: providers, processors, exporters)
              └► dartastic_opentelemetry_api (OTelAPI, interfaces, no-op)
```

* **API**: `OTelAPI` static methods delegate to a global `OTelFactory`. The
  default `OTelAPIFactory` is a no-op; the SDK installs its own factory.
  Constructors are hidden in `*_create.dart` part files because Dart has no
  package-private visibility. Context lives in Zones. The package includes
  every semantic convention of the spec as generated enums (159 files).
* **SDK**: `OTel.initialize()` builds a Resource, a TracerProvider with a
  BatchSpanProcessor, a MeterProvider with a periodic reader, and a
  LoggerProvider. Export is OTLP over gRPC (4317) or HTTP/protobuf (4318),
  using generated protobuf classes.
* **Flutter layer**: `FlutterOTel.initialize()` picks gRPC on native and HTTP
  on web, adds a lifecycle observer, a route observer, and metric "trackers".

**What it needs to connect:** an OTLP endpoint (collector or vendor), and
optionally auth headers and TLS certificates. Nothing Dartastic-specific.

## 3. Problems found

Items marked ✔ were re-checked by reading the exact code. The others come from
a line-by-line review, with file references in the review notes.

### Flutter layer: broken

| | Problem | Impact |
|---|---|---|
| ✔ | Doesn't compile against the current SDK: passes `dartasticApiKey`/`tenantId`, which the SDK removed | unusable with current versions |
| ✔ | No automatic error capture (no `FlutterError.onError` / `PlatformDispatcher.onError`), though advertised | crashes not reported |
| ✔ | Metrics exported **every 1 second**, forever, also in background | battery and data drain |
|  | New metric instrument created on every event and never freed | memory leak; growing export payloads |
|  | Span durations zero or negative (`end` ignores the time; subtraction reversed) | wrong timings |
|  | No frame/jank capture at all; Apdex gauge always 0.75; layout-shift score invented | misleading dashboards |
|  | Background flush not awaited; `shutdown` never called | data lost when the OS kills the app |
|  | Default endpoint port 4318 (HTTP) used with the gRPC exporter, TLS forced on | default setup can't connect |
|  | `go_router ^14` hard dependency | every app pulls in go_router 14 |
|  | Route arguments `toString()`'d into span attributes | personal-data leak |
|  | Duplicate listeners, ~185 lines commented out, 21 TODOs | maintenance cost |

### SDK: works, but unreliable on phones

| | Problem | Impact |
|---|---|---|
| ✔ | HTTP exporters never retry network errors (only 429/502/503/504) | data lost on every offline moment |
| ✔ | No disk persistence; nothing flushed when the app is backgrounded | data lost when offline or when the app is killed |
| ✔ | BatchSpanProcessor sends at most 512 spans per 5 s; then drops silently | throughput cap, silent loss |
| ✔ | `span.end()` twice exports the span twice | duplicates |
| ✔ | gRPC ignores custom CA / mTLS certificates (builds a context, then discards it) | can't use private CAs |
| ✔ | gRPC endpoint parsed with `split(':')`: `https://host` connects to port 4317, a trailing `/` throws | misconfiguration breaks all exports |
|  | Exports can run concurrently (timer + flush), against the spec | gRPC channel torn down mid-export |
|  | All encoding and gzip on the UI thread | jank on big batches |
|  | Env var endpoint overrides the one passed in code | surprising config |
|  | `http/json` ignored for metrics and logs | wrong format sent |
|  | All metrics exported under one hard-coded scope name | meter names lost |
|  | `Counter.add(-1)` throws, against the spec's "API must not throw" rule | app crash risk |
|  | No metric cardinality limit | unbounded memory |
|  | `host.name` from `Platform.localHostname` | often the user's device name (privacy) |

### API: mostly fine

| Problem | Impact |
|---|---|
| Setting one attribute copies all attributes (O(n²) per span) | CPU on attribute-heavy spans |
| "Immutable" spans keep caller-owned lists; `addEvent` on a span built with a const list throws | crashes, shared state |
| Trace/span ids re-hexed on every `==`/`hashCode` | allocations in hot paths |
| A tracer obtained before SDK init never records | instrumentation silently lost |
| Timestamps from `DateTime.now()` (wall clock), as fixnum `Int64` | negative durations on clock changes; allocations |
| Some API calls can still throw (`StateError` after reset) | crash risk |

## 4. Old vs new

| | Dartastic stack | otel_flutter |
|---|---|---|
| Code | ~69k lines, 3 packages | ~4k lines, 1 package |
| Dependencies | grpc, protobuf, fixnum, http, synchronized, collection, uuid, go_router, web, meta | http, meta |
| Wire format | generated protobuf classes, gRPC or HTTP | hand-written OTLP protobuf writer, HTTP |
| Offline | data dropped | disk queue, circuit breaker, resent after restart |
| App backgrounded | timers keep running, flush not awaited | timers stop, data written to disk then sent |
| Idle app | requests every 1 s (Flutter layer) | no timers, no requests |
| Batch throughput | 512 spans / 5 s, then silent drops | full batches sent immediately, one at a time |
| Errors | manual only | Flutter + uncaught errors, handlers chained, rate-limited |
| Jank | none | slow/frozen frames by refresh rate + UI-thread stall detector |
| Screens | arguments leaked, wrong durations | foreground-only screen spans, names only |
| Sessions | no | `session.id`, rotation, start/end events |
| HTTP tracing | no | `OtelHttpClient` (spans, metric, `traceparent`) |
| Tests | yes (no end-to-end) | 79 unit/widget tests + end-to-end against the real OpenTelemetry Collector |
