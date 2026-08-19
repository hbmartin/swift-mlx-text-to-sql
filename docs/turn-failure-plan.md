# Turn Failure: typed reasons, recovery surface, scope diagnosis

Revision 2 — incorporates the 2026-08-19 codebase verification pass and the
device-floor decision. Supersedes the draft plan.

## Context

Users ask CREG questions the bundled SQLite portfolio cannot answer and get a
dead end. The draft plan framed this as a single generic message emitted from
three engine states; verification corrected the baseline: the engine strings at
`QueryPipeline+Live.swift` (`.failed(` at `:356`, `:365`, `:391`, `:398`,
`:411`, `:451`, `:459`, `:503`, `:523`, `:579`) **never reach the user in
production**. `LiveDependencies.swift:358-367` wraps the pipeline in
`reportingTerminalFailures` (`QueryPipeline+Diagnostics.swift:70-104`), which
intercepts every `.failed`, classifies it through
`PipelineTerminalFailure.init(stage:telemetry:)` (`:225-287`), and re-emits
`.failed(message: failure.userMessage)` — already seven differentiated
messages behind an explicit precedence ladder.

The real defect is therefore not "one message for five causes" but that the
differentiation is **stringly and invisible**: it lives in a diagnostics
wrapper, ships out of the engine as a finished English sentence inside
`TurnOutcome.failed(message: String)`, and never reaches `ChatMessage.Body` or
telemetry as data — violating the convention at `PipelineEvent.swift:6-8`:
*"Events are data, never display strings — the UI maps them to user-facing
language."* Because the reason is a string, the UI cannot gate recovery
behavior on it, the eval harness cannot score it, and a scope claim has
nowhere to attach.

### The measurement that shaped this plan

Every SQL error in all 119 stored eval runs (`eval/runs/*/*.json`; 460 item
rows across the three files carrying `results` arrays) was harvested and
classified against `schema_catalog.json`: 44 errors, all prefixed
`SQLite error 1:`, **every one on a gold-set question that is by definition
answerable**, mapping to exactly 23 distinct gold question ids.

| Error shape | Count | Meaning |
|---|---|---|
| Qualified (`ln.status`, `f.name`, `t.market`) | 18 | Wrong alias — column exists in all 12 distinct cases |
| Bare, column exists somewhere | 15 | Wrong join scope |
| Bare, absent from every table | 8 | `current_rate`, `vacancy`, `year`, `rnk` |

The last bucket is the only signal a deterministic scope check could fire on,
and all four names are false positives: `current_rate` → `loans.interest_rate`
exists; `year` → date columns exist; `rnk` is a window-function alias; and
`vacancy` is a first-class Portfolio term (`CONTEXT.md:41`). Precision of the
rule "unresolved identifier ⇒ the data doesn't cover it" is **0/41**. Worst
case: `T2-21` *"What are the five properties with the highest vacancy right
now?"* — semantically the `highest-vacancy-v1` Starter Query, present in all
three gold files — produced `no such column: vacancy`. A naive scope check
would refuse CREG's own reviewed product query.

**Therefore: SQLite binding errors are evidence about the model, never about
the data.** Scope claims come only from an enumerated Foundation Model verdict
that has seen the schema. Recorded as ADR 0010.

### Intended outcome

A failed turn states what actually went wrong as typed data end to end,
explains coverage only when there is admissible evidence, and offers
pre-executed next questions instead of a dead end — with the mechanism
measurable rather than assumed. The app requires hardware and Apple
Intelligence sufficient to run Foundation Models, and leans on them.

---

## Decisions taken

| Decision | Choice |
|---|---|
| Device floor | **Raised: iPhone 15 Pro and newer** (model identifier major ≥ 16). ADR 0011 |
| Apple Intelligence | **Required on.** Structured availability reasons; blocking enable-AI callout; `FMClient.fallback()` survives only as a mid-turn safety net |
| Evidence for a scope claim | FM + schema only; never SQL errors (ADR 0010) |
| Failure representation | Typed reason emitted **at each site** (authoritative); wrapper stops rewriting outcomes |
| `derive(from:)` | Test oracle only — telemetry under-determines the reason (zero-signal sites `:503`/`:523`; `.exhausted` co-occurs with success at `:482`) |
| Cancellation | Distinct `cancelled` reason, never folded into timeout |
| Scope verdict's place | Annotation on top of the reason, not a reason itself |
| FM output shape | Enumerated verdict + one optional guarded noun phrase |
| Diagnosis timing | After the failure renders; in-place revisioned update |
| Recovery suggestions | FM-generated and pre-executed; **strategy branches on the scope verdict** (D waits for C's result); starter-query fallback on FM proposal failure |
| Provenance | New `QueryOrigin.recoverySuggestion` + distinct preparation policy version |
| Telemetry | Typed reason and verdict stamped into `TurnTelemetry` (schema v7) so `events.jsonl`/eval see them |
| Eval | Checked-in ~90-item corpus + deterministic scorer; FM verdicts captured on device via a debug-only Settings export |
| False-abstention gate | Provisional **≤ 1 of 23**, `T2-21` a hard gate; recalibration procedure documented in `docs/eval.md` |
| Vocabulary | New sibling terms; `Follow-up Suggestion` and `Ambiguity Gate` untouched |
| Order | Phase 0 (floor + AI) → 1 (reasons) → 2 (recovery) → 3 (corpus) → 4 (verdict) |

---

## Phase 0 — Device floor and Apple Intelligence requirement

**`CREGCore/DeviceCapability.swift`** — replace the split rule
(`minimumMajor 15` / `minimumMinorAtMinimumMajor 4`, with the iPhone 14 Pro
carve-out comment) with **major ≥ 16**: iPhone 15 Pro is `iPhone16,1`, so the
new rule admits exactly the 15 Pro/Pro Max and everything newer while dropping
`iPhone15,4`/`iPhone15,5` (15 / 15 Plus). Update `requirementMessage`
("CREG requires iPhone 15 Pro or newer…"), `UnsupportedDeviceView`
(`FailureViews.swift:8-29`), and `DeviceCapabilityTests`. The DEBUG bypass
(`isCurrentDeviceSupported` returns true in DEBUG) stays — it is what the
preview/simulator harness relies on. iOS 26 is already the deployment target
everywhere (`Package.swift` `.iOS("26.0")`, `IPHONEOS_DEPLOYMENT_TARGET =
26.0`), so no change there.

**Structured FM availability** — today `FMClient.swift:67-74` collapses every
unavailability into `.unavailable(reason: String(describing: reason))` and the
string is never read again. Replace `FMAvailability` (`Models.swift:112-115`)
with typed reasons mapped from
`SystemLanguageModel.Availability.UnavailableReason`:

```
available
unavailable(FMUnavailabilityReason)
  appleIntelligenceNotEnabled
  modelNotReady            // assets downloading — transient
  deviceNotEligible        // unreachable post-floor: debug assert + diagnostic
  other(String)            // @unknown default
```

**App-level FM readiness gate** — a sibling to `ModelReadiness`
(`AppFeature.swift:16-20`), re-checked on foreground/scene-phase changes
(availability is a synchronous call). `isSubmissionEnabled`
(`AppFeature+ConversationLifecycle.swift:179`) now requires MLX ready **and**
FM available. UI states:

- `appleIntelligenceNotEnabled` → blocking callout over the composer with a
  link into Settings. This is the product's only no-FM surface.
- `modelNotReady` → transient "preparing Apple Intelligence" state, not a wall.
- All new turns are gated, starter queries included — CREG requires Apple
  Intelligence, full stop. History stays readable.

`FMClient.fallback()` is retained strictly as a **mid-turn safety net**: a turn
already in flight when FM flips unavailable degrades that turn gracefully
(templated narration) rather than crashing. It is no longer a designed
experience, and no feature below plans around it.

---

## Phase 1 — Typed failure reasons and honest copy

No FM, fully unit-testable. Ship-ready on its own.

**`CREGCore` (Models.swift or a new TurnFailure.swift)** — replace
`TurnOutcome.failed(message: String)` (`Models.swift:695-702`) with
`failed(reason: TurnFailureReason)`. The taxonomy reconciles the draft's seven
cases with the production ladder's seven messages:

```
timedOut(stage: String)        // deadline exceeded; stage from PipelineDeadlineExceeded
cancelled                      // CancellationError; today's "cancelled" magic string
databaseUnavailable            // validation disposition .terminal / kind .databaseUnavailable
generationFailed               // model produced no SQL at all (ladder case: sql == nil)
generationExhausted            // no repairable path (:411) or repairs exhausted
noCandidateSelected            // vote selector nil (:503), or winner incomplete (:523)
languageServiceFailed(stage: String)  // FM rewrite/gate/narration threw
starterQueryUnavailable        // DeterministicStarterPipeline
pipelineUnavailable            // QueryPipeline+Unavailable / unavailable(failure:)
unexpected
```

**Authority: the reason is emitted at each site.** Every producer knows its
exact state — richer than any telemetry reconstruction. Producer sites:
`QueryPipeline+Live.swift` `.failed(` at `:356`, `:365`, `:391`, `:398`,
`:411`, `:451`, `:459`, `:503`, `:523`, and the outer catch at `:579` (which
distinguishes `PipelineDeadlineExceeded` → `timedOut`, `CancellationError` →
`cancelled`, an error thrown during rewrite/gate/narration →
`languageServiceFailed` — requires tracking the current FM stage locally —
else `unexpected`); `DeterministicStarterPipeline.swift:87-89`/`:174-178`;
`QueryPipeline+Unavailable.swift:22`;
`QueryPipeline+Diagnostics.swift:49`/`:102`; **and
`AppFeature+PipelineEvents.swift:226`** (`recoverFromUnterminatedPipelineStream`,
the producer the draft missed).

**The wrapper stops rewriting outcomes.** `reportingTerminalFailures`
(`QueryPipeline+Diagnostics.swift:70-104`) keeps its diagnostics logging and
`terminalError` stamping but passes the site's `.failed(reason:)` through
untouched. `PipelineTerminalFailure`'s userMessage ladder (`:225-287`) is
retired from classification duty; its copy migrates to the presentation
mapping below. This removes the competing precedence ladder the draft would
otherwise have created.

**`TurnFailureReason.derive(from: TurnTelemetry)`** is demoted to a **test
oracle**: a pure function used to cross-check that each site's emitted reason
is consistent with its telemetry, with the documented caveats that the vote
sites set no telemetry fields locally and `recoveryOutcome == .exhausted` is
set at `:482` on turns that then *succeed* — so the oracle is advisory, never
the production source.

**Telemetry (schema v7)** — add `failureReason: TurnFailureReason?` and
`scopeVerdict: ScopeVerdict?` (Phase 4) to `TurnTelemetry`; bump
`currentSchemaVersion` 6 → 7 and extend the tolerant custom `init(from:)`
(`Models.swift:591-692`). This puts the typed record into `devInfo`, the
`event` table JSONL, `events.jsonl` in the Support Bundle, and the eval
surface.

**Event-line wire shape** — `TurnOutcome` is persisted: every
`PipelineEvent.turnFinished` is JSON-encoded and inserted into the SQLite
`event` table (`AppFeature+PipelineEvents.swift:20-22` →
`HistoryStore+Transactions.swift:291-311`) and re-exported via `exportJSONL`
and the Support Bundle. Nothing in-app decodes stored lines back, so old lines
remain valid opaque text; the shape change is documented in `docs/eval.md` for
external consumers.

**Persistence** — new `ChatMessage.Body` case
`failedTurn(reason: TurnFailureReason, scopeVerdict: ScopeVerdict?)`. Keep
`.failure(String)` decodable for existing history (decode is already
per-message tolerant — `compactMap { try? … }` in
`HistoryStore+Conversations.swift:82-85` — so an app rollback degrades to
silently dropped messages, acceptable for an internal TestFlight app). No
schema migration; the payload column is opaque
(`HistoryStore+Migrations.swift` ends at `v4-prepared-follow-ups`). Exhaustive
`Body` switches to touch: fingerprint (`ChatMessage.swift:98-105`),
`previewText` (`ConversationModels.swift:315-322`), `searchEntry`
(`HistoryStore+SupportBundle.swift:136-143` — `.failure` is deliberately not
indexed today; the new case keeps that parity), and routing
(`MessageViews.swift:43-47`).

**Copy** — extend `FailurePresentation`
(`CREGFeatures/FailurePresentation.swift`, `code`/`title`/`message`/
`diagnostic`, `technicalDetails(developerMode:)`) with a
`TurnFailureReason` → presentation mapping, seeding it from the ladder's
existing seven messages (including "That answer was cancelled" for
`cancelled`). Copy must not imply user error for causes the user cannot fix;
"try rephrasing" appears only where rephrasing can actually work. All copy is
hardcoded English, consistent with the rest of the app (no localization
infrastructure exists).

**Views** — `FailureMessageView` (`FailureViews.swift:72`, currently
`message`/`diagnostic`/`developerMode`) takes the presentation; the hardcoded
`Label("Unable to answer", …)` at `:79` becomes the per-reason title.
`timedOut`/`cancelled` cells get a **Try again** affordance that re-submits
the same question — for those two reasons retry is the honest recovery and
needs no model work.

**Fix in passing** — unify the two duplicated `timeoutStage` whitelists
(`PipelineOperationFormatting.swift:74-83`,
`AppFeature+ConversationLifecycle.swift:298-307`) into one helper that
includes the `starter-*` stages, which today normalize to `"unknown"`.

---

## Phase 2 — Recovery surface

Reuse `FollowUpPreparationPipeline`'s generate → validate → execute →
provenance flow; `PreparedFollowUp` renders instantly on tap, so a suggestion
cannot fail twice. Two draft assumptions were wrong and are corrected here:

**Seeding** — `FollowUpSuggestionContext`
(`CREGCore/FollowUpSuggestion.swift:7-27`) requires a non-optional
`result: QueryResult` and `narration`, and is only constructed inside
`case .answered` (`AppFeature+PipelineEvents.swift:161-169`). Restructure it
around a seed:

```
enum Seed {
  case answer(result: QueryResult, narration: String)
  case turnFailure(reason: TurnFailureReason, scopeVerdict: ScopeVerdict?)
}
```

with the common fields (`sourceAssistantMessageID`, `question`,
`standaloneQuestion`) unchanged. The `suggestFollowUps` prompt branches on the
seed. The verdict field is optional from day one so Phase 2 can ship before
Phase 4; until C exists the strategy is verdict-unaware.

**Reason gating (the draft never gated D):** recovery suggestions run only for
`generationFailed`, `generationExhausted`, and `noCandidateSelected`. Skipped:
`timedOut`/`cancelled` (retry affordance instead), `databaseUnavailable` and
`pipelineUnavailable` (pre-execution is impossible), `starterQueryUnavailable`
(suggesting starter queries would be circular), `unexpected`.

**Verdict-aware strategy (D waits for C):** the reducer starts the scope
verdict first; recovery preparation starts when the verdict arrives, or
immediately if the reason is verdict-ineligible. On `outsideRealEstate`, skip
FM generation entirely — a nonsense question seeds nothing useful — and offer
up to three starter queries in registry order under "Here's what CREG can
answer." All other verdicts (and no-verdict) use FM-generated suggestions
seeded by the failed question.

**No pipeline path existed for the fallback:**
`FollowUpPreparationPipeline.swift:28` hard-exits when FM is unavailable, so
the starter fallback cannot live inside the FM proposal step. Instead: when
the proposal fails (`FollowUpProposalFailure` — `schemaLoadingFailed`,
`generationFailed`, `generationTimedOut`) or the verdict says
`outsideRealEstate`, prepare **starter-seeded** candidates through a
deterministic branch of the same pipeline: fixed reviewed SQL
(`StarterQuery.sql`), no generation, then the existing validate → execute →
ground → provenance steps. With Apple Intelligence required (Phase 0), this
fallback is an FM-failure contingency, not a device tier.

**Provenance discriminator (the draft had none):** add
`QueryOrigin.recoverySuggestion` (`Models.swift:437-441` — today
`FollowUpPreparationPipeline.swift:155` stamps `.preparedFollowUp`
unconditionally) and a distinct preparation policy version
(`"recovery-suggestion-v1|…"`) so telemetry, eval, and cache-validity checks
can tell the two surfaces apart.

**Wiring** — on `.turnFinished(.failed(reason:))` with an eligible reason, set
`followUpContext` with the failure seed (mirroring
`AppFeature+PipelineEvents.swift:161-170`). The existing five-condition guard
at `AppFeature+FollowUps.swift:11-17` (`activeTurn == nil`, `queue.isEmpty`,
`pendingTurnPersistence == nil`, `modelReadiness == .ready`, conversation
exists) and `.low` priority stay as-is. **No view change is needed for
placement**: the chips at `MessageViews.swift:133-142` sit outside the body
switch with an ID-based guard, so they render under the failure cell as soon
as a batch carries its message ID; only the section label changes ("Try one of
these instead").

---

## Phase 3 — Answerability corpus and scorer

**Constraint:** the dev Mac is macOS 15.7.9; `FMClient.live()` gates on
26 (`FMClient.swift:57-61`) and returns `fallback()` here, and `creg-eval-cli`
is a single-shot SQL-gen + execute + EX harness (non-optional `GoldItem.sql`,
no pipeline/gate/FM). So the corpus, labels, scorer, and stub-FM tests are
built offline; real verdicts are captured on device.

**`eval/gold/answerability.jsonl`** — `{id, question, expectedVerdict}`, plus
an optional `acceptableVerdicts` array used sparingly for genuinely
bucket-straddling questions. Target ~90 items:

- `outsideRealEstate` — ~20–25 authored
- `inDomainButNotTracked` — ~20–25 authored (property manager, tenant
  contacts, ESG)
- `needsDataNotInSnapshot` — ~20–25 authored (forecasts, tax bills,
  post-as-of-date)
- `likelyAnswerableModelFailed` — the 23 distinct gold questions with recorded
  real failures, recovered by joining erroring `ItemResult.id` against
  `gold_v1`/`gold_v2`/`binding_regressions`. This is the false-abstention
  guard; `T2-21` is its keystone case.

**Scorer** — pure, deterministic, offline; a new target/subcommand in CREGKit;
emits a 4×4 confusion matrix reproducible byte-for-byte from a fixed input.
The shipping gate for Phase 4 is the **false-abstention rate**: the share of
`likelyAnswerableModelFailed` items misclassified as any not-covered bucket.
**Provisional threshold: ≤ 1 of 23, with `T2-21` correct as a hard gate.**
`docs/eval.md` gains an "Answerability" section recording the threshold as
provisional and the recalibration procedure: after the first on-device
capture, review every miss individually; either fix the verdict prompt and
re-capture, or — if the misses are judged irreducible — keep ≤ 1; otherwise
ratchet to 0. Each capture is recorded under the content-addressed run
discipline (manifest with schema/model/corpus hashes).

**`CREGKit/Tests/CREGEngineTests/`** — the `derive` oracle truth table over
constructed `TurnTelemetry` values (including the simultaneous-signal
combinations: timeout + terminal, exhausted-then-answered, zero-signal vote
failures), and the whole failure path with a stubbed FM
(`EngineTestSupport.swift` / `SQLGenClientFactory`; `QueryPipelineTests.swift`
is the host).

**On-device capture** — a debug-only Settings action (`#if DEBUG`), following
the `SupportBundle.swift` + `SettingsView.swift:229` `ShareLink` precedent:
streams the corpus through the real `scopeVerdict` closure and exports JSONL
with a manifest. Chosen over a device-run test target to maximize
debuggability — the capture sees exactly the app's serializer, prompt, and
availability path.

---

## Phase 4 — Scope diagnosis, behind the corpus

**`CREGCore/FMClient.swift`** — add a `scopeVerdict` closure alongside
`gate`/`narrate`/`suggestFollowUps`, with a `@Generable` probe in the
`GateProbe` style (`FMClient.swift:41-47`), and a new
`InferenceSerializer.Operation` case (`.scopeVerdict`):

```
enum ScopeVerdict: outsideRealEstate | inDomainButNotTracked
                 | needsDataNotInSnapshot | likelyAnswerableModelFailed
var missingSubject: String?   // rendered ONLY for inDomainButNotTracked
```

The prompt receives the standalone question **and**
`SQLGenClient.schemaPrompt()` — 2,431 chars ≈ 700 tokens
(`CREGInference/Resources/schema_prompt.txt`), so the full prompt sits around
1,300 tokens, comfortably inside the on-device session window. Bias the prompt
toward `likelyAnswerableModelFailed` the way the gate prompt biases toward
answering.

**`missingSubject` guards** — the noun phrase is the one piece of FM text a
user reads, so it is capped (~40 chars), stripped of newlines/markup, and
passed through a deterministic coverage check: if it lexically matches any
table or column in `schema_catalog.json` or a CONTEXT.md Portfolio term, the
annotation is dropped and only the human-written bucket copy renders.
Otherwise the annotation itself could make a false scope claim — the exact
failure mode ADR 0010 exists to prevent.

**When it runs** — only for `generationFailed`, `generationExhausted`, and
`noCandidateSelected`. Skipped for `timedOut`, `cancelled`,
`databaseUnavailable`, `starterQueryUnavailable`, `pipelineUnavailable`,
`unexpected`: the cause is already known and the user has waited long enough.
(`withPipelineDeadline` throws immediately at `seconds <= 0` —
`PipelineDeadline.swift:22-24` — so running inside a timed-out turn would fail
instantly anyway.)

**Where it runs** — after the failure renders, outside the turn deadline,
updating the message in place through `MessageUpdateQueue` (revisioned saves;
same pattern as `preparedAnswer → .answer`, whose race/kill handling —
per-conversation FIFO, `INSERT OR IGNORE` idempotence, deletion protocol — is
already in place). The verdict lands in both the `Body` case and
`devInfo.scopeVerdict`. C and D both pass through `InferenceSerializer` (FIFO
over FM **and** MLX); C is enqueued first and D's strategy consumes its
result per Phase 2. If the app dies before the verdict lands, the reason-only
copy from Phase 1 is a complete experience. `FMClient.fallback()` returns no
verdict; with Apple Intelligence required this is only a transient state.

---

## Documentation

**`docs/adr/0010-scope-claims-from-fm-verdict-only.md`** — the rule and the
numbers (0/41 precision; the `vacancy`/`T2-21` case), with the corrected
baseline (production already differentiated messages via
`PipelineTerminalFailure`; the defect was stringly representation, not absent
differentiation), so the decision is not re-litigated by someone who finds a
clean `no such column` error and assumes it is usable.

**`docs/adr/0011-require-a17pro-and-apple-intelligence.md`** — the floor raise
to major ≥ 16 and the Apple Intelligence requirement, replacing the draft's
"keep the floor, gate the feature" decision. Records why: CREG leans into
Foundation Models as a first-class dependency; the no-FM population collapses
to a single transient/settings state with one honest UI.

**`CONTEXT.md`** — three new sibling terms under *Query pipeline* (`:97`),
leaving `Follow-up Suggestion` (`:164`) and `Ambiguity Gate` (`:122`)
untouched, in the house `**Term**:` / definition / `_Avoid_:` style:

- **Turn Failure** — a completed turn that produced no answer, carrying
  exactly one typed reason. _Avoid_: error, crash
- **Scope Verdict** — the enumerated judgement of whether the portfolio covers
  a Standalone Question's subject, produced only with the schema in hand.
  _Avoid_: unanswerable, no data
- **Recovery Suggestion** — a pre-executed next question offered beneath a
  Turn Failure. _Avoid_: follow-up suggestion, starter query

Boundary note: a **Scope Miss** (schema does not cover the subject) is not an
empty result (schema covers it, no rows match) — the latter is existing
**Grounding Check** territory (`CONTEXT.md:125`), already handled by
`HeuristicFinding.literalNotFound` (`GroundingModels.swift:17-19`).

**`docs/eval.md`** — the Answerability section (corpus, scorer, provisional
threshold, recalibration procedure) and a note on the `turnFinished`
event-line shape change.

**Docs honesty fix (small, in scope):** every doc describes the Ambiguity Gate
as an active stage while production wires `gateSensitivity: 0`
(`LiveDependencies.swift:365`; bypass branch `QueryPipeline+Live.swift:302-323`;
`telemetry.gateMode == .bypassed`). Add a one-line correction to `README.md`,
`docs/walkthrough.md`, and the PRD's gate section noting the dial currently
ships at 0. Re-enabling the gate stays out of scope.

---

## Verification

**Phase 0** — `DeviceCapabilityTests` truth table over the new rule (15 Pro
admitted, 15/15 Plus rejected, 16-family and simulator/iPad identifiers as
today); `FMAvailability` mapping tests over each `UnavailableReason` including
`@unknown`; submission-gate tests for each readiness combination.

**Phase 1** — `swift test` in CREGKit: the derive oracle truth table; every
producer site asserted to yield its intended reason **through the wrapped
pipeline** (`reportingTerminalFailures` must be shown to pass reasons through,
not rewrite them — this is the test the draft could not have written);
`ChatMessage` round-trips the new `Body` case; a persisted legacy
`.failure(String)` still decodes and renders; telemetry v7 tolerant decode of
v6 payloads; cancelled turns assert the `cancelled` reason, never `timedOut`.

**Phase 2** — `QueryPipelineTests` with a stubbed SQLGen forced to fail:
suggestions produced, pre-executed, carrying `QueryOrigin.recoverySuggestion`
and the recovery policy version; the starter-seeded fallback fires on FM
proposal failure; preparation never starts for ineligible reasons
(`databaseUnavailable` et al.) nor while a turn is active or queued;
verdict-eligible reasons wait for C before D starts.

**Phase 3** — scorer unit tests over a hand-labelled fixture; confusion matrix
byte-reproducible; the 23-item recovered bucket regenerates deterministically
from the stored runs.

**Phase 4** — stub-FM tests for gating (fires only on the three eligible
reasons; never on timeout or cancellation), in-place enrichment ordering, and
the `missingSubject` guards (length cap, schema-coverage drop). Then on
device: run the corpus on an A17 Pro-class iPhone via the debug capture,
score it, and hold shipping until the false-abstention rate is within the
provisional gate (≤ 1 of 23, `T2-21` correct), then follow the documented
recalibration procedure.

**Visual** — SwiftUI `#Preview` states in `PreviewFixtures.swift` (which has
no failure-body fixture today) for each `TurnFailureReason`, plus
reason-with-verdict, reason-with-suggestions, the retry affordance, and the
enable-Apple-Intelligence callout. Per the project's simulator constraint (MLX
Metal aborts on launch), previews with inert fixtures are the harness.

## Out of scope

- Re-enabling the Ambiguity Gate (`gateSensitivity: 0` stays) — the docs
  correction above is the only gate work
- Any deterministic scope inference from SQL errors — see ADR 0010
- Localization — the app is uniformly hardcoded English today
- Typing `timeoutStage` as an enum in telemetry (kept `String` for schema
  continuity; the unified whitelist helper is the Phase 1 fix)
