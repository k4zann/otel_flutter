# configuration Specification

## Purpose

Define how an app initializes telemetry, where data is sent, and which resource attributes identify the app, with OpenTelemetry-standard overrides from the build.

## Requirements

### Requirement: Initialization
`Otel.init` SHALL require only a service name and SHALL be callable once. A second call SHALL be ignored with a warning. An endpoint that is not an http(s) URL SHALL make `init` throw `ArgumentError` and leave the SDK uninitialized.

#### Scenario: Invalid endpoint
- **WHEN** `Otel.init` is called with endpoint `not a url`
- **THEN** it throws `ArgumentError` and `Otel.isInitialized` is false

### Requirement: Endpoint resolution
For each signal the URL SHALL be chosen in this order: signal-specific config, signal-specific `--dart-define` (`OTEL_EXPORTER_OTLP_<SIGNAL>_ENDPOINT`), then base config endpoint, then `OTEL_EXPORTER_OTLP_ENDPOINT`, then `http://localhost:4318`. Signal-specific URLs SHALL be used as-is; base URLs SHALL get `/v1/<signal>` appended. A port of 4317 SHALL trigger a warning that it is the gRPC port.

#### Scenario: Code beats build define
- **WHEN** `endpoint` is set in code and `OTEL_EXPORTER_OTLP_ENDPOINT` is also defined
- **THEN** the endpoint from code is used

### Requirement: Headers
Headers from `OTEL_EXPORTER_OTLP_HEADERS` (`k=v,k2=v2`, percent-decoded) SHALL be merged with configured headers; configured headers SHALL win.

#### Scenario: Percent-encoded define
- **WHEN** `OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer%20abc`
- **THEN** requests carry `Authorization: Bearer abc`

### Requirement: Resource attributes
Every request SHALL describe the app with `service.name`, `service.version` and `deployment.environment.name` when set, a per-launch `service.instance.id`, `telemetry.sdk.name/language/version`, and on native platforms `os.type`, `os.name`, `os.version`, `process.runtime.name/version`. The device host name SHALL not be collected. Precedence SHALL be: explicit service name/version/environment, then configured resource attributes, then `OTEL_RESOURCE_ATTRIBUTES`, then detected values.

#### Scenario: iOS simulator resource
- **WHEN** the example app runs on an iOS simulator
- **THEN** the resource has `os.type = darwin`, `os.name = iOS` and the configured service name and version

### Requirement: Global attributes
`Otel.setGlobalAttribute` and `Otel.setUser` SHALL add attributes to all spans and logs created afterwards, before or after init. A null value SHALL remove the attribute.

#### Scenario: Logout
- **WHEN** `Otel.setUser(null)` is called after `Otel.setUser('u-42')`
- **THEN** spans created afterwards have no `user.id`

### Requirement: Custom transport
A custom HTTP client SHALL be accepted for the exporter (for example for self-signed certificates or mutual TLS). The SDK SHALL close only clients it created.

#### Scenario: mTLS client
- **WHEN** an `IOClient` with a client certificate is passed as `httpClient`
- **THEN** all exports use it and shutdown does not close it

### Requirement: Feature toggles
Error, frame, stall, app-start and lifecycle capture SHALL each be individually disableable. Defaults SHALL be: export delay 5 s, queue 2048, batch 512, metric interval 60 s, cumulative temporality, export timeout 10 s, 4 attempts, gzip on, session timeout 30 min, offline cap 5 MB and 2 days, 128 attributes/events/links.

#### Scenario: Frames disabled
- **WHEN** `captureFrames` is false
- **THEN** no `app.frames*` metrics are exported
