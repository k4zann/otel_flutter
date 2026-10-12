# ui-performance Specification

## Purpose

Measure what users feel as slowness: slow and frozen frames, UI-thread freezes between frames, and cold start time.

## Requirements

### Requirement: Frame metrics
When frame capture is enabled (default), the SDK SHALL count rendered frames (`app.frames`), slow frames (`app.frames.slow`: max(build, raster) above the frame budget derived from the display refresh rate, 60 Hz if unknown) and frozen frames (`app.frames.frozen`: 700 ms or more). It SHALL record histogram `app.frame.duration` in milliseconds, tagged with `app.screen.name`. The engine's vsync overhead SHALL not be counted. Each frozen frame SHALL emit an `app.jank` event with `flutter.jank.source = frame`. Collection SHALL add no per-frame work on the UI thread beyond processing the engine's batched timings.

#### Scenario: Mixed frames
- **WHEN** frames with (build, raster) of (4, 5), (25, 3) and (2, 800) ms are reported on a 60 Hz display
- **THEN** frames = 3, slow = 2, frozen = 1, and one `app.jank` event is emitted

### Requirement: UI stall detection
When stall capture is enabled (default), the SDK SHALL detect the UI thread being blocked for 500 ms or more between frames, for example by a slow tap handler. It SHALL count each stall in `app.ui.stalls` with `app.screen.name` and emit an `app.jank` event with `flutter.jank.source = ui_stall` and `app.jank.period` set to the measured lower bound in seconds. Detection SHALL run only in the foreground, with at most 5 wake-ups per second.

#### Scenario: Blocking tap handler
- **WHEN** a button handler blocks the UI thread for 800 ms
- **THEN** one `app.ui.stalls` increment and one `app.jank` event with a period of at least 0.6 s are exported

#### Scenario: Background
- **WHEN** the app goes to the background
- **THEN** stall detection stops until the app is resumed

### Requirement: App start
When app-start capture is enabled (default) and `Otel.init` runs before the first frame, the SDK SHALL export a root span `app.start` from init to the first rasterized frame, and record histogram `app.start.duration` in milliseconds.

#### Scenario: Cold start
- **WHEN** the app launches and draws its first frame
- **THEN** one `app.start` span and one `app.start.duration` value are exported
