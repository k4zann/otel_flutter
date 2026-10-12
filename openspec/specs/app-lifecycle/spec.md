# app-lifecycle Specification

## Purpose

React to the app moving between foreground and background so buffered telemetry is not lost when the OS suspends or kills the app, timers do not drain the battery, and user sessions are identified.

## Requirements

### Requirement: Background handling
When lifecycle capture is enabled (default) and the app becomes hidden, paused or detached, the SDK SHALL stop its batching, metric-collection and stall-detection timers, end the current screen span, emit a `device.app.lifecycle` event on iOS and Android with state `background`, and flush all pending telemetry urgently. The transient `inactive` state SHALL be ignored.

#### Scenario: User presses Home
- **WHEN** the app is paused with spans still waiting for the batch delay
- **THEN** those spans are exported (or written to disk) right away and no batching, metric or stall timer keeps running

#### Scenario: Notification shade
- **WHEN** the app becomes inactive and then resumed without being hidden
- **THEN** nothing is flushed and no lifecycle event is emitted

### Requirement: Foreground handling
When the app is resumed after being in the background, the SDK SHALL restart its timers, retry the offline queue, start a new segment of the current screen span, and emit a `device.app.lifecycle` event with state `foreground`.

#### Scenario: Return from background
- **WHEN** the app is resumed
- **THEN** stored offline requests are retried immediately

### Requirement: Sessions
Every span and log SHALL carry `session.id`, a random UUID. A new session SHALL start at init and when the app returns after more than the session timeout (default 30 min) in the background. A rotation SHALL emit a `session.end` event with the old id and a `session.start` event with `session.previous_id`.

#### Scenario: Long absence
- **WHEN** the app returns after 31 minutes in the background
- **THEN** `session.id` changes and `session.end` / `session.start` events link the old and new ids

### Requirement: No idle work
Apart from the metric collection timer and the stall detector, both only while in the foreground, the SDK SHALL have no timers or network activity when there is nothing to export.

#### Scenario: Idle in foreground
- **WHEN** the app shows a static screen and records nothing for five minutes
- **THEN** no export request is made

### Requirement: Flush and shutdown
`Otel.flush` SHALL export everything buffered, with a timeout (default 10 s). `Otel.shutdown` SHALL flush, remove all hooks and observers, stop all timers, and allow `Otel.init` to be called again.

#### Scenario: Re-init after shutdown
- **WHEN** `Otel.shutdown` completes and `Otel.init` is called again
- **THEN** telemetry is recorded and exported normally
