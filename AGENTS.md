# AGENTS.md: otel_flutter

The single source of truth for agents. Read this first; it should be all the
context you need for most tasks. Go deeper only when the task calls for it:

1. `openspec/specs/<capability>/spec.md` for the required behavior of the area
   you touch (the specs are the behavior contract).
2. `openspec/changes/<id>/` for the planned work you were asked to do.
3. `docs/HOW_IT_WORKS.md` only for deep internals (human-oriented, long).
4. `docs/ORIGINAL_ANALYSIS.md` only if asked about the Dartastic packages this
   project replaced.

Keep this file current: update it in the same change whenever structure,
commands, invariants or the backlog change.

## What this is

A lean OpenTelemetry SDK for Flutter apps. It sends traces, metrics and logs
over OTLP/HTTP protobuf to any OpenTelemetry backend, and captures errors,
screens, frames, UI stalls, app start, sessions and HTTP calls automatically.

* Written from scratch from the OpenTelemetry spec and opentelemetry-proto.
  It contains no Dartastic code.
* Version 0.1.0, created 2026-10-12. Public git repo at
  https://github.com/k4zann/otel_flutter (branch `main`).
* License: Apache-2.0, `Copyright 2026 The otel_flutter Authors` (root
  `LICENSE`; the plugin has an identical copy). Not on pub.dev yet; the
  core pubspec has its publishing metadata (`repository`/`homepage`, no
  `publish_to`) and `pub publish --dry-run` reports no license or metadata
  errors. The plugin keeps `publish_to: none` until its path
  dependency on `otel_flutter` can become a hosted version. No third-party
  code, so no NOTICE file.
* Verified: 87 unit/widget tests (+4 in `otel_flutter_native`); end-to-end
  against the official OpenTelemetry Collector 0.162.0 (33 field checks
  plus an offline-restart test); example app run on the iOS simulator
  (iPhone 16e, iOS 26.1); `flutter build web` compiles. Native crash and
  ANR reports verified end-to-end on the Android API 36.1 emulator
  (profile build). **Not yet verified on a real device or in a browser;
  the core SDK has had no full Android pass yet.**

## Commands

Flutter is **not on PATH**; use fvm's binary:

```bash
FLUTTER=~/fvm/versions/3.44.2/bin/flutter   # Flutter 3.44.2 / Dart 3.12.2
$FLUTTER analyze                            # must report "No issues found!"
$FLUTTER test                               # 87 pass, 2 skipped (e2e)
(cd packages/otel_flutter_native && $FLUTTER test)  # plugin: 4 pass
OTEL_E2E_ENDPOINT=http://127.0.0.1:4318 $FLUTTER test test/e2e   # needs a collector
cd example && $FLUTTER build ios --simulator --debug             # then launch Runner.app
openspec list                     # open changes (the backlog)
openspec validate --all --strict  # must pass after editing specs/changes
```

Local collector without Docker: download `otelcol` for darwin_arm64 from
github.com/open-telemetry/opentelemetry-collector-releases (verify the
`.sha256`), run `./otelcol --config backend/otel-collector.yaml`. To inspect
decoded data, add a `file` exporter. Docker is not installed on this Mac.

## Layout

```
lib/otel_flutter.dart        public API: only what is listed in `show` is exported
lib/src/otel.dart            Otel facade: init/shutdown, installs Flutter hooks
lib/src/config.dart          OtelConfig (all options + defaults), --dart-define parsing
lib/src/sdk.dart             OtelSdk: queues, exporter, resource, session; implements Pipeline
lib/src/core/                clock (monotonic), ids (CSPRNG), attributes (rules/limits),
                             context (Zones), scope, diagnostics (print-once), pipeline (API<->SDK seam)
lib/src/trace/               span, tracer (trace/traceAsync), sampler, propagation (W3C)
lib/src/metrics/meter.dart   instruments, aggregation, MeterRegistry (global, pre-init safe)
lib/src/logs/                logger, log_record (Severity)
lib/src/export/              proto_writer (wire format), otlp_encoder, batch_queue,
                             otlp_http_exporter (retry/circuit breaker), offline_store (interface)
lib/src/platform/            platform_io.dart (gzip, file queue, OS info) | platform_stub.dart (web)
lib/src/flutter/             errors, lifecycle, screens (NavigatorObserver), frames (+ StallDetector)
lib/src/http/                OtelHttpClient (package:http wrapper)
test/                        unit + widget tests; test/support/proto_reader.dart decodes protobuf
test/e2e/                    real-collector tests (skipped unless OTEL_E2E_ENDPOINT is set)
example/                     demo app (buttons for every feature, incl. native crash and ANR;
                             uses path_provider and otel_flutter_native)
packages/otel_flutter_native/  optional plugin: native crashes, ANRs, exit reasons on next launch
                             (Kotlin ApplicationExitInfo + JVM handler, Swift MetricKit; Dart
                             side registers via dartPluginClass + Otel.registerNativeCrashReporter)
backend/                     docker-compose (Grafana LGTM, optional Jaeger) + plain collector config
openspec/specs/              behavior specs: tracing, metrics, logs, otlp-export, offline-delivery,
                             error-reporting, app-lifecycle, screen-tracking, ui-performance,
                             http-client, configuration
```

## Data flow (one paragraph)

The API classes (`Tracer`, `Meter`, `Logger`) check `Pipeline.current`
(null means no-op) on every call. Ended spans and emitted logs go to a
`BatchQueue` (sent at 512 items or 5 s; one export at a time; no timer while
empty). Metrics aggregate in their instruments and are collected every 60 s
in the foreground; nothing is sent if nothing changed. `OtlpEncoder` writes
protobuf directly through `ProtoWriter`, with the resource pre-encoded once.
Bodies are gzipped (on an isolate when over 64 KB) and POSTed by
`OtlpHttpExporter` to `/v1/{traces,metrics,logs}`. On failure: retry, then
the disk queue plus a circuit breaker. On app background: timers stop and
pending data goes to disk first, then is sent.

## Invariants: do not break

1. **Never throw into app code** from telemetry paths. Everything is a no-op
   before `Otel.init`. Bad input is converted or dropped with a print-once
   warning (`Diagnostics.warnOnce`). Only `init` with an invalid endpoint
   throws.
2. **No idle work.** No timers or requests when nothing is pending. The only
   periodic timers are metrics (60 s) and the stall detector (200 ms), both
   foreground-only.
3. **Dependencies: `http` and `meta` only.** A new dependency needs an
   OpenSpec design.md justifying it.
4. **Web safety.** `dart:io` only in `lib/src/platform/*_io.dart`. Encoder
   arithmetic stays below 2^53: no 64-bit bitwise ops (JavaScript `&`/`>>`
   are 32-bit).
5. **Wire format** follows opentelemetry-proto field numbers. Any change to
   `proto_writer`/`otlp_encoder`/exporter must pass `test/e2e` against a real
   collector. Oneof defaults (`0`, `false`, `""`) must be written explicitly.
6. **Chain, don't replace** global handlers (`FlutterError.onError`,
   `PlatformDispatcher.onError`), and restore them on shutdown.
7. **Privacy.** Never record route arguments, URL query strings (unless
   opted in), credentials or host name. Metric attributes must be bounded
   (cardinality cap 2000).
8. **Public API surface** = `show` lists in `lib/otel_flutter.dart`. Internals
   are `@internal` in `lib/src`.
9. **Bounded memory.** Queue 2048, 128 attributes/events/links, offline cap
   5 MB / 2 days.

## Conventions

* Comments explain *why*. Doc comments on public API. Match the existing
  style: small final classes, no codegen.
* Tests: `flutter_test`; `fake_async` for timers; `MockClient`
  (`package:http/testing`) for HTTP; `Msg` in `test/support/proto_reader.dart`
  to assert encoded protobuf; `FakePipeline` / `MemoryStore` in
  `test/support/fakes.dart`.
* In `testWidgets`, call `Otel.shutdown()` **inside** the test body (see
  `otelTest` in `test/flutter_integration_test.dart`). Otherwise pending
  timers fail the test.
* Behavior changes go through OpenSpec: `/opsx:propose` → `/opsx:apply` →
  `/opsx:archive`. Specs describe observable behavior, not class names.
  Update the matching spec in the same change.
* Before finishing any task: `$DART format .` (no changes), `$FLUTTER analyze`
  clean (infos count) and `$FLUTTER test` green. Run e2e if export code
  changed. `DART=~/fvm/versions/3.44.2/bin/dart`; the version is pinned in
  `.fvmrc`.
* CI (`.github/workflows/ci.yml`, every PR and push to `main`) enforces it:
  format, analyze with infos/warnings fatal, all Dart tests including e2e
  against a collector container, the plugin's Kotlin tests
  (`-Potel.warningsAsErrors`) and Swift tests (warnings in its sources
  fail). On PRs the Kotlin/Swift jobs run only when the plugin's
  `android/`/`ios/` code (or its example's), the plugin pubspecs or
  lockfiles, `.fvmrc` or `ci.yml` change; Dart- or docs-only PRs skip them.
  The `CI passed` job fails if any job failed or was cancelled and is the
  one check to require for merging. `.githooks/pre-commit` runs the format
  and analyze checks locally; enable once per clone with
  `git config core.hooksPath .githooks`.

## Gotchas learned the hard way

* **iOS `FrameTiming.vsyncOverhead`** is a constant ~17 ms (one frame), an
  artifact. Don't use it for jank. UI freezes between frames come from the
  StallDetector instead.
* Flutter `print` on iOS goes to the system log, not stdout:
  `xcrun simctl spawn booted log show --last 2m --predicate 'process == "Runner"'`.
* Creating more than 2048 spans in one synchronous loop overflows the queue
  (by design: bounded memory). Exports only run once the loop yields.
* `testWidgets` swaps the HTTP client for one that answers 400 → use
  `OtelConfig.httpClient: MockClient(...)`.
* The collector `file` exporter keeps its offset: truncating its output file
  leaves NUL bytes. Delete the file and restart instead.
* ANR testing on the emulator: a frozen app only gets an ANR *exit* record
  if "Close app" is pressed on the dialog (it closes itself when the
  freeze ends, and ignores taps for its first second). `adb shell input
  tap` into a frozen app blocks every later injected tap; trigger the ANR
  with `input keyevent --async KEYCODE_SPACE` instead. The example freezes
  for 20 s for this reason.
* The `Medium_Phone_API_36.1` AVD's data partition is full; native-crash
  runs used a separate `otel_test` AVD (8 GB) with a profile build (debug
  APK is 142 MB; profile manifest allows cleartext to the local collector).
* Android emulator → host is `10.0.2.2`; plain http needs
  `usesCleartextTraffic` (debug manifest) and, on iOS,
  `NSAllowsLocalNetworking`. Release Android needs the INTERNET permission
  (all three are already set in `example/`).
* CI's Swift job: the Runner scheme marks `RunnerTests` parallelizable, so
  plain `xcodebuild test` clones the simulator and cold-boots the clone
  (3 to 6.5 min; the tests take 0.01 s). CI passes
  `-parallel-testing-enabled NO` (testing then takes ~100 s). Boot the
  simulator only after `build-for-testing`: booting it at the start of the
  job, alongside the Flutter setup, made that setup take 172 to 288 s
  instead of 33 to 96 s and tripled the build (runners have 3 CPUs).

## Backlog (OpenSpec changes, `openspec list`)

| Change | Goal |
|---|---|
| `verify-android-and-real-devices` | Run on Android emulator + real iPhone/Android; record results; fix what breaks |
| `run-local-grafana-backend` | Container runtime, run `backend/docker-compose.yml`, provision a Flutter health dashboard |
| `add-native-crash-capture` | Native crashes/ANRs as `app.crash`/`app.anr` on next launch. Done except 4.1 (MetricKit on a real iPhone); Crashlytics coexistence verified |
| `add-web-compression` | gzip on web via the browser's CompressionStream |
| `choose-project-license` | Done: Apache-2.0 applied (core + plugin); remove this row at archive |
| `production-collector-deployment` | Hardened collector config + deploy guide; keep vendor keys out of the app |

Known small gaps (not yet in a change): the offline-retry timer is not paused
in background; web has no offline queue; app start is measured from
`Otel.init`, not from process start.
