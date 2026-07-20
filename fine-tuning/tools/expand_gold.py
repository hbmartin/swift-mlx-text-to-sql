"""Expand the gold set from stage 1 (60 hand-written) to ~200 items.

Template families instantiated over real entities from db/creg.sqlite, with
paraphrase rotation. Every generated item is executed; degenerate results
(empty / NULL scalar) are dropped; questions are deduped against stage 1 and
within the batch. Deterministic (seeded).

The synthetic TRAINING data generator (synth/) must dedup against the union
of these questions — gold never enters training (PRD §12).

Usage:  uv run python -m tools.expand_gold
"""

import json
import random
import sqlite3
from pathlib import Path

from eval.ex import ExecutionError, execute

REPO_ROOT = Path(__file__).resolve().parents[2]
DB = REPO_ROOT / "db" / "creg.sqlite"
GOLD_V1 = REPO_ROOT / "eval" / "gold" / "gold_v1.jsonl"
GOLD_V2 = REPO_ROOT / "eval" / "gold" / "gold_v2.jsonl"
SEED = 20260719
TARGET_NEW = 140

OCCUPYING = "('Active', 'Holdover')"


def normalize(question: str) -> str:
    return "".join(c for c in question.lower() if c.isalnum() or c == " ").strip()


def main() -> None:
    rng = random.Random(SEED)
    conn = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)

    def col(sql: str) -> list:
        return [r[0] for r in conn.execute(sql)]

    types = col("SELECT DISTINCT property_type FROM properties ORDER BY 1")
    markets = col("SELECT DISTINCT market FROM properties ORDER BY 1")
    funds = col("SELECT name FROM funds ORDER BY fund_id")
    held_props = col("SELECT name FROM properties WHERE status != 'Sold' ORDER BY name")
    financial_props = col(
        "SELECT DISTINCT p.name FROM properties p JOIN property_financials f USING (property_id) ORDER BY 1")
    big_tenants = col(f"""
        SELECT t.name FROM tenants t JOIN leases l USING (tenant_id)
        WHERE l.status IN {OCCUPYING} GROUP BY t.name
        ORDER BY SUM(l.leased_sqft) DESC LIMIT 30""")
    industries = col("SELECT DISTINCT industry FROM tenants ORDER BY 1")
    lease_types = col("SELECT DISTINCT lease_type FROM leases ORDER BY 1")

    items: list[dict] = []

    def add(family: str, tier: int, question: str, sql: str, tags: list[str]) -> None:
        items.append({
            "family": family, "tier": tier, "tags": tags,
            "question": question, "sql": sql,
        })

    def pick(options: list[str], **kw) -> str:
        return rng.choice(options).format(**kw)

    for t in types:
        add("type_rentroll", 2, pick([
            "What's the total annual base rent from our {t} properties right now?",
            "How much annual base rent do the {t} assets generate currently?",
        ], t=t.lower()), f"SELECT SUM(l.annual_base_rent) FROM leases l JOIN properties p ON p.property_id = l.property_id WHERE p.property_type = '{t}' AND l.status IN {OCCUPYING}", ["rentroll", "join"])
        add("type_count", 1, pick([
            "How many {t} properties do we currently hold?",
            "How many {t} buildings are in the held portfolio?",
        ], t=t.lower()), f"SELECT COUNT(*) FROM properties WHERE property_type = '{t}' AND status != 'Sold'", ["count"])
        add("type_avg_psf", 2, pick([
            "What's the average base rent per square foot on active leases in {t} properties?",
            "Across our {t} assets, what's the mean active-lease rent PSF?",
        ], t=t.lower()), f"SELECT AVG(l.base_rent_psf) FROM leases l JOIN properties p ON p.property_id = l.property_id WHERE p.property_type = '{t}' AND l.status = 'Active'", ["join", "aggregate"])

    for m in markets:
        add("market_value", 2, pick([
            "What's the combined current market value of our held properties in {m}?",
            "How much are the {m} holdings worth today in total?",
        ], m=m), f"SELECT SUM(current_market_value) FROM properties WHERE market = '{m}' AND status != 'Sold'", ["canonical", "aggregate"])
        add("market_occ", 2, pick([
            "What was the average occupancy rate across {m} properties in June 2026?",
            "In June 2026, how occupied were our {m} buildings on average?",
        ], m=m), f"SELECT AVG(f.occupancy_rate) FROM property_financials f JOIN properties p ON p.property_id = f.property_id WHERE p.market = '{m}' AND f.period_end = '2026-06-30'", ["financials", "join"])

    for f in funds:
        add("fund_hold", 1, pick([
            "How many properties does {f} currently hold?",
            "What's the held property count for {f}?",
        ], f=f), f"SELECT COUNT(*) FROM properties p JOIN funds fu ON fu.fund_id = p.fund_id WHERE fu.name = '{f}' AND p.status != 'Sold'", ["count", "join"])
        add("fund_noi", 2, pick([
            "What NOI did {f}'s portfolio produce over the last 12 months?",
            "How much net operating income came from {f} in the past year?",
        ], f=f), f"SELECT SUM(pf.net_operating_income) FROM property_financials pf JOIN properties p ON p.property_id = pf.property_id JOIN funds fu ON fu.fund_id = p.fund_id WHERE fu.name = '{f}' AND pf.period_end >= '2025-07-01'", ["financials", "join"])

    for p in rng.sample(held_props, 8):
        add("prop_value", 1, pick([
            "What is {p} worth today?",
            "What's the current market value of {p}?",
        ], p=p), f"SELECT current_market_value FROM properties WHERE name = '{p}'", ["canonical"])
    for p in rng.sample(held_props, 8):
        question = pick([
            "How many active leases are in place at {p}?",
            "How many tenants hold active leases at {p}?",
        ], p=p)
        count_expr = "COUNT(DISTINCT l.tenant_id)" if "tenants" in question.lower() else "COUNT(*)"
        add(
            "prop_leasecount", 2, question,
            f"SELECT {count_expr} FROM leases l JOIN properties p ON p.property_id = l.property_id WHERE p.name = '{p}' AND l.status = 'Active'",
            ["count", "join"])
    for p in rng.sample(financial_props, 8):
        add("prop_noi25", 2, pick([
            "What was {p}'s total NOI in 2025?",
            "How much net operating income did {p} generate during 2025?",
        ], p=p), f"SELECT SUM(f.net_operating_income) FROM property_financials f JOIN properties p ON p.property_id = f.property_id WHERE p.name = '{p}' AND f.period_end >= '2025-01-01' AND f.period_end <= '2025-12-31'", ["financials", "join"])
    for p in rng.sample(financial_props, 8):
        add("prop_occ_latest", 2, pick([
            "What's the latest occupancy rate at {p}?",
            "How occupied is {p} as of the most recent month?",
        ], p=p), f"SELECT f.occupancy_rate FROM property_financials f JOIN properties p ON p.property_id = f.property_id WHERE p.name = '{p}' AND f.period_end = (SELECT MAX(period_end) FROM property_financials WHERE property_id = p.property_id)", ["canonical", "nested"])
    for p in rng.sample(financial_props, 6):
        add("prop_vacancy", 2, pick([
            "What is the current vacancy at {p}?",
            "How vacant is {p} right now?",
        ], p=p), f"SELECT 1 - f.occupancy_rate FROM property_financials f JOIN properties p ON p.property_id = f.property_id WHERE p.name = '{p}' AND f.period_end = (SELECT MAX(period_end) FROM property_financials WHERE property_id = p.property_id)", ["canonical", "vacancy", "nested"])

    for t in rng.sample(big_tenants, 8):
        add("tenant_sqft", 2, pick([
            "How much space does {t} lease from us in total?",
            "What's {t}'s total leased square footage with us right now?",
        ], t=t), f"SELECT SUM(l.leased_sqft) FROM leases l JOIN tenants t ON t.tenant_id = l.tenant_id WHERE t.name = '{t}' AND l.status IN {OCCUPYING}", ["join", "aggregate"])
    for t in rng.sample(big_tenants, 8):
        add("tenant_props", 2, pick([
            "Which properties does {t} currently occupy?",
            "Where does {t} lease space from us?",
        ], t=t), f"SELECT DISTINCT p.name FROM properties p JOIN leases l ON l.property_id = p.property_id JOIN tenants t ON t.tenant_id = l.tenant_id WHERE t.name = '{t}' AND l.status IN {OCCUPYING}", ["join"])

    for ind in industries:
        if ind == "Healthcare":  # covered by hand-written T2-39
            continue
        add("industry_sqft", 2, pick([
            "How much space is currently leased to {ind} tenants?",
            "What's the total square footage occupied by tenants in {ind}?",
        ], ind=ind.lower() if ind != "Government" else ind.lower()), f"SELECT SUM(l.leased_sqft) FROM leases l JOIN tenants t ON t.tenant_id = l.tenant_id WHERE t.industry = '{ind}' AND l.status IN {OCCUPYING}", ["join", "aggregate"])

    for months, end in [(6, "2027-01-01"), (18, "2028-01-01"), (24, "2028-07-01")]:
        add("expiry_window", 1, pick([
            "How many active leases expire within the next {n} months?",
            "How many of our active leases roll in the coming {n} months?",
        ], n=months), f"SELECT COUNT(*) FROM leases WHERE status = 'Active' AND expiration_date >= '2026-07-01' AND expiration_date < '{end}'", ["count", "dates"])

    for year in [2027, 2028, 2029, 2030]:
        add("loan_year", 2, pick([
            "Which properties have loans maturing in {y}, and with which lenders?",
            "List the {y} loan maturities: property and lender.",
        ], y=year), f"SELECT p.name, ln.lender FROM loans ln JOIN properties p ON p.property_id = ln.property_id WHERE ln.maturity_date >= '{year}-01-01' AND ln.maturity_date <= '{year}-12-31'", ["join", "dates"])

    for n, metric, sql_metric, tier in [
        (3, "current market value", "current_market_value", 1),
        (5, "current market value", "current_market_value", 1),
        (3, "rentable square footage", "rentable_sqft", 1),
        (10, "rentable square footage", "rentable_sqft", 1),
    ]:
        add("top_n_prop", tier, pick([
            "What are the top {n} held properties by {metric}?",
            "Rank our {n} largest held properties by {metric}.",
        ], n=n, metric=metric), f"SELECT name FROM properties WHERE status != 'Sold' ORDER BY {sql_metric} DESC LIMIT {n}", ["superlative"])
    for n in [3, 5]:
        add("top_n_noi", 3, pick([
            "Which {n} properties produced the most NOI over the last 12 months?",
            "Top {n} properties by trailing-12-month NOI?",
        ], n=n), f"SELECT p.name FROM property_financials f JOIN properties p ON p.property_id = f.property_id WHERE f.period_end >= '2025-07-01' GROUP BY p.name ORDER BY SUM(f.net_operating_income) DESC LIMIT {n}", ["superlative", "financials"])

    for c in ["A", "B", "C"]:
        add("class_count", 1, pick([
            "How many held properties are Class {c} buildings?",
            "What's our count of Class {c} properties still held?",
        ], c=c), f"SELECT COUNT(*) FROM properties WHERE building_class = '{c}' AND status != 'Sold'", ["count"])

    for lt in lease_types:
        add("lease_type_rent", 2, pick([
            "How much annual base rent comes from occupying {lt} leases?",
            "What's the current annual rent total on {lt} lease structures?",
        ], lt=lt), f"SELECT SUM(annual_base_rent) FROM leases WHERE lease_type = '{lt}' AND status IN {OCCUPYING}", ["aggregate"])

    for m in rng.sample(markets, 5):
        add("market_latest_val", 3, pick([
            "For each held property in {m}, what was its most recent appraised value?",
            "Show the latest appraisal value for every held property in {m}.",
        ], m=m), f"SELECT p.name, v.market_value FROM properties p JOIN valuations v ON v.property_id = p.property_id WHERE p.market = '{m}' AND p.status != 'Sold' AND v.valuation_date = (SELECT MAX(valuation_date) FROM valuations WHERE property_id = p.property_id)", ["nested", "valuations"])

    add("rank_markets", 3,
        "Rank the markets by total current rent roll, highest first.",
        f"SELECT p.market, SUM(l.annual_base_rent) AS rent FROM leases l JOIN properties p ON p.property_id = l.property_id WHERE l.status IN {OCCUPYING} GROUP BY p.market ORDER BY rent DESC", ["rentroll", "order"])

    for r in ["AAA", "BBB", "NR"]:
        add("credit_rent", 2, pick([
            "How much annual base rent comes from tenants rated {r}?",
            "What's the rent roll exposure to {r}-rated tenants?",
        ], r=r), f"SELECT SUM(l.annual_base_rent) FROM leases l JOIN tenants t ON t.tenant_id = l.tenant_id WHERE t.credit_rating = '{r}' AND l.status IN {OCCUPYING}", ["join", "aggregate"])

    # -- validate, dedup, cap ------------------------------------------------
    seen = {normalize(json.loads(line)["question"])
            for line in GOLD_V1.read_text().splitlines() if line.strip()}
    kept: list[dict] = []
    dropped = {"dup": 0, "degenerate": 0, "error": 0}
    for item in items:
        key = normalize(item["question"])
        if key in seen:
            dropped["dup"] += 1
            continue
        try:
            rows = execute(DB, item["sql"])
        except ExecutionError:
            dropped["error"] += 1
            continue
        if not rows or (len(rows) == 1 and all(v is None for v in rows[0])):
            dropped["degenerate"] += 1
            continue
        seen.add(key)
        kept.append(item)
        if len(kept) >= TARGET_NEW:
            break

    lines = GOLD_V1.read_text().splitlines()
    for i, item in enumerate(kept):
        record = {
            "id": f"G-{101 + i}", "tier": item["tier"],
            "tags": item["tags"] + ["generated", item["family"]],
            "question": item["question"], "sql": item["sql"],
        }
        lines.append(json.dumps(record))
    GOLD_V2.write_text("\n".join(lines) + "\n")
    print(f"generated {len(items)}, kept {len(kept)}, dropped {dropped}")
    print(f"gold_v2 total = {len(lines)} -> {GOLD_V2}")


if __name__ == "__main__":
    main()
