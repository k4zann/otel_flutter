## 1. Baseline web check

- [ ] 1.1 Run the example in Chrome (`flutter run -d chrome`) against a local collector with CORS enabled (`backend/otel-collector.yaml`); verify spans, logs and metrics arrive uncompressed. This is the first runtime check of the web target; record any web-only bug as a follow-up

## 2. Implementation

- [ ] 2.1 Add `lib/src/platform/platform_web.dart` with `gzipBytes` using `CompressionStream` via `dart:js_interop` (feature-detected; returns null on absence or error), other functions delegating to stub behavior; verify `flutter build web` succeeds and `pubspec.yaml` dependencies are unchanged
- [ ] 2.2 Extend the conditional export in `platform.dart` (`if (dart.library.js_interop) 'platform_web.dart'`); verify `flutter analyze` is clean and native tests still pass
- [ ] 2.3 Add a browser test (`flutter test --platform chrome test/web_gzip_test.dart`) that gzips a payload and checks it decompresses to the original bytes (decompress with `DecompressionStream` in the test); verify it passes in Chrome

## 3. Backend and end-to-end

- [ ] 3.1 Add `Content-Encoding` to `cors.allowed_headers` in `backend/otel-collector.yaml`; verify `otelcol validate --config backend/otel-collector.yaml`
- [ ] 3.2 Run the example in Chrome against the collector; verify requests carry `Content-Encoding: gzip` (DevTools Network tab), the collector decodes them, and the payload is about 3 to 6× smaller than in step 1.1
- [ ] 3.3 Run the example in Safari; verify delivery works (compressed on 16.4+)

## 4. Docs and checks

- [ ] 4.1 Update the README (web compression, CORS `allowed_headers` note for other backends) and AGENTS.md (web verification status, platform layout); verify both are updated
- [ ] 4.2 Run `openspec validate add-web-compression --strict`, `flutter analyze` and `flutter test`; verify all pass
