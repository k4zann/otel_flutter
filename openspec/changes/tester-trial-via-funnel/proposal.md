## Why

Before the team lead deploys a real server that every QA can use, a few
testers should run the owner's own Flutter app, with `otel_flutter`
integrated, on their own phones while the data lands in the Grafana stack on
the owner's Mac. The repo's example app is not part of the trial. Today that
stack is only reachable from the same machine or the same Wi-Fi: the Mac sits
behind a home router, and testers' phones (iPhones and any TestFlight or
release build) refuse plain HTTP to a public address. This trial needs a public HTTPS
address for the Mac without buying a domain or running anything new on a VPS.

## What Changes

- A README section for a short tester trial: Tailscale on the Mac, Tailscale
  Funnel exposing only the existing OTLP port 4318 at a free
  `https://<mac>.<tailnet>.ts.net` address, testers' builds pointed at it
  with `--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT`, Funnel turned off when
  the trial ends.
- Tasks to integrate `otel_flutter` into the owner's app (dependency,
  `Otel.init`, navigator observer) and verify it end to end on a real phone.
  That code lives in the app's own repository, not here.
- The README states what testers' apps need: `offlineStorageDirectory` set,
  so data waits on the phone while the Mac sleeps, and no other `endpoint`
  hardcoded (a value in code wins over `--dart-define`).
- The trial's output for the team lead: proof that the path works with real
  phones, plus measured storage growth per day and the backend's memory, to
  size the real server.
- The previous `vps-collector-mac-backend` change is removed. A collector on
  the VPS forwarding to the Mac adds a hop without making delivery more
  reliable (see design.md).
- AGENTS.md lists this change in the backlog.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
None. Docs and a manual verification run (`skip_specs: true`). The SDK
already sends OTLP/HTTP to any endpoint and keeps failed requests on disk
when `offlineStorageDirectory` is set.

## Impact

- Files here: `README.md`, `AGENTS.md`. No library code, no new dependency,
  no change to the SDK's battery, network use, privacy or size.
- The owner's app gains `otel_flutter` and `path_provider` as dependencies,
  in its own repository.
- The backend (`backend/docker-compose.yml`, `lgtm-data`) is unchanged and
  stays the only store. The VPS is not involved; its unrelated Telegram bot
  is untouched.
- While Funnel is on, anyone who learns the `ts.net` address can send
  telemetry to the Mac's OTLP port. Nothing else on the Mac is exposed, and
  Funnel is off outside test sessions.
- Data waits on testers' phones (up to 5 MB and 2 days each) while the Mac is
  asleep or offline; nothing is accepted and then dropped in between.
- Free: Tailscale's Personal plan. Funnel's bandwidth cap is unpublished,
  which suits a few testers, not a whole QA team.
