## 1. Mac setup

- [ ] 1.1 Install Tailscale on the Mac and sign in; verify `tailscale status` in Terminal lists the Mac (the CLI must work, not only the menu bar app)
- [ ] 1.2 Start the backend (`colima start`, then `cd backend && docker compose up -d`); verify `curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:4318/v1/traces -H 'Content-Type: application/json' -d '{}'` prints `200`
- [ ] 1.3 Run `tailscale funnel --bg 4318` and turn on MagicDNS, HTTPS certificates and Funnel through the admin link it prints; verify `tailscale funnel status` shows `https://<mac>.<tailnet>.ts.net` proxying to `http://127.0.0.1:4318`, and confirm on Tailscale's pricing page that the plan includes Funnel
- [ ] 1.4 From outside the home network (the VPS, or a laptop on a phone hotspot): verify the same POST to `https://<mac>.<tailnet>.ts.net/v1/traces` prints `200` without `-k`, and `https://<mac>.<tailnet>.ts.net/api/health` gets the collector's 404, not Grafana's JSON (only 4318 is published)
- [ ] 1.5 Run `tailscale funnel reset`; verify the POST from outside now fails to connect, then turn Funnel back on and verify it prints `200` again

## 2. Integrate otel_flutter into your app

- [ ] 2.1 In your Flutter app's `pubspec.yaml`, add `otel_flutter` as a git dependency on `https://github.com/k4zann/otel_flutter` pinned to a commit (or `path:` to this checkout), plus `path_provider`; verify `flutter pub get` succeeds and the app still builds
- [ ] 2.2 In the app's `main()`, call `Otel.init` with the app's `serviceName` and `offlineStorageDirectory: (await getApplicationSupportDirectory()).path`. Read `OTEL_EXPORTER_OTLP_ENDPOINT` first and fall back to the local backend, like `example/lib/main.dart`, because an `endpoint` in code wins over the define. Add `OtelNavigatorObserver()` to the app's navigator observers. Verify on a simulator or emulator against the local backend: the app's `service_name` shows up in Grafana with `screen <name>` spans in Tempo and a `session.start` event in Loki (`{service_name="<app>"} | event_name="session.start"`)

## 3. Your app on a real phone, through Funnel

- [ ] 3.1 Build your app in release or profile mode for a real phone with `--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=https://<mac>.<tailnet>.ts.net`, turn the phone's Wi-Fi off, open the app and visit a few screens; verify within a minute: a new `session.start` in Loki and `screen <name>` spans in Tempo for the screens you visited
- [ ] 3.2 Run `tailscale funnel reset`, visit a few more screens, wait for the SDK's backoff, turn Funnel back on and bring the app to the foreground; verify the screen spans from while Funnel was off arrive, with their original timestamps
- [ ] 3.3 Repeat 3.2 by putting the Mac to sleep for 10 minutes instead; verify that after waking, Funnel works again without any command and the phone's backlog arrives

## 4. Docs and testers

- [ ] 4.1 README, section "3. What it needs to connect": add "Testing with other people (Tailscale Funnel)" covering one-time setup, on/off commands, the `--dart-define`, the `offlineStorageDirectory` requirement, that an `endpoint` in code wins, what is exposed, what happens while the Mac sleeps, and that it is not meant for a whole QA team. Add a "Testers' phones, any network" row to the endpoint table. Verify every command in the section is one that worked in groups 1 to 3
- [ ] 4.2 AGENTS.md: add `tester-trial-via-funnel` to the backlog table and a Commands note for Funnel; add a Gotchas entry for anything surprising found in groups 1 to 3; verify `openspec list` shows the change and the table matches it
- [ ] 4.3 Hand out builds of your app made with the define (TestFlight, Firebase App Distribution or an APK); verify each tester's device appears in Loki with `{service_name="<app>"} | event_name="session.start"`, one `app_installation_id` per tester

## 5. Trial results and wrap-up

- [ ] 5.1 Once a day during the trial, record the `lgtm-data` size (`docker system df -v`), the LGTM container's memory (`docker stats --no-stream`) and the number of active testers in `openspec/changes/tester-trial-via-funnel/trial-results.md`; verify at least three days are recorded and handed to the team lead
- [ ] 5.2 End the trial with `tailscale funnel reset`; verify `tailscale funnel status` shows nothing published and the POST from 1.4 fails to connect

## 6. Verification

- [ ] 6.1 Run `openspec validate --all --strict`; verify it passes
- [ ] 6.2 Run `~/fvm/versions/3.44.2/bin/dart format --output=none --set-exit-if-changed .`, `~/fvm/versions/3.44.2/bin/flutter analyze` and `~/fvm/versions/3.44.2/bin/flutter test`; verify no format changes, "No issues found!" and all tests pass (no Dart code changes, so no e2e run is needed)
