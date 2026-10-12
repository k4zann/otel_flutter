# otel_flutter

Lean OpenTelemetry for Flutter apps: **traces, metrics and logs** sent over
standard **OTLP/HTTP** to any backend (Grafana, Jaeger, SigNoz, Honeycomb,
Datadog via a collector, ...). No vendor, no account, no API key required.

* ~4k lines, two dependencies (`http`, `meta`): no gRPC, no protobuf codegen.
* Built for phones: works offline (disk queue), flushes when the app goes
  to background, never wakes the device when idle.
* Captures crashes, screens, slow/frozen frames, UI freezes, app start time,
  sessions and HTTP calls automatically.

How it works inside: [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md).
Why it was written and what was wrong with the Dartastic packages:
[docs/ORIGINAL_ANALYSIS.md](docs/ORIGINAL_ANALYSIS.md).

---

## 1. Quick start

```yaml
# pubspec.yaml
dependencies:
  otel_flutter:
    path: ../otel_flutter        # or a git URL
  path_provider: ^2.1.0          # optional, for the offline queue
```

```dart
import 'package:flutter/material.dart';
import 'package:otel_flutter/otel_flutter.dart';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Otel.init(OtelConfig(
    serviceName: 'my_app',
    serviceVersion: '1.4.0',
    environment: 'production',
    endpoint: 'https://otel.my-company.com',       // your collector
    offlineStorageDirectory: (await getApplicationSupportDirectory()).path,
  ));
  runApp(MaterialApp(
    navigatorObservers: [OtelNavigatorObserver()],  // screen tracking
    // ...
  ));
}
```

That's it. Everything below is captured without more code.

## 2. What you get automatically

| Signal | What | Name |
|---|---|---|
| Logs | Flutter framework errors (`FlutterError.onError`) | severity ERROR, `app.error.source=flutter_framework` |
| Logs | Uncaught async errors (`PlatformDispatcher.onError`) | severity FATAL, `app.error.source=uncaught` |
| Metric | Error count by type and screen | `app.errors` |
| Span | Time spent on each screen (foreground only) | `screen <route name>` |
| All | Current screen on every span/log | `app.screen.name` |
| Metrics | Rendered / slow / frozen frames, frame time histogram | `app.frames`, `app.frames.slow`, `app.frames.frozen`, `app.frame.duration` |
| Metric + log | UI thread blocked >= 500 ms (slow tap handler, sync parsing) | `app.ui.stalls`, event `app.jank` |
| Span + metric | `Otel.init` to first frame | `app.start`, `app.start.duration` |
| Logs | Session start/end, background/foreground | events `session.start`, `session.end`, `device.app.lifecycle` |
| All | Session id (new after 30 min in background) | `session.id` |
| Resource | Service, version, environment, OS, install id | `service.*`, `os.*`, `app.installation.id` |

Existing error handlers (Crashlytics, Sentry, the red error screen) keep
working: `otel_flutter` chains onto them instead of replacing them.

### Native crashes, ANRs and exit reasons (optional plugin)

Crashes in Kotlin/Swift/C++ code, signals such as SIGSEGV, Android ANRs and
low-memory kills end the process before Dart can react. The companion
plugin [`otel_flutter_native`](packages/otel_flutter_native) reads what the
OS recorded about them and reports it **on the next launch**. Add it and
rebuild the app; no code needed:

```yaml
dependencies:
  otel_flutter_native:
    path: ../otel_flutter/packages/otel_flutter_native   # or a git URL
```

| Signal | What | Name |
|---|---|---|
| Log | JVM crash, native crash (signal), uncaught Objective-C/Swift exception: FATAL, `exception.*`, crash time | event `app.crash` |
| Log | Android ANR, with the main thread's stack | event `app.anr` |
| Metric | How the previous process ended: `crash`, `native_crash`, `anr`, `low_memory`, `user_request`, `os_update`, `other` | `app.exits` by `app.exit.reason` |

* Each report carries the `session.id` and `app.screen.name` of the run
  that crashed (needs `offlineStorageDirectory`). Each OS record is reported
  once.
* Android: full history on API 30+ (`ApplicationExitInfo`); below 30 only
  JVM crashes. iOS 14+ (MetricKit): delivered shortly after the next launch
  on iOS 15+, in a daily batch on iOS 14. MetricKit does not run in the
  simulator.
* Coexists with Crashlytics/Sentry: it only reads OS records and chains the
  JVM handler; no signal handlers. Does nothing on web and desktop.
* Stacks are not symbolicated. Frames carry build ids / image UUIDs, so they
  can be resolved later with your R8 mapping or dSYMs.
* Turn it off without uninstalling: `captureNativeCrashes: false`.

## 3. What it needs to connect

Only an **OTLP/HTTP endpoint**: an OpenTelemetry Collector or any backend
that speaks OTLP, usually on **port 4318**. The SDK posts to
`<endpoint>/v1/traces`, `/v1/metrics` and `/v1/logs`.

### Free, local (for development)

```bash
cd backend && docker compose up -d   # Grafana + Tempo + Loki + Prometheus
```

Open http://localhost:3000, then **Explore**: Tempo for traces, Loki for
logs, Prometheus for metrics. No Docker? Run the plain collector (prints
everything to the terminal):

```bash
./otelcol --config backend/otel-collector.yaml
```

Which address the app should use:

| App runs on | Endpoint |
|---|---|
| iOS simulator, macOS, web | `http://localhost:4318` |
| Android emulator | `http://10.0.2.2:4318` |
| Real phone (same Wi-Fi) | `http://<your-computer-LAN-IP>:4318` |

Plain `http://` needs a debug exception: Android
`android:usesCleartextTraffic="true"` in `src/debug/AndroidManifest.xml`,
iOS `NSAllowsLocalNetworking` in `Info.plist`. The example app has both.
Android release builds also need
`<uses-permission android:name="android.permission.INTERNET"/>` in the main
manifest.

### Production

Recommended: run your **own collector** (one small container, free) and point
the app at it. The collector forwards to whatever backend you choose and holds
the vendor API key, so no secret ships inside the app. See the `otlphttp`
example in [backend/otel-collector.yaml](backend/otel-collector.yaml).

Direct to a vendor also works, using its OTLP endpoint and headers:

```dart
OtelConfig(
  serviceName: 'my_app',
  endpoint: 'https://otlp-gateway-prod-eu-west-2.grafana.net/otlp',
  headers: {'Authorization': 'Basic <base64 instanceId:token>'},
)
```

Anything inside an app binary can be extracted. If you go direct, use a
write-only ingestion token.

Endpoint and headers can also come from the build instead of code (standard
OpenTelemetry names):

```bash
flutter run \
  --dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=https://otel.my-company.com \
  --dart-define=OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer%20abc
```

## 4. Manual instrumentation

```dart
final tracer = Otel.tracer('checkout');
final logger = Otel.logger('checkout');
final orders = Otel.meter('checkout').counter('orders', unit: '{order}');

Future<void> pay(Cart cart) => tracer.traceAsync('pay', (span) async {
      span.setAttribute('cart.items', cart.items.length);
      await api.charge(cart);           // child spans attach automatically
      orders.add(1, {'payment.method': 'card'});
      logger.info('Payment done');      // linked to this trace
    });
```

* `trace` / `traceAsync` make the span active, record exceptions, set error
  status and always end the span. Or use `startSpan` + `end()` yourself.
* Metrics: `counter`, `upDownCounter`, `histogram`, `gauge`,
  `observableGauge`. Keep attribute values bounded (no user ids or URLs as
  metric attributes); each metric is capped at 2000 attribute combinations.
* `Otel.recordError(e, st)` for errors you catch yourself.
* `Otel.setUser('id')` / `Otel.setGlobalAttribute(k, v)` add attributes to
  all telemetry.
* All of this is a no-op before `Otel.init`, so libraries can be instrumented
  safely.

### HTTP calls

```dart
final client = OtelHttpClient();   // wraps package:http
await client.get(Uri.parse('https://api.example.com/items'));
```

Each request becomes a CLIENT span plus `http.client.request.duration`, and
sends a `traceparent` header so backend spans join the same trace. Query
strings are dropped from `url.full` by default. Limit propagation with
`propagateTo: (uri) => uri.host.endsWith('my-company.com')`, which matters on
web, where foreign servers may reject the header (CORS).

Using **Dio**? Add the header yourself:

```dart
dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
  final headers = <String, String>{};
  Otel.injectTraceHeaders(headers);
  o.headers.addAll(headers);
  h.next(o);
}));
```

### go_router

No dependency needed: `GoRouter(observers: [OtelNavigatorObserver()])`. Give
routes a `name:` (or pass `screenName: (route) => ...`) so screens get
readable names.

## 5. Configuration

| Option | Default | |
|---|---|---|
| `serviceName` | required | `service.name` |
| `serviceVersion`, `environment` | null | `service.version`, `deployment.environment.name` |
| `endpoint` | `--dart-define` or `http://localhost:4318` | OTLP/HTTP base URL |
| `tracesEndpoint` / `metricsEndpoint` / `logsEndpoint` | null | full URLs, used as-is |
| `headers` | `{}` | auth headers |
| `resourceAttributes` | `{}` | e.g. `device.model.name` from device_info_plus |
| `sampleRatio` | 1.0 | share of traces kept |
| `offlineStorageDirectory` | null | enables the disk queue + `app.installation.id` |
| `maxOfflineStorageBytes` / `maxOfflineAge` | 5 MB / 2 days | queue caps |
| `exportDelay` | 5 s | batching delay (full batches go immediately) |
| `maxQueueSize` / `maxExportBatchSize` | 2048 / 512 | in-memory bounds |
| `metricInterval` | 60 s | nothing is sent if nothing changed |
| `metricTemporality` | cumulative | `delta` for Datadog-style backends |
| `compression` | true | gzip (native) |
| `sessionTimeout` | 30 min | background time before a new session |
| `captureErrors` / `captureFrames` / `captureStalls` / `captureAppStart` / `captureLifecycle` | true | automatic instrumentation |
| `captureNativeCrashes` | true | native crash reports when `otel_flutter_native` is installed |
| `debug` | false | print one line per export and every problem |
| `httpClient` | null | custom client, e.g. for self-signed certs / mTLS |

## 6. Troubleshooting

Turn on `debug: true`. Each problem is printed once with a hint:

* `Cannot reach ...`: wrong host for the emulator or phone (see the table in
  section 3), the collector isn't running, or cleartext http is blocked.
* `HTTP 404`: wrong path or port. OTLP/HTTP is port 4318; 4317 is gRPC.
* `HTTP 401/403`: missing or wrong auth header.
* Nothing in Grafana: data is batched for 5 s; `Otel.flush()` sends it
  immediately.

## 7. Development

Project context for contributors and AI agents: [AGENTS.md](AGENTS.md).
Behavior specs and the backlog (planned changes with tasks) live in
[openspec/](openspec/): run `openspec list`.

```bash
flutter test                                             # 87 unit + widget tests
OTEL_E2E_ENDPOINT=http://localhost:4318 flutter test test/e2e   # against a real collector
cd example && flutter run                                # demo app
cd packages/otel_flutter_native && flutter test          # native crash plugin
```

CI checks every pull request: formatting (`dart format`), the analyzer with
infos and warnings treated as errors, all tests (including end-to-end against
a real collector, and the plugin's Kotlin and Swift tests). Run the same
format and analyzer checks before each commit with the bundled hook:

```bash
git config core.hooksPath .githooks   # once per clone
```

## 8. License

Apache License 2.0: see [LICENSE](LICENSE). Copyright 2026 The otel_flutter
Authors. The `otel_flutter_native` plugin in `packages/` uses the same
license.
