# CREG

CREG lets a commercial-real-estate professional explore a fixed portfolio database by asking questions in plain language, fully offline on iOS. This context covers the portfolio domain and the question-answering pipeline.

## Language

### Portfolio

**Fund**:
An investment vehicle that owns properties; characterized by strategy (Core, Core-Plus, Value-Add, Opportunistic) and vintage year.

**Property**:
A building held by a fund, possibly fractionally (ownership percentage).
_Avoid_: asset, building

**Property Type**:
The use classification of a property (Office, Retail, Industrial, Multifamily, Mixed-Use, Hospitality, Self-Storage).
_Avoid_: asset class

**Tenant**:
An organization that rents space under one or more leases.

**Lease**:
An agreement granting a tenant a suite in a property for a term at a base rent. The lease itself carries suite, floor, and leased square footage — there is no separate unit entity.

**Suite**:
The space within a property that a lease covers.
_Avoid_: unit, space

**Occupancy Rate**:
The reported fraction (0–1) of a property's rentable square footage that is occupied, from its monthly financials.

**Vacancy**:
One minus the occupancy rate from the property's latest monthly financials. Never derived by summing leases; the lease-derived figure is only a cross-check.

**Monthly Financials**:
A property's per-month operating figures: gross potential rent, vacancy loss, effective gross income, operating expenses, net operating income, capex, debt service, occupancy rate.

**Current Market Value**:
The canonical present value of a property, held on the property record.

**Valuation**:
A historical appraisal event for a property (date, method, value, cap rate). Answers trend and history questions, never "what is it worth now."

**Loan**:
Mortgage debt secured by a property (lender, balances, rate, maturity, LTV, DSCR).

### Query pipeline

**Standalone Question**:
A user turn after follow-up rewriting: self-contained, answerable without conversation context.

**Ambiguity Gate**:
The decision point that either passes a standalone question through or asks the user one clarifying question.

**Narration**:
The one-line plain-English summary of what was looked at and found; doubles as a back-translation of intent for the user to judge.

**Thinking Trace**:
The user-visible, plain-English disclosure of pipeline steps. Never shows SQL.

**Correction Layers**:
The four defenses against wrong answers: (A) result-shape and value-grounding heuristics, (B) narration-as-confirmation, (C) self-consistency voting, (D) uncertainty-gated compute.

**Gold Set**:
Hand-verified (question → SQL → result) triples held out from all training data; the measuring stick for accuracy.

**Execution Accuracy (EX)**:
The fraction of gold-set questions whose predicted SQL returns the same result set as the gold SQL, order-insensitive.
