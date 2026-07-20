from pathlib import Path

import xgrammar
from xgrammar.testing import _is_grammar_accept_string as grammar_accepts


GRAMMAR_PATH = (
    Path(__file__).resolve().parents[2]
    / "CREGKit"
    / "Sources"
    / "CREGEngine"
    / "Resources"
    / "sql_grammar.ebnf"
)


def grammar():
    return xgrammar.Grammar.from_ebnf(GRAMMAR_PATH.read_text())


def test_aggregate_forms_match_sqlite_arity():
    parsed = grammar()
    assert grammar_accepts(parsed, "SELECT COUNT(*) FROM leases")
    assert grammar_accepts(
        parsed, "SELECT COUNT(DISTINCT tenant_id) FROM leases"
    )
    assert grammar_accepts(parsed, "SELECT SUM(annual_base_rent) FROM leases")
    assert not grammar_accepts(parsed, "SELECT SUM(*) FROM leases")


def test_coalesce_requires_at_least_two_arguments():
    parsed = grammar()
    assert grammar_accepts(
        parsed, "SELECT COALESCE(current_market_value, 0) FROM properties"
    )
    assert not grammar_accepts(
        parsed, "SELECT COALESCE(current_market_value) FROM properties"
    )


def test_boolean_chains_are_bounded():
    parsed = grammar()
    allowed = " AND ".join(["status = 'Active'"] * 13)
    rejected = " AND ".join(["status = 'Active'"] * 14)
    assert grammar_accepts(parsed, f"SELECT lease_id FROM leases WHERE {allowed}")
    assert not grammar_accepts(
        parsed, f"SELECT lease_id FROM leases WHERE {rejected}"
    )
