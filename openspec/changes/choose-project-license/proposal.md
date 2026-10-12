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

Decision: _pending. Fill in before applying._

## Capabilities

### New Capabilities
None.

### Modified Capabilities
None. Licensing only (`skip_specs: true`).

## Impact

- `LICENSE`, `README.md`, `pubspec.yaml` (`publish_to`, `repository`,
  `homepage`), `example/` (inherits).
- No code or behavior changes. No third-party attribution is needed: the code
  was written from scratch; opentelemetry-proto field numbers are protocol
  facts.
