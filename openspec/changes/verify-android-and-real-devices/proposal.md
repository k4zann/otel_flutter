## Why

The SDK is verified only by unit tests, a real collector, and the iOS
simulator. Android (lifecycle order, emulator networking, cleartext rules,
process death) and real devices (suspension timing, 120 Hz displays,
iOS local-network permission, real offline transitions) are unverified,
and they are where mobile telemetry usually breaks.

## What Changes

- Run a fixed test matrix on an Android emulator, a real iPhone and a real
  Android phone, in debug and release builds.
- Record results in a new `docs/DEVICE_TEST_REPORT.md`.
- Add the iOS `NSLocalNetworkUsageDescription` to the example app (needed to
  reach a collector on the LAN from a real iPhone).
- Fix defects found here when they don't change specified behavior. Defects
  that do become follow-up OpenSpec changes.
- Decide whether the offline-retry timer must be paused in the background
  (known gap) based on measured background activity.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
None. This is verification work (`skip_specs: true`). Behavior fixes found
here get their own changes.

## Impact

- `example/ios/Runner/Info.plist` (local network usage description).
- New `docs/DEVICE_TEST_REPORT.md`; AGENTS.md "Verified" line.
- No library API or dependency changes expected.
