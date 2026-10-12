## Why

On web, export bodies are sent uncompressed. OTLP protobuf usually shrinks 3
to 6× with gzip, so web users upload several times more data than mobile
users. All current browsers ship a built-in streaming compressor, so this can
be fixed without a dependency. The web target has also only been compiled,
never run, so this change is the natural moment to verify it in a browser.

## What Changes

- gzip request bodies on web using the browser's built-in compression, off
  the main thread's critical path, with a fallback to uncompressed for older
  browsers.
- A web platform implementation alongside the existing native and stub ones.
- Allow the `Content-Encoding` header in the example collector's CORS config.
- Verify the example app end to end in Chrome and Safari against a
  collector.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
- `otlp-export`: the Compression requirement now covers web (gzip when the
  browser supports it, uncompressed otherwise).

## Impact

- `lib/src/platform/` (new web implementation, conditional export), no new
  dependencies (`dart:js_interop` only).
- `backend/otel-collector.yaml` CORS `allowed_headers`.
- Network: 3 to 6× smaller uploads on web. CPU: compression runs natively
  in the browser.
