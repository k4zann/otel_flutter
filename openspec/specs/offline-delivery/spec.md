# offline-delivery Specification

## Purpose

Keep telemetry that cannot be sent (no network, server down, app suspended or killed) on disk and deliver it later, without waking the radio repeatedly while offline.

## Requirements

### Requirement: Opt-in disk queue
The disk queue SHALL be enabled only when an offline storage directory is configured, and SHALL be unavailable on web. Stored entries SHALL be the exact request bytes that would be sent, so resending needs no re-encoding.

#### Scenario: No directory configured
- **WHEN** no offline storage directory is set and every attempt fails
- **THEN** the request is dropped and counted after the configured attempts

### Requirement: Store on failure and resend
A request that still fails with a transient error SHALL be written to disk. Stored requests SHALL be resent oldest first after the next successful export, when the backoff expires, when the app returns to the foreground, and at the next startup. A stored request rejected permanently SHALL be deleted.

#### Scenario: Offline then app restart
- **WHEN** a span is exported while the endpoint is unreachable, the SDK is shut down, and a new SDK starts with the same directory and a reachable endpoint
- **THEN** the span is delivered exactly once and the queue directory becomes empty

### Requirement: Circuit breaker
After a transient failure with the disk queue enabled, the SDK SHALL make no network attempts until a backoff expires (5 s doubling to 5 min, with jitter, or `Retry-After` when longer). New requests in that window SHALL go straight to disk.

#### Scenario: Still offline
- **WHEN** a request has just failed and another export happens before the backoff expires
- **THEN** the second request is written to disk without any network attempt

### Requirement: Write-ahead on background
When the app goes to the background and the disk queue is enabled, pending telemetry SHALL be written to disk before any send is attempted, so it survives the OS suspending or killing the app mid-request.

#### Scenario: Urgent export
- **WHEN** an urgent export happens with the disk queue enabled
- **THEN** the payload is on disk before the network request starts, and is deleted after it succeeds

### Requirement: Bounded storage
The queue SHALL be capped by total size (default 5 MB, oldest evicted first) and by age (default 2 days, expired entries discarded). Writes SHALL be atomic so a crash never leaves a partial entry, and leftover temporary files SHALL be cleaned up.

#### Scenario: Size cap
- **WHEN** five 100-byte requests are stored with a 250-byte cap
- **THEN** only the newest two remain

### Requirement: Delivery semantics
Delivery SHALL be at-least-once: a request may be resent if the app died after the server accepted it but before the entry was deleted.

#### Scenario: Killed after send
- **WHEN** the app is killed after the server accepted a stored request but before deletion
- **THEN** the request is sent again on next launch (duplicate span ids are possible)

### Requirement: Installation id
When an offline storage directory is configured, a random installation id SHALL be created once, persisted there, and reported as resource attribute `app.installation.id` on every launch.

#### Scenario: Two launches
- **WHEN** the SDK starts twice with the same directory
- **THEN** both launches report the same `app.installation.id`
