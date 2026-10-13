## Why

Some screens change without a route being pushed: auto_route tabs
(`AutoTabsScaffold`), other tab bars that keep their pages alive in an
`IndexedStack`, and page views. `OtelNavigatorObserver` cannot see those
changes, and the SDK has no public way to report a screen by name. In
`my_team`, the app for the `tester-trial-via-funnel` trial, all four main tabs
would be recorded as one `HomeRoute` screen. Errors, slow frames and stalls
on any tab would then carry the wrong `app.screen.name`.

## What Changes

- New public call `Otel.setScreen(String name)`. It reports the current
  screen by name, with the same effects as a page route the observer sees:
  a `screen <name>` span, `app.screen.name` on later telemetry, and the
  screen recorded for crash reports. It pairs with the existing
  `Otel.currentScreen` getter.
- The observer and the call drive one current screen; whichever reports
  last wins.
- Fix: a screen reported while the app is in the background (by the call or
  by the observer) becomes current at once, but its span starts only when
  the app returns. Today that span starts immediately and counts background
  time.
- README: a section for screens without a route push, including an auto_route
  tabs example (tab changes call `Otel.setScreen`; going back to the tab host
  reports the active tab).

## Capabilities

### New Capabilities
None.

### Modified Capabilities
- `screen-tracking`: adds a requirement for reporting a screen by name from
  app code.

## Impact

- Code: `lib/src/otel.dart` (one static method) and tests. The public API
  grows by that method; `Otel` is already exported. No new dependency.
- Battery and network: one screen span per reported screen change, the same
  as a route push. No timers, no extra requests.
- Privacy: screen names come from the app. The doc comment and README ask
  for fixed names, never ids or user data, because `app.screen.name` is also
  a metric attribute (bounded by the 2000-series cardinality cap).
- App size: negligible.
- Unblocks `tester-trial-via-funnel`, group 2.
