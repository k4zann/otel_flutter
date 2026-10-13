## Context

See proposal.md for the motivation.

- The Mac runs `backend/docker-compose.yml` (`grafana/otel-lgtm`) under
  Colima. Its collector listens on 4318 and is verified reachable from the
  Mac's loopback (iOS simulator, Android emulator via `10.0.2.2`). Whether
  Colima also exposes it on other Mac addresses has not been checked.
- The SDK treats network errors, timeouts and 429/502/503/504 as retryable.
  With `offlineStorageDirectory` set, a failed request goes to disk (5 MB,
  2 days), a circuit breaker waits 5 s doubling to 5 min, and stored requests
  are resent after the next success, on return to the foreground and at the
  next start (`offline-delivery` spec). Without it, a request is dropped
  after `maxExportAttempts` (4).
- `endpoint` passed in code wins over `--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT`.

## Goals / Non-Goals

**Goals:** testers' phones on any network reach the Mac's OTLP receiver over
HTTPS with a valid certificate; nothing on the Mac except that receiver is
reachable from the internet; a sleeping Mac costs delay, not data the phones
still hold; the trial is switched on and off with one command.

**Non-Goals:** a server for the whole QA team (the team lead's deployment;
`production-collector-deployment` stays that plan); any use of the VPS; a
domain; an ingest token; showing Grafana to testers; SDK changes.

## Decisions

1. **Tailscale Funnel on the Mac, pointing at the unchanged LGTM collector.**
   Tailscale is installed on the Mac. `tailscale funnel` publishes
   `https://<mac>.<tailnet>.ts.net` (port 443) and forwards it to
   `http://127.0.0.1:4318`. Public DNS for that name points at Tailscale's
   Funnel relays. They pass the TCP connection over the tunnel the Mac
   opened outward, and tailscaled on the Mac terminates TLS with a
   certificate it obtains itself, so the relays never see plaintext. The
   home router needs no port forward, and forwarding to loopback sidesteps
   the open question about Colima's other addresses.
   *Rejected:*
   - **A collector on the VPS forwarding to the Mac over the tailnet** (the
     removed `vps-collector-mac-backend`). It needs Tailscale on both
     machines, an ACL so the VPS reaches only port 4318, and a Mac port
     reachable on the tailnet. With `batch` and a sending queue it answers
     200 and later drops the batch while the Mac sleeps. As a pass-through
     it behaves exactly like this design, with one more machine.
   - **Caddy with a domain** (on the VPS, or on the Mac behind a router port
     forward): a domain to buy and more parts to run, for a short trial.
   - **Plain HTTP to a public IP:** iPhones and release Android builds
     refuse it, and the router blocks inbound connections anyway.
   - **Cloudflare quick tunnel:** its `trycloudflare.com` address changes at
     every restart, so every tester build would need a new endpoint. A
     named tunnel needs a domain on Cloudflare.
   - **Testers join the tailnet:** they would install Tailscale and sit
     inside the owner's private network.

2. **Funnel is on only during test sessions.** `tailscale funnel --bg`
   persists across restarts, so it is switched off explicitly when a session
   or the trial ends. Only the OTLP/HTTP receiver is published: not Grafana
   (3000), not gRPC (4317), not the collector's health port.

3. **No ingest token.** The LGTM collector has no auth. Adding
   `bearertokenauth` to `backend/lgtm/otelcol-config.yaml` would force a
   token on local development too, and the trial is short. The `ts.net` name
   appears in public Certificate Transparency logs, so it can be found; the
   worst case is junk telemetry in the Mac's Grafana, cleared with
   `docker compose down -v`.
   *Rejected:* a second, authenticated receiver on another port, which
   is more config to maintain for a trial. The real server gets a token
   (`production-collector-deployment`).

4. **Phones hold the data while the Mac is away.** With the Mac asleep or
   offline, the relay cannot reach it, the phone sees a connection error or
   timeout, and the SDK stores the request and retries (see Context).
   Nothing in between accepts data and drops it. This requires
   `offlineStorageDirectory` in testers' apps. Keeping the Mac plugged in
   and awake during sessions shortens delays but is not needed for
   correctness.

5. **Testers' builds get the endpoint from `--dart-define`.**
   `OTEL_EXPORTER_OTLP_ENDPOINT=https://<mac>.<tailnet>.ts.net`, with no
   path (the SDK appends `/v1/traces`, `/v1/metrics`, `/v1/logs`). Because
   a value in code wins, the app either leaves `endpoint` unset or reads the
   define itself and falls back to its local default, as
   `example/lib/main.dart` does.

6. **The trial measures what the real server needs.** During the trial,
   record daily: the size of the `lgtm-data` volume, the LGTM container's
   memory (`docker stats --no-stream`) and the number of active testers. The
   team lead gets these numbers with the result.

## Risks / Trade-offs

- [Funnel's bandwidth cap is unpublished] → enough for a few testers. If
  exports start failing under load, the SDK retries. The whole QA team
  belongs on the team lead's server.
- [Funnel's plan terms could change] → confirm on Tailscale's pricing page
  at setup. Fallback: a Cloudflare named tunnel with a domain.
- [The address is public while Funnel is on] → only port 4318 is reachable;
  Funnel is off between sessions; junk is cleared with `docker compose down -v`.
- [The Mac is away longer than a phone can hold] → each phone keeps 5 MB and
  2 days, oldest evicted first. Keep the Mac on during active test days.
- [A tester build still sets `endpoint` in code] → its data never arrives.
  The verification task checks a tester build's data in Grafana.
- [Funnel needs MagicDNS, HTTPS certificates and the Funnel attribute in the
  tailnet policy] → the first `tailscale funnel` run prints the admin link
  that enables them.
- [Duplicates] → delivery is at-least-once. A phone that times out after the
  Mac accepted a request sends it again. Acceptable for a trial.
- [Testers' telemetry sits on a personal laptop] → it is only what the SDK
  records (no route arguments, query strings or credentials). Delete it with
  `docker compose down -v` after the trial if needed.

## Migration Plan

Switch on: install Tailscale, run `tailscale funnel --bg 4318`, and hand out
builds. Rollback: `tailscale funnel reset`. Nothing else changed, so nothing
else needs undoing. After the trial, the README section stays as a general
"share your local backend with testers" how-to.
