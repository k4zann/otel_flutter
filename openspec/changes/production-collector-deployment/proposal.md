## Why

In production the app needs an internet-reachable HTTPS endpoint. Putting a
vendor API key in the app is unsafe: anything in an app binary can be
extracted and abused. The repo only ships a local-development collector
config with no TLS, auth, limits or PII scrubbing.

## What Changes

- A production collector setup in `backend/production/`:
  - TLS through a reverse proxy;
  - an ingest token the app sends (write-only, rotatable, revocable);
  - request size limits and memory limits;
  - removal of sensitive attributes;
  - forwarding to the chosen backend, with the vendor key kept server-side.
- A deployment guide (single small VPS with Docker Compose as the default
  path), plus how to point a release build at it with `--dart-define`.
- A runbook: rotate the token, read collector health, scale.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
None. Deployment tooling and docs (`skip_specs: true`); the library already
supports endpoint + headers.

## Impact

- New `backend/production/` (collector config, Caddyfile, compose file,
  `.env.example`), README "Production" section, AGENTS.md.
- Requires owner decisions: backend vendor (or self-hosted Grafana stack),
  hosting provider, domain name.
- Ongoing cost: one small VPS (or managed container) plus the backend vendor's
  plan.
