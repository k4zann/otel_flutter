# tracing Specification

## Purpose

Create, sample and propagate spans that describe units of work in a Flutter app, following the OpenTelemetry trace model and W3C Trace Context.

## Requirements

### Requirement: Safe no-op before initialization
The library SHALL accept every tracing call before `Otel.init` and after `Otel.shutdown` without throwing and without recording. Spans created in that state SHALL be non-recording and SHALL carry the parent's context so propagation keeps working. A tracer obtained before initialization SHALL record normally once initialization has completed.

#### Scenario: Span started before init
- **WHEN** a span is started before `Otel.init`
- **THEN** the span is non-recording, nothing is exported and no exception is thrown

#### Scenario: Tracer obtained early, used later
- **WHEN** a tracer is obtained before `Otel.init` and used to start a span after it
- **THEN** that span is recorded and exported

### Requirement: Span lifecycle
A span SHALL record name, kind, start and end timestamps, attributes, events, links and status. Ending a span more than once SHALL export it only once. Changes made after a span has ended SHALL be ignored.

#### Scenario: Span ended twice
- **WHEN** `end()` is called twice on the same span
- **THEN** exactly one copy of the span is exported

#### Scenario: Change after end
- **WHEN** an attribute is set, an event added or the name updated after `end()`
- **THEN** the exported span does not contain the change

### Requirement: Span status rules
Setting `ok` SHALL be final. Setting `unset` SHALL be ignored. A status description SHALL be kept only for `error`.

#### Scenario: Error after Ok
- **WHEN** status is set to `ok` and later to `error`
- **THEN** the exported status is `ok` with no description

### Requirement: Active span across asynchronous code
`trace` and `traceAsync` SHALL make their span active for the callback, including across `await`, timers and microtasks started inside it. When the callback throws, the span SHALL record an `exception` event, get status `error` with the error message, end, and the error SHALL be rethrown. The span SHALL always end.

#### Scenario: Child after await
- **WHEN** a span is started inside `traceAsync` after an `await`
- **THEN** its parent is the `traceAsync` span

#### Scenario: Callback throws
- **WHEN** the callback of `trace` throws
- **THEN** the span has an `exception` event and status `error`, it is ended, and the caller receives the original error

### Requirement: Parent selection
A new span's parent SHALL be the active span unless an explicit context is passed or `newRoot` is set. A child SHALL share its parent's trace id, record the parent span id, and record whether the parent was remote.

#### Scenario: New root inside an active span
- **WHEN** a span is started with `newRoot: true` while another span is active
- **THEN** the new span has a new trace id and no parent span id

### Requirement: Sampling
Sampling SHALL be parent-based: a child SHALL follow its parent's sampled flag. A root span SHALL be sampled when the low 56 random bits of its trace id meet the configured ratio (default 1.0), so the decision is the same for the same trace id. Unsampled spans SHALL be non-recording but SHALL still get valid ids with the sampled flag cleared, so propagation tells downstream services not to sample.

#### Scenario: Ratio zero
- **WHEN** the sample ratio is 0 and a root span is started
- **THEN** it is non-recording, not exported, and its context has a valid trace id with flags `00`

#### Scenario: Statistical ratio
- **WHEN** 20,000 root spans are started with ratio 0.25
- **THEN** between 23% and 27% are sampled

### Requirement: Attribute rules and limits
Attribute values SHALL be string, bool, int, double or a homogeneous list of those. Enums SHALL be stored as their name and other objects as `toString()`. Null values SHALL be ignored. List values SHALL be copied so later mutation by the caller cannot change recorded data. Each span SHALL keep at most 128 attributes, 128 events and 128 links by default, count what it drops, and optionally truncate string values to a configured length. Common attributes (`session.id`, `app.screen.name`, global attributes) SHALL be applied first so a span's own attributes override them.

#### Scenario: Too many attributes
- **WHEN** a span with a limit of 2 attributes receives 3 distinct keys
- **THEN** 2 are kept and the dropped count is 1

#### Scenario: Caller mutates a list afterwards
- **WHEN** a list attribute is set and the caller then appends to the original list
- **THEN** the recorded attribute keeps the original elements

### Requirement: Monotonic timestamps
Span durations SHALL be measured with a monotonic clock so they are never negative. Timestamps SHALL be re-anchored to wall-clock time when the two drift apart by more than one second, which happens after the OS suspends the app.

#### Scenario: Clock adjusted during a span
- **WHEN** the device wall clock moves backwards while a span is open
- **THEN** the exported end time is not earlier than the start time

### Requirement: W3C Trace Context and Baggage propagation
Injection SHALL write `traceparent` as version `00` with lowercase hex ids and the trace flags, copy `tracestate` unchanged, and write `baggage` with percent-encoded values (at most 180 entries and 8192 bytes). Extraction SHALL read headers in any letter case, mark the parent as remote, and ignore malformed input instead of throwing. Extraction SHALL reject version `ff`, all-zero ids and uppercase hex, and SHALL accept higher versions that keep the version-00 layout. Baggage properties after `;` SHALL be dropped and entries with invalid keys or encoding skipped.

#### Scenario: Round trip
- **WHEN** headers with a valid `traceparent`, `tracestate` and `baggage` are extracted and injected again
- **THEN** the injected headers equal the extracted ones

#### Scenario: Malformed header
- **WHEN** `traceparent` contains uppercase hex or an all-zero trace id
- **THEN** extraction yields no parent and does not throw

### Requirement: Random identifiers
Trace ids, span ids and generated UUIDs (session, instance, installation) SHALL come from a cryptographically secure random source and SHALL never be all zeros.

#### Scenario: Uniqueness
- **WHEN** 10,000 span ids are generated
- **THEN** all are distinct and non-zero
