## Why

`LICENSE` is still the placeholder from `flutter create`. Without a license
the code is "all rights reserved" by default: teammates, clients or
open-source users have no legal right to use it, and it can't be published
on pub.dev.

## What Changes

- The owner picks a license. Options:
  - **Apache-2.0**: permissive, includes an explicit patent grant. Fits well
    since Dartastic mentions filed patents in this space.
  - **MIT**: permissive and shortest.
  - **Proprietary**: keep the code internal to the company.
- Replace `LICENSE`, add a README section, and set publishing metadata to
  match.

Decision (owner, 2026-10-12): **Apache-2.0**, copyright holder
**The otel_flutter Authors**. The same license applies to the
`otel_flutter_native` plugin in `packages/`.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
None. Licensing only (`skip_specs: true`).

## Impact

- `LICENSE`, `README.md`, `pubspec.yaml` (`publish_to`, `repository`,
  `homepage`), `example/` (inherits).
- `packages/otel_flutter_native/`: `LICENSE`, `README.md`, `pubspec.yaml`
  (`repository`, `homepage`). It keeps `publish_to: none` because its path
  dependency on `otel_flutter` blocks publishing until the core package is
  on pub.dev.
- No code or behavior changes. No third-party attribution is needed: the code
  was written from scratch; opentelemetry-proto field numbers are protocol
  facts.
