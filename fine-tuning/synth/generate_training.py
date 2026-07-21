"""Generate synthetic in-domain training data for the SQL specialist.

Schema-grounded templating over real entity values (PRD §13 method 1), with
paraphrase rotation (method 4 done template-side). Every candidate passes the
quality gate before entering training:

  1. executes against db/creg.sqlite without error
  2. non-degenerate result (rows > 0, not a single NULL scalar)
  3. accepted by the decoding grammar (sql_grammar.ebnf)
  4. question not present (normalized) in the gold set — gold stays held out
  5. deduped within the batch

Judge-gate stats are logged to synth/out/gate_stats.json for auditing.
Output: chat-format JSONL (system prompt identical to the runtime prompt)
split into train/valid for mlx_lm lora.

The SQL specialist is trained on STANDALONE questions only — follow-up
rewriting is the FM's job at runtime, so multi-turn pairs are not part of
this dataset (see docs/data-synthesis.md).

Usage:  uv run python -m synth.generate_training
"""

import argparse
import json
import random
import sqlite3
from pathlib import Path

import xgrammar
from xgrammar.testing import _is_grammar_accept_string as grammar_accepts

from eval.ex import ExecutionError, execute

REPO_ROOT = Path(__file__).resolve().parents[2]
DB = REPO_ROOT / "db" / "creg.sqlite"
GOLD = REPO_ROOT / "eval" / "gold" / "gold_v2.jsonl"
GRAMMAR_PATH = REPO_ROOT / "CREGKit" / "Sources" / "CREGEngine" / "Resources" / "sql_grammar.ebnf"
SCHEMA_PROMPT = REPO_ROOT / "CREGKit" / "Sources" / "CREGEngine" / "Resources" / "schema_prompt.txt"
OUT_DIR = REPO_ROOT / "fine-tuning" / "synth" / "out"

SEED = 424242
TARGET = 3000
VALID_FRACTION = 0.05
OCCUPYING = "('Active', 'Holdover')"

SYSTEM_PROMPT = """You translate questions about a commercial real estate portfolio into a single \
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


def normalize(question: str) -> str:
    return "".join(c for c in question.lower() if c.isalnum() or c == " ").strip()


def load_entities(conn) -> dict:
    def col(sql):
        return [r[0] for r in conn.execute(sql)]

    return {
        "types": col("SELECT DISTINCT property_type FROM properties ORDER BY 1"),
        "markets": col("SELECT DISTINCT market FROM properties ORDER BY 1"),
        "submarkets": col("SELECT DISTINCT submarket FROM properties ORDER BY 1"),
        "funds": col("SELECT name FROM funds ORDER BY fund_id"),
        "props": col("SELECT name FROM properties ORDER BY name"),
        "held": col("SELECT name FROM properties WHERE status != 'Sold' ORDER BY name"),
        "fin_props": col("SELECT DISTINCT p.name FROM properties p JOIN property_financials f USING (property_id) ORDER BY 1"),
        "tenants": col(f"SELECT DISTINCT t.name FROM tenants t JOIN leases l USING (tenant_id) WHERE l.status IN {OCCUPYING} ORDER BY 1"),
        "industries": col("SELECT DISTINCT industry FROM tenants ORDER BY 1"),
        "lease_types": col("SELECT DISTINCT lease_type FROM leases ORDER BY 1"),
        "lenders": col("SELECT DISTINCT lender FROM loans ORDER BY 1"),
        "classes": ["A", "B", "C"],
        "ratings": col("SELECT DISTINCT credit_rating FROM tenants ORDER BY 1"),
        "statuses": col("SELECT DISTINCT status FROM properties ORDER BY 1"),
    }


def build_candidates(rng: random.Random, e: dict) -> list[dict]:
    """Yield (question, sql, family, tier) candidates — intentionally more
    than TARGET; the gate and dedup thin them out."""
    out: list[dict] = []

    def add(family, tier, question, sql):
        out.append({"family": family, "tier": tier, "question": question, "sql": sql})

    def phr(options, **kw):
        return rng.choice(options).format(**kw)

    months = [("January", "01", "31"), ("February", "02", "28"), ("March", "03", "31"),
              ("April", "04", "30"), ("May", "05", "31"), ("June", "06", "30")]
    years = ["2024", "2025", "2026"]

    # --- per-property scalars (wide entity coverage) ----------------------
    for p in e["held"]:
        add("prop_value", 1, phr([
            "What is {p} worth today?", "Current value of {p}?",
            "What's {p}'s current market value?", "How much is {p} valued at right now?",
        ], p=p), f"SELECT current_market_value FROM properties WHERE name = '{p}'")
        add("prop_sqft", 1, phr([
            "How big is {p} in rentable square feet?", "What's the rentable area of {p}?",
            "Rentable square footage of {p}?",
        ], p=p), f"SELECT rentable_sqft FROM properties WHERE name = '{p}'")
        add("prop_type_q", 1, phr([
            "What type of property is {p}?", "What's the asset type of {p}?",
        ], p=p), f"SELECT property_type FROM properties WHERE name = '{p}'")
        add("prop_market_q", 1, phr([
            "Which market is {p} in?", "Where is {p} located?",
        ], p=p), f"SELECT market FROM properties WHERE name = '{p}'")
        add("prop_built", 1, phr([
            "When was {p} built?", "What year was {p} constructed?",
        ], p=p), f"SELECT year_built FROM properties WHERE name = '{p}'")
        add("prop_acq", 1, phr([
            "When did we acquire {p} and for how much?",
            "What did we pay for {p}, and when?",
        ], p=p), f"SELECT acquisition_date, acquisition_price FROM properties WHERE name = '{p}'")
    for p in e["held"]:
        add("prop_active_leases", 2, phr([
            "How many active leases are at {p}?", "Active lease count at {p}?",
            "How many tenants have active leases in {p}?",
        ], p=p), f"SELECT COUNT(*) FROM leases l JOIN properties p ON p.property_id = l.property_id WHERE p.name = '{p}' AND l.status = 'Active'")
        add("prop_rentroll", 2, phr([
            "What's the current rent roll at {p}?",
            "Total annual base rent at {p} right now?",
        ], p=p), f"SELECT SUM(l.annual_base_rent) FROM leases l JOIN properties p ON p.property_id = l.property_id WHERE p.name = '{p}' AND l.status IN {OCCUPYING}")
        add("prop_tenants", 2, phr([
            "Who are the tenants at {p}?", "Which companies lease space in {p}?",
        ], p=p), f"SELECT DISTINCT t.name FROM tenants t JOIN leases l ON l.tenant_id = t.tenant_id JOIN properties p ON p.property_id = l.property_id WHERE p.name = '{p}' AND l.status IN {OCCUPYING}")
    for p in e["fin_props"]:
        add("prop_occ", 2, phr([
            "What's the latest occupancy at {p}?", "How occupied is {p} now?",
            "Current occupancy rate for {p}?",
        ], p=p), f"SELECT f.occupancy_rate FROM property_financials f JOIN properties p ON p.property_id = f.property_id WHERE p.name = '{p}' AND f.period_end = (SELECT MAX(period_end) FROM property_financials WHERE property_id = p.property_id)")
        add("prop_vacancy", 2, phr([
            "How vacant is {p} right now?", "What's the current vacancy at {p}?",
        ], p=p), f"SELECT 1 - f.occupancy_rate FROM property_financials f JOIN properties p ON p.property_id = f.property_id WHERE p.name = '{p}' AND f.period_end = (SELECT MAX(period_end) FROM property_financials WHERE property_id = p.property_id)")
        for y in years:
            add("prop_noi_year", 2, phr([
                "What was {p}'s NOI in {y}?", "Total net operating income for {p} during {y}?",
                "How much NOI did {p} produce in {y}?",
            ], p=p, y=y), f"SELECT SUM(f.net_operating_income) FROM property_financials f JOIN properties p ON p.property_id = f.property_id WHERE p.name = '{p}' AND f.period_end >= '{y}-01-01' AND f.period_end <= '{y}-12-31'")

    # --- monthly financial lookups ---------------------------------------
    for p in e["fin_props"]:
        for name, mm, dd in rng.sample(months, 2):
            add("prop_month_noi", 2, phr([
                "What was {p}'s NOI in {m} 2026?", "NOI at {p} for {m} 2026?",
            ], p=p, m=name), f"SELECT net_operating_income FROM property_financials f JOIN properties p ON p.property_id = f.property_id WHERE p.name = '{p}' AND f.period_end = '2026-{mm}-{dd}'")

    # --- per-tenant -------------------------------------------------------
    for t in e["tenants"]:
        add("tenant_sqft", 2, phr([
            "How much space does {t} lease from us?", "Total square footage leased by {t}?",
            "What's {t}'s footprint across the portfolio?",
        ], t=t), f"SELECT SUM(l.leased_sqft) FROM leases l JOIN tenants t ON t.tenant_id = l.tenant_id WHERE t.name = '{t}' AND l.status IN {OCCUPYING}")
        add("tenant_rent", 2, phr([
            "How much annual rent does {t} pay us?", "What's {t}'s total annual base rent?",
        ], t=t), f"SELECT SUM(l.annual_base_rent) FROM leases l JOIN tenants t ON t.tenant_id = l.tenant_id WHERE t.name = '{t}' AND l.status IN {OCCUPYING}")
        add("tenant_where", 2, phr([
            "Which properties does {t} lease in?", "Where does {t} rent space?",
        ], t=t), f"SELECT DISTINCT p.name FROM properties p JOIN leases l ON l.property_id = p.property_id JOIN tenants t ON t.tenant_id = l.tenant_id WHERE t.name = '{t}' AND l.status IN {OCCUPYING}")
        add("tenant_expiry", 2, phr([
            "When does {t}'s earliest active lease expire?",
            "What's the next lease expiration for {t}?",
        ], t=t), f"SELECT MIN(l.expiration_date) FROM leases l JOIN tenants t ON t.tenant_id = l.tenant_id WHERE t.name = '{t}' AND l.status = 'Active'")

    # --- groupings and slices --------------------------------------------
    for ptype in e["types"]:
        for m in rng.sample(e["markets"], 4):
            add("type_market_count", 1, phr([
                "How many {t} properties do we hold in {m}?",
                "Count of held {t} assets in {m}?",
            ], t=ptype.lower(), m=m), f"SELECT COUNT(*) FROM properties WHERE property_type = '{ptype}' AND market = '{m}' AND status != 'Sold'")
        add("type_value", 2, phr([
            "What's the combined current value of our {t} portfolio?",
            "Total current market value of held {t} assets?",
        ], t=ptype.lower()), f"SELECT SUM(current_market_value) FROM properties WHERE property_type = '{ptype}' AND status != 'Sold'")
        add("type_sqft", 1, phr([
            "How many rentable square feet of {t} space do we hold?",
        ], t=ptype.lower()), f"SELECT SUM(rentable_sqft) FROM properties WHERE property_type = '{ptype}' AND status != 'Sold'")
    for m in e["markets"]:
        add("market_rentroll", 2, phr([
            "What's the rent roll in {m}?", "Total annual base rent from {m} properties?",
        ], m=m), f"SELECT SUM(l.annual_base_rent) FROM leases l JOIN properties p ON p.property_id = l.property_id WHERE p.market = '{m}' AND l.status IN {OCCUPYING}")
        add("market_props", 1, phr([
            "Which properties do we hold in {m}?", "List our {m} holdings.",
        ], m=m), f"SELECT name FROM properties WHERE market = '{m}' AND status != 'Sold'")
        for y in years:
            add("market_noi", 2, phr([
                "What NOI did the {m} portfolio produce in {y}?",
            ], m=m, y=y), f"SELECT SUM(f.net_operating_income) FROM property_financials f JOIN properties p ON p.property_id = f.property_id WHERE p.market = '{m}' AND f.period_end >= '{y}-01-01' AND f.period_end <= '{y}-12-31'")
    for f in e["funds"]:
        add("fund_props", 1, phr([
            "Which properties does {f} hold?", "List {f}'s current holdings.",
        ], f=f), f"SELECT p.name FROM properties p JOIN funds fu ON fu.fund_id = p.fund_id WHERE fu.name = '{f}' AND p.status != 'Sold'")
        add("fund_value", 2, phr([
            "What's the total current value of {f}'s holdings?",
        ], f=f), f"SELECT SUM(p.current_market_value) FROM properties p JOIN funds fu ON fu.fund_id = p.fund_id WHERE fu.name = '{f}' AND p.status != 'Sold'")
        add("fund_rentroll", 2, phr([
            "What's {f}'s total rent roll?", "Annual base rent across {f}'s portfolio?",
        ], f=f), f"SELECT SUM(l.annual_base_rent) FROM leases l JOIN properties p ON p.property_id = l.property_id JOIN funds fu ON fu.fund_id = p.fund_id WHERE fu.name = '{f}' AND l.status IN {OCCUPYING}")

    # --- group-by rollups -------------------------------------------------
    rollups = [
        ("by property type", "p.property_type", "properties p", None),
        ("by market", "p.market", "properties p", None),
        ("by building class", "p.building_class", "properties p", None),
    ]
    for label, group_col, _, _ in rollups:
        add("groupby_count", 1, phr([
            "How many held properties do we have {label}?",
            "Break down the held property count {label}.",
        ], label=label), f"SELECT {group_col.replace('p.', '')}, COUNT(*) FROM properties WHERE status != 'Sold' GROUP BY {group_col.replace('p.', '')}")
        add("groupby_value", 2, phr([
            "Show total current market value {label}.",
            "Sum the held portfolio value {label}.",
        ], label=label), f"SELECT {group_col.replace('p.', '')}, SUM(current_market_value) FROM properties WHERE status != 'Sold' GROUP BY {group_col.replace('p.', '')}")
        add("groupby_rentroll", 2, phr([
            "What's the rent roll {label}?",
        ], label=label), f"SELECT {group_col}, SUM(l.annual_base_rent) FROM leases l JOIN properties p ON p.property_id = l.property_id WHERE l.status IN {OCCUPYING} GROUP BY {group_col}")
    add("industry_rollup", 2, "How much space is leased to each tenant industry?",
        f"SELECT t.industry, SUM(l.leased_sqft) FROM leases l JOIN tenants t ON t.tenant_id = l.tenant_id WHERE l.status IN {OCCUPYING} GROUP BY t.industry")
    for y in years:
        add("noi_by_market_year", 2, f"Show total NOI by market for {y}.",
            f"SELECT p.market, SUM(f.net_operating_income) FROM property_financials f JOIN properties p ON p.property_id = f.property_id WHERE f.period_end >= '{y}-01-01' AND f.period_end <= '{y}-12-31' GROUP BY p.market")
        add("noi_by_year", 2, phr([
            "What was total portfolio NOI in {y}?", "Portfolio-wide NOI for {y}?",
        ], y=y), f"SELECT SUM(net_operating_income) FROM property_financials WHERE period_end >= '{y}-01-01' AND period_end <= '{y}-12-31'")

    # --- date windows -----------------------------------------------------
    for n, end in [(3, "2026-10-01"), (6, "2027-01-01"), (9, "2027-04-01"),
                   (12, "2027-07-01"), (18, "2028-01-01"), (24, "2028-07-01")]:
        add("expiry_count", 1, phr([
            "How many active leases expire in the next {n} months?",
            "How many leases roll within {n} months?",
        ], n=n), f"SELECT COUNT(*) FROM leases WHERE status = 'Active' AND expiration_date >= '2026-07-01' AND expiration_date < '{end}'")
        add("expiry_list", 2, phr([
            "Which tenants have active leases expiring in the next {n} months?",
        ], n=n), f"SELECT DISTINCT t.name FROM leases l JOIN tenants t ON t.tenant_id = l.tenant_id WHERE l.status = 'Active' AND l.expiration_date >= '2026-07-01' AND l.expiration_date < '{end}'")
        add("expiry_sqft", 2, phr([
            "How much leased square footage expires within {n} months?",
        ], n=n), f"SELECT SUM(leased_sqft) FROM leases WHERE status = 'Active' AND expiration_date >= '2026-07-01' AND expiration_date < '{end}'")
    for y in ["2027", "2028", "2029", "2030", "2031"]:
        add("loan_maturity_year", 2, phr([
            "Which loans mature in {y}? Show property and balance.",
            "List {y}'s loan maturities with property names and current balances.",
        ], y=y), f"SELECT p.name, ln.current_balance FROM loans ln JOIN properties p ON p.property_id = ln.property_id WHERE ln.maturity_date >= '{y}-01-01' AND ln.maturity_date <= '{y}-12-31'")

    # --- thresholds / comparisons ----------------------------------------
    for threshold in [20, 30, 40, 50, 60]:
        add("rent_threshold", 2, phr([
            "Which active leases pay more than ${x} per square foot? Show tenant and rate.",
            "List tenants on active leases above ${x} PSF.",
        ], x=threshold), f"SELECT t.name, l.base_rent_psf FROM leases l JOIN tenants t ON t.tenant_id = l.tenant_id WHERE l.status = 'Active' AND l.base_rent_psf > {threshold}")
    for pct in [70, 80, 90]:
        add("occ_threshold", 2, phr([
            "Which properties were below {pct} percent occupancy in June 2026?",
        ], pct=pct), f"SELECT p.name FROM property_financials f JOIN properties p ON p.property_id = f.property_id WHERE f.period_end = '2026-06-30' AND f.occupancy_rate < 0.{pct}")
    for sqft in [100000, 250000, 400000]:
        add("size_threshold", 1, phr([
            "Which held properties are larger than {s} square feet?",
        ], s=f"{sqft:,}"), f"SELECT name FROM properties WHERE rentable_sqft > {sqft} AND status != 'Sold'")
    for ltv in [55, 65, 70]:
        add("ltv_threshold", 2, phr([
            "Which properties have loans above {x} percent LTV?",
        ], x=ltv), f"SELECT p.name, ln.ltv FROM loans ln JOIN properties p ON p.property_id = ln.property_id WHERE ln.ltv > 0.{ltv}")

    # --- superlatives / ordering -----------------------------------------
    for n in [1, 3, 5, 10]:
        add("top_value", 1, phr([
            "What are the top {n} held properties by current value?",
            "Our {n} most valuable held assets?",
        ], n=n), f"SELECT name FROM properties WHERE status != 'Sold' ORDER BY current_market_value DESC LIMIT {n}")
        add("top_rent_leases", 2, phr([
            "What are the {n} largest active leases by annual rent? Show tenant and rent.",
        ], n=n), f"SELECT t.name, l.annual_base_rent FROM leases l JOIN tenants t ON t.tenant_id = l.tenant_id WHERE l.status = 'Active' ORDER BY l.annual_base_rent DESC LIMIT {n}")
        add("top_tenants_sqft", 2, phr([
            "Who are our top {n} tenants by leased area?",
        ], n=n), f"SELECT t.name FROM tenants t JOIN leases l ON l.tenant_id = t.tenant_id WHERE l.status IN {OCCUPYING} GROUP BY t.name ORDER BY SUM(l.leased_sqft) DESC LIMIT {n}")
    add("oldest", 1, "What's the oldest building we hold?",
        "SELECT name FROM properties WHERE status != 'Sold' ORDER BY year_built ASC LIMIT 1")
    add("newest_lease", 1, "What's the most recently commenced lease? Show the commencement date.",
        "SELECT MAX(commencement_date) FROM leases")

    # --- windows, CTEs, nesting (tier 3) ---------------------------------
    for m in e["markets"]:
        add("market_best", 3, phr([
            "Which property in {m} has the highest current value?",
            "What's the most valuable held asset in {m}?",
        ], m=m), f"SELECT name FROM properties WHERE market = '{m}' AND status != 'Sold' ORDER BY current_market_value DESC LIMIT 1")
        add("latest_val_market", 3, phr([
            "Show the latest appraisal value for each held property in {m}.",
            "For each held {m} property, what did the most recent appraisal say it's worth?",
        ], m=m), f"SELECT p.name, v.market_value FROM properties p JOIN valuations v ON v.property_id = p.property_id WHERE p.market = '{m}' AND p.status != 'Sold' AND v.valuation_date = (SELECT MAX(valuation_date) FROM valuations WHERE property_id = p.property_id)")
    for t in e["types"]:
        add("type_best", 3, phr([
            "Which {t} property has the highest current value?",
        ], t=t.lower()), f"SELECT name FROM properties WHERE property_type = '{t}' AND status != 'Sold' ORDER BY current_market_value DESC LIMIT 1")
        add("type_latest_occ", 3, phr([
            "Show the latest occupancy rate for each {t} property.",
        ], t=t.lower()), f"SELECT p.name, f.occupancy_rate FROM property_financials f JOIN properties p ON p.property_id = f.property_id WHERE p.property_type = '{t}' AND f.period_end = (SELECT MAX(period_end) FROM property_financials WHERE property_id = p.property_id)")
    for group, group_col in [("property type", "property_type"), ("market", "market"),
                             ("building class", "building_class")]:
        add("rank_group_rent", 3, phr([
            "Rank each {g} by rent roll, with the rank shown.",
            "Using a ranking, order the {g}s by total current rent.",
        ], g=group), f"WITH cte AS (SELECT p.{group_col} AS grp, SUM(l.annual_base_rent) AS rent FROM leases l JOIN properties p ON p.property_id = l.property_id WHERE l.status IN {OCCUPYING} GROUP BY p.{group_col}) SELECT grp, rent, RANK() OVER (ORDER BY rent DESC) AS rnk FROM cte")
        add("share_by_group", 3, phr([
            "What fraction of held portfolio value is in each {g}?",
        ], g=group), f"SELECT {group_col}, SUM(current_market_value) / (SELECT SUM(current_market_value) FROM properties WHERE status != 'Sold') FROM properties WHERE status != 'Sold' GROUP BY {group_col}")
        add("best_in_group", 3, phr([
            "Which property has the highest current value within each {g}?",
        ], g=group), f"SELECT {group_col}, name FROM (SELECT {group_col}, name, ROW_NUMBER() OVER (PARTITION BY {group_col} ORDER BY current_market_value DESC) AS rn FROM properties WHERE status != 'Sold') WHERE rn = 1")
    add("latest_val_all", 3, "Show each held property's most recent appraisal value.",
        "SELECT p.name, v.market_value FROM properties p JOIN valuations v ON v.property_id = p.property_id WHERE p.status != 'Sold' AND v.valuation_date = (SELECT MAX(valuation_date) FROM valuations WHERE property_id = p.property_id)")
    for k in [2, 3]:
        add("multi_prop_tenants", 3, phr([
            "Which tenants occupy space in {k} or more properties?",
        ], k=k), f"SELECT t.name FROM tenants t JOIN leases l ON l.tenant_id = t.tenant_id WHERE l.status IN {OCCUPYING} GROUP BY t.name HAVING COUNT(DISTINCT l.property_id) >= {k}")
    add("no_debt", 3, "Which held properties have no loan against them?",
        "SELECT name FROM properties WHERE status != 'Sold' AND property_id NOT IN (SELECT property_id FROM loans)")
    add("never_leased", 3, "Which tenants have no active lease with us right now?",
        "SELECT name FROM tenants WHERE tenant_id NOT IN (SELECT tenant_id FROM leases WHERE status = 'Active')")
    for mm, dd, mname in [("03", "31", "March"), ("06", "30", "June"), ("09", "30", "September"), ("12", "31", "December")]:
        for y1, y2 in [("2024", "2025"), ("2025", "2026")]:
            if y2 == "2026" and mm in ("09", "12"):
                continue
            add("yoy_noi", 3, phr([
                "Compare each property's {m} NOI between {a} and {b}.",
                "How did {m} NOI change per property from {a} to {b}?",
            ], m=mname, a=y1, b=y2), f"SELECT p.name, a.net_operating_income, b.net_operating_income FROM properties p JOIN property_financials a ON a.property_id = p.property_id AND a.period_end = '{y1}-{mm}-{dd}' JOIN property_financials b ON b.property_id = p.property_id AND b.period_end = '{y2}-{mm}-{dd}'")
    for date_col, what in [("expiration_date", "expirations"), ("commencement_date", "commencements")]:
        add("by_year", 3, f"Count active lease {what} by calendar year.",
            f"SELECT STRFTIME('%Y', {date_col}) AS yr, COUNT(*) FROM leases WHERE status = 'Active' GROUP BY yr")
    add("avg_lease_size_type", 3, "What's the average active lease size in square feet by property type?",
        "SELECT p.property_type, AVG(l.leased_sqft) FROM leases l JOIN properties p ON p.property_id = l.property_id WHERE l.status = 'Active' GROUP BY p.property_type")
    for pct in [80, 85, 90]:
        add("case_occupancy", 3, phr([
            "Label each property's June 2026 occupancy as high (over {x} percent) or low.",
        ], x=pct), f"SELECT p.name, CASE WHEN f.occupancy_rate > 0.{pct} THEN 'high' ELSE 'low' END FROM property_financials f JOIN properties p ON p.property_id = f.property_id WHERE f.period_end = '2026-06-30'")
    for ptype in rng.sample(e["types"], 4):
        add("largest_lease_per_prop", 3, phr([
            "For each {t} property, who holds the largest active lease?",
        ], t=ptype.lower()), f"SELECT name, tenant FROM (SELECT p.name AS name, t.name AS tenant, ROW_NUMBER() OVER (PARTITION BY p.property_id ORDER BY l.leased_sqft DESC) AS rn FROM leases l JOIN properties p ON p.property_id = l.property_id JOIN tenants t ON t.tenant_id = l.tenant_id WHERE p.property_type = '{ptype}' AND l.status = 'Active') WHERE rn = 1")

    # --- LIKE / string ----------------------------------------------------
    for prefix in ["The", "Shops", "Hotel"]:
        add("name_like", 1, phr([
            "Which properties have names starting with '{x}'?",
        ], x=prefix), f"SELECT name FROM properties WHERE name LIKE '{prefix}%'")

    # --- loans ------------------------------------------------------------
    for lender in e["lenders"]:
        add("lender_exposure", 2, phr([
            "What's our total loan balance with {x}?",
            "How much do we owe {x} across all loans?",
        ], x=lender), f"SELECT SUM(current_balance) FROM loans WHERE lender = '{lender}'")
    add("float_share", 2, "How many loans are floating rate versus fixed?",
        "SELECT rate_type, COUNT(*) FROM loans GROUP BY rate_type")
    add("avg_dscr", 2, "What's the average DSCR across the loan book?",
        "SELECT AVG(dscr) FROM loans")
    add("recourse", 1, "How many loans are recourse?",
        "SELECT COUNT(*) FROM loans WHERE is_recourse = 1")

    return out


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=OUT_DIR,
        help="output directory (default: committed synth/out corpus)",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    out_dir = args.out_dir.resolve()
    rng = random.Random(SEED)
    conn = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    entities = load_entities(conn)
    grammar = xgrammar.Grammar.from_ebnf(GRAMMAR_PATH.read_text())
    gold_questions = {normalize(json.loads(line)["question"])
                      for line in GOLD.read_text().splitlines() if line.strip()}

    candidates = build_candidates(rng, entities)
    rng.shuffle(candidates)

    stats = {"raw": len(candidates), "gold_dup": 0, "batch_dup": 0,
             "exec_error": 0, "degenerate": 0, "not_in_grammar": 0, "kept": 0}
    seen: set[str] = set()
    kept: list[dict] = []
    for item in candidates:
        key = normalize(item["question"])
        if key in gold_questions:
            stats["gold_dup"] += 1
            continue
        if key in seen:
            stats["batch_dup"] += 1
            continue
        try:
            rows = execute(DB, item["sql"])
        except ExecutionError:
            stats["exec_error"] += 1
            continue
        if not rows or (len(rows) == 1 and all(v is None for v in rows[0])):
            stats["degenerate"] += 1
            continue
        if not grammar_accepts(grammar, item["sql"]):
            stats["not_in_grammar"] += 1
            continue
        seen.add(key)
        kept.append(item)
        if len(kept) >= TARGET:
            break
    stats["kept"] = len(kept)

    system_prompt = SYSTEM_PROMPT.format(schema=SCHEMA_PROMPT.read_text().strip())
    records = [
        {"messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": f"Question: {item['question']}"},
            {"role": "assistant", "content": item["sql"]},
        ]}
        for item in kept
    ]
    n_valid = max(1, int(len(records) * VALID_FRACTION))
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "valid.jsonl").write_text(
        "\n".join(json.dumps(r) for r in records[:n_valid]) + "\n")
    (out_dir / "train.jsonl").write_text(
        "\n".join(json.dumps(r) for r in records[n_valid:]) + "\n")

    families: dict[str, int] = {}
    tiers: dict[int, int] = {}
    for item in kept:
        families[item["family"]] = families.get(item["family"], 0) + 1
        tiers[item["tier"]] = tiers.get(item["tier"], 0) + 1
    stats["families"] = dict(sorted(families.items()))
    stats["tiers"] = {str(k): v for k, v in sorted(tiers.items())}
    (out_dir / "gate_stats.json").write_text(json.dumps(stats, indent=2))
    print(json.dumps({k: v for k, v in stats.items() if k != "families"}, indent=2))
    print(f"train={len(records) - n_valid} valid={n_valid} -> {out_dir}")


if __name__ == "__main__":
    main()
