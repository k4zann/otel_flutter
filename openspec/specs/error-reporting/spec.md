# error-reporting Specification

## Purpose

Capture Flutter framework errors, uncaught asynchronous errors and manually reported errors as logs and metrics, without breaking other crash reporters.

## Requirements

### Requirement: Automatic capture
When error capture is enabled (default), Flutter framework errors SHALL be reported with severity ERROR and `app.error.source = flutter_framework` (plus `flutter.error.library` and `flutter.error.context` when known). Uncaught asynchronous errors SHALL be reported with severity FATAL and `app.error.source = uncaught`.

#### Scenario: Build error
- **WHEN** a widget throws during build
- **THEN** an ERROR log with source `flutter_framework` and a stack trace is exported

#### Scenario: Uncaught async error
- **WHEN** a Future throws and nothing handles it
- **THEN** a FATAL log with source `uncaught` is exported and the app keeps running

### Requirement: Handler chaining
Installing capture SHALL keep previously installed handlers working: the previous framework handler SHALL be called for every error, and the previous platform handler's return value SHALL be returned (false when none was installed). Shutdown SHALL restore the previous handlers if ours are still installed.

#### Scenario: Existing crash reporter
- **WHEN** another reporter had set the platform error handler before `Otel.init` and it returns true
- **THEN** it is still called once per error and true is returned to the engine

### Requirement: Manual reporting
`Otel.recordError` SHALL report caught errors with `app.error.source = manual`, an optional fatal flag and extra attributes. It SHALL work even when automatic capture is disabled.

#### Scenario: Caught parse error
- **WHEN** `Otel.recordError(e, st)` is called inside a catch block
- **THEN** an ERROR log with source `manual` is exported

### Requirement: Error content
Each reported error SHALL produce a log whose body is the first line of the message (at most 300 characters), with `exception.type`, `exception.message`, `exception.stacktrace`, `session.id` and `app.screen.name`. It SHALL also increment counter `app.errors` with `error.type`, `app.error.source` and `app.screen.name`.

#### Scenario: Error on a screen
- **WHEN** an error occurs while screen `/details` is shown
- **THEN** both the log and the `app.errors` point carry `app.screen.name = /details`

### Requirement: Flood protection and prompt export
At most 60 error logs per minute SHALL be emitted; further errors SHALL still be counted in `app.errors`, and one warning SHALL be printed. Error logs SHALL be exported immediately rather than after the batch delay.

#### Scenario: Error every frame
- **WHEN** 200 errors happen within a minute
- **THEN** 60 error logs are exported and `app.errors` counts 200
