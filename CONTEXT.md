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

**Lease Listing**:
A row-per-lease view that identifies the lease by its `lease_id` and shows tenant, property, suite, expiration date, and status. A lease has no name; human-readable names come from the related Tenant and Property.
_Avoid_: lease name

**Portfolio As-of Date**:
The fixed date used to interpret relative dates in the bundled portfolio snapshot. It is versioned with the data and currently equals 2026-07-01; it is not the device clock.
_Avoid_: today, current device date

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

**Held Property**:
A Property whose status is anything other than Sold. “Held,” “current holdings,” and an unqualified “portfolio” refer to this set unless the question explicitly asks for sold or historical properties.
_Avoid_: active property, owned-only property

**Portfolio**:
The set of Held Properties across all Funds. A named Fund, market, or Property Type narrows that set; “all properties” explicitly includes sold properties.
_Avoid_: all properties

**Latest Snapshot**:
The most recent Monthly Financials row for each Property independently. It is not the single greatest reporting date across the entire Portfolio.
_Avoid_: current month, global latest date

**Explicit Month**:
The Monthly Financials row whose period end matches the month named in the question. It never falls back to a Property's Latest Snapshot.

**Right Now**:
The canonical current source for the requested metric: Current Market Value for value, Latest Snapshot for occupancy or vacancy, and Active or Holdover Leases for current rent-roll measures.
_Avoid_: latest appraisal

**Valuation**:
A historical appraisal event for a property (date, method, value, cap rate). Answers trend and history questions, never "what is it worth now."

**Loan**:
Mortgage debt secured by a property (lender, balances, rate, maturity, LTV, DSCR).

### Conversation experience

**Conversation**:
A persisted, user-visible thread of portfolio questions and CREG responses, with its own title and unsent draft.
_Avoid_: session

**Conversation Browser**:
The user-visible collection of Conversations used to search, create, and return to portfolio explorations.
_Avoid_: history screen, chat list

**Queued Question**:
A submitted question accepted into a Conversation but waiting for CREG to finish earlier inference work before answering it.
_Avoid_: pending message

**Answer Feedback**:
A user's Helpful or Not right judgment attached to one completed CREG answer, optionally followed by correction context.
_Avoid_: rating

**Support Bundle**:
An explicit developer-support export containing Conversations, drafts, results, Answer Feedback, diagnostics, and model and build provenance. It excludes model weights and the bundled portfolio database itself.
_Avoid_: log export, telemetry dump

### Query pipeline

**Standalone Question**:
A user turn after follow-up rewriting: self-contained, answerable without conversation context.

**Candidate Query**:
One identified SQL proposal generated for a turn, including its role, model revision, decoding configuration, seed, execution, and result.
_Avoid_: sample, answer candidate

**Result Group**:
Candidate Queries whose complete typed result rows have the same canonical SHA-256 identity; row order is ignored, duplicate rows remain significant.
_Avoid_: result signature, hash bucket

**Consensus**:
A Result Group containing a strict majority of the configured Candidate Queries.
_Avoid_: plurality, best vote

**No Consensus**:
A vote in which no Result Group contains a strict majority of the configured Candidate Queries; the Deterministic Anchor is selected.
_Avoid_: tie

**Deterministic Anchor**:
An executed temperature-zero Candidate Query that provides the stable fallback for every vote.
_Avoid_: greedy winner, default candidate

**Ambiguity Gate**:
The decision point that either passes a standalone question through or asks the user one clarifying question.

**Grounding Check**:
A comparison between one literal in a supported equality or membership predicate and the complete value domain of its unambiguously resolved entity or categorical column.
_Avoid_: literal scan, global catalog check

**Grounding Degradation**:
A failed or incomplete Grounding Check that leaves a valid query result usable, suppresses an unsupported correction notice, and remains eligible for retry on a later turn.
_Avoid_: grounding failure, cache miss

**Narration**:
The one-line plain-English summary of what was looked at and found; doubles as a back-translation of intent for the user to judge.

**Thinking Trace**:
The user-visible, plain-English disclosure of pipeline steps. Never shows SQL.

**Correction Layers**:
The four defenses against wrong answers: (A) result-shape and value-grounding heuristics, (B) narration-as-confirmation, (C) self-consistency voting, (D) uncertainty-gated compute.

**Gold Set**:
Hand-verified (question → SQL → result) triples held out from all training data; the measuring stick for accuracy.

**Execution Accuracy (EX)**:
The fraction of Gold Set questions whose Candidate Query returns the same complete typed row multiset as the gold SQL; numeric values use four-decimal half-even normalization.

**Evaluation Run**:
One immutable model, Gold Set, grammar mode, temperature, and seed execution whose command, inputs, environment, item rows, timings, and summary are content-addressed.
_Avoid_: result file, benchmark output

**Production Generation Configuration**:
The manifest-backed model revision, grammar mode, temperatures, sampling limits, and voting policy used by the app and parity harness.
_Avoid_: runtime defaults, model settings

**Starter Query**:
A versioned, reviewed question-and-SQL product contract exposed on the empty chat surface. It executes its canonical SQL directly through validation, read-only execution, grounding, and narration; it is not sent to SQL generation or repair.
_Avoid_: sample prompt, suggested prompt

**Free-form Question**:
User-authored text that enters follow-up rewriting, the Ambiguity Gate, SQL generation, validation, bounded repair, voting, grounding, and narration.
_Avoid_: starter query

**Follow-up Suggestion**:
One of up to three standalone next questions derived only from the latest completed question-and-answer pair. It appears beneath that answer only after its Candidate Query has already validated, executed, returned a useful result, and passed Grounding Checks.
_Avoid_: starter query, suggested prompt

**Prepared Follow-up**:
A Follow-up Suggestion bundled with its validated Candidate Query, cached typed result, and versioned model, runtime, schema, portfolio-database, SQL, and result provenance. A cache mismatch sends the question through the Free-form Question path.
_Avoid_: cached answer, starter query

**Prepared Answer**:
The in-place answer state after a Prepared Follow-up is tapped: its cached result is visible immediately while Narration is being produced. If Narration is interrupted, the same message is finalized with deterministic fallback Narration.
_Avoid_: partial answer, duplicate answer
