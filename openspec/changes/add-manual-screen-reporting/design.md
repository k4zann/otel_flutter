## Context

See proposal.md for the motivation and specs/screen-tracking for the
behavior.

- All `OtelNavigatorObserver` instances feed one process-wide screen tracker.
  It owns the current name, the open `screen <name>` span, the
  `app.screen.name` value other signals read, and the crash-context save.
- The lifecycle observer suspends the tracker on `hidden`/`paused`/`detached`
  (the span ends) and resumes it on `resumed` (a new span starts).
- `Otel.currentScreen` already exposes the current name; nothing can set it.
- auto_route reports tab changes only to `AutoRouterObserver`
  (`didInitTabRoute`, `didChangeTabRoute`). A tab switch pushes no route, so
  `NavigatorObserver` callbacks never fire for it.

## Goals / Non-Goals

**Goals:** app code can report a screen by name with exactly the effects of
an observed route; tabs in `my_team` become separate screens; a screen
reported while in the background no longer starts a span that counts
background time.

**Non-Goals:** an auto_route (or go_router shell) integration inside the SDK;
automatic tab detection; ending a screen without starting another; changing
how the observer names routes.

## Decisions

1. **A static `Otel.setScreen(String name)` that feeds the same tracker.**
   It pairs with the `Otel.currentScreen` getter, needs no instance, and
   gives one current screen with "last report wins" between the observer and
   app code.
   *Rejected:*
   - **A method on `OtelNavigatorObserver`:** auto_route builds observers
     through a callback, one per navigator, so the app has no single
     instance to call. The state is process-wide anyway.
   - **An auto_route-aware observer in this package:** it needs an
     auto_route dependency, which breaks the "only `http` and `meta`" rule.
     A separate `otel_flutter_auto_route` package stays possible if several
     apps need it.
   - **App code passing a fake `Route` to the observer:** that relies on
     internals and creates routes that are never shown.
   - **`Otel.setGlobalAttribute('app.screen.name', ...)`:** it tags
     telemetry, but gives no screen spans and no crash context, and the
     observer would fight it.

2. **Same rules as the observer, enforced in the tracker.** Reporting the
   current name again is a no-op. A new name ends the old span and starts
   `screen <name>` as a new root span. The crash context is saved, so a
   native crash on a tab reports that tab. Before `Otel.init` the call goes
   through the no-op pipeline like every other API (invariant 1).

3. **Blank names are dropped with a one-time warning** (`Diagnostics.warnOnce`,
   one key for all blank names). Names are used as given, without trimming.
   Telemetry calls never throw (invariant 1).

4. **The tracker remembers that it is suspended.** Today a screen shown while
   suspended starts a span at once, and `resume()` then keeps that span, so
   it includes background time. With the fix, a screen reported while
   suspended becomes current (name, crash context) and its span starts on
   resume. Both the observer and `Otel.setScreen` benefit, because they share
   the tracker. A deep link or notification tap that navigates before
   `resumed` is the realistic case.

5. **The README shows the auto_route tabs pattern rather than shipping it.**
   An `AutoRouterObserver` calls `Otel.setScreen(route.name)` on tab init
   and tab change, and remembers the last tab. `OtelNavigatorObserver`'s
   `screenName` maps the tab host route to that last tab, so popping back
   from a page opened on a tab reports the tab, not the host. Wrapper routes
   such as `SessionWrapperRoute` are left out with `routeFilter`.

## Risks / Trade-offs

- [The app reports dynamic names (ids, user data)] → `app.screen.name` is
  also a metric attribute. The doc comment and README require fixed names;
  the 2000-series cardinality cap bounds the damage.
- [The app and the observer disagree about the current screen] → last
  report wins by design. The README pattern shows how tab hosts and wrapper
  routes avoid fighting the tab names.
- [The tab host shows briefly at startup] → `HomeRoute` is pushed before the
  first `didInitTabRoute`, so a near-zero `screen HomeRoute` span can appear.
  This is harmless; the README mentions it, and the app can filter the host
  until the first tab is known.
- [The README snippet is not compiled in this repo (no auto_route
  dependency)] → it is checked against auto_route 11's `AutoRouterObserver`
  API and exercised for real in `my_team` (`tester-trial-via-funnel` 2.5).
