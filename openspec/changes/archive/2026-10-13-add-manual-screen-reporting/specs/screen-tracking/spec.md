## ADDED Requirements

### Requirement: Manual screen reporting
`Otel.setScreen(name)` SHALL make `name` the current screen, for screens that no navigator observer sees (tabs, page views, custom navigation). It SHALL have the same effects as a page route shown through `OtelNavigatorObserver`: the previous screen span ends, a `screen <name>` span starts, and later telemetry carries `app.screen.name = <name>`. The observer and this call SHALL share one current screen, so whichever reports last wins. Reporting the current screen again SHALL change nothing. A blank name SHALL be ignored with a one-time warning. Before `Otel.init` the call SHALL NOT throw.

#### Scenario: Tab switch
- **WHEN** screen `/` is shown through the observer and then `Otel.setScreen('ProfileTab')` is called
- **THEN** the `screen /` span ends, a `screen ProfileTab` span starts, and a span created afterwards has `app.screen.name = ProfileTab`

#### Scenario: Same screen again
- **WHEN** `Otel.setScreen('ProfileTab')` is called twice in a row and another screen is shown afterwards
- **THEN** exactly one `screen ProfileTab` span is exported

#### Scenario: Route pushed after a tab
- **WHEN** `Otel.setScreen('ProfileTab')` is called and then the observer sees `/details` pushed
- **THEN** the current screen is `/details` and the `screen ProfileTab` span has ended

#### Scenario: Blank name
- **WHEN** `Otel.setScreen('  ')` is called while `/` is shown
- **THEN** the current screen stays `/`, no span is started, and one warning is printed however often it happens

#### Scenario: Background during a reported screen
- **WHEN** the user leaves the app while on `ProfileTab` (reported by `Otel.setScreen`) and returns
- **THEN** two `screen ProfileTab` spans are exported, neither including the background time

#### Scenario: Screen reported while in the background
- **WHEN** `Otel.setScreen('ProfileTab')` is called, or the observer sees a route pushed, while the app is in the background
- **THEN** that screen becomes current immediately, and its `screen` span starts only when the app returns to the foreground
