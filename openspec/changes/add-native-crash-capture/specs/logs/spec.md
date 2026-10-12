## MODIFIED Requirements

### Requirement: Common attributes
Every record SHALL include `session.id`, the current `app.screen.name` when known, and global attributes. Explicit record attributes SHALL override them, and an explicit null value SHALL remove them (for example, a report about an earlier run must not carry the current session).

#### Scenario: Global user id
- **WHEN** `Otel.setUser('u-42')` was called and a log is emitted
- **THEN** the record has `user.id = u-42`

#### Scenario: Record about an earlier run
- **WHEN** a log is emitted with attribute `session.id = null`
- **THEN** the record has no `session.id`
