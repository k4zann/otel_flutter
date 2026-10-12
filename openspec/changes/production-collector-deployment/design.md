## Context

The SDK posts OTLP/HTTP protobuf (optionally gzip) to `<endpoint>/v1/*` with
configurable headers (see the `configuration` and `otlp-export` specs).
`backend/otel-collector.yaml` is development-only: plain HTTP, no auth, debug
exporter.

## Goals / Non-Goals

**Goals:** a secure, cheap, reproducible ingestion endpoint for release apps;
vendor credentials never in the app; easy token rotation.

**Non-Goals:** Kubernetes manifests, multi-region HA, remote SDK config
(server-pushed sampling), per-user authentication.

## Decisions

1. **otelcol-contrib behind Caddy on one VPS, using Docker Compose.** Caddy
   gives automatic Let's Encrypt TLS and a request body limit (5 MB).
   *Alternatives:* app → vendor directly with a write-only key (simplest, but
   the key is extractable and abuse spends your vendor quota); Kubernetes
   (overkill at this stage); a managed collector (vendor lock-in).
2. **Ingest token check in the collector** with the contrib
   `bearertokenauth` extension on the OTLP receiver. The app sends
   `Authorization: Bearer <app-token>` via `OTEL_EXPORTER_OTLP_HEADERS`. A
   leaked token only allows writing telemetry, and is rotated by deploying a
   new token and accepting old and new during the app-update window.
3. **Processors:** `memory_limiter` (first), then `batch`. `attributes/scrub`
   deletes `user.email`, `enduser.*`, `http.request.header.*`; `filter` drops
   DEBUG/TRACE logs from release builds. Exporter `otlphttp/vendor` with the
   key from an environment variable.
4. **Rate limiting** starts with the memory limiter, the body limit and the
   token. Per-IP limits need a Caddy plugin or nginx `limit_req`; add them
   only if abuse is observed (record that decision).

## Risks / Trade-offs

- [The token is still extractable from the app] → it only grants ingestion,
  can be rotated, and abuse is visible in collector metrics. This is the
  standard trade-off for client-side telemetry.
- [Single VPS is a single point of failure] → the SDK's offline queue
  buffers up to 2 days, so short outages lose no data.
- [Contrib distribution is large] → acceptable server-side. Pin the version.
