# How otel_flutter works

## The big picture

```
 your code / auto-instrumentation
   │  Otel.tracer().startSpan()   Otel.meter().counter().add()   Otel.logger().info()
   ▼
 ┌──────────────── API (no-op until Otel.init) ─────────────────────────┐
 │ Tracer ── Span          Meter ── Counter/Histogram/Gauge   Logger    │
 │   │ context via Zones     │ aggregated in memory            │        │
 └───┼───────────────────────┼─────────────────────────────────┼────────┘
     ▼ span.end()            ▼ every 60 s (if changed)         ▼ emit()
 ┌──────────── SDK (OtelSdk) ───────────────────────────────────────────┐
 │ BatchQueue<Span>        MeterRegistry.collect()      BatchQueue<Log> │
 │   5 s or 512 items        cumulative or delta          5 s or 512    │
 │         └──────────────┬────────────┴──────────────┬───────┘          │
 │                        ▼                           ▼                  │
 │          OtlpEncoder: protobuf bytes (+ cached resource bytes)       │
 │                        ▼                                              │
 │          gzip (background isolate when > 64 KB)                       │
 │                        ▼                                              │
 │          OtlpHttpExporter: POST /v1/{traces,metrics,logs}             │
 │             retry + backoff + Retry-After, circuit breaker            │
 │                        │ fails / app backgrounded                     │
 │                        ▼                                              │
 │          OfflineStore: one file per request, resent oldest-first      │
 └───────────────────────────────────────────────────────────────────────┘
                          ▼
              OpenTelemetry Collector / backend (port 4318)
```

## Source map

| Folder | Role |
|---|---|
| `lib/src/core/` | clock, ids, attributes, context (Zones), scope, diagnostics, `Pipeline` interface |
| `lib/src/trace/` | `Span`, `Tracer`, sampler, W3C propagation |
| `lib/src/metrics/` | `Meter`, instruments, aggregation, `MeterRegistry` |
| `lib/src/logs/` | `Logger`, `Severity`, log records |
| `lib/src/export/` | protobuf writer, OTLP encoder, batch queue, HTTP exporter, offline store interface |
| `lib/src/platform/` | dart:io-only parts (gzip, file queue, OS info) with web stubs |
| `lib/src/flutter/` | lifecycle, errors, screens, frames, UI stalls |
| `lib/src/http/` | `OtelHttpClient` |
| `lib/src/sdk.dart` | `OtelSdk`: wires queues, exporter, session, resource |
| `lib/src/otel.dart` | `Otel`: the public entry point, installs the Flutter hooks |

## API vs SDK: why everything is safe before `init`

The API classes (`Tracer`, `Meter`, `Logger`) look up `Pipeline.current` on
every call. While it is null (before `Otel.init`, or after `shutdown`):

* `startSpan` returns a `NonRecordingSpan` that still carries a parent's
  context (propagation keeps working);
* instruments ignore values (`MeterRegistry.enabled == false`);
* `Logger.emit` returns immediately.

Because the lookup happens per call, not when the tracer is created, a
tracer or counter created in a static field before `init` starts recording
after `init`. (The original package froze such objects as no-ops.)

## A span's life

1. `startSpan` picks the parent from the active `OtelContext` (or the
   `context:` argument), reuses its trace id or makes a new one, asks the
   sampler, and creates a `RecordingSpan` with a start timestamp from the
   monotonic `Clock`.
2. The SDK adds common attributes first: `session.id`, `app.screen.name`,
   global attributes (`user.id`, ...). Your attributes come after and win.
3. Attributes go in a plain `Map` (O(1) per set), capped at 128 by default;
   extras are counted as `dropped_attributes_count`. Lists are copied, so a
   list you mutate later can't change recorded data.
4. `end()` stamps the end time once (later calls are ignored) and hands the
   span to the SDK, which queues it only if sampled.

### Context and Zones

`OtelContext` is immutable: active span + baggage. `context.run(fn)` runs
`fn` in a Dart `Zone` holding it, and Zones follow `await`, `Future`,
`Timer`, `Stream` and microtasks. So in

```dart
tracer.traceAsync('a', (_) async {
  await something();
  tracer.startSpan('b');   // parent is 'a', even after the await
});
```

`b` finds `a` without passing anything around. This is the only correct way
to propagate context in Dart.

### Sampling

ParentBased + TraceIdRatio: a child always follows its parent (no
half-recorded traces). For a root span, the low 56 bits of the random trace
id are compared with a threshold. The same trace id always gets the same
decision, which is compatible with W3C Trace Context Level 2 and the
collector's probabilistic sampler.

### Clock

`Clock.nowMicros()` = wall time at start + `Stopwatch` elapsed. Durations are
monotonic, so NTP corrections can't make them negative. The Stopwatch stops
while the device sleeps, so when it drifts more than 1 s from wall time (after
the app was suspended) it re-anchors.

## Metrics

* Instruments are cached by name per meter: `meter.counter('x')` in a hot
  path returns the same object (the original leaked one per call).
* Each instrument keeps a map from attribute set to aggregated point. The key
  is the sorted attributes, typed, so `1` and `"1"` differ.
* **Cardinality limit** 2000 per instrument; beyond it values go to one
  `otel.metric.overflow=true` series, so memory can't grow without bound.
* Collection every `metricInterval` (60 s). If nothing changed since the
  last collection, no request is sent, so an idle app costs nothing.
* **Cumulative** (default): totals since start; works with
  Prometheus/Grafana. **Delta**: changes per interval, points reset after
  export; suits Datadog-style backends.
* Histograms use explicit bucket bounds (inclusive upper bounds, per spec)
  and record count, sum, min and max.

## Logs

`Logger.emit` creates a record with severity, body (string or structured
map), attributes, optional `eventName`, and the **trace/span id of the active
span**. That link lets a backend jump from a log line to its trace. Errors
add `exception.type`, `exception.message` and `exception.stacktrace`.

## Export pipeline

### BatchQueue (spans, logs)

* An item is queued; a timer starts only if none is running, so an idle app
  has **no timers**.
* When 512 items are queued, they are exported **immediately** (the original
  sent at most 512 per 5 s and silently dropped the rest).
* **One export at a time.** While one runs, items keep queuing; the next
  batch follows as soon as it finishes.
* Full queue (2048): new items are dropped and counted, with one warning.
* `pause()` (app backgrounded) cancels the timer; `flush()` drains
  everything.

### OTLP encoding

`ProtoWriter` writes the protobuf wire format directly into one growable
byte buffer: varints, fixed64 timestamps, length-delimited nested messages.
Each nested message reserves one length byte and only shifts its body when
the body reaches 128 bytes. There are no generated classes and no object
graph per span. The resource (service name, OS, ...) never changes, so it is
encoded once at startup and copied into each request. All arithmetic stays
below 2^53, so the same code is exact on the web (JavaScript numbers).

The field numbers come from the official
[opentelemetry-proto](https://github.com/open-telemetry/opentelemetry-proto)
definitions. `test/e2e` checks the output against the real OpenTelemetry
Collector: every attribute type, 64-bit ints, UTF-8, links, events, status,
histograms, and log correlation.

### Compression

gzip on native platforms. Requests over 64 KB are compressed in
`Isolate.run`, so a big batch can't drop a frame. The result comes back via
`Isolate.exit` without a copy. On web, bodies are sent uncompressed.

### OtlpHttpExporter: delivery rules

| Situation | Behaviour |
|---|---|
| 2xx | done; if the disk queue has a backlog, it is sent next |
| network error, timeout, 429, 502, 503, 504 | retried with jittered exponential backoff; `Retry-After` honoured |
| still failing, offline store configured | request written to disk; **circuit opens** |
| circuit open | new requests go straight to disk, **no network attempt** until the backoff (5 s → 5 min) expires; then the oldest file is tried |
| still failing, no store | dropped after 4 attempts and counted |
| other 4xx/5xx | permanent: dropped, with one explanatory warning (404 → wrong path/port, 401 → auth) |
| app goes to background | pending data is written to disk **first**, then sent. If iOS suspends or kills the app mid-request, nothing is lost: it's resent on next launch |

The circuit breaker is what keeps an offline phone from waking the radio
every few seconds.

### OfflineStore (file queue)

One file per request, named `<timestamp>_<seq>.<signal>[.gz]`, so name order
is age order. Files are written to `.tmp` and renamed (atomic: a crash can't
leave half a file). Capped by total size (oldest dropped first) and age.
Stored bytes are exactly what goes on the wire, so resending costs no
encoding. Delivery is at-least-once: a request can be resent if the app died
after the server got it but before the file was deleted. Span ids make such
duplicates easy to spot.

## Flutter integration

| Piece | How |
|---|---|
| Errors | Wraps `FlutterError.onError` and `PlatformDispatcher.onError`, calls the previous handlers, keeps their return value, and restores them on `shutdown`. Rate-limited to 60 logs/min (a broken `build` can throw every frame); the counter still counts all. Error logs trigger an immediate export. |
| Lifecycle | `hidden`/`paused`/`detached` = background: stop all timers, end the screen span, emit `device.app.lifecycle`, urgent flush. `resumed` = foreground: maybe rotate session, restart timers, retry the disk queue. `inactive` (notification shade, incoming call) is ignored. |
| Sessions | `session.id` UUID on every span and log; a new one after `sessionTimeout` in background, with `session.end` / `session.start` (`session.previous_id`) events. |
| Screens | `OtelNavigatorObserver` reacts to push/pop/replace/remove of page routes (dialogs ignored). One `screen <name>` root span per visit, split at background so it measures foreground time only. The name is also put on every span, log, error and frame metric. |
| Frames | `SchedulerBinding.addTimingsCallback`: the engine delivers frame timings in batches, so there's no per-frame cost. Slow = `max(build, raster)` over the display budget (from the actual refresh rate: 60/90/120 Hz). Frozen = 700 ms or more, which also emits an `app.jank` event. |
| UI stalls | Freezes between frames (a slow `onTap`, synchronous JSON decoding) don't show in frame timings. A one-shot 200 ms timer measures event-loop lateness and reports blocks of 500 ms or more as `app.ui.stalls` + `app.jank`. Foreground only. |
| App start | Span from `Otel.init` to `waitUntilFirstFrameRasterized`. Engine startup before `main()` isn't visible from Dart. |

## What it deliberately doesn't do

* **gRPC export**: OTLP/HTTP is supported by every collector and vendor,
  works on web, and avoids the `grpc` + `protobuf` dependencies.
* **The whole semantic-conventions registry as Dart enums** (23k generated
  lines in the original). The few keys used are plain strings; follow
  https://opentelemetry.io/docs/specs/semconv/ for your own.
* **Native crash capture** (signals, ANRs in Java/Swift code). That needs
  platform plugins; use Crashlytics/Sentry alongside if needed. Their
  handlers are chained, not replaced.
* **Exemplars, views, exponential histograms**: rarely needed in apps; easy
  to add later.
