## Context

Phones run `otel_flutter` and POST OTLP/HTTP protobuf to `<endpoint>/v1/*`.
The Mac already runs `grafana/otel-lgtm` via `backend/docker-compose.yml`:
collector on 4318, Grafana on 3000, and Prometheus, Loki and Tempo writing
under `/data`, which is the `lgtm-data` volume. The in-container collector
copies `event.name` before handing logs to Loki.

The VPS is 1 vCPU, 1 GB RAM, 20 GB disk. It cannot run that image. The Mac
is not a public address: home NAT, sleep, and the laptop leaving the desk.

`production-collector-deployment` remains the vendor-forwarding plan
(Caddy, ingest token, vendor key). This change does not edit it.

## Goals / Non-Goals

**Goals:** phones reach a small always-on collector; that collector forwards
to the Mac; the Mac's existing stack is the only store; the VPS stays
inside 1 GB.

**Non-Goals:** the Telegram bot; running LGTM on the VPS; a vendor backend;
a durable spool of telemetry on the 20 GB disk; changing SDK behavior;
Kubernetes; editing `production-collector-deployment`.

## Decisions

1. **Two machines, one store.** The VPS runs a collector. The Mac runs
   `docker compose` in `backend/` unchanged. `lgtm-data` on the Mac holds
   Prometheus, Loki, Tempo and Grafana's SQLite file.
   *Rejected:* LGTM on the 1 GB VPS (the image wants about 4 GB).
   *Rejected:* phones posting straight at the Mac (no public address, and
   the laptop sleeps). *Rejected:* folding this into
   `production-collector-deployment` (that change forwards to a vendor and
   stays the other path).

2. **The VPS config is a forwarder, in `backend/vps-collector/`.** Receiver
   `otlp` HTTP on `0.0.0.0:4318`, then `memory_limiter`, then `batch`, then
   an `otlphttp/mac` exporter whose endpoint is `${env:MAC_OTLP_ENDPOINT}`.
   No `transform/event_name` here: the Mac collector already does that
   before Loki. No debug exporter in the default pipeline (it would write
   every payload into the VPS logs).
   *Rejected:* reusing `backend/lgtm/otelcol-config.yaml` (its exporters are
   `127.0.0.1:9090`, `:3100` and `:4418`). *Rejected:* reusing
   `backend/otel-collector.yaml` (it prints to the terminal).

3. **Tailscale is the path from the VPS to the Mac.**
   `MAC_OTLP_ENDPOINT=http://<mac-tailscale-ip>:4318`, TLS insecure because
   the tailnet is the trust boundary. The Mac does not port-forward 4318.
   *Rejected:* opening the Mac's 4318 on the home router.
   *Rejected:* a Cloudflare tunnel to the Mac and no VPS (the VPS is the
   public door so collection does not follow the laptop's network).

4. **Memory cap for a 1 GB VPS.** `memory_limiter` limit 256 MiB, spike
   limit 64 MiB. The OS takes a few hundred megabytes; this leaves room
   for a small process beside the collector. The exporter queue stays
   small (a few dozen batches) and retries for a short window. When the
   Mac is unreachable past that, the collector drops the batch.
   *Rejected:* a file storage extension that spools until the Mac wakes.
   A long sleep would fill 20 GB, and the plan already requires the Mac
   to stay awake.

5. **HTTPS on the phone-facing side only.** Caddy on the VPS terminates
   TLS for a hostname and reverse-proxies to the local collector, with a
   5 MB body limit. Release Android and iOS builds refuse plain HTTP.
   The Mac hop stays plain HTTP on the tailnet. No ingest token in this
   change: Tailscale plus the public hostname is the boundary we are
   documenting. Token auth remains the other change's job if this VPS is
   later pointed at a vendor.
   *Assumption:* a DNS name for the VPS exists before the release-build
   task. Debug builds on the same network may use `http://<vps>:4318`
   until that name exists.

## Risks / Trade-offs

- [Mac asleep, off, or off the tailnet] → batches the VPS already accepted
  are dropped. The phone's offline queue only helps until the VPS returns
  success.
- [Home upload is the ceiling] → 4000 accounts do not mean 4000 concurrent
  exports, but the Mac's uplink is the bottleneck, not the VPS CPU.
- [256 MiB is a guess] → confirm the collector's RSS on the VPS during a
  short replay; lower the limit if the box swaps, raise it only while
  total RSS stays under 1 GB.
- [No ingest token] → anyone who can reach the public hostname can write
  telemetry. Acceptable for a private app hostname; revisit if the endpoint
  is abused. Do not "fix" that by editing `production-collector-deployment`.
