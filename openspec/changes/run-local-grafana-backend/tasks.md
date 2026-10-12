## 1. Container runtime

- [ ] 1.1 Install `brew install colima docker docker-compose` and run `colima start --cpu 2 --memory 4`; verify `docker run --rm hello-world` succeeds
- [ ] 1.2 Make the compose plugin visible to docker (`cliPluginsExtraDirs` in `~/.docker/config.json`, per the brew caveats); verify `docker compose version` prints a version

## 2. Run the stack

- [ ] 2.1 Run `cd backend && docker compose up -d`; verify http://localhost:3000 opens Grafana and `curl -s -o /dev/null -w '%{http_code}' -X POST localhost:4318/v1/traces` returns 400 (receiver up)
- [ ] 2.2 Run the example on the iOS simulator against `http://localhost:4318` and tap every button; verify in Explore that Tempo shows `screen /`, `load_profile` and `GET` spans, Loki shows the error logs, and Prometheus has `app_frames_total`
- [ ] 2.3 From an error log in Loki, follow its trace id to Tempo; verify the click-through works, or provision a Loki `trace_id` derived field until it does

## 3. Flutter App Health dashboard

- [ ] 3.1 List the translated metric names in Prometheus (`/api/v1/label/__name__/values`) and write one working query per panel: errors/min by `error_type` and `app_screen_name`; uncaught errors; UI stalls/min; slow and frozen frame ratio by screen; app start p50/p95; HTTP p95 latency and error rate by `server_address`; `session.start` events/hour (LogQL). Verify each query returns data from step 2.2
- [ ] 3.2 Save the dashboard as `backend/grafana/dashboards/flutter-app-health.json`, add a provisioning YAML, and mount both in `docker-compose.yml`; verify that after `docker compose down -v && docker compose up -d` the dashboard is listed and every panel shows data
- [ ] 3.3 Add a `service_name` template variable so one Grafana instance can show several apps; verify switching it filters all panels

## 4. Docs and verification

- [ ] 4.1 Update README section 3 (dashboard, Colima commands) and AGENTS.md (Docker now available, how to start the stack); verify both mention the dashboard path
- [ ] 4.2 Verify `~/fvm/versions/3.44.2/bin/flutter analyze` is clean and `flutter test` is green (no library change expected)
