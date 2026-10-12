# otlp-export Specification

## Purpose

Deliver traces, metrics and logs to any OpenTelemetry-compatible backend over OTLP/HTTP with protobuf encoding, efficiently and without blocking or draining the device.

## Requirements

### Requirement: OTLP/HTTP protocol
Each signal SHALL be sent as an OTLP protobuf export request by HTTP POST to `<endpoint>/v1/traces`, `/v1/metrics` or `/v1/logs`, or to the signal-specific URL unchanged when one is configured. Requests SHALL use `Content-Type: application/x-protobuf` and carry the configured headers.

#### Scenario: Base endpoint
- **WHEN** the endpoint is `http://collector:4318` and logs are exported
- **THEN** the request goes to `http://collector:4318/v1/logs`

### Requirement: Encoding fidelity
The encoded requests SHALL be accepted and decoded correctly by the official OpenTelemetry Collector. This covers every attribute type (including negative integers and, on native platforms, integers above 2^53), UTF-8 text, span events, links, status, span flags (sampled, has-is-remote, is-remote), instrumentation scope grouping, sums, gauges, histograms with bucket counts, explicit bounds, min and max, and log severity, body and trace correlation. Default values such as `0`, `false` and `""` inside attribute values SHALL be preserved.

#### Scenario: Real collector
- **WHEN** the end-to-end test sends a span with every attribute type, metrics of every kind and a correlated log to a running collector
- **THEN** all 33 field checks of the collector's decoded output pass

### Requirement: Compression
On native platforms request bodies SHALL be gzip-compressed when compression is enabled (default). Bodies larger than 64 KB SHALL be compressed off the UI isolate. On web, bodies SHALL be sent uncompressed.

#### Scenario: Gzip header
- **WHEN** compression is enabled on a native platform
- **THEN** the request has `Content-Encoding: gzip` and the body decompresses to the protobuf payload

### Requirement: Batching
Spans and logs SHALL be queued and exported when a batch of 512 is reached, or after the export delay (default 5 s) from the first queued item. Only one export per signal SHALL run at a time. The queue SHALL hold at most 2048 items; further items SHALL be dropped, counted, and reported with one warning. No timer SHALL run while the queue is empty.

#### Scenario: Full batch
- **WHEN** 512 spans end within one second
- **THEN** they are exported immediately without waiting for the delay

#### Scenario: Export already running
- **WHEN** new items arrive while an export is in progress
- **THEN** no second concurrent export starts; the next batch is sent when the first finishes

### Requirement: Retry of transient failures
Network errors, timeouts and HTTP 429, 502, 503 and 504 SHALL be retried with jittered exponential backoff. A `Retry-After` header (seconds or HTTP date) SHALL be honoured, capped at 30 s within one export. Without an offline store a request SHALL be dropped and counted after the configured attempts (default 4). Each attempt SHALL time out after the export timeout (default 10 s).

#### Scenario: Temporary network loss
- **WHEN** the first two attempts fail with a socket error and the third succeeds
- **THEN** the data is delivered once and nothing is dropped

### Requirement: Permanent failures
Any other non-2xx response SHALL be treated as permanent: the request SHALL be dropped and one warning SHALL be printed with a hint (401/403 auth headers, 404 wrong path or port, 413 batch too large, 415 not OTLP protobuf). The response body SHALL be included only when it is text or JSON.

#### Scenario: Wrong port
- **WHEN** the endpoint answers 404
- **THEN** the request is not retried and the warning mentions port 4318 and the `/v1/<signal>` path

### Requirement: Diagnostics
With `debug` enabled the SDK SHALL print one line per export (signal, item count, size, compression, duration). Each distinct problem SHALL be printed once rather than once per batch. Release builds SHALL stay silent unless `debug` is enabled.

#### Scenario: Unreachable endpoint in debug mode
- **WHEN** the endpoint cannot be reached repeatedly
- **THEN** one warning is printed that includes the emulator and LAN-address hints
