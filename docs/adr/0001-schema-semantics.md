# Schema semantics: no units table, snapshot vacancy, month-grain financials, valuations as history

The seven-table schema (`db/schema.sql`, frozen 2026-07-19) is baked into the SQL grammar, the gold set, and the fine-tuning data, so these choices are expensive to reverse. Four of them will surprise a reader who knows CRE data models:

1. **No units table.** Suite, floor, and leased square footage live on `leases`. A separate unit/space entity would enable per-suite vacancy tracking but doubles the join surface for every tenant question; v1 doesn't need it.
2. **Vacancy is a financials snapshot, not lease arithmetic.** Canonical vacancy = `1 − occupancy_rate` from the property's latest Month row in `property_financials`. Deriving it from `SUM(leased_sqft)` would force judgment calls on Holdover/Pending statuses and can disagree with reported occupancy; the lease-derived figure is used only as a correction-layer cross-check.
3. **`property_financials` contains Month rows only.** The `period_type` column allows Quarter/Year, but v1 data never uses them: mixed grains in one table make every unfiltered SUM silently double-count — the worst failure mode for a text-to-SQL system. Quarters and years are derived in SQL by date grouping.
4. **`properties.current_market_value` is THE current value.** `valuations` is appraisal history (trends, cap rates, methods) and never answers "what is it worth now."

Reversing any of these means regenerating the grammar, re-verifying the gold set, and re-training.
