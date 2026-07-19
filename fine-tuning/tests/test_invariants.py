"""Invariant tests for the generated CREG database.

These are the guarantees the correction heuristics, the gold set, and the
narration layer rely on. If one of these fails, the data — not the test —
is wrong. See docs/adr/0001-schema-semantics.md.
"""

import sqlite3

import pytest

from tools.generate_db import AS_OF, DEFAULT_SCHEMA, SEED, build, write_db

MONEY_EPS = 0.011  # two half-cent roundings


@pytest.fixture(scope="session")
def db(tmp_path_factory):
    path = tmp_path_factory.mktemp("db") / "creg.sqlite"
    write_db(build(), path, DEFAULT_SCHEMA)
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    yield conn
    conn.close()


def test_row_counts(db):
    counts = {t: db.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
              for t in ["funds", "properties", "tenants", "leases",
                        "property_financials", "loans", "valuations"]}
    assert counts["funds"] == 4
    assert counts["properties"] == 50
    assert counts["tenants"] == 150
    assert 250 <= counts["leases"] <= 600
    assert 1400 <= counts["property_financials"] <= 1800
    assert 35 <= counts["loans"] <= 60
    assert 90 <= counts["valuations"] <= 250


def test_foreign_key_integrity(db):
    assert db.execute("PRAGMA foreign_key_check").fetchall() == []


def test_month_grain_only(db):
    assert db.execute(
        "SELECT COUNT(*) FROM property_financials WHERE period_type != 'Month'"
    ).fetchone()[0] == 0


def test_financial_identities(db):
    rows = db.execute("""
        SELECT financial_id, gross_potential_rent, vacancy_loss,
               effective_gross_income, operating_expenses, net_operating_income
        FROM property_financials""").fetchall()
    for r in rows:
        assert abs(r["effective_gross_income"] - (r["gross_potential_rent"] - r["vacancy_loss"])) < MONEY_EPS, r["financial_id"]
        assert abs(r["net_operating_income"] - (r["effective_gross_income"] - r["operating_expenses"])) < MONEY_EPS, r["financial_id"]


def test_occupancy_matches_leases(db):
    """Stored occupancy_rate must equal lease-derived occupancy at each period_end.

    A lease occupies a month when commencement <= period_end and either
    expiration >= period_end or the lease is in Holdover.
    """
    rows = db.execute("""
        SELECT f.financial_id, f.occupancy_rate, p.rentable_sqft,
               (SELECT COALESCE(SUM(l.leased_sqft), 0) FROM leases l
                 WHERE l.property_id = f.property_id
                   AND l.status != 'Pending'
                   AND l.commencement_date <= f.period_end
                   AND (l.expiration_date >= f.period_end OR l.status = 'Holdover')
               ) AS occupied
        FROM property_financials f JOIN properties p USING (property_id)""").fetchall()
    for r in rows:
        expected = round(min(1.0, r["occupied"] / r["rentable_sqft"]), 4)
        assert abs(r["occupancy_rate"] - expected) <= 0.0001, r["financial_id"]


def test_lease_rent_identity(db):
    rows = db.execute(
        "SELECT lease_id, base_rent_psf, leased_sqft, annual_base_rent FROM leases").fetchall()
    for r in rows:
        assert abs(r["annual_base_rent"] - r["base_rent_psf"] * r["leased_sqft"]) < MONEY_EPS, r["lease_id"]


def test_no_suite_overlap(db):
    overlaps = db.execute("""
        SELECT a.lease_id, b.lease_id FROM leases a
        JOIN leases b ON a.property_id = b.property_id AND a.suite = b.suite
                     AND a.lease_id < b.lease_id
        WHERE a.commencement_date <= b.expiration_date
          AND b.commencement_date <= a.expiration_date""").fetchall()
    assert overlaps == []


def test_lease_status_agrees_with_dates(db):
    as_of = AS_OF.isoformat()
    bad = db.execute(f"""
        SELECT lease_id, status FROM leases WHERE NOT (
            (status = 'Active'     AND commencement_date <= '{as_of}' AND expiration_date >= '{as_of}')
         OR (status = 'Pending'    AND commencement_date >  '{as_of}')
         OR (status IN ('Expired', 'Terminated', 'Holdover') AND expiration_date < '{as_of}')
        )""").fetchall()
    assert [tuple(r) for r in bad] == []


def test_loan_sanity(db):
    rows = db.execute("""
        SELECT l.loan_id, l.original_balance, l.current_balance, l.ltv, l.dscr,
               l.origination_date, l.maturity_date, p.current_market_value
        FROM loans l JOIN properties p USING (property_id)""").fetchall()
    for r in rows:
        assert r["current_balance"] <= r["original_balance"] + MONEY_EPS, r["loan_id"]
        assert r["maturity_date"] > r["origination_date"], r["loan_id"]
        assert abs(r["ltv"] - r["current_balance"] / r["current_market_value"]) < 0.005, r["loan_id"]
        if r["dscr"] is not None:
            assert 0.5 <= r["dscr"] <= 5.0, r["loan_id"]


def test_latest_valuation_tracks_current_market_value(db):
    rows = db.execute("""
        SELECT p.property_id, p.current_market_value,
               (SELECT v.market_value FROM valuations v
                 WHERE v.property_id = p.property_id
                 ORDER BY v.valuation_date DESC LIMIT 1) AS latest
        FROM properties p WHERE p.status IN ('Owned', 'Under Contract')""").fetchall()
    for r in rows:
        assert r["latest"] is not None, r["property_id"]
        assert abs(r["latest"] - r["current_market_value"]) / r["current_market_value"] <= 0.05, r["property_id"]


def test_special_statuses(db):
    assert db.execute("SELECT COUNT(*) FROM properties WHERE status='Sold' AND disposition_date IS NOT NULL").fetchone()[0] == 2
    assert db.execute("SELECT COUNT(*) FROM properties WHERE status='In Development'").fetchone()[0] == 1
    dev_id = db.execute("SELECT property_id FROM properties WHERE status='In Development'").fetchone()[0]
    assert db.execute("SELECT COUNT(*) FROM leases WHERE property_id=?", (dev_id,)).fetchone()[0] == 0
    assert db.execute("SELECT COUNT(*) FROM property_financials WHERE property_id=?", (dev_id,)).fetchone()[0] == 0
    # sold properties have no financials after disposition
    assert db.execute("""
        SELECT COUNT(*) FROM property_financials f JOIN properties p USING (property_id)
        WHERE p.status = 'Sold' AND f.period_end > p.disposition_date""").fetchone()[0] == 0


def test_determinism():
    assert build(seed=SEED) == build(seed=SEED)
