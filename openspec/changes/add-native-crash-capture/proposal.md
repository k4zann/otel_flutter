## Why

Dart errors are captured, but native crashes (Swift/Kotlin/C++ in plugins,
signals such as SIGSEGV), Android ANRs and out-of-memory kills end the
process before any Dart code runs. They are currently invisible, and they are
the most important stability signal for a mobile app (crash-free sessions).

## What Changes

- Add native crash capture as an **optional companion plugin**,
  `otel_flutter_native`, in this repository (`packages/otel_flutter_native/`).
  The core `otel_flutter` package stays pure Dart and web-safe.
- On the next launch, read the crash records the OS provides (Android
  `ApplicationExitInfo`, iOS MetricKit crash diagnostics), plus a chained JVM
  uncaught-exception handler for Android versions without exit-info history.
- Report each crash once as an `app.crash` event, each Android ANR as
  `app.anr`, and every previous-process exit reason as a bounded
  `app.exits` metric. Each report is linked to the session and screen that
  were active when it happened.
- Keep working alongside Crashlytics/Sentry (handlers chained, OS records
  only read).

## Capabilities

### New Capabilities
- `native-crash-reporting`: report native crashes, ANRs and abnormal process
  exits from the previous run on the next launch.

### Modified Capabilities
- `logs`: an explicit null record attribute removes a common attribute, so
  a crash from an earlier run never carries the current `session.id`.
  Dart error reporting is unchanged.

## Impact

- New plugin package with Kotlin (Android) and Swift (iOS) code. Apps add one
  dependency and rebuild natively. No new Dart dependencies in the core.
- Requires Android API 30+ for exit history (degrades to the JVM handler
  below 30), and iOS 14+ for MetricKit (no-op below).
- App size: small native code (tens of KB). Battery/network: work happens
  once per launch, nothing while running.
- Privacy: only exception type, message and stack frames are sent; no
  memory dumps. Stack addresses need symbols (dSYM / R8 mapping) to read.
  Symbolication is out of scope.
