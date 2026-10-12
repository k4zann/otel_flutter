## 1. Setup

- [ ] 1.1 Confirm the Android toolchain and an emulator image (API 34+) are installed; verify `~/fvm/versions/3.44.2/bin/flutter devices` lists the emulator
- [ ] 1.2 Start a collector reachable from devices (`otelcol --config backend/otel-collector.yaml`, listens on 0.0.0.0:4318, plus a `file` exporter for checking); verify `curl -s -o /dev/null -w '%{http_code}' -X POST http://<LAN-IP>:4318/v1/traces` returns 400 or 415 (reachable)
- [ ] 1.3 Create `docs/DEVICE_TEST_REPORT.md` with a matrix (device, OS, build mode, scenario, result, notes); verify the file exists with one row per scenario in groups 2 to 6

## 2. Android emulator (debug)

- [ ] 2.1 Run the example (default endpoint `http://10.0.2.2:4318`); verify the collector shows resource `os.name=Android`, a `session.start` event and a `screen /` span after backgrounding
- [ ] 2.2 Tap every example button; verify the same telemetry as on iOS: `load_profile` trace, `GET` client span, manual + uncaught error logs, `app.ui.stalls`, `app.frames*`, `screen /details` span
- [ ] 2.3 Press Home, then reopen; verify `device.app.lifecycle` with `android.app.state=background`, then `foreground`, and that pending spans arrive within 2 s of backgrounding
- [ ] 2.4 Enable airplane mode, generate telemetry, background the app; verify files exist in the app's `otel_flutter_queue` directory (`adb shell run-as kz.mystartups.otel_flutter_example ls files/...`); disable airplane mode and resume; verify delivery and an empty queue
- [ ] 2.5 Generate telemetry, then kill the process (`adb shell am kill` and swipe-away) and relaunch; verify the backlog is delivered exactly once (no duplicate span ids)

## 3. Android release build

- [ ] 3.1 Build `flutter build apk --release` with an `http://` endpoint; verify the cleartext block shows up as the "Cannot reach" warning (expected, release forbids http) and the app does not crash
- [ ] 3.2 Build release against an `https://` endpoint (production collector or a temporary tunnel such as `cloudflared tunnel --url http://localhost:4318`); verify data arrives, which also confirms the INTERNET permission and R8 minification are fine

## 4. Real iPhone

- [ ] 4.1 Add `NSLocalNetworkUsageDescription` to `example/ios/Runner/Info.plist`; run on the iPhone with `--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=http://<LAN-IP>:4318`; verify the permission prompt appears and, once accepted, telemetry arrives
- [ ] 4.2 Generate telemetry, press Home and lock the phone for 2 minutes; verify the data reached the collector or the disk queue before suspension and the remainder arrives after unlock (no loss)
- [ ] 4.3 On a 120 Hz (ProMotion) iPhone, scroll a long list; verify `app.frames.slow` uses the 8.3 ms budget (slow ratio plausibly higher than on 60 Hz) and record numbers
- [ ] 4.4 Run `flutter run --release`; verify telemetry arrives and the device log shows no `[otel]` lines (quiet release)

## 5. Real Android phone

- [ ] 5.1 Repeat 2.1 to 2.5 on a physical phone using the LAN IP; verify the same results and record any OEM-specific differences
- [ ] 5.2 Leave the app in the background 10+ minutes with the network off, then on; measure SDK network activity (`adb shell dumpsys netstats detail` or collector logs); decide whether the offline-retry timer must pause in background, and record the decision (follow-up change if yes)

## 6. Overhead

- [ ] 6.1 Profile a release build idle on a static screen for 60 s with DevTools; verify no export requests and only stall-detector ticks (~5/s); record CPU %
- [ ] 6.2 Measure app-size impact with `flutter build apk --analyze-size` with and without `otel_flutter`; record the KB delta in the report

## 7. Wrap-up

- [ ] 7.1 Complete `docs/DEVICE_TEST_REPORT.md`; for each failure that changes behavior, create a follow-up change (`/opsx:propose`); verify `openspec list` shows them
- [ ] 7.2 Update the AGENTS.md "Verified" line and backlog; verify `flutter analyze` is clean and `flutter test` is green
