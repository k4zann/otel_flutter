## 1. VPS collector

- [ ] 1.1 Write `backend/vps-collector/otel-collector.yaml`: OTLP/HTTP receiver on `0.0.0.0:4318`, `memory_limiter` (256 MiB limit, 64 MiB spike) before `batch`, `otlphttp/mac` exporter to `${env:MAC_OTLP_ENDPOINT}` with TLS insecure, `health_check` on `127.0.0.1:13133`. No debug exporter, no Loki/Prometheus/Tempo exporters, no `transform/event_name`. Verify `otelcol validate --config backend/vps-collector/otel-collector.yaml` passes.
- [ ] 1.2 Write `backend/vps-collector/docker-compose.yml` and `.env.example` (`MAC_OTLP_ENDPOINT=http://<mac-tailscale-ip>:4318`, no real addresses committed). The compose file runs only the collector. Verify `docker compose -f backend/vps-collector/docker-compose.yml config` succeeds.

## 2. Phone-facing TLS

- [ ] 2.1 Write `backend/vps-collector/Caddyfile`: TLS for the VPS hostname, `request_body` max 5 MB, reverse proxy to the collector on 4318, `/health` proxied to the collector health port. Verify `caddy validate --config backend/vps-collector/Caddyfile`.
- [ ] 2.2 Add the Caddy service to that compose file. Verify `docker compose config` still succeeds and no vendor endpoint or vendor token variable appears.

## 3. Docs

- [ ] 3.1 Add a README section for this layout: Mac runs `cd backend && docker compose up -d` and keeps `lgtm-data`; VPS and Mac join a Tailscale network; VPS `.env` points at the Mac's tailnet address and port 4318; the release build uses `--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=https://<vps-hostname>`. State that the Mac must stay awake, and that a batch already accepted by the VPS is dropped if the Mac is unreachable. State that `production-collector-deployment` is a different path and is unchanged.
- [ ] 3.2 Update the AGENTS.md backlog table and the layout blurb so `vps-collector-mac-backend` is listed and `production-collector-deployment` is still listed with its original goal. Verify `openspec list` shows both changes.

## 4. Rehearsal

- [ ] 4.1 On one machine, start `backend/docker-compose.yml`, then start the VPS collector with `MAC_OTLP_ENDPOINT=http://127.0.0.1:4318` and a different host port. Send one OTLP trace through the forwarder. Verify it shows up in Grafana (Tempo) and that the VPS container's filesystem has no trace or log data files.
- [ ] 4.2 Stop the LGTM container and send another batch. Verify the forwarder does not grow a disk queue and, after its short retry, the collector log shows the export failure.

## 5. Verification

- [ ] 5.1 Run `openspec validate --all --strict` and confirm it passes. No library code changes in this change, so `flutter analyze` and `flutter test` are expected to stay green without edits; run them if any Dart file was touched.
