## 1. Decisions (human checkpoint)

- [ ] 1.1 Owner picks the backend (Grafana Cloud, Honeycomb, SigNoz, self-hosted Grafana stack, ...), the hosting (VPS provider / region) and the domain (for example `otel.<company-domain>`); verify the choices are recorded in design.md

## 2. Authenticated ingest works locally end to end

- [ ] 2.1 Write `backend/production/otel-collector.yaml` (contrib): OTLP HTTP receiver with `bearertokenauth`, `memory_limiter`, `batch`, `otlphttp/vendor` exporter with `${env:VENDOR_ENDPOINT}` / `${env:VENDOR_AUTH}`, `health_check` extension; verify `otelcol-contrib validate --config` passes
- [ ] 2.2 Write `backend/production/Caddyfile` (TLS for the domain, `request_body max_size 5MB`, reverse proxy to the collector on 4318, `/health` route); verify `caddy validate`
- [ ] 2.3 Write `backend/production/docker-compose.yml` and `.env.example` (APP_INGEST_TOKEN, VENDOR_ENDPOINT, VENDOR_AUTH; no real secrets committed); verify `docker compose config` succeeds
- [ ] 2.4 Run the production compose locally with Caddy's internal CA; verify `curl -k -X POST https://localhost/v1/traces` returns 401 without a token and 400 (bad body, but authorized) with `Authorization: Bearer <token>`
- [ ] 2.5 Point the example at it (`--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=https://localhost` plus the headers define, with a dev-only client trusting the local CA); verify telemetry reaches the vendor (or the local debug exporter)

## 3. Sensitive data never leaves the collector

- [ ] 3.1 Add `attributes/scrub` (delete `user.email`, `enduser.*`, `http.request.header.*`) and `filter` (drop DEBUG/TRACE logs) to the pipeline after `memory_limiter`; verify `otelcol-contrib validate --config` passes
- [ ] 3.2 With the local compose from group 2, send telemetry from the example that includes a scrubbed attribute and a DEBUG log; verify both are absent at the vendor (or the local debug exporter) while other attributes and INFO logs arrive

## 4. Deployed endpoint receives release-build telemetry

- [ ] 4.1 Provision the VPS, DNS record and firewall (only 80/443 open); deploy with compose; verify `https://<domain>/health` returns 200 with a valid certificate
- [ ] 4.2 Build the example in release mode with the production endpoint and token; verify data appears in the chosen backend within a minute and the collector logs show no auth failures for it

## 5. Token rotation without data loss

- [ ] 5.1 Write `backend/production/RUNBOOK.md` (rotate token with an overlap window, check collector health and metrics, update versions); verify by rehearsing the rotation once locally: during the overlap both old and new tokens are accepted, after it the old token gets 401

## 6. Docs and checks

- [ ] 6.1 Add README "Production" steps (deploy, `--dart-define` usage, never ship vendor keys) and update the AGENTS.md backlog and layout; verify both are updated
- [ ] 6.2 Run `openspec validate --all --strict`; verify it passes
