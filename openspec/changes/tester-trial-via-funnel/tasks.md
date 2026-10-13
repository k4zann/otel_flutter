## 1. Mac setup

- [ ] 1.1 Install Tailscale on the Mac and sign in; verify `tailscale status` in Terminal lists the Mac (the CLI must work, not only the menu bar app)
- [ ] 1.2 Start the backend (`colima start`, then `cd backend && docker compose up -d`); verify `curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:4318/v1/traces -H 'Content-Type: application/json' -d '{}'` prints `200`
- [ ] 1.3 Run `tailscale funnel --bg 4318` and turn on MagicDNS, HTTPS certificates and Funnel through the admin link it prints; verify `tailscale funnel status` shows `https://<mac>.<tailnet>.ts.net` proxying to `http://127.0.0.1:4318`, and confirm on Tailscale's pricing page that the plan includes Funnel
- [ ] 1.4 From outside the home network (the VPS, or a laptop on a phone hotspot): verify the same POST to `https://<mac>.<tailnet>.ts.net/v1/traces` prints `200` without `-k`, and `https://<mac>.<tailnet>.ts.net/api/health` gets the collector's 404, not Grafana's JSON (only 4318 is published)
- [ ] 1.5 Run `tailscale funnel reset`; verify the POST from outside now fails to connect, then turn Funnel back on and verify it prints `200` again

## 2. Integrate otel_flutter into my_team

The code lives in the `mylink` monorepo (`apps/my_team`) and gets its own OpenSpec change there; these tasks track it.

- [ ] 2.1 Wait for `add-manual-screen-reporting` to be merged here; verify `Otel.setScreen` is on `main` and note the commit to pin
- [ ] 2.2 In the `mylink` repo, create the integration change (for example `integrate-otel-flutter`) on a new branch, following that repo's conventions; verify `openspec list` there shows it
- [ ] 2.3 Add `otel_flutter` as a git dependency pinned to the commit from 2.1 (root `pubspec.yaml` and `apps/my_team/pubspec.yaml`); verify `make get` and `make check_warnings` pass
- [ ] 2.4 Call `Otel.init` in `initializeSdks` right after `WidgetsFlutterBinding.ensureInitialized()`, with `serviceName: 'my_team'`, the version from `package_info_plus`, the flavor as `environment`, `offlineStorageDirectory` from `path_provider`, and the endpoint read from `OTEL_EXPORTER_OTLP_ENDPOINT` with a local fallback. In `main.dart`'s `runZonedGuarded` handler, also call `Otel.recordError(error, stackTrace)`. Verify on a simulator against the local backend: a `session.start` event in Loki for `my_team` (`{service_name="my_team"} | event_name="session.start"`), and an error thrown in an async callback shows up in Loki with `app.error.source = manual`
- [ ] 2.5 Track screens: an `AutoRouterObserver` that calls `Otel.setScreen` on tab init and tab change, plus `OtelNavigatorObserver` that skips `SessionWrapperRoute` and names `HomeRoute` after the last active tab, both in `app.dart`'s `navigatorObservers`. Verify on a simulator: each tab produces its own `screen MainRoute`, `screen MyTasksRoute`, `screen ServicesRoute` and `screen ProfileRoute` span in Tempo; after opening a page from the Profile tab and going back, the current screen is `ProfileRoute` again, not `HomeRoute`
- [ ] 2.6 Trace HTTP: a Dio interceptor on `BaseDioClient` that matches the `http-client` spec (a CLIENT span named by the method; `http.request.method`, `url.full` without the query, `url.scheme`, `server.address`, `server.port`, `http.response.status_code`; `error.type` for status 400 or higher and for exceptions; `Otel.injectTraceHeaders` for the app's own API hosts; histogram `http.client.request.duration` in seconds with `OtelHttpClient`'s buckets), plus one QA-only request through `OtelHttpClient`. Verify on a simulator: both kinds of request appear in Tempo as CLIENT spans with the same attributes, and both feed the HTTP panels on the Flutter App Health dashboard

## 3. my_team on a real phone, through Funnel

- [ ] 3.1 Build `my_team` in release or profile mode for a real phone with its usual flavor flags plus `--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=https://<mac>.<tailnet>.ts.net`, and turn the phone's Wi-Fi off. Log in, switch through all four tabs, open a page from a tab and go back, and use screens that call the API. Verify within a minute: a new `session.start` in Loki, one `screen` span per tab in Tempo, Dio CLIENT spans, and the dashboard's HTTP panels for `my_team`
- [ ] 3.2 Run `tailscale funnel reset`, switch tabs and make a few API calls, wait for the SDK's backoff, turn Funnel back on and bring the app to the foreground; verify the screen and HTTP spans from while Funnel was off arrive, with their original timestamps
- [ ] 3.3 Repeat 3.2 by putting the Mac to sleep for 10 minutes instead; verify that after waking, Funnel works again without any command and the phone's backlog arrives

## 4. Docs and testers

- [ ] 4.1 README, section "3. What it needs to connect": add "Testing with other people (Tailscale Funnel)" covering one-time setup, on/off commands, the `--dart-define`, the `offlineStorageDirectory` requirement, that an `endpoint` in code wins, what is exposed, what happens while the Mac sleeps, and that it is not meant for a whole QA team. Add a "Testers' phones, any network" row to the endpoint table. Verify every command in the section is one that worked in groups 1 to 3
- [ ] 4.2 AGENTS.md: add `tester-trial-via-funnel` to the backlog table and a Commands note for Funnel; add a Gotchas entry for anything surprising found in groups 1 to 3; verify `openspec list` shows the change and the table matches it
- [ ] 4.3 Hand out `my_team` builds made with the define (TestFlight, Firebase App Distribution or an APK); verify each tester's device appears in Loki with `{service_name="my_team"} | event_name="session.start"`, one `app_installation_id` per tester

## 5. Trial results and wrap-up

- [ ] 5.1 Once a day during the trial, record the `lgtm-data` size (`docker system df -v`), the LGTM container's memory (`docker stats --no-stream`) and the number of active testers in `openspec/changes/tester-trial-via-funnel/trial-results.md`; verify at least three days are recorded and handed to the team lead
- [ ] 5.2 End the trial with `tailscale funnel reset`; verify `tailscale funnel status` shows nothing published and the POST from 1.4 fails to connect

## 6. Verification

- [ ] 6.1 Run `openspec validate --all --strict`; verify it passes
- [ ] 6.2 Run `~/fvm/versions/3.44.2/bin/dart format --output=none --set-exit-if-changed .`, `~/fvm/versions/3.44.2/bin/flutter analyze` and `~/fvm/versions/3.44.2/bin/flutter test`; verify no format changes, "No issues found!" and all tests pass (no Dart code changes, so no e2e run is needed)
