# Typed deterministic starter queries

Status: accepted.

## Context

The empty chat surface initially offered three built-in questions as plain
strings. Tapping one copied the text into the composer and sent it through the
same probabilistic text-to-SQL path as arbitrary user text. That made reviewed
product affordances dependent on model binding accuracy, repair sampling, and
model availability. A lease-expiry starter consequently generated `l.name`, even
though `leases` has no `name` column, and repeated the same invalid SQL during
repair.

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

The reviewed v1 catalog contains exactly five contracts:

1. **Which properties have the highest vacancy?** Five Held Properties with the
   highest Vacancy at each Property's Latest Snapshot.
2. **What's my rent roll by property type?** Annual base rent from Active or
   Holdover Leases at Held Properties, grouped by Property Type.
3. **Which leases expire in the next 12 months?** Active Leases at Held
   Properties expiring on or after the Portfolio As-of Date and before the date
   12 months later, listed with lease, tenant, and property identity.
4. **What's the current market value of the portfolio by fund?** The sum of
   `properties.current_market_value` for Held Properties, grouped by Fund. Its
   canonical SQL is:

   ```sql
   SELECT f.name AS fund,
          SUM(p.current_market_value) AS current_market_value
   FROM properties p
   JOIN funds f ON f.fund_id = p.fund_id
   WHERE p.status != 'Sold'
   GROUP BY f.name
   ORDER BY current_market_value DESC, f.name
   ```

5. **Which properties have loans maturing in the next 24 months?** Loans secured
   by Held Properties with maturity dates on or after the Portfolio As-of Date
   and before the date 24 months later, including property, lender, current
   balance, and maturity date. For the 2026-07-01 snapshot, its canonical SQL is:

   ```sql
   SELECT p.name AS property, ln.lender, ln.current_balance, ln.maturity_date
   FROM loans ln
   JOIN properties p ON p.property_id = ln.property_id
   WHERE p.status != 'Sold'
     AND ln.maturity_date >= '2026-07-01'
     AND ln.maturity_date < '2028-07-01'
   ORDER BY ln.maturity_date, p.name, ln.lender
   ```

The two date literals above are rendered from the versioned Portfolio As-of Date
contract, not read from the device clock. Any future semantic change adds a new
Starter Query identifier rather than reusing an existing identifier.

## Consequences

Built-in affordances become fast, reproducible, and immune to model binding
errors. Their semantics and date boundaries are reviewable in code, tests, and
telemetry. Product copy and SQL can still evolve, but only as an intentional
contract change.

The app now has two explicit query origins. Diagnostics and evaluation must keep
Starter Query reliability separate from free-form model accuracy. Adding a
Starter Query carries a maintenance obligation to review its semantics whenever
the portfolio schema or snapshot as-of date changes. The empty state must render
the five contracts in the catalog above and no longer treats display copy as an
execution identifier.
