## Purpose

Report native crashes, ANRs and abnormal process exits that kill the app before Dart code can react, on the next launch, linked to the session and screen where they happened.

## ADDED Requirements

### Requirement: Crash reports on next launch
When the native companion plugin is installed and the previous process ended in a JVM crash, a native crash (signal) or an uncaught Objective-C/Swift exception, the SDK SHALL emit exactly one `app.crash` log event with severity FATAL on the next launch. The event SHALL carry `exception.type` (exception class or signal name), `exception.message`, `exception.stacktrace` as provided by the OS, the crash time as its timestamp, and the `session.id` and `app.screen.name` that were active when the crash happened.

#### Scenario: Kotlin crash
- **WHEN** a Kotlin plugin throws an uncaught exception, the app dies, and the user relaunches it
- **THEN** one `app.crash` event with the exception class, message and stack is exported, carrying the previous session's id

#### Scenario: Native signal on iOS
- **WHEN** the app crashes with SIGSEGV on iOS 15+ and is relaunched
- **THEN** one `app.crash` event with `exception.type = SIGSEGV` is exported once the OS delivers the diagnostic

### Requirement: ANR reports
On Android, when the previous process was killed for not responding, the SDK SHALL emit one `app.anr` event with severity FATAL, the OS-provided main-thread stack, the exit time, and the previous `session.id`.

#### Scenario: Frozen main thread
- **WHEN** the main thread was blocked until Android killed the app, and the app is relaunched
- **THEN** one `app.anr` event is exported

### Requirement: Exit reasons metric
On launch, the SDK SHALL count the previous process's exit reason in counter `app.exits` with attribute `app.exit.reason` limited to `crash`, `native_crash`, `anr`, `low_memory`, `user_request`, `os_update` and `other`, where the platform provides this information.

#### Scenario: Low-memory kill
- **WHEN** Android killed the backgrounded app for memory and the user relaunches it
- **THEN** `app.exits` is incremented with `app.exit.reason = low_memory` and no `app.crash` event is emitted

### Requirement: Exactly-once reporting
Each OS crash record SHALL be reported once, even across multiple launches, app updates or a failed export (the report SHALL go through the normal offline delivery).

#### Scenario: Second relaunch
- **WHEN** the app is launched twice after a single crash
- **THEN** only the first launch reports the crash

### Requirement: Coexistence and safety
The plugin SHALL only read OS-provided records and SHALL chain to any previously installed JVM uncaught-exception handler, so other crash reporters keep working. It SHALL install no signal handlers. On web and desktop it SHALL do nothing.

#### Scenario: Crashlytics installed
- **WHEN** Crashlytics is installed and a Kotlin crash occurs
- **THEN** Crashlytics still records the crash and `app.crash` is also reported on next launch

### Requirement: Opt-out
Native crash capture SHALL be enabled by installing the companion plugin and SHALL be disableable with a configuration flag without uninstalling it.

#### Scenario: Disabled
- **WHEN** native crash capture is disabled in the configuration
- **THEN** no `app.crash`, `app.anr` or `app.exits` telemetry is produced
