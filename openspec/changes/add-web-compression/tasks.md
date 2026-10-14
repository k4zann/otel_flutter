## 1. Web works at all (uncompressed baseline)

- [ ] 1.1 Run the example in Chrome (`flutter run -d chrome`) against a local collector with CORS enabled (`backend/otel-collector.yaml`); verify spans, logs and metrics arrive uncompressed and note the request body sizes in the DevTools Network tab for step 2.4. This is the first runtime check of the web target; record any web-only bug as a follow-up

## 2. Chrome sends gzip end to end

- [ ] 2.1 Add a browser test (`test/web_gzip_test.dart`) that gzips a payload with `gzipBytes` and checks it decompresses to the original bytes (decompress with `DecompressionStream` in the test); verify it fails before 2.2 (the stub returns null) with `flutter test --platform chrome test/web_gzip_test.dart`
- [ ] 2.2 Add `lib/src/platform/platform_web.dart` with `gzipBytes` using `CompressionStream` via `dart:js_interop` (feature-detected; returns null on absence or error), other functions delegating to stub behavior, and extend the conditional export in `platform.dart` (`if (dart.library.js_interop) 'platform_web.dart'`); verify the 2.1 test passes in Chrome, `flutter build web` succeeds, `flutter analyze` is clean, native tests still pass and `pubspec.yaml` dependencies are unchanged
- [ ] 2.3 Add `Content-Encoding` to `cors.allowed_headers` in `backend/otel-collector.yaml` (without it the browser preflight blocks every compressed request); verify `otelcol validate --config backend/otel-collector.yaml`
- [ ] 2.4 Run the example in Chrome against the collector; verify requests carry `Content-Encoding: gzip` (DevTools Network tab), the collector decodes them, and the payload is about 3 to 6× smaller than in step 1.1

## 3. Browsers without CompressionStream fall back to uncompressed

- [ ] 3.1 Extend `test/web_gzip_test.dart`: with `globalThis.CompressionStream` hidden, `gzipBytes` returns null and does not throw; verify it passes with `flutter test --platform chrome test/web_gzip_test.dart`
- [ ] 3.2 Run the example in Safari; verify delivery works (compressed on 16.4+; on an older Safari, if available, sent without `Content-Encoding` and without errors)

## 4. Docs and checks

- [ ] 4.1 Update the README (web compression, CORS `allowed_headers` note for other backends) and AGENTS.md (web verification status, platform layout); verify both are updated
- [ ] 4.2 Run `openspec validate add-web-compression --strict`, `flutter analyze`, `flutter test` and `flutter test --platform chrome test/web_gzip_test.dart`; verify all pass
