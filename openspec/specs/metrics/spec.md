# metrics Specification

## Purpose

Record numeric measurements (counts, distributions, current values), aggregate them in memory and export them periodically with bounded memory and no traffic when idle.

## Requirements

### Requirement: Instrument kinds
The library SHALL provide counter (monotonic sum), up-down counter (sum that can decrease), histogram (explicit buckets with count, sum, min and max), gauge (last recorded value) and observable gauge (value read from a callback at collection). A counter SHALL ignore negative values and print a warning once.

#### Scenario: Negative counter value
- **WHEN** `add(-3)` is called on a counter
- **THEN** the value is ignored and nothing is thrown

#### Scenario: Observable gauge callback throws
- **WHEN** an observable gauge callback throws during collection
- **THEN** that gauge is skipped and other metrics are still exported

### Requirement: Instrument identity
Requesting an instrument with the same name (case-insensitive) on the same meter SHALL return the same instrument. Requesting the same name with a different kind SHALL create a separate instrument and print a warning once.

#### Scenario: Instrument requested in a hot path
- **WHEN** `counter('x')` is called 1,000 times on the same meter
- **THEN** one instrument exists and all values accumulate in it

### Requirement: Aggregation per attribute set
Values SHALL be aggregated per distinct attribute set. The set SHALL not depend on key order and SHALL distinguish value types (int `1` and string `"1"` are different sets). Sums SHALL stay integers until a double is added.

#### Scenario: Same attributes, different order
- **WHEN** a counter receives 1 with `{a: 1, b: x}` and 2 with `{b: x, a: 1}`
- **THEN** one point with value 3 is exported

### Requirement: Histogram buckets
Histogram buckets SHALL use inclusive upper bounds. The default bounds SHALL be `0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000`. Custom bounds SHALL be accepted per instrument and sorted ascending.

#### Scenario: Value on a boundary
- **WHEN** bounds are `[10, 20]` and the values `0, 10, 10.5, 20, 21, 1000` are recorded
- **THEN** bucket counts are `[2, 2, 2]`, count 6, sum 1061.5, min 0, max 1000

### Requirement: Temporality
Cumulative temporality (default) SHALL export running totals with the start time of each series. Delta temporality SHALL export only series changed since the last collection, reset them after export, and use the previous collection time as start time.

#### Scenario: Delta resets
- **WHEN** temporality is delta and a counter receives 1, is collected, then receives 4
- **THEN** the second collection exports 4

### Requirement: Cardinality limit
Each instrument SHALL keep at most 2000 attribute sets. Values for further sets SHALL go to a single series with attribute `otel.metric.overflow=true`, and a warning SHALL be printed once.

#### Scenario: Unbounded attribute value
- **WHEN** the limit is 5 and a counter receives values for 20 distinct user ids
- **THEN** 5 series are exported, one of them the overflow series holding the remaining 16

### Requirement: Collection and idle behaviour
Metrics SHALL be collected every metric interval (default 60 s) while the app is in the foreground, and once when it goes to the background. When no instrument changed since the last collection and no observable gauge exists, no request SHALL be sent.

#### Scenario: Idle app
- **WHEN** nothing is recorded between two collections
- **THEN** the second collection sends no request

### Requirement: No-op before initialization
Recording before `Otel.init` SHALL be ignored without error. Instruments created before initialization SHALL record once initialization has completed.

#### Scenario: Early instrument
- **WHEN** a counter is created and incremented before init, then incremented by 2 after init
- **THEN** the exported value is 2
