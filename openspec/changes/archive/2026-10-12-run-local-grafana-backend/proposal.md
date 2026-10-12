## Why

`backend/docker-compose.yml` (Grafana + Tempo + Loki + Prometheus) was
written but never run, because no container runtime is installed on this
Mac. There is also no dashboard: seeing app health means writing queries by
hand in Explore.

## What Changes

- Install a free container runtime and run the local stack.
- Verify every signal end to end in Grafana: traces in Tempo, logs in Loki
  with a jump to their trace, metrics in Prometheus.
- Add a provisioned **Flutter App Health** dashboard (errors, crashes and
  stalls, slow/frozen frames by screen, app start, HTTP latency and errors,
  sessions) that loads automatically with `docker compose up`.
- Document how to use it.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
None. This is local tooling and docs (`skip_specs: true`); library behavior is
unchanged.

## Impact

- `backend/docker-compose.yml`, new `backend/grafana/` (dashboard JSON +
  provisioning).
- README section 3, AGENTS.md (Docker availability, commands).
- Dev machine: Colima + docker CLI via Homebrew.
