## 1. Implementation

- [ ] 1.1 Make the screen tracker remember that it is suspended: `show()` while suspended updates the name, `app.screen.name` and the crash context but starts no span, and `resume()` starts the span for the current name; verify the new "screen reported while in the background" test in 2.1 fails before the change and passes after it
- [x] 1.2 Add `static void setScreen(String name)` to `Otel` in `lib/src/otel.dart`: blank names go to `Diagnostics.warnOnce` (one key) and are dropped, anything else goes to the shared tracker. Write a doc comment (for screens without a route push, last report wins with the observer, fixed names only, never ids or user data) and point the `currentScreen` doc at it; verify `~/fvm/versions/3.47.7/bin/flutter analyze` reports "No issues found!"

## 2. Tests

- [ ] 2.1 In `test/flutter_integration_test.dart`, add `otelTest` cases for each scenario in specs/screen-tracking: tab switch after an observed route, the same name twice, a route pushed after a manual screen, a blank name (current screen unchanged, one warning through `Diagnostics.printer`), background during a manual screen (two spans, simulated with `handleAppLifecycleStateChanged`), and a screen reported while in the background (no span until `resumed`, for both `Otel.setScreen` and an observed push); verify `~/fvm/versions/3.47.7/bin/flutter test test/flutter_integration_test.dart` passes
- [x] 2.2 Add a test that `Otel.setScreen('x')` before `Otel.init` neither throws nor exports anything; verify it passes in the same run

## 3. Docs

- [ ] 3.1 README, section "4. Manual instrumentation": add "Tabs and other screens without a route" next to the go_router section. Show `Otel.setScreen`, then the auto_route tabs pattern: an `AutoRouterObserver` calling `Otel.setScreen(route.name)` on `didInitTabRoute`/`didChangeTabRoute`, and `OtelNavigatorObserver` with `screenName` mapping the tab host to the last tab and `routeFilter` skipping wrapper routes. Mention the brief host span at startup and the fixed-names rule; verify the snippet against auto_route 11's `AutoRouterObserver` signatures
- [ ] 3.2 AGENTS.md: add `add-manual-screen-reporting` to the backlog table and update the test count under "Verified" and in Commands; verify `openspec list` shows the change and the counts match the `flutter test` output

## 4. Verification

- [ ] 4.1 Run `~/fvm/versions/3.47.7/bin/dart format --output=none --set-exit-if-changed .`, `~/fvm/versions/3.47.7/bin/flutter analyze` and `~/fvm/versions/3.47.7/bin/flutter test`; verify no format changes, "No issues found!" and all tests pass. No export or encoding code changes, so no e2e run is needed
- [ ] 4.2 Run `openspec validate --all --strict`; verify it passes
