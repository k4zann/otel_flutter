# screen-tracking Specification

## Purpose

Know which screen the user is on, how long they stay there, and on which screen errors, slow frames and other telemetry happen.

## Requirements

### Requirement: Navigator observer
`OtelNavigatorObserver` SHALL track page routes pushed, popped, replaced or removed in the navigator it is attached to, including go_router via its `observers` list. Dialogs, popups and bottom sheets SHALL be ignored by default. Both the route filter and the screen name SHALL be configurable; the default name SHALL be `RouteSettings.name`, or `unnamed` when absent.

#### Scenario: Dialog over a page
- **WHEN** a dialog opens on screen `/details` and is closed
- **THEN** the current screen stays `/details` throughout

#### Scenario: Pop back
- **WHEN** `/details` is popped back to `/`
- **THEN** the current screen becomes `/`

### Requirement: Screen view spans
Each visit to a screen SHALL produce one root span named `screen <name>` with attribute `app.screen.name`, ending when another screen is shown. Time in the background SHALL not count: the span SHALL end when the app goes to the background and a new one SHALL start on return.

#### Scenario: Background during a visit
- **WHEN** the user leaves the app for a while on screen `/` and returns
- **THEN** two `screen /` spans are exported, neither including the background time

### Requirement: Screen context on all telemetry
The current screen name SHALL be added as `app.screen.name` to spans, logs, error metrics and frame metrics recorded while it is shown.

#### Scenario: Span on details
- **WHEN** a span is created while `/details` is shown
- **THEN** it has `app.screen.name = /details`

### Requirement: Privacy
Route arguments SHALL never be recorded.

#### Scenario: Route with arguments
- **WHEN** a route is pushed with arguments containing an email address
- **THEN** no exported telemetry contains those arguments

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
