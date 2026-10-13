## Why

The deployment we are using is a split: a 1-core / 1 GB / 20 GB VPS only
receives OTLP, and a Mac (M4 Pro) runs the existing Grafana LGTM stack and
keeps the data. `production-collector-deployment` stays as it is. That change
is a single VPS that terminates TLS and forwards to a vendor backend. It does
not describe this split, and it is left unchanged.

The LGTM collector config (`backend/lgtm/otelcol-config.yaml`) writes to
Prometheus, Loki and Tempo on `127.0.0.1`. Those processes exist only inside
the `grafana/otel-lgtm` container. Copying that file onto the VPS would give
the collector nowhere to store data.

## What Changes

- A forward-only collector in `backend/vps-collector/` for the small VPS.
  It receives OTLP/HTTP and exports to the Mac's collector. It does not run
  Grafana, Prometheus, Loki or Tempo, and it does not keep telemetry on the
  VPS disk.
- A short guide: the Mac runs the existing `backend/docker-compose.yml`
  (`lgtm-data` is the only store); the VPS reaches the Mac over Tailscale;
  a release build points at the VPS.
- Phone-facing HTTPS on the VPS, so a release build is not stuck on
  cleartext. The bytes still end on the Mac, not at a vendor.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
None. Deployment config and docs (`skip_specs: true`). The SDK already
sends OTLP/HTTP to whatever endpoint it is given.

## Impact

- New `backend/vps-collector/` (collector config, Caddyfile, compose file,
  `.env.example`). README section. AGENTS.md backlog and layout.
- No library code, no new dependency, no change to app size, battery or
  what the SDK records.
- The VPS disk holds the OS, the collector and access logs. Traces, metrics
  and logs live in the Mac's `lgtm-data` volume.
- While the Mac is asleep or off the tailnet, the VPS has nowhere to put
  accepted batches, and that data is dropped.
- A Telegram bot on the same VPS is out of scope for this repo.
