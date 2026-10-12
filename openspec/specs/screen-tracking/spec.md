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
