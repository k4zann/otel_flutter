## 1. Decisions

- [ ] 1.1 Owner picks the backend (Grafana Cloud, Honeycomb, SigNoz, self-hosted Grafana stack, ...), the hosting (VPS provider / region) and the domain (for example `otel.<company-domain>`); verify the choices are recorded in design.md

## 2. Configuration

- [ ] 2.1 Write `backend/production/otel-collector.yaml` (contrib): OTLP HTTP receiver with `bearertokenauth`, `memory_limiter`, `batch`, `attributes/scrub`, `filter` (drop DEBUG/TRACE logs), `otlphttp/vendor` exporter with `${env:VENDOR_ENDPOINT}` / `${env:VENDOR_AUTH}`, `health_check` extension; verify `otelcol-contrib validate --config` passes
- [ ] 2.2 Write `backend/production/Caddyfile` (TLS for the domain, `request_body max_size 5MB`, reverse proxy to the collector on 4318, `/health` route); verify `caddy validate`
- [ ] 2.3 Write `backend/production/docker-compose.yml` and `.env.example` (APP_INGEST_TOKEN, VENDOR_ENDPOINT, VENDOR_AUTH; no real secrets committed); verify `docker compose config` succeeds

## 3. Local rehearsal

- [ ] 3.1 Run the production compose locally with Caddy's internal CA; verify `curl -k -X POST https://localhost/v1/traces` returns 401 without a token and 400 (bad body, but authorized) with `Authorization: Bearer <token>`
- [ ] 3.2 Point the example at it (`--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=https://localhost` plus the headers define, with a dev-only client trusting the local CA); verify telemetry reaches the vendor (or the local debug exporter) and scrubbed attributes are absent

## 4. Deploy

- [ ] 4.1 Provision the VPS, DNS record and firewall (only 80/443 open); deploy with compose; verify `https://<domain>/health` returns 200 with a valid certificate
- [ ] 4.2 Build the example in release mode with the production endpoint and token; verify data appears in the chosen backend within a minute and the collector logs show no auth failures for it

## 5. Docs and runbook

- [ ] 5.1 Add README "Production" steps (deploy, `--dart-define` usage, never ship vendor keys) and `backend/production/RUNBOOK.md` (rotate token with an overlap window, check collector health and metrics, update versions); verify the token rotation is rehearsed once locally
- [ ] 5.2 Update the AGENTS.md backlog and layout; verify `openspec validate --all --strict` passes
