# otel_flutter example

1. Start a backend: `cd ../backend && docker compose up -d`
   (or `./otelcol --config ../backend/otel-collector.yaml`).
2. `flutter run` (Android emulator uses `10.0.2.2:4318` automatically).
3. Tap the buttons, then open Grafana at http://localhost:3000 → Explore.

Use another endpoint with
`--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=https://your-collector`.
