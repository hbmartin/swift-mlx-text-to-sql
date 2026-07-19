# CREG — Product Requirements Document

## 1. Summary

CREG is a fully offline iOS app that lets a non-technical commercial-real-estate (CRE) professional explore a portfolio database by asking questions in plain language. A chat interface takes a natural-language question, an on-device model converts it to SQL, the query runs against a bundled SQLite database, and the resulting table is displayed alongside a plain-English summary. Everything — model, data, and inference — lives on the device.

The best fully-local text-to-SQL systems land in the ~65–72% execution-accuracy range on hard cross-domain benchmarks. CREG's advantage is that it targets a **single fixed schema**, which — combined with in-domain fine-tuning and grammar-constrained decoding — should push accuracy well above those cross-domain numbers. The correction framework is therefore a first-class feature, not a fallback.

------

## 2. Goals

- Let a non-technical user answer real portfolio questions through conversation, without ever seeing or writing SQL.
- Run entirely on-device and offline, including at install time (model bundled in the binary).
- Achieve high execution accuracy on a curated CRE gold set (target threshold TBD via the eval harness).
- Make model/runtime/GCD choices **empirically**, via a reusable evaluation harness, rather than by pre-selection. Evaluation runs on the developer's Mac.

### Success metrics

- **Query accuracy** — execution accuracy (EX) on the held-out CRE gold set.
- **Task completion** — the user reaches a correct answer within a short number of turns (including corrections).

------

## 3. Non-Goals

- No cloud sync; no multi-user; no accounts.
- No write/mutation queries — read-only only.
- No charts in v1 (deferred to v2).
- Not shipping to the App Store in this phase.

------

## 4. Target User & Primary Use Case

**User:** a non-technical CRE professional (asset manager, analyst, broker, executive) who understands their portfolio conceptually but cannot write SQL and should never be shown SQL.

**Job to be done:** *exploratory analysis* — poking at the portfolio to understand it ("which properties have the highest vacancy?", "what's my rent roll by asset class?", "which leases expire in the next 12 months?"), with natural follow-ups that refine the previous question.

------

## 5. Scope: v1 vs v2

| Area                  | v1 prototype                                                 | v2 prototype                                                 |
| --------------------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| Runtime               | MLX (bundled, 4-bit)                                         | Evaluate iOS 27 **Core AI** (Core ML successor)              |
| Results               | Table only                                                   | Tables **+ charts/visualizations**                           |
| 4th correction layer  | Heuristics + narration-confirmation + self-consistency + uncertainty-gating | **+ Explicit round-trip semantic check via Apple FM**        |
| Everything else       | Full pipeline, correction, eval + fine-tune harness, developer mode | Carried forward                                              |
| Follow-up suggestions | None                                                         | Apple FM offers 3 likely followup questions, pre-verify answerability. |

------

## 6. Data & Schema

- **One bundled SQLite database** (optional, consider access via GRDB), shipped inside the app binary. Single database; no import, no switching.
- **Scale:** ~5 tables, ~10k rows total. Small enough to enumerate distinct values for low-cardinality columns (used by grammar value-grounding and correction heuristics).
- **Access:** read-only. The connection is opened read-only, and a SQLite authorizer callback denies any non-SELECT statement as a second line of defense.
- **Schema:** final table/column definitions TBD. The schema is baked into the SQL grammar and the fine-tuning data, so it must be frozen before those steps.

> **Action:** finalize and freeze the 5-table CRE schema (DDL) — it is an input to grammar construction, synthetic-data generation, and fine-tuning.

------

## 7. System Architecture — the runtime pipeline

Each user turn flows through a strictly **sequential** pipeline. Two models are involved — the bundled fine-tuned SQL specialist and Apple's on-device Foundation Model (FM) — and **they never run at the same time** (see §7.1).

1. **User message** arrives in the chat.
2. **FM — follow-up rewrite (decontextualization):** the FM rewrites a context-dependent follow-up ("now just last year") into a standalone question ("total leased area by property for 2024") using the prior turn. This means the SQL specialist never has to track conversation state — it always sees a clean, self-contained question. (This is the well-established "question rewriting" technique for turning multi-turn into single-turn.) **Consider making this a developer toggle for eval rewrite vs complete history approaches.**
3. **FM — ambiguity gate:** the FM decides whether the standalone question is answerable as-is or genuinely ambiguous. Clear → pass through (best-guess). Ambiguous → the FM asks one friendly clarifying question and the turn pauses for the user. The gate's sensitivity is a **single tunable dial** between "always guess" and "always clarify."
4. **SQL specialist — constrained generation:** the fine-tuned model generates SQL under **grammar-constrained decoding** (§9): SELECT-only, schema-aware, so invalid tables/columns and write statements are unrepresentable.
5. **Pre-execution validation:** mostly guaranteed by the grammar; residual deterministic checks only.
6. **Execute** against the read-only connection.
7. **Correction** (§10): on error, self-repair (≤2 retries); optional self-consistency voting; result-shape and value-grounding heuristics.
8. **FM — result narration:** the FM produces a one-line plain-English summary of what was looked at and found ("Here's leased area by property for 2024 — Tower One leads").
9. **Render:** result table + narration + the "thinking"-style step trace (§11).
10. **Follow-up suggestions:** FM suggests likely follow-up questions offered as tappable bubbles. Evaluate ability to answer against table schema. Out of scope for v1, plan for v2.

### 7.1 Inference serializer (hard requirement)

A single **serializer** — implemented as a Swift `actor` (or a serial dispatch queue) — owns **every** model call, FM and bundled alike. It guarantees no two inferences ever overlap. Because the pipeline is sequential by nature, this mostly means the serializer never dispatches an FM call while an MLX generation is in flight, and vice versa.

- **Memory consequence:** since the two paths never execute concurrently, active-inference peak memory is `max(FM, bundled)`, not the sum — comfortably within budget on an 8 GB iPhone 15 Pro with a ≤4B bundled model.
- **Residency:** keep the bundled MLX model resident between turns (reloading is slow); sequence FM calls around it. Apple's FM is OS-managed, so its lifecycle is partly outside app control — frame the guarantee precisely as *"our two inference paths never overlap,"* which is what protects the memory/thermal budget.

------

## 8. Model & Runtime Decisions

### 8.1 Runtime: MLX for v1 (not CoreML)

**Decision: v1 ships on MLX. Do not convert the SQL model to Core ML.**

The deciding factor is CREG's own grammar-constrained-decoding requirement. Grammar-constrained decoding needs per-token access to the logits to apply a mask at each step; MLX exposes this via a logit-processor hook, and **Core ML does not support structured-output / grammar-constrained decoding at all.** Converting to Core ML would break the single most valuable part of the architecture.

Secondary reasons: MLX is the default, simplest-from-Swift path with the candidate models already available, and it is far better for a compare-many-configs eval phase (swapping a model, adapter, or grammar is trivial; Core ML would gate every candidate behind a fragile `coremltools` conversion). Core ML's genuine advantage — much lower RAM and better power via the Neural Engine (a 2B model in ~241 MB on the ANE vs ~1.3 GB for MLX) — matters for a *shipping* app on battery, which this prototype is not.

**v2:** evaluate **iOS 27 "Core AI"** (Apple's announced Core ML successor) as a runtime, once the device target moves to iOS 27. Document the known cost that grammar constraints would need to be re-solved outside the runtime on any ANE/Core-AI path.

MLX runs on the GPU (Metal), not the ANE — acceptable for a prototype with no latency/battery budget.

### 8.2 Bundled SQL specialist

- **≤4B parameters, 4-bit quantized, bundled in the binary.**
- **No pre-selection.** The winning model is chosen by the eval harness (§12). Candidates include general code/SQL bases and existing text-to-SQL fine-tunes (Appendix A).
- **Fine-tuned in-domain** on synthetic CRE data (§13) — the single biggest accuracy lever, since one fixed schema is far easier than cross-domain.

### 8.3 Apple Foundation Models — the augmentation layer

The FM handles conversational glue so the SQL specialist can stay laser-focused on constrained SQL generation:

- Follow-up rewriting / decontextualization (step 2).
- Ambiguity gate + clarifying questions (step 3).
- Result narration (step 8).

The FM is bundled with the OS (no app-size cost) and never runs concurrently with the SQL model (§7.1).

------

## 9. Grammar-Constrained Decoding (GCD)

At each decoding step, a grammar engine masks out any next token that would break the grammar (disallowed tokens → −∞ logit before sampling), so output is **valid by construction** — no parse errors, no retries for syntax.

CREG exploits its fixed schema by baking three constraints into the grammar:

- **Valid SQLite syntax only.**
- **Only the real tables/columns** as identifier terminals — the model cannot hallucinate a column. For low-cardinality columns, distinct values can be enumerated into the grammar (value-grounding), feasible at ~10k rows.
- **SELECT-only** — write statements are omitted from the grammar and thus unrepresentable.

This gives read-only enforcement + schema validity **for free at decode time**, absorbing most of the pre-execution validation layer.

**Caveat:** GCD guarantees *structure, not meaning.* Valid, schema-correct SQL can still answer the wrong question; free-text literal values can't be fully constrained. The 4th correction layer (§10) handles semantics. Also measure GCD **on vs off** in the harness — over-tight constraints can occasionally dent reasoning ("the hidden cost of structure").

### GCD engines to evaluate (harness axis)

- **MLXGuidedGeneration** — native to the MLX ecosystem; JSON Schema or EBNF. *Verify the minimum SDK works on the iOS 26 target* before committing (the FoundationModels bridge portion requires the 27 SDK).
- **XGrammar** — general context-free grammar, Swift API, runs on Apple Silicon with near-zero overhead. Most production-shaped for a full SQLite grammar.
- **mlx-swift-structured** — community package exposing a `GrammarMaskedLogitProcessor` for the token loop.

*(PICARD explicitly out of scope.)*

------

## 10. Correction Framework

### Structural guarantees (free, no model, no correction turn)

Read-only enforcement and schema/syntax validity are handled by GCD + read-only connection + SQLite authorizer.

### The three free layers (v1)

1. **Pre-execution validation** — mostly covered by GCD; residual deterministic checks only.
2. **Execution-error self-repair** — on a SQLite runtime error, re-prompt the *same* model with the error string; retry ≤2, then fall back gracefully.
3. **Natural-language correction** — identical operation to multi-turn refinement: prior context + new user turn → same model. No second model.

### The fourth (semantic) layer — v1 includes A + B + C + D

Handles valid SQL that answers the wrong question.

- **A. Result-shape + value-grounding heuristics (deterministic).** Detect 0-rows-when-expected, single-scalar-when-a-list-was-asked, empty aggregates; fuzzy-match unmatched literals against actual column values ("nothing matched 'Tower A', did you mean 'Tower One'?"). Catches the #1 silent-failure mode. *Always on.*
- **B. Narration-as-confirmation.** The FM's plain-English result summary doubles as a back-translation of intent, letting the user (who knows what they meant) be the semantic judge. *Always on.*
- **C. Self-consistency voting.** Sample 3–5 candidate SQLs, execute all, cluster by result-set equivalence; agreement → confidence, split → "I read this a couple of ways" or take the majority. The strongest local accuracy lever; costs N× generation (affordable — no latency budget).
- **D. Uncertainty-gated compute.** Use token entropy at decision points (free via the logit processor) to trigger C's N× sampling *only* when the model is unsure. Adaptive: cheap when confident.

### Deferred to v2

- **E. Explicit round-trip semantic check via FM** — FM compares its narration against the original question; large divergence flags a likely wrong answer. Extra FM call with some false positives; mostly subsumed by B in v1.

### Product-philosophy note

Because this is **read-only exploration, the cost of a wrong answer is one more turn.** Bias toward "show a confident answer, make correction one tap" over heavy up-front verification. Let the failure taxonomy (§12), not intuition, decide how much of the 4th layer to build out.

------

## 11. Chat UX

- **Chat interface:** message bubbles; result tables rendered inline; multi-turn.
- **Result display:** table only (v1). Paging: whichever is simplest — auto-`LIMIT` with "show more," or a virtualized scroll. Charts in v2.
- **History:** persisted conversation history.
- **"Thinking"-style step trace:** a collapsible, per-message disclosure showing the pipeline in **plain English, never SQL** — e.g., "Understanding your question," "Rephrasing your follow-up," "Looking at leases and properties," "Running the numbers," "Double-checking the result," "Fixing a hiccup and retrying," "Summarizing what I found." Collapsed by default.
- **Empty/error/clarification states:** graceful; a clarifying question from the ambiguity gate appears as a normal assistant turn.

### Developer mode (visible in app settings)

A settings toggle (not hidden) that surfaces per-message internals for accuracy work:

- The FM-rewritten standalone question and the ambiguity-gate decision.
- The generated SQL, plus all candidate SQLs and their self-consistency votes.
- Validation results, execution metadata (row count, ms), execution errors and each self-repair attempt.
- Per-stage latency and tokens/sec, and which model + quantization + GCD engine ran each stage.

### Structured logs + export

- The **same structured event stream** that drives the thinking trace is written to disk (JSONL) for the eval harness — one event stream, two consumers. Build it as structured events from the start, not display strings.
- **"Mail logs to developer"** — an export action (e.g., `MFMailComposeViewController`, or the share sheet) that attaches the JSONL session logs, so real-usage traces can be gathered for offline analysis.

------

## 12. Evaluation Harness

One harness does model selection, GCD-engine comparison, and fine-tune feedback — they are all axes in the same sweep. Treat them as independently selectable factorial / matrix choice. Evals must run on developer's Mac MLX. Harness may be with Swict (CLI) or Python. Use Claude Opus (claude code CLI) as a judge model with human correction for ambiguous cases.

### Gold set

- **150–300 (question → gold SQL → gold result) triples** against the CRE schema, hand-verified. Kept strictly separate from any generated training data.
- Tiered by difficulty: single-table filter/aggregate → multi-table joins → windowed/nested.
- Deliberately includes messy cases: fuzzy entity references, ambiguous phrasing, and multi-turn follow-ups.

### Metrics

- **Primary — Execution Accuracy (EX):** compare the *result set* of predicted vs gold SQL (order-insensitive set equality). Note EX's known blind spot: it can deem semantically different queries equivalent when results coincide — spot-check with exact-set-match where needed.
- **Secondary:** valid-SQL rate (≈100% with GCD), latency (TTFT + total, tok/s), peak memory.
- **Ambiguity-gate quality:** did it clarify when it should and pass through when it should?

### Failure taxonomy

Bucket every miss — wrong table/join, wrong aggregation, wrong filter, wrong literal value, empty-when-expected, timeout. This taxonomy drives fine-tuning data priorities and tells you which correction layer actually earns its keep.

### Ablation axes

`model × quantization × {fine-tuned | base} × GCD-engine × schema-serialization (raw DDL | compact | DDL+sample-values) × self-consistency-N × value-grounding-on/off`. Emit a leaderboard. Run **GCD on and off** per model to catch any reasoning regression.

### Execution

Run on-device and on a Mac harness; note device-vs-Mac differences. Reuse the structured event logs from §11.

------

## 13. Synthetic Data & Fine-Tuning Harness

### Data sources

- **CRE schema** (frozen DDL) + real value distributions sampled from the bundled DB (so literals are realistic).
- **Existing text-to-SQL datasets**, re-targeted to the CRE schema for patterns and coverage:
  - Single-turn: Spider, BIRD, WikiSQL, KaggleDBQA.
  - Multi-turn / conversational (for follow-ups + ambiguity/clarification behavior): SParC, CoSQL, PRACTIQ.
  - Synthetic at scale: `gretelai/synthetic_text_to_sql`, SYNSQL-2.5M, `b-mc2/sql-create-context`.

### Generation method

1. **Schema-grounded templating:** generate questions and gold SQL directly over the CRE schema, seeded with sampled real values, across difficulty tiers.
2. **Pattern transfer:** take NL/SQL structures from the existing datasets and re-target them onto the CRE schema (join shapes, aggregations, window functions, nested queries).
3. **Conversational augmentation:** derive multi-turn sequences and their decontextualized single-turn equivalents (mirrors the runtime FM rewrite step), drawing on SParC/CoSQL patterns; include clarification and unanswerable cases for the ambiguity gate.
4. **Paraphrase:** expand question phrasings with a larger model at dev-time (offline tooling, not a runtime dependency).
5. **Claude-as-judge (quality gate):** a large Claude model scores each (question, SQL) pair before it enters training. This follows the precedent set by the Gretel synthetic dataset, which used an LLM-as-judge with an explicit rubric. Proposed rubric criteria:
   - SQL executes without error against the CRE schema.
   - Question ↔ SQL semantic alignment (does the SQL actually answer the question?).
   - Result sensibility (non-degenerate, plausible).
   - SQLite-dialect correctness.
   - Readability / canonical form. Pairs below threshold are dropped or regenerated. Log judge scores for dataset auditing.

### Fine-tuning loop

`generate → dedupe → judge/filter → split (test = held-out gold) → LoRA/QLoRA (MLX-LM, in-ecosystem, no conversion hop) → fuse adapter → 4-bit quantize → package for MLX → run eval harness → read failure taxonomy → add targeted data → repeat.` Pin seeds and version the training data for reproducibility.

------

## 14. Privacy & Positioning

Fully offline; the bundled model means nothing is downloaded and nothing is transmitted. **"Your data never leaves the device"** is an explicit positioning pillar, backed by architecture: no network entitlement is required for core function.

------

## 15. Open Questions / TBD

- Finalize and freeze the 5-table CRE schema (blocks grammar + fine-tuning).
- Gold-set size and the EX threshold that defines "good enough" for the prototype.
- Confirm MLXGuidedGeneration's EBNF path works on the iOS 26 SDK; otherwise default to XGrammar.
- Keep the MLX model resident between turns vs unload under memory pressure — measure on device.
- Self-consistency N and the uncertainty-gate threshold (tune via harness).
- Ambiguity-gate default sensitivity (lightly biased toward clarifying only on genuine ambiguity).

------

## Appendix A — Candidate models (≤4B)

**General code/SQL bases (fine-tune targets):** Qwen2.5-Coder-1.5B, Qwen2.5-Coder-3B, Qwen3-1.7B, Qwen3-4B, Gemma 3 (1B / 4B), Llama-3.2-3B. DeepSeek-Coder (1.3B). 

**Existing text-to-SQL fine-tunes (evaluate directly and/or as fine-tune starting points):** XiYanSQL-QwenCoder-3B (multi-dialect incl. SQLite; explicitly recommended as a fine-tune base), `Ellbendls/Qwen-3-4b-Text_to_SQL`, `Ellbendls/Qwen-2.5-3b-Text_to_SQL`, `Piyush026/Qwen2.5-Coder-3B-sql-finetuned`, plus small SQL specialists in the SLM-SQL / Prem-1B-SQL family as reference points. Prefer existing SQL fune tunes e.g. https://huggingface.co/models?num_parameters=min:0,max:3B&sort=likes&search=text+sql . Also consider SLM-SQL (https://github.com/CycloneBoy/slm_sql). PremSQL (https://github.com/premAI-io/premsql). T5 fine tunes e.g. https://github.com/griddbnet/sql_llm_model and https://huggingface.co/cssupport/t5-small-awesome-text-to-sql

Document possible implementation of this or similiar techniques for v2:
https://layer6.ai/can-smaller-ai-models-solve-text-to-sql/

*The harness picks the winner; this list only seeds it.*

## Appendix B — Datasets

Spider, BIRD, WikiSQL, KaggleDBQA, Spider 2.0 (single-turn); SParC, CoSQL, PRACTIQ (multi-turn / ambiguous — for follow-ups and the ambiguity gate); `gretelai/synthetic_text_to_sql`, SYNSQL-2.5M, `b-mc2/sql-create-context` (synthetic / training scale).

## Appendix C — Key tools & frameworks

MLX / MLX-Swift + MLX-LM (inference + LoRA), one of MLXGuidedGeneration / XGrammar / mlx-swift-structured (GCD), GRDB (SQLite access), Apple Foundation Models (augmentation), `coremltools` / Core AI (v2 runtime evaluation only).

## Appendix D — Chat UI code references.

- https://github.com/EnesKaraosman/SwiftyChat
- https://github.com/sendbird/sendbird-swiftui-ios
- https://github.com/GetStream/stream-chat-swift/
- https://github.com/exyte/chat

## Appendix E - guides for finetuning MLX models

- https://tds.s-anand.net/2026-02/docs/week-2/11-local-llms-4-mlx-labs/
- https://github.com/MoAshour93/MLX_Finetuning
- https://heidloff.net/article/apple-mlx-fine-tuning/

Note: when using Python, you must use `uv` not `pip` or bare `python`