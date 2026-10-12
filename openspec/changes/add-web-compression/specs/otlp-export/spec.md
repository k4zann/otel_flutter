## MODIFIED Requirements

### Requirement: Compression
When compression is enabled (default), request bodies SHALL be gzip-compressed and sent with `Content-Encoding: gzip`. On native platforms, bodies larger than 64 KB SHALL be compressed off the UI isolate. On web, bodies SHALL be compressed with the browser's built-in streaming compression without blocking rendering. When the browser does not support it, bodies SHALL be sent uncompressed without error.

#### Scenario: Gzip header
- **WHEN** compression is enabled on a native platform
- **THEN** the request has `Content-Encoding: gzip` and the body decompresses to the protobuf payload

#### Scenario: Modern browser
- **WHEN** compression is enabled and the app runs in a browser with built-in streaming compression
- **THEN** the request has `Content-Encoding: gzip` and the body decompresses to the protobuf payload

#### Scenario: Browser without compression support
- **WHEN** the app runs in a browser without built-in streaming compression
- **THEN** the body is sent uncompressed, without `Content-Encoding`, and no error is raised
