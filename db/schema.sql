-- CREG portfolio schema — FROZEN 2026-07-19.
-- This DDL is an input to the SQL grammar, the gold set, and fine-tuning data.
-- Semantic rules for querying this schema are recorded in docs/adr/0001-schema-semantics.md.

PRAGMA foreign_keys = ON;

CREATE TABLE funds (
    fund_id           INTEGER PRIMARY KEY,
    name              TEXT NOT NULL,
    vintage_year      INTEGER,
    strategy          TEXT CHECK (strategy IN ('Core','Core-Plus','Value-Add','Opportunistic')),
    committed_capital REAL,
    target_irr        REAL,
    inception_date    TEXT,
    status            TEXT CHECK (status IN ('Investing','Harvesting','Closed'))
);

CREATE TABLE properties (
    property_id          INTEGER PRIMARY KEY,
    fund_id              INTEGER REFERENCES funds(fund_id),
    name                 TEXT NOT NULL,
    address              TEXT,
    city                 TEXT,
    state                TEXT,
    market               TEXT,
    submarket            TEXT,
    property_type        TEXT CHECK (property_type IN
                            ('Office','Retail','Industrial','Multifamily',
                             'Mixed-Use','Hospitality','Self-Storage')),
    building_class       TEXT CHECK (building_class IN ('A','B','C')),
    rentable_sqft        INTEGER,
    year_built           INTEGER,
    year_renovated       INTEGER,
    num_floors           INTEGER,
    acquisition_date     TEXT,
    acquisition_price    REAL,
    current_market_value REAL,
    ownership_pct        REAL CHECK (ownership_pct BETWEEN 0 AND 1),
    status               TEXT CHECK (status IN
                            ('Owned','Under Contract','Sold','In Development')),
    disposition_date     TEXT
);

CREATE TABLE tenants (
    tenant_id          INTEGER PRIMARY KEY,
    name               TEXT NOT NULL,
    industry           TEXT CHECK (industry IN
                          ('Technology','Finance','Healthcare','Legal','Retail',
                           'Government','Manufacturing','Professional Services','Other')),
    credit_rating      TEXT,
    is_national_tenant INTEGER CHECK (is_national_tenant IN (0,1)),
    headquarters_city  TEXT,
    headquarters_state TEXT
);

CREATE TABLE leases (
    lease_id           INTEGER PRIMARY KEY,
    property_id        INTEGER REFERENCES properties(property_id),
    tenant_id          INTEGER REFERENCES tenants(tenant_id),
    suite              TEXT,
    floor              INTEGER,
    leased_sqft        INTEGER,
    lease_type         TEXT CHECK (lease_type IN
                          ('NNN','Gross','Modified Gross','Full Service')),
    base_rent_psf      REAL,
    annual_base_rent   REAL,
    escalation_pct     REAL,
    commencement_date  TEXT,
    expiration_date    TEXT,
    term_months        INTEGER,
    security_deposit   REAL,
    has_renewal_option INTEGER CHECK (has_renewal_option IN (0,1)),
    free_rent_months   INTEGER,
    ti_allowance_psf   REAL,
    status             TEXT CHECK (status IN
                          ('Active','Expired','Pending','Terminated','Holdover'))
);

CREATE TABLE property_financials (
    financial_id           INTEGER PRIMARY KEY,
    property_id            INTEGER REFERENCES properties(property_id),
    period_end            TEXT,
    period_type           TEXT CHECK (period_type IN ('Month','Quarter','Year')),
    gross_potential_rent  REAL,
    vacancy_loss          REAL,
    effective_gross_income REAL,
    operating_expenses    REAL,
    net_operating_income  REAL,
    capex                 REAL,
    debt_service          REAL,
    occupancy_rate        REAL CHECK (occupancy_rate BETWEEN 0 AND 1)
);

CREATE TABLE loans (
    loan_id             INTEGER PRIMARY KEY,
    property_id         INTEGER REFERENCES properties(property_id),
    lender              TEXT,
    original_balance    REAL,
    current_balance     REAL,
    interest_rate       REAL,
    rate_type           TEXT CHECK (rate_type IN ('Fixed','Floating')),
    origination_date    TEXT,
    maturity_date       TEXT,
    amortization_months INTEGER,
    io_period_months    INTEGER,
    ltv                 REAL,
    dscr                REAL,
    is_recourse         INTEGER CHECK (is_recourse IN (0,1))
);

-- Appraisal history. Included in v1 (see docs/adr/0001-schema-semantics.md):
-- properties.current_market_value is the canonical current value.
CREATE TABLE valuations (
    valuation_id   INTEGER PRIMARY KEY,
    property_id    INTEGER REFERENCES properties(property_id),
    valuation_date TEXT,
    method         TEXT CHECK (method IN ('Income','Sales Comparison','Cost')),
    market_value   REAL,
    cap_rate       REAL,
    appraiser      TEXT
);

-- Indexes on foreign keys and common filter columns
CREATE INDEX idx_properties_fund      ON properties(fund_id);
CREATE INDEX idx_properties_type      ON properties(property_type);
CREATE INDEX idx_properties_market    ON properties(market);
CREATE INDEX idx_properties_status    ON properties(status);
CREATE INDEX idx_leases_property      ON leases(property_id);
CREATE INDEX idx_leases_tenant        ON leases(tenant_id);
CREATE INDEX idx_leases_status        ON leases(status);
CREATE INDEX idx_leases_expiration    ON leases(expiration_date);
CREATE INDEX idx_fin_property_period  ON property_financials(property_id, period_end);
CREATE INDEX idx_loans_property       ON loans(property_id);
CREATE INDEX idx_loans_maturity       ON loans(maturity_date);
CREATE INDEX idx_valuations_property  ON valuations(property_id);
