## 1. Decision and scaffolding

- [x] 1.1 Confirm with the owner: separate `otel_flutter_native` plugin (design decision 1); verify the decision is recorded in design.md
- [x] 1.2 Create `packages/otel_flutter_native` with `flutter create --template=plugin --platforms=android,ios --org kz.mystartups`, depending on `otel_flutter` by path; verify `flutter analyze` is clean in the new package
- [x] 1.3 Add a `captureNativeCrashes` flag (default true) and a public hook in `otel_flutter` so the plugin can register at init without the core importing it; verify core tests still pass and the core still has only `http` and `meta` as dependencies

## 2. Session context persistence (Dart)

- [x] 2.1 Write `{session.id, app.screen.name, time}` to `<offlineStorageDirectory>/otel_flutter_context.json` on session start and screen change, debounced to 1 write/s and asynchronous; verify a unit test checks file content after navigation
- [x] 2.2 Keep the previous run's context file for crash attribution (rotate to `.prev` at init); verify a unit test covers rotation

## 3. Android

- [x] 3.1 Implement `getPendingCrashes()`: read `getHistoricalProcessExitReasons` (API 30+), map reasons to `crash | native_crash | anr | low_memory | user_request | os_update | other`, attach the ANR trace and description, and for native crashes decode the tombstone (signal name, abort message, crashing thread's frames with build ids); verify with an instrumented test or a manual run on an API 34 emulator (done on the API 36 emulator, the only AVD available: JVM crash, SIGSEGV with tombstone, ANR, force stop, reinstall)
- [x] 3.2 On all API levels, add a chained JVM uncaught-exception handler that writes `{type, message, stack, time, pid}` to a crash file, then calls the previous handler; use it as the record below API 30 and to enrich the matching `REASON_CRASH` record (by pid) on API 30+; verify the previous handler is still invoked (Robolectric/unit test)
- [x] 3.3 Persist the newest processed exit timestamp (SharedPreferences); verify a second call returns nothing

## 4. iOS

- [ ] 4.1 Subscribe to `MXMetricManager` at plugin registration; store received `MXCrashDiagnostic` payloads (signal, exception type/code, call stack tree JSON, time) to a file; verify with Xcode's "Simulate MetricKit Payloads" on a device
- [x] 4.2 Implement `getPendingCrashes()` returning stored diagnostics, then mark them processed; verify a second call returns nothing

## 5. Reporting (Dart side of the plugin)

- [ ] 5.1 At init, call `getPendingCrashes()`, join each record with the previous context file by time, and emit `app.crash` / `app.anr` (FATAL, `exception.*`, crash time, previous `session.id` and `app.screen.name`); verify widget tests with a mocked MethodChannel cover crash, ANR and missing context
- [ ] 5.2 Increment `app.exits` with `app.exit.reason`; verify the metric test checks the bounded value set
- [ ] 5.3 Make every channel failure a silent no-op (never throw into the app); verify a test with a throwing channel

## 6. End-to-end verification

- [ ] 6.1 Add a "Native crash" button to the example (Kotlin `throw RuntimeException`, Swift `fatalError` via a small method channel); crash, relaunch, and verify one `app.crash` reaches the collector with the right `session.id` and screen
- [ ] 6.2 Trigger an ANR on the Android emulator (block the main thread ~10 s via the channel), relaunch, and verify `app.anr` arrives once
- [ ] 6.3 Install Firebase Crashlytics in a scratch copy of the example; verify both Crashlytics and `app.crash` record the same Kotlin crash

## 7. Docs and checks

- [ ] 7.1 Promote the delta spec to `openspec/specs/native-crash-reporting/spec.md` at archive; update README (installation, limits, symbolication note) and AGENTS.md (layout, backlog); verify `openspec validate --all --strict` passes
- [ ] 7.2 Verify `flutter analyze` is clean and `flutter test` is green in both packages, and run `test/e2e` against a collector
