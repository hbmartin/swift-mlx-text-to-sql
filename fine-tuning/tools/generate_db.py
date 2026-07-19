"""Deterministic generator for the bundled CREG portfolio database.

Every run with the same seed produces identical table contents; there is no
wall-clock dependence (AS_OF is a constant). The generated data guarantees the
accounting invariants that the correction heuristics and the gold set rely on
(enforced by tests/test_invariants.py):

  effective_gross_income = gross_potential_rent - vacancy_loss      (exact)
  net_operating_income   = effective_gross_income - operating_expenses (exact)
  occupancy_rate         = occupied leased sqft / rentable_sqft     (exact)
  annual_base_rent       = base_rent_psf * leased_sqft              (to the cent)
  leases in the same suite never overlap in time
  lease status agrees with commencement/expiration relative to AS_OF
  loans: current_balance <= original_balance, ltv = current_balance / value
  valuations: the latest value tracks properties.current_market_value

Modeling notes:
  - Terminated leases store their actual early-exit date in expiration_date;
    term_months keeps the original contract length.
  - Holdover leases have expiration_date in the past but still occupy their
    suite (occupancy queries must treat status='Holdover' as occupied).
  - Sold properties stop accruing financials at disposition; their leases are
    recorded as Expired at the disposition date.
  - The In Development property has no leases and no financials.

Usage:  uv run python tools/generate_db.py [--out PATH] [--seed N]
"""

import argparse
import random
import sqlite3
from datetime import date
from pathlib import Path

SEED = 20260719
AS_OF = date(2026, 7, 1)          # "today" for all status/current-value logic
WINDOW_START = date(2023, 7, 1)   # first financials month
WINDOW_MONTHS = 36                # through 2026-06

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SCHEMA = REPO_ROOT / "db" / "schema.sql"
DEFAULT_OUT = REPO_ROOT / "db" / "creg.sqlite"

# ---------------------------------------------------------------- reference data

MARKETS = [
    # (market, state, [submarkets], value multiplier band)
    ("New York", "NY", ["Midtown", "Downtown", "Brooklyn"], (1.40, 1.70)),
    ("San Francisco", "CA", ["SoMa", "Financial District", "Peninsula"], (1.35, 1.60)),
    ("Boston", "MA", ["Seaport", "Back Bay", "Cambridge"], (1.25, 1.50)),
    ("Los Angeles", "CA", ["West LA", "Downtown", "Burbank"], (1.15, 1.35)),
    ("Seattle", "WA", ["Downtown", "Bellevue", "South Lake Union"], (1.10, 1.30)),
    ("Miami", "FL", ["Brickell", "Wynwood", "Coral Gables"], (1.10, 1.30)),
    ("Chicago", "IL", ["The Loop", "River North", "O'Hare"], (0.90, 1.10)),
    ("Dallas", "TX", ["Uptown", "Las Colinas", "Plano"], (0.90, 1.10)),
    ("Atlanta", "GA", ["Buckhead", "Midtown", "Perimeter"], (0.85, 1.05)),
    ("Denver", "CO", ["LoDo", "Cherry Creek", "Tech Center"], (0.85, 1.05)),
]

# per property type: (count, rentable sqft band, market rent $/sf/yr at window
# start, value $/sf band, opex $/sf/yr, suite count band, lease term band months)
TYPE_PARAMS = {
    "Office":       (14, (80_000, 600_000), 45.0, (350, 650), 14.0, (4, 10), (36, 120)),
    "Industrial":   (10, (100_000, 800_000), 11.0, (110, 220), 3.5, (1, 4), (36, 84)),
    "Retail":       (8, (30_000, 250_000), 32.0, (250, 420), 9.0, (3, 8), (60, 120)),
    "Multifamily":  (8, (120_000, 350_000), 28.0, (280, 450), 10.0, (2, 4), (12, 36)),
    "Mixed-Use":    (4, (60_000, 300_000), 38.0, (300, 480), 11.0, (3, 8), (36, 96)),
    "Hospitality":  (3, (80_000, 250_000), 30.0, (240, 380), 16.0, (1, 1), (120, 240)),
    "Self-Storage": (3, (40_000, 120_000), 18.0, (130, 220), 5.0, (1, 1), (120, 240)),
}

NAME_PATTERNS = {
    "Office": ["{stem} Tower", "{stem} Plaza", "One {stem} Center", "{stem} Exchange"],
    "Industrial": ["{stem} Logistics Center", "{stem} Distribution Park", "{stem} Industrial Park"],
    "Retail": ["{stem} Marketplace", "Shops at {stem}", "{stem} Commons", "{stem} Crossing"],
    "Multifamily": ["The {stem} Residences", "{stem} Flats", "{stem} Court Apartments"],
    "Mixed-Use": ["{stem} Square", "{stem} District", "{stem} Yards"],
    "Hospitality": ["Hotel {stem}", "The {stem} Inn", "{stem} Suites"],
    "Self-Storage": ["{stem} Storage Center", "{stem} SecureSpace"],
}

NAME_STEMS = [
    "Harborview", "Gateway", "Meridian", "Summit", "Lakeside", "Ironworks",
    "Beacon", "Cascade", "Sterling", "Granite", "Willow", "Foundry",
    "Crescent", "Pinnacle", "Riverfront", "Monarch", "Aspen", "Cobalt",
    "Halcyon", "Juniper", "Keystone", "Larkspur", "Magnolia", "Northgate",
    "Obsidian", "Palisade", "Quarry", "Redwood", "Sable", "Tidewater",
    "Union", "Vantage", "Westfield", "Yellowstone", "Zephyr", "Arlington",
    "Bristol", "Concord", "Dorchester", "Ellsworth", "Fairmont", "Grandview",
    "Hawthorne", "Ivory", "Jackson", "Kingsley", "Lexington", "Millbrook",
    "Newport", "Oakland", "Prescott", "Quincy", "Rockland", "Somerset",
]

STREETS = [
    "Main Street", "Market Street", "Commerce Way", "Park Avenue", "5th Avenue",
    "Industrial Boulevard", "Harbor Drive", "Elm Street", "Broadway",
    "Riverside Drive", "Technology Parkway", "Union Square", "Bay Street",
]

LENDERS = [
    "First Meridian Bank", "Cornerstone Life Insurance", "Pacific Capital Partners",
    "Atlantic Federal Bank", "Summit National Bank", "Heritage Mutual Life",
    "Blackrock Ridge Credit", "Union Trust Company", "Lakeshore Capital",
]

APPRAISERS = [
    "Calloway & Marsh", "TrueNorth Valuation Group", "Sentinel Appraisal Partners",
    "Hargrove Advisory", "Beacon Hill Valuations",
]

INDUSTRY_NAMES = {
    "Technology": ["{s}soft", "{s} Systems", "{s} Labs", "{s} Digital", "{s} Cloudworks"],
    "Finance": ["{s} Capital Group", "{s} Financial", "{s} Asset Management", "{s} Securities"],
    "Healthcare": ["{s} Health Partners", "{s} Medical Group", "{s} Diagnostics", "{s} Wellness"],
    "Legal": ["{s} & {s2} LLP", "{s} Law Group", "{s}, {s2} & Associates"],
    "Retail": ["{s} Outfitters", "{s} Home Goods", "{s} Market Co.", "{s} Trading Company"],
    "Government": ["State Department of {g}", "{c} County {g} Office", "U.S. {g} Administration"],
    "Manufacturing": ["{s} Fabrication", "{s} Precision Industries", "{s} Components"],
    "Professional Services": ["{s} Consulting", "{s} Advisory Group", "{s} Partners"],
    "Other": ["{s} Foundation", "{s} Studios", "{s} Logistics Services"],
}

SURNAMES = [
    "Whitfield", "Calder", "Ostrander", "Beaumont", "Ferris", "Langley",
    "Marbury", "Nakamura", "Osei", "Petrov", "Quintana", "Rosales",
    "Silverman", "Tran", "Ulrich", "Vasquez", "Winslow", "Yates",
    "Abernathy", "Bhatt", "Castellano", "Drummond", "Eastman", "Fontaine",
]

GOV_AREAS = ["Revenue", "Transportation", "Health Services", "Labor", "Housing"]

CREDIT_RATINGS = ["AAA", "AA", "AA-", "A+", "A", "A-", "BBB+", "BBB", "BBB-", "BB+", "BB", "NR"]

STRATEGY_IRR = {"Core": 0.08, "Core-Plus": 0.10, "Value-Add": 0.13, "Opportunistic": 0.17}

LEASE_TYPE_BY_PROPERTY = {
    "Office": ["Full Service", "Modified Gross"],
    "Industrial": ["NNN"],
    "Retail": ["NNN"],
    "Multifamily": ["Gross"],
    "Mixed-Use": ["Modified Gross", "NNN"],
    "Hospitality": ["NNN"],
    "Self-Storage": ["NNN"],
}

# ---------------------------------------------------------------- date helpers


def add_months(d: date, n: int) -> date:
    y, m = divmod((d.year * 12 + d.month - 1) + n, 12)
    return date(y, m + 1, 1)


def eom(d: date) -> date:
    """Last day of d's month."""
    first_next = add_months(d.replace(day=1), 1)
    return first_next.fromordinal(first_next.toordinal() - 1)


def months_between(a: date, b: date) -> int:
    return (b.year - a.year) * 12 + (b.month - a.month)


def iso(d: date | None) -> str | None:
    return d.isoformat() if d else None


# ---------------------------------------------------------------- generation


def build(seed: int = SEED) -> dict[str, list[tuple]]:
    """Generate all table rows. Returns {table_name: [row tuples]}."""
    rng = random.Random(seed)

    funds = [
        # fund_id, name, vintage, strategy, committed (filled later), irr, inception, status
        [1, "CREG Core Income Fund", 2015, "Core", None, None, "2015-03-01", "Harvesting"],
        [2, "CREG Value Partners II", 2018, "Value-Add", None, None, "2018-06-01", "Harvesting"],
        [3, "CREG Core-Plus Real Estate Fund", 2019, "Core-Plus", None, None, "2019-09-01", "Investing"],
        [4, "CREG Opportunity Fund III", 2021, "Opportunistic", None, None, "2021-05-01", "Investing"],
    ]
    for f in funds:
        f[5] = round(STRATEGY_IRR[f[3]] + rng.uniform(-0.005, 0.005), 3)

    # ---- properties ------------------------------------------------------
    used_names: set[str] = set()
    properties: list[dict] = []
    pid = 0
    for ptype, (count, sqft_band, rent_psf0, val_psf_band, opex_psf, suite_band, term_band) in TYPE_PARAMS.items():
        for _ in range(count):
            pid += 1
            market, state, submarkets, mult_band = MARKETS[rng.randrange(len(MARKETS))]
            mult = rng.uniform(*mult_band)
            while True:
                pattern = rng.choice(NAME_PATTERNS[ptype])
                name = pattern.format(stem=rng.choice(NAME_STEMS))
                if name not in used_names:
                    used_names.add(name)
                    break
            rentable = rng.randrange(sqft_band[0], sqft_band[1], 1000)
            year_built = rng.randint(1965, 2022)
            year_renov = rng.randint(year_built + 15, 2025) if year_built < 2005 and rng.random() < 0.5 else None
            floors = {"Office": rng.randint(6, 45), "Industrial": 1,
                      "Retail": rng.randint(1, 2), "Multifamily": rng.randint(4, 20),
                      "Mixed-Use": rng.randint(3, 12), "Hospitality": rng.randint(4, 15),
                      "Self-Storage": rng.randint(1, 4)}[ptype]
            acq = date(rng.randint(2016, 2025), rng.randint(1, 12), 1)
            eligible = [f for f in funds if f[6] <= iso(acq)]
            fund = rng.choice(eligible)
            acq_psf = rng.uniform(*val_psf_band) * mult
            acq_price = round(rentable * acq_psf, -3)
            years_held = max(0.0, (AS_OF - acq).days / 365.25)
            cmv = round(acq_price * min(1.6, max(0.85, 1.02 ** years_held + rng.uniform(-0.08, 0.12))), -3)
            properties.append({
                "property_id": pid, "fund_id": fund[0], "name": name,
                "address": f"{rng.randint(1, 999)} {rng.choice(STREETS)}",
                "city": market, "state": state, "market": market,
                "submarket": rng.choice(submarkets), "property_type": ptype,
                "building_class": rng.choices("ABC", weights=[5, 4, 2])[0],
                "rentable_sqft": rentable, "year_built": year_built,
                "year_renovated": year_renov, "num_floors": floors,
                "acquisition_date": acq, "acquisition_price": acq_price,
                "current_market_value": cmv,
                "ownership_pct": 1.0 if rng.random() < 0.8 else round(rng.uniform(0.5, 0.95), 2),
                "status": "Owned", "disposition_date": None,
                # non-persisted modeling attributes
                "_rent_psf0": rent_psf0 * mult, "_opex_psf": opex_psf * mult * rng.uniform(0.9, 1.1),
                "_suite_band": suite_band, "_term_band": term_band,
            })

    rng.shuffle(properties)
    for i, p in enumerate(properties):
        p["property_id"] = i + 1

    # special statuses: 2 Sold, 1 In Development, 1 Under Contract
    sold = [p for p in properties if p["property_type"] in ("Office", "Retail")][:2]
    for p in sold:
        p["status"] = "Sold"
        p["disposition_date"] = date(rng.randint(2024, 2025), rng.randint(1, 12), 15)
        if p["disposition_date"] <= p["acquisition_date"]:
            p["disposition_date"] = add_months(p["acquisition_date"], rng.randint(24, 60)).replace(day=15)
        p["current_market_value"] = p["current_market_value"]  # value at/near sale
    dev = next(p for p in properties if p["property_type"] == "Multifamily")
    dev["status"] = "In Development"
    dev["year_built"] = 2026
    dev["year_renovated"] = None
    dev["acquisition_date"] = date(2024, 10, 1)
    dev["fund_id"] = 4
    under_contract = next(p for p in properties if p["status"] == "Owned" and p["property_type"] == "Industrial")
    under_contract["status"] = "Under Contract"

    # fund committed capital from assigned properties
    for f in funds:
        invested = sum(p["acquisition_price"] for p in properties if p["fund_id"] == f[0])
        f[4] = round(invested * 0.65 / 5_000_000) * 5_000_000

    # ---- tenants ---------------------------------------------------------
    tenants: list[tuple] = []
    industries = list(INDUSTRY_NAMES)
    used_tenant_names: set[str] = set()
    for tid in range(1, 151):
        industry = rng.choices(industries, weights=[18, 14, 12, 8, 14, 6, 10, 12, 6])[0]
        while True:
            pattern = rng.choice(INDUSTRY_NAMES[industry])
            tname = pattern.format(
                s=rng.choice(SURNAMES), s2=rng.choice(SURNAMES),
                g=rng.choice(GOV_AREAS), c=rng.choice([m[0] for m in MARKETS]),
            )
            if tname not in used_tenant_names:
                used_tenant_names.add(tname)
                break
        hq_market = rng.choice(MARKETS)
        tenants.append((
            tid, tname, industry,
            "NR" if industry == "Government" else rng.choices(CREDIT_RATINGS, weights=[1, 2, 3, 4, 6, 6, 8, 8, 6, 4, 3, 10])[0],
            1 if rng.random() < 0.3 else 0,
            hq_market[0], hq_market[1],
        ))

    # ---- suites + lease chains ------------------------------------------
    def market_rent_psf(p: dict, when: date) -> float:
        years = (when - WINDOW_START).days / 365.25
        return p["_rent_psf0"] * (1.03 ** years)

    leases: list[dict] = []
    lease_id = 0
    for p in properties:
        if p["status"] == "In Development":
            continue
        n_suites = rng.randint(*p["_suite_band"])
        # allocate suite sqft summing to 92-100% of rentable
        weights = [rng.uniform(0.5, 1.5) for _ in range(n_suites)]
        usable = p["rentable_sqft"] * rng.uniform(0.92, 1.0)
        suite_sqft = [int(usable * w / sum(weights)) for w in weights]
        horizon = p["disposition_date"] or add_months(AS_OF, 12)
        used_suites: set[str] = set()
        for si in range(n_suites):
            floor = rng.randint(1, p["num_floors"])
            while True:
                suite_label = f"{floor}{rng.choice('0123')}{rng.choice('05')}"
                if suite_label not in used_suites:
                    used_suites.add(suite_label)
                    break
                floor = rng.randint(1, p["num_floors"])
            # chain may begin before the property was acquired (in-place leases)
            t = add_months(p["acquisition_date"], -rng.randint(0, 48))
            while t < horizon:
                term = rng.randint(*p["_term_band"])
                commencement = t
                expiration = eom(add_months(commencement, term - 1))
                if commencement >= horizon:
                    break
                lease_id += 1
                psf = round(market_rent_psf(p, commencement) * rng.uniform(0.85, 1.15), 2)
                sqft = suite_sqft[si]
                ltype = rng.choice(LEASE_TYPE_BY_PROPERTY[p["property_type"]])
                ti = {"Office": rng.uniform(20, 80), "Retail": rng.uniform(10, 50)}.get(
                    p["property_type"], rng.uniform(0, 15))
                leases.append({
                    "lease_id": lease_id, "property_id": p["property_id"],
                    "tenant_id": rng.randint(1, 150), "suite": suite_label,
                    "floor": floor, "leased_sqft": sqft, "lease_type": ltype,
                    "base_rent_psf": psf, "annual_base_rent": round(psf * sqft, 2),
                    "escalation_pct": round(rng.uniform(0.02, 0.035), 3),
                    "commencement_date": commencement, "expiration_date": expiration,
                    "term_months": term,
                    "security_deposit": round(psf * sqft / 12 * rng.randint(1, 3), 2),
                    "has_renewal_option": 1 if rng.random() < 0.4 else 0,
                    "free_rent_months": rng.choices([0, 1, 2, 3], weights=[6, 1, 1, 1])[0],
                    "ti_allowance_psf": round(ti, 2),
                    "status": None,  # derived below
                })
                t = add_months(expiration.replace(day=1), 1 + rng.choices(
                    [0, 1, 2, 3, 6, 9], weights=[5, 3, 3, 2, 1, 1])[0])

    # truncate at disposition for sold properties; derive statuses
    sold_by_id = {p["property_id"]: p["disposition_date"] for p in properties if p["status"] == "Sold"}
    kept: list[dict] = []
    for lz in leases:
        dispo = sold_by_id.get(lz["property_id"])
        if dispo:
            if lz["commencement_date"] >= dispo:
                continue
            if lz["expiration_date"] >= dispo:
                lz["expiration_date"] = dispo
            lz["status"] = "Expired"
        elif lz["commencement_date"] > AS_OF:
            lz["status"] = "Pending"
        elif lz["expiration_date"] >= AS_OF:
            lz["status"] = "Active"
        else:
            lz["status"] = "Expired"
        kept.append(lz)
    leases = kept

    # Pending leases: keep only near-term ones (within 12 months of AS_OF)
    leases = [lz for lz in leases if lz["status"] != "Pending"
              or lz["commencement_date"] <= add_months(AS_OF, 12)]

    # Holdover: recently expired leases with no successor in the same suite
    by_suite: dict[tuple, list[dict]] = {}
    for lz in leases:
        by_suite.setdefault((lz["property_id"], lz["suite"]), []).append(lz)
    holdover_candidates = []
    for (prop, _suite), chain in by_suite.items():
        if prop in sold_by_id:
            continue
        chain.sort(key=lambda x: x["commencement_date"])
        for idx, lz in enumerate(chain):
            if lz["status"] != "Expired":
                continue
            if not 0 <= months_between(lz["expiration_date"], AS_OF) <= 6:
                continue
            successor = chain[idx + 1] if idx + 1 < len(chain) else None
            # only safe to hold over if the suite stays empty through AS_OF,
            # otherwise occupancy would double-count the suite
            if successor is None or successor["commencement_date"] > AS_OF:
                holdover_candidates.append(lz)
    for lz in rng.sample(holdover_candidates, min(3, len(holdover_candidates))):
        lz["status"] = "Holdover"

    # Terminated: some expired leases actually ended early
    expired = [lz for lz in leases if lz["status"] == "Expired"
               and lz["property_id"] not in sold_by_id and lz["term_months"] >= 24]
    for lz in rng.sample(expired, min(10, len(expired))):
        actual = int(lz["term_months"] * rng.uniform(0.3, 0.7))
        lz["expiration_date"] = eom(add_months(lz["commencement_date"], actual - 1))
        lz["status"] = "Terminated"

    # renumber leases for stable ids
    leases.sort(key=lambda x: (x["property_id"], x["suite"], x["commencement_date"]))
    for i, lz in enumerate(leases):
        lz["lease_id"] = i + 1

    # ---- loans -----------------------------------------------------------
    def monthly_payment(balance: float, rate: float, amort_months: int) -> float:
        r = rate / 12
        return balance * r / (1 - (1 + r) ** -amort_months)

    loans: list[dict] = []
    loan_id = 0
    financeable = [p for p in properties if p["status"] in ("Owned", "Under Contract")]
    for p in financeable:
        if rng.random() < 0.12:      # ~12% of properties are unlevered
            continue
        loan_id += 1
        ltv0 = rng.uniform(0.5, 0.7)
        original = round(p["acquisition_price"] * ltv0, -3)
        rate_type = "Floating" if rng.random() < 0.15 else "Fixed"
        rate = round(rng.uniform(0.055, 0.08) if rate_type == "Floating" else rng.uniform(0.035, 0.065), 4)
        origination = p["acquisition_date"]
        amort = rng.choice([300, 360])
        io = rng.choices([0, 12, 24, 36, 60], weights=[4, 2, 2, 2, 1])[0]
        maturity = add_months(origination, 12 * rng.randint(5, 10))
        elapsed = max(0, months_between(origination, AS_OF))
        amortizing_elapsed = max(0, elapsed - io)
        r = rate / 12
        if amortizing_elapsed > 0:
            pmt = monthly_payment(original, rate, amort)
            current = original * (1 + r) ** amortizing_elapsed - pmt * (((1 + r) ** amortizing_elapsed - 1) / r)
        else:
            current = original
        loans.append({
            "loan_id": loan_id, "property_id": p["property_id"],
            "lender": rng.choice(LENDERS), "original_balance": original,
            "current_balance": round(current, 2), "interest_rate": rate,
            "rate_type": rate_type, "origination_date": origination,
            "maturity_date": maturity, "amortization_months": amort,
            "io_period_months": io,
            "ltv": round(current / p["current_market_value"], 3),
            "dscr": None,  # filled after financials
            "is_recourse": 1 if rng.random() < 0.2 else 0,
        })
    # construction loan for the development property
    loan_id += 1
    loans.append({
        "loan_id": loan_id, "property_id": dev["property_id"],
        "lender": rng.choice(LENDERS),
        "original_balance": round(dev["acquisition_price"] * 0.6, -3),
        "current_balance": round(dev["acquisition_price"] * 0.45, -3),
        "interest_rate": 0.089, "rate_type": "Floating",
        "origination_date": dev["acquisition_date"],
        "maturity_date": add_months(dev["acquisition_date"], 36),
        "amortization_months": 0, "io_period_months": 36,
        "ltv": round(dev["acquisition_price"] * 0.45 / dev["current_market_value"], 3),
        "dscr": None, "is_recourse": 1,
    })

    # ---- financials ------------------------------------------------------
    loans_by_prop: dict[int, list[dict]] = {}
    for ln in loans:
        loans_by_prop.setdefault(ln["property_id"], []).append(ln)

    def occupied_sqft(prop_id: int, pe: date) -> int:
        total = 0
        for lz in leases:
            if lz["property_id"] != prop_id or lz["status"] == "Pending":
                continue
            if lz["commencement_date"] <= pe and (lz["expiration_date"] >= pe or lz["status"] == "Holdover"):
                total += lz["leased_sqft"]
        return total

    financials: list[tuple] = []
    noi_history: dict[int, list[tuple[date, float]]] = {}
    fin_id = 0
    for p in properties:
        if p["status"] == "In Development":
            continue
        for m in range(WINDOW_MONTHS):
            pe = eom(add_months(WINDOW_START, m))
            if p["disposition_date"] and pe > p["disposition_date"]:
                break
            occ_rate = round(min(1.0, occupied_sqft(p["property_id"], pe) / p["rentable_sqft"]), 4)
            gpr = round(p["rentable_sqft"] * market_rent_psf(p, pe) / 12, 2)
            vloss = round(gpr * (1 - occ_rate), 2)
            egi = round(gpr - vloss, 2)
            opex = round(p["rentable_sqft"] * p["_opex_psf"] / 12 * (0.80 + 0.30 * occ_rate) * rng.uniform(0.95, 1.05), 2)
            noi = round(egi - opex, 2)
            capex = round(opex * rng.uniform(0.5, 3.0), 2) if rng.random() < 0.08 else round(opex * rng.uniform(0.0, 0.1), 2)
            ds = 0.0
            for ln in loans_by_prop.get(p["property_id"], []):
                if ln["origination_date"] <= pe <= ln["maturity_date"]:
                    if ln["amortization_months"] == 0 or months_between(ln["origination_date"], pe) < ln["io_period_months"]:
                        ds += ln["original_balance"] * ln["interest_rate"] / 12
                    else:
                        ds += monthly_payment(ln["original_balance"], ln["interest_rate"], ln["amortization_months"])
            fin_id += 1
            financials.append((fin_id, p["property_id"], iso(pe), "Month",
                               gpr, vloss, egi, opex, noi, capex, round(ds, 2), occ_rate))
            noi_history.setdefault(p["property_id"], []).append((pe, noi))

    # loan DSCR from trailing-12-month NOI
    for ln in loans:
        hist = noi_history.get(ln["property_id"], [])
        if len(hist) >= 12:
            ttm = sum(v for _, v in hist[-12:])
            annual_ds = 0.0
            if ln["amortization_months"] == 0 or months_between(ln["origination_date"], AS_OF) < ln["io_period_months"]:
                annual_ds = ln["original_balance"] * ln["interest_rate"]
            else:
                annual_ds = monthly_payment(ln["original_balance"], ln["interest_rate"], ln["amortization_months"]) * 12
            ln["dscr"] = round(ttm / annual_ds, 2) if annual_ds else None

    # ---- valuations ------------------------------------------------------
    valuations: list[tuple] = []
    val_id = 0
    for p in properties:
        if p["status"] == "In Development":
            val_id += 1
            valuations.append((val_id, p["property_id"], iso(add_months(p["acquisition_date"], 6)),
                               "Cost", p["current_market_value"], None, rng.choice(APPRAISERS)))
            continue
        n = rng.randint(2, 4)
        last_date = p["disposition_date"] or add_months(AS_OF, -rng.randint(1, 10))
        dates = [add_months(last_date, -12 * k).replace(day=1) for k in range(n)][::-1]
        dates = [d for d in dates if d > p["acquisition_date"]]
        if not dates:
            dates = [add_months(p["acquisition_date"], 12)]
        for k, d in enumerate(dates):
            val_id += 1
            frac = (k + 1) / len(dates)
            value = round(p["acquisition_price"] + (p["current_market_value"] - p["acquisition_price"]) * frac
                          * rng.uniform(0.97, 1.03), -3)
            if k == len(dates) - 1:  # latest tracks current_market_value closely
                value = round(p["current_market_value"] * rng.uniform(0.98, 1.02), -3)
            hist = [v for pe, v in noi_history.get(p["property_id"], []) if pe <= d]
            cap = round(min(0.095, max(0.035, sum(hist[-12:]) / max(len(hist[-12:]), 1) * 12 / value)), 4) if len(hist) >= 6 else None
            method = rng.choices(["Income", "Sales Comparison", "Cost"], weights=[7, 2, 1])[0] if cap else "Sales Comparison"
            valuations.append((val_id, p["property_id"], iso(d), method, value, cap, rng.choice(APPRAISERS)))

    # ---- pack rows -------------------------------------------------------
    return {
        "funds": [tuple(f) for f in funds],
        "properties": [(p["property_id"], p["fund_id"], p["name"], p["address"], p["city"],
                        p["state"], p["market"], p["submarket"], p["property_type"],
                        p["building_class"], p["rentable_sqft"], p["year_built"],
                        p["year_renovated"], p["num_floors"], iso(p["acquisition_date"]),
                        p["acquisition_price"], p["current_market_value"], p["ownership_pct"],
                        p["status"], iso(p["disposition_date"])) for p in properties],
        "tenants": tenants,
        "leases": [(lz["lease_id"], lz["property_id"], lz["tenant_id"], lz["suite"], lz["floor"],
                    lz["leased_sqft"], lz["lease_type"], lz["base_rent_psf"], lz["annual_base_rent"],
                    lz["escalation_pct"], iso(lz["commencement_date"]), iso(lz["expiration_date"]),
                    lz["term_months"], lz["security_deposit"], lz["has_renewal_option"],
                    lz["free_rent_months"], lz["ti_allowance_psf"], lz["status"]) for lz in leases],
        "property_financials": financials,
        "loans": [(ln["loan_id"], ln["property_id"], ln["lender"], ln["original_balance"],
                   ln["current_balance"], ln["interest_rate"], ln["rate_type"],
                   iso(ln["origination_date"]), iso(ln["maturity_date"]), ln["amortization_months"],
                   ln["io_period_months"], ln["ltv"], ln["dscr"], ln["is_recourse"]) for ln in loans],
        "valuations": valuations,
    }


def write_db(rows: dict[str, list[tuple]], out_path: Path, schema_path: Path = DEFAULT_SCHEMA) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if out_path.exists():
        out_path.unlink()
    conn = sqlite3.connect(out_path)
    try:
        conn.executescript(schema_path.read_text())
        for table, table_rows in rows.items():
            if not table_rows:
                continue
            placeholders = ",".join("?" * len(table_rows[0]))
            conn.executemany(f"INSERT INTO {table} VALUES ({placeholders})", table_rows)
        conn.commit()
        conn.execute("VACUUM")
    finally:
        conn.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA)
    parser.add_argument("--seed", type=int, default=SEED)
    args = parser.parse_args()
    rows = build(seed=args.seed)
    write_db(rows, args.out, args.schema)
    counts = ", ".join(f"{t}={len(r)}" for t, r in rows.items())
    print(f"wrote {args.out} ({counts})")


if __name__ == "__main__":
    main()
