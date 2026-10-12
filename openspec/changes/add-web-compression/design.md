## Context

`lib/src/platform/platform.dart` exports `platform_io.dart` on native and
`platform_stub.dart` elsewhere; the stub's `gzipBytes` returns null, so web
sends raw bytes. The exporter already handles a null result. AGENTS.md
invariant 3 allows only the `http` and `meta` dependencies.

## Goals / Non-Goals

**Goals:** gzip on web with no new dependency and no main-thread stall;
verify the web target actually works.

**Non-Goals:** an offline queue on web (IndexedDB), `sendBeacon`/`keepalive`
on page unload. Both are possible follow-up changes.

## Decisions

1. **`CompressionStream('gzip')` through `dart:js_interop` extension types**
   (`Blob([bytes]).stream().pipeThrough(cs)` → `Response(stream).arrayBuffer()`).
   *Alternatives:* `package:web` (a new dependency, against invariant 3); the
   pure-Dart `package:archive` (a dependency, and synchronous on the main
   thread, so it janks).
2. **Feature detection** through `globalThis.CompressionStream`; return null
   (the existing uncompressed path) when absent or on any JS error.
3. **Conditional export chain**: `platform_stub.dart` stays the default, with
   `if (dart.library.io) 'platform_io.dart' if (dart.library.js_interop)
   'platform_web.dart'`. The web file implements only `gzipBytes` with
   compression; its other functions keep the stub behavior.
4. **No size threshold on web**: the browser compresses on its own threads,
   so every body is compressed.

## Risks / Trade-offs

- [CORS: `Content-Encoding` is not a safelisted request header, so the
  preflight must allow it] → add it to the collector's `cors.allowed_headers`
  and document it for other backends.
- [Safari before 16.4 lacks CompressionStream] → automatic uncompressed
  fallback; covered by a spec scenario.
- [The web test runner needs Chrome] → if Chrome is not installed, run the
  browser tests manually and record the result in the tasks.
