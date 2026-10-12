# logs Specification

## Purpose

Emit structured log records and named events that are linked to the active trace, so a backend can jump from a log line to the trace it belongs to.

## Requirements

### Requirement: Log records
A log record SHALL carry a timestamp, an observed timestamp, a severity (trace 1, debug 5, info 9, warn 13, error 17, fatal 21, with matching upper-case text), an optional body, attributes and an optional event name. The body SHALL be a string, number, bool, list or a nested map (up to 8 levels); other objects SHALL be converted with `toString()`.

#### Scenario: Structured body
- **WHEN** a record is emitted with body `{msg: hi, n: 2}` and severity warn
- **THEN** the exported record has a key-value body with those entries, severity number 13 and text `WARN`

### Requirement: Error details
When an error is passed, the record SHALL get `exception.type`, `exception.message` and, if a stack trace is given, `exception.stacktrace`.

#### Scenario: Error with stack
- **WHEN** `logger.error('failed', error: e, stackTrace: st)` is called
- **THEN** the record contains all three `exception.*` attributes

### Requirement: Trace correlation
A record emitted while a valid span is active SHALL carry that span's trace id, span id and trace flags.

#### Scenario: Log inside a span
- **WHEN** a log is emitted inside `traceAsync('op', ...)`
- **THEN** its trace id and span id equal those of the `op` span

### Requirement: Common attributes
Every record SHALL include `session.id`, the current `app.screen.name` when known, and global attributes. Explicit record attributes SHALL override them.

#### Scenario: Global user id
- **WHEN** `Otel.setUser('u-42')` was called and a log is emitted
- **THEN** the record has `user.id = u-42`

### Requirement: Batching and no-op
Records SHALL be batched and exported like spans (see otlp-export). Emitting before `Otel.init` SHALL do nothing and SHALL not throw.

#### Scenario: Log before init
- **WHEN** `logger.info` is called before init
- **THEN** nothing is queued and no exception is thrown
