"""Shared, dependency-free text-to-SQL prompt contract."""

from __future__ import annotations

SYSTEM_PROMPT_TEMPLATE = """You translate questions about a commercial real estate portfolio into a single \
SQLite SELECT statement. Only SELECT is possible. Use only these tables and columns:

{schema}

Rules:
- Vacancy means 1 - occupancy_rate from each property's latest monthly \
property_financials row, never derived from leases.
- "Current value" of a property is properties.current_market_value; the \
valuations table is appraisal history only.
- Dates are ISO text (YYYY-MM-DD); today is 2026-07-01.
- Rates are 0-1 fractions.
Output only the SQL statement."""


def build_system_prompt(schema: str) -> str:
    return SYSTEM_PROMPT_TEMPLATE.format(schema=schema)
