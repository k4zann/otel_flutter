## Context

Dart errors already flow through `ErrorReporter` (see the `error-reporting`
spec). Native crashes kill the process, so no Dart code can report them while
it happens; the only safe time is the next launch. The core package is pure
Dart with two dependencies and must stay web-safe (AGENTS.md invariants 3
and 4).

## Goals / Non-Goals

**Goals:** report previous-run crashes, ANRs and exit reasons once, linked to
session and screen, with no runtime cost and no conflict with other crash
reporters.

**Non-Goals:** symbolication (dSYM / R8 mapping upload and server-side
lookup), live in-process signal handling, desktop/web crashes, crash
grouping (the backend's job).

## Decisions

1. **Separate companion plugin `otel_flutter_native`** in
   `packages/otel_flutter_native/`, depending on `otel_flutter`.
   *Alternative:* turn `otel_flutter` itself into a plugin. Rejected: it
   would force native builds on every user, break the pure-Dart/web-safe
   invariant, and add platform code to a package that doesn't need it.
   **Confirmed by the owner on 2026-10-12.** It changes the repo layout to
   a small monorepo.
2. **OS-provided records, not signal handlers.**
   - Android: `ActivityManager.getHistoricalProcessExitReasons` (API 30+)
     for crash, native crash, ANR (with `getTraceInputStream` for the ANR
     stack) and low-memory kills.
   - Android native crashes (API 31+): the record itself says only
     `description=crash`, `status=0` (verified on API 36). The signal name,
     abort message and backtrace (with build ids) are read from the
     tombstone that `getTraceInputStream` returns, a protobuf decoded by a
     small built-in reader (no dependency).
   - Android JVM crashes: the record has no exception class, message or
     stack on any API level (verified on API 36: `trace=null`). A chained
     `Thread.setDefaultUncaughtExceptionHandler`, installed on **all** API
     levels, writes a small crash file (with the pid) before delegating. On
     API 30+ it enriches the matching `REASON_CRASH` record; below 30 it is
     the only source.
   - iOS: MetricKit `MXCrashDiagnostic` via `MXMetricManagerSubscriber`
     (iOS 14+; delivered on next launch on iOS 15+).

   *Alternatives:* KSCrash / PLCrashReporter (async-signal-safe C handlers
   with a large surface, conflicts with other reporters), or depending on
   Crashlytics/Sentry (vendor lock-in, which is what this project avoids).
3. **Session/screen attribution**: the Dart side writes the current
   `session.id` and screen name to a tiny file in the app support directory on
   every change (rare events, about one write per navigation). On the next
   launch the native side returns crash records, and Dart joins them with the
   saved context whose time range contains the crash time.
4. **Exactly-once**: persist the newest processed record timestamp per
   platform; process only newer records.
5. **Transport**: a single `MethodChannel` call `getPendingCrashes()` at init
   returns plain maps. Dart emits them through the existing Logger and Meter,
   so offline delivery, batching and resources are reused unchanged.

## Risks / Trade-offs

- [MetricKit on iOS 14 delivers diagnostics only in daily batches] → accept
  the delay; document it.
- [Unsymbolicated stacks are hard to read] → include image UUIDs / build ids
  so a later symbolication change can resolve them.
- [Saving session context on every navigation costs a file write] → write
  asynchronously, debounce to at most one write per second, at most a few
  hundred bytes.
- [OEM Android builds may report odd exit reasons] → map unknown values to
  `other`, which keeps `app.exit.reason` bounded.

## Open Questions

- Report "abnormal exit while in foreground" on iOS (a possible OOM or watchdog
  kill) from a clean-shutdown marker? Deferred: it can be added later
  without changing these specs.
