# Typed deterministic starter queries

Status: accepted.

## Context

The empty chat surface offered three built-in questions as plain strings. Tapping
one copied the text into the composer and sent it through the same probabilistic
text-to-SQL path as arbitrary user text. That made reviewed product affordances
dependent on model binding accuracy, repair sampling, and model availability. A
lease-expiry starter consequently generated `l.name`, even though `leases` has no
`name` column, and repeated the same invalid SQL during repair.

Treating starter text as its identity also lets a copy edit silently change its
meaning. Relative dates are especially unsafe because the bundled portfolio is a
fixed snapshot whose as-of date can differ from the device clock.

## Decision

Starter Queries are typed, versioned product contracts in the engine. Each has a
stable identifier, display question, semantic description, and canonical,
read-only SQLite query. Relative date boundaries use the Portfolio As-of Date
versioned with the bundled data.

The UI submits a Starter Query identifier, never an arbitrary starter string.
The pipeline validates and executes its canonical SQL, performs grounding, and
narrates the result. It does not invoke follow-up rewriting, the Ambiguity Gate,
SQL generation, repair, or voting. Telemetry records the query origin, starter
identifier, and deterministic execution path. Free-form questions retain the
generated path.

Every Starter Query must have regression coverage that validates its SQL against
the production schema and executes it against the bundled snapshot. The
lease-listing starter must obtain human-readable names from `tenants.name` and
`properties.name`; `leases` is identified by `lease_id` and has no name.

## Consequences

Built-in affordances become fast, reproducible, and immune to model binding
errors. Their semantics and date boundaries are reviewable in code, tests, and
telemetry. Product copy and SQL can still evolve, but only as an intentional
contract change.

The app now has two explicit query origins. Diagnostics and evaluation must keep
Starter Query reliability separate from free-form model accuracy. Adding a
Starter Query carries a maintenance obligation to review its semantics whenever
the portfolio schema or snapshot as-of date changes.
