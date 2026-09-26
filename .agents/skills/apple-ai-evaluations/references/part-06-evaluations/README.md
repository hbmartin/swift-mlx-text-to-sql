# Part 6 — Evaluations

**Version floor:** the `Evaluations` framework is **new in the 27 cycle and does not back-deploy**. Every
symbol is **iOS 27.0 · iPadOS 27.0 · Mac Catalyst 27.0 · macOS 27.0 · visionOS 27.0 · watchOS 27.0**, the
whole index is tagged **Beta**, and **there is no tvOS**. You need **Xcode 27** — the `.evaluates` trait
and the Evaluations report are Xcode features, not just library code — and the framework is **Swift-only**,
confirmed by an Apple Frameworks Engineer on forum thread 833729. One sub-floor is easy to miss:
`Transcript.structuredTranscript`—an Evaluations extension on `FoundationModels.Transcript`, so its use
site must `import Evaluations`—makes tool-trajectory evaluation possible, supports Mac Catalyst 27.0,
and remains unavailable on tvOS. The *feature* can be much older; `SystemLanguageModel` is 26.0. You can
evaluate a 26.0-era feature, but you can only run the evaluation on 27.

> ✅ **VERIFIED — where the framework physically lives** (Xcode 27 beta, checked 2026-07-29).
> `Evaluations.framework` is **not in the OS SDKs**: the macOS 27.0 and iOS 27.0 beta SDKs contain no
> public `Evaluations` module (`System/Library/Frameworks`, `System/Library/SubFrameworks` and
> `usr/lib/swift` all searched). It ships **inside Xcode**, exactly like `XCTest.framework` and Swift
> Testing's `Testing.framework`, at
> `…/Xcode-beta.app/Contents/Developer/Platforms/<Platform>.platform/Developer/Library/Frameworks/Evaluations.framework`
> — present for macOS, iPhoneOS/Simulator, watchOS/Simulator and visionOS(XROS)/Simulator, and
> **absent for AppleTVOS**, corroborating "no tvOS" from the shipped binary rather than only the doc
> index. The macOS module's `.swiftinterface` marks 102 declarations `@available(anyAppleOS 27.0, *)`
> and 99 `@available(tvOS, unavailable)`, imports `Testing`, `FoundationModels` and `TabularData`,
> and is Swift-only. Consequence for readers: `import Evaluations` resolves in **test targets**
> (Xcode's test-framework search path), like `import Testing`; it will not resolve when compiling
> directly against the bare OS SDK. A spot-check of ~25 API spellings used across this part
> (`ModelJudgeEvaluator`, `ScoreDimension`, `TrajectoryExpectation`, `ArgumentMatcher`,
> `missingTranscript(evaluatorType:)`, `saveJSON`, …) found every one in that interface — which is
> now the strongest on-disk evidence source for signatures in this part. A full end-to-end pass of
> the interface followed on 2026-07-29 and closed several of the part's open 🔴 GAPs:
> `ScoringMode = .discrete | .continuous` (default `.discrete`), `ModelJudgeError`'s five cases,
> `SamplingStrategy = .random(retries: Int = 5) | .slidingWindow`, `TrajectoryExpectation`'s public
> `ordered`/`unordered`/`disallowed` accessors and `allowsAdditionalToolCalls = true` default, and
> `ModelJudgePrompt.reference`'s second parameter (`Input.ExpectedValue`). Each guide's gap list
> records what moved; signature claims across the part now cite the interface as ✅ **SDK-verified**
> with line numbers.

**Who this is for:** anyone shipping an AI feature — and that is not a figure of speech. Part 6 is the one
cross-cutting part of this series, because there is no model version pinning API and an evaluation suite
is the only regression detector you get for a dependency you cannot version-pin.

---

## Why this part exists

The obvious reason is the one Apple leads with: the same input can produce different outputs, so unit
tests are *insufficient* (WWDC26 session 298). That is true, and it is the smaller half of the argument.

The larger half is that **you cannot pin the thing you are testing.** An Apple Frameworks Engineer
answering forum thread 833642 confirmed there is no version-pinning API and no version-retrieval API, and
named the Evaluations framework as the mitigation. Meanwhile `SystemLanguageModel` has shipped **three
model versions in about a year** (26.0–26.3, 26.4, 27.0), the 26.4 refresh explicitly changed
instruction-following and tool-calling, and guardrails update out of band with OS releases entirely. Your
feature's behaviour is pinned by nothing you control — not your binary, not your deployment target, not
the user's OS version — and nothing notifies you when it moves.

So this part is not "how to test AI." It is: **move your assertion up one level of abstraction**, from
*this input produces this output* to *across this dataset, this measurable property holds often enough*,
and keep a diffable record of every run so that when a point release lands you read the diff instead of
guessing.

There is a second insight that runs through all three guides and organises every warning in them: **a
broken evaluation may produce a misleading number or fail before producing metrics**, and both shapes
need explicit checks. A `JSONLoader` that drops 63 of 100 rows reports an aggregate over 37. A judge with
no prompt can return confident, stable, meaningless scores. A `ToolCallEvaluator` handed a `nil`
transcript instead throws `EvaluationError.missingTranscript(evaluatorType:)`; it does not score an
empty trajectory.[^missing-transcript] Guide 6.1's denominator assertion protects the silent cases;
the tool-trajectory path must also treat this thrown error as a broken evaluation setup.

---

## Read this first: the triage table

| If your situation is… | Read | Why |
|---|---|---|
| "I have never written an `Evaluation`" | [6.1](references/01-foundations-and-hill-climbing.md) | The five steps, mapped to exact API, with a complete copyable file |
| "I have eval code from a blog post or a transcript reconstruction" | [6.1 §19](references/01-foundations-and-hill-climbing.md#19-quick-reference) | The corrections table. Four out of four spellings in circulation are wrong and do not compile |
| "My tests are green and the output is visibly bad" | [6.1 §10](references/01-foundations-and-hill-climbing.md#10-the-quantitative--qualitative-rule-of-thumb) | The defect is in your measurements. Four heuristics passed on tags including "overrated" and a wrong genre |
| "My pass rate is 100% and I am suspicious" | [6.1 §7](references/01-foundations-and-hill-climbing.md#7-step-4--aggregatemetricsusing) | A range metric reads 100% over a collapsed distribution. Pair it with a scored metric and a σ |
| "I work in Python" | [6.1](references/01-foundations-and-hill-climbing.md), then [Part 5](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md) | Evaluations is Swift-only. Apple's guidance is the Python FM SDK plus your own scoring code |
| "I need to measure something I can only describe in words" | [6.2](references/02-model-judges-and-alignment.md) | `ModelJudgeEvaluator`, `ScoreDimension`, `ScoringScale` |
| "I disagree with a score the judge gave" | [6.2 §7](references/02-model-judges-and-alignment.md#7-the-key-technique-split-the-question) | **Split the question.** The judge is usually right by the rubric you wrote |
| "The judge scores everything 3" | [6.2 §5.1](references/02-model-judges-and-alignment.md#51-why-an-even-number-of-levels) | Odd-numbered scale, or a question that is asking two things |
| "Can I trust the judge at all?" | [6.2 §16](references/02-model-judges-and-alignment.md#16-the-meta-evaluation-end-to-end) | The κ meta-evaluation: freeze the output, replay it, score it against your own ratings |
| "Where is Cohen's kappa in the framework?" | [6.2 §15](references/02-model-judges-and-alignment.md#15-implementing-kappa--the-framework-does-not-ship-it) | **It is not there.** 72 lines of ordinary Swift in Apple's sample. You are writing it |
| "Thirteen hand-written samples feel like enough" | [6.3 §1](references/03-synthetic-data-and-tool-trajectories.md#1-the-thirteen-sample-lie) | They are enough to mislead you, and Apple demonstrates exactly how on camera |
| "I asked for 100 samples and got 87" | [6.3 §3](references/03-synthetic-data-and-tool-trajectories.md#3-️-targetcount-counts-the-samples-you-already-have) | `targetCount` is the size of the *final* dataset, seeds included |
| "The back half of my generated dataset repeats itself" | [6.3 §5](references/03-synthetic-data-and-tool-trajectories.md#5-️-sessionprovider-is-a-factory-and-it-may-be-called-twice) | `sessionProvider` was called a second time and the new session remembers nothing |
| "The answer looks right but I don't think it called my tool" | [6.3 §12–§17](references/03-synthetic-data-and-tool-trajectories.md#12-why-the-final-answer-is-not-enough) | `TrajectoryExpectation`, `ToolCallEvaluator`, and the nine argument matchers |
| "My tool metrics are 0% everywhere, or blank" | [6.3 §17.2](references/03-synthetic-data-and-tool-trajectories.md#172-the-line-everyone-forgets) | You built `ModelSubject(value:)` without `transcript:`. It compiles |
| "Does an eval run spend my users' PCC quota?" | [6.3 §6.2](references/03-synthetic-data-and-tool-trajectories.md#62-pcc-quota-is-per-user-and-generation-is-not-free) | 🔴 Nobody knows. Apple has not answered it. Treat generation as manual and attended |

---

## The guides in this part

### [6.1 — Building blocks, Swift Testing integration, and evaluation-driven development](references/01-foundations-and-hill-climbing.md)

The foundation everything else hangs on: the `Evaluation` protocol's five steps (`subject(from:)` →
`dataset` → `evaluators` + `Metric` → `aggregateMetrics(using:)` → a Swift Testing `@Test`), each with the
corrected spelling verified against Apple's Book Tracker sample rather than reconstructed from spoken
narration. It covers the Xcode 27 report and its **Compare** button, the attachment every run writes out
(the least-known feature in the framework, and the thing that makes judge calibration possible at all),
and **hill climbing** run as a controlled experiment — control versus experimental, one variable at a
time, and the backport step almost everyone skips. It closes on §18, the argument that this framework is
structural rather than a testing convenience.

> ⚠️ **SILENT FAILURE (seven of them, and six are the same shape).** `JSONLoader` **skips malformed rows
> and only tells `OSLog`** — a missing file throws, but a file whose rows no longer decode loads a
> fraction of itself and reports a clean aggregate over whatever survived. A `(3...8).contains(n)` metric
> reads 100% whether the model produces a healthy spread or the identical value every time; adding
> `@Guide(.count(3...8))` fixed the range and silently collapsed the output to a constant 8. An
> evaluation that constructs its session differently from the app — a dropped `guardrails:` argument is
> enough — reports a number about a model you do not ship.
>
> 🔴 **GAP — several, and each has a stated safe default.** Whether `Metric` identity is by **name or by
> instance** (Apple's doc example and Apple's sample code imply opposite answers; the interface shows a
> hand-written `==` but not its semantics); what `aggregateValue(.mean(of:))` returns when every sample
> was `.ignore()`d; and what happens to a run when `subject(from:)` throws for a subset of samples —
> `SubjectInferenceError` and `EvaluatorError`'s cases are now SDK-verified, and a deprecation message
> in the interface says missing metrics are *"materialized as ignored columns and logged"*, but the
> thrown-subject path itself is still unconfirmed. All three are neutralised by the same one-line habit:
> assert the scored row count before you assert anything computed from it.

### [6.2 — Model judges, score dimensions, drift, and Cohen's kappa](references/02-model-judges-and-alignment.md)

The half of evaluation that cannot be written as an `if`, and then the harder half: proving the thing
doing the judging deserves to be trusted. A judge is just another `Evaluator` producing the same `Metric`, so it
drops into an existing `evaluators` block with no restructuring. The single highest-yield technique in the
part is here — **when you disagree with a score, split the question into two dimensions** — along with why
an even number of scale levels is structural, why *accuracy* is the wrong alignment measure on a dataset
that is always skewed toward good output, and the full meta-evaluation: extract the previous run's
attachment, hand-score it, freeze `subject(from:)` so it performs no inference, and aggregate Cohen's κ
against your own ratings.

> ⚠️ **CORRECTION, and the most consequential in the part.** Session 335 discusses Cohen's kappa at
> length as a first-class part of the workflow and never says otherwise, so readers reasonably conclude it
> ships. **It does not.** `MetricsAggregator` has no agreement statistic of any kind; Apple's sample
> hand-writes 72 lines in `Statistics.swift` and wires it in through `custom(of:label:_:)`.
>
> ⚠️ **SILENT FAILURE — the κ apparatus is a machine for producing plausible numbers.** The join between
> the judge's scores and the expert's is **positional and nothing validates it**; a misaligned join lands
> around 0.0–0.2, which reads exactly like "my judge is badly calibrated", and you will spend a day
> rewriting a prompt that was fine. `?? 0.0` turns a row you forgot to score into a rating of zero, which
> is off-scale and depresses κ by more than its share. Omit `ModelJudgePrompt` entirely and the judge
> returns confident, *stable* numbers from a model that does not know what your app is. And the one that
> points the wrong way: a **contaminated calibration reports a higher κ**, so this failure makes your
> judge look better the more you break it.
>
> 🔴 **GAP — narrowed by the 2026-07-29 interface pass.** `ScoringMode` is now pinned to
> `.discrete | .continuous` with `.discrete` the default (still omit it, as Apple does at all three of
> its judge call sites — the *semantics* of `.continuous` remain undocumented); `ModelJudgeError`'s five
> cases are SDK-verified, but the framework's behaviour when a judge inference throws mid-run is not;
> and `ModelJudgePrompt.reference`'s second closure parameter is settled — it is the model's output
> value, typed `Input.ExpectedValue`. Also worth knowing before you search for help: the Evaluations
> developer forum contains **exactly three threads**, one unanswered. There is essentially no community
> knowledge yet.
> **What would resolve the rest:** an Apple doc pass on `ScoringMode`, and a probe that forces a
> judge's session to throw mid-run (the `eval.subject-throws` probe in `probes/` is the pattern —
> it answered the same question for subject inference). **Safe default:** omit `scoringMode:` as
> Apple does at all three of its call sites, and treat a run whose judge threw as invalid rather
> than trusting whatever aggregate it still reports.

### [6.3 — `SampleGenerator`, synthetic datasets, and evaluating tool trajectories](references/03-synthetic-data-and-tool-trajectories.md)

Two subjects that share a chapter because both are about honesty. First, getting *enough* data: the two
doors into synthetic generation, what `sessionProvider`, `samplingStrategy` and `validator` really do, why
generation belongs in a command-line target whose output you commit rather than in a test, and the finding
that justifies the whole exercise — **expanding Book Tracker's dataset from 13 to 100 samples made the
quality scores drop**, because the feature was never as good as the small dataset said. Second, evaluating
the *path*: a model can hand you a reasonable-sounding answer having never called the tool that would make
it true, and `TrajectoryExpectation` / `ToolCallEvaluator` / the nine `ArgumentMatcher` cases are how you
catch that.

> ⚠️ **SILENT FAILURE — four, all of which under-deliver rather than error.** `targetCount` counts the
> samples you already have, so 13 seeds plus `targetCount: 100` generates **87**; pass a target below your
> current count and the run ends immediately with no error and no log line. `sessionProvider` is a
> **factory that may be called again mid-run** when the context window is exhausted, and the replacement
> session has forgotten every sample generated so far — the symptom is a dataset whose second half is
> measurably less diverse than its first. A validator written for a corpus rule ("reviews must vary in
> length") is **vacuous** and accepts everything; the tell is an empty `invalidSamples`. A
> `ModelSubject(value:)` without `transcript:` still **compiles**, but `ToolCallEvaluator` rejects it
> with `EvaluationError.missingTranscript(evaluatorType:)` before scoring.[^missing-transcript]
>
> 🔴 **GAP — the most consequential unanswered question in the part is a billing question.** Nobody has
> established **whose PCC quota an evaluation run spends** — a 100-sample judge evaluation or an 87-sample
> generation is hundreds of Private Cloud Compute requests, and no session, doc page or sample says
> whether they bill against the signed-in developer's iCloud account. Apple has not answered it. The
> smaller gaps closed on 2026-07-29 against the shipped interface: `SamplingStrategy` is
> `.random(retries: Int = 5)` / `.slidingWindow` with `.random()` the default;
> `allowsAdditionalToolCalls` defaults to `true` (its `false` semantics are still unverified — keep
> writing it explicitly); and `TrajectoryExpectation`'s `ordered` / `unordered` / `disallowed` lists
> are public vars after all, so generated expectations can be validated directly — though generating
> into a `@Generable` type you own remains the better workflow.

---

## Reading order

**Everyone reads [6.1](references/01-foundations-and-hill-climbing.md) first, and most people should stop
there for a while.** The other two guides assume you have a working `Evaluation`, a dataset, at least one
heuristic `Evaluator` and a passing `@Test`. §10's rule of thumb — *if you can measure it in code it is
quantitative; if you can only describe it in words you need a `ModelJudgeEvaluator`* — is what tells you
whether you need guide 6.2 at all.

**Then follow the ladder in [6.2 §1.1](references/02-model-judges-and-alignment.md#11-the-order-to-add-things-in), which is Apple's own
file layout rather than our invention:** `#Playground` → heuristics over a curated `ArrayLoader` → a model
judge → coverage → κ calibration. Do not skip the heuristic rung to get to the judge faster; a judge whose
disagreements you cannot interpret is worse than no judge.

**One ordering correction the guides make explicitly.** The ladder puts dataset expansion before judge
calibration, but [6.2 §12.2](references/02-model-judges-and-alignment.md#122-the-mechanics-and-the-part-that-should-alarm-you) argues the reverse and is right:
drift is a *bias*, not noise, so it **widens as your dataset grows**. Calibrate the judge before you scale
to a thousand samples, or you will hill-climb a feature against a ruler that was never straight.

**Defer or skip:**
- **All of [6.2](references/02-model-judges-and-alignment.md)** if every expectation you have is
  code-measurable. Judges cost an inference per sample per run and buy you nothing a `count` would answer.
- **[6.2 §12–§18](references/02-model-judges-and-alignment.md#12-drift)** (drift, κ, the meta-evaluation, the four
  documented hill-climb iterations) until you have a judge whose scores you are about to make decisions
  with. It is the most demanding material in the part and it needs a human willing to score 30–100 rows.
- **[6.2 §10](references/02-model-judges-and-alignment.md#10-pairwise-judging)** (pairwise judging) is documentation-sourced
  with no precedent in Apple's sample archive, and it is the wrong tool for calibration anyway.
- **[6.3 §1–§11](references/03-synthetic-data-and-tool-trajectories.md#1-the-thirteen-sample-lie)** (synthetic data) until your
  curated 20–30 rows stop telling you anything new. Coverage beats count, and a hundred samples from one
  narrow generator prompt is thirteen samples with extra steps.
- **[6.3 §12–§19](references/03-synthetic-data-and-tool-trajectories.md#12-why-the-final-answer-is-not-enough)** (trajectories) only if your
  feature calls tools — but read it the same day you add your first one.

---

## What this part deliberately does not cover

- **The API being evaluated.** `LanguageModelSession`, `@Generable`, `@Guide`, the `Tool` protocol and
  `Transcript` are [Part 2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/README.md); the guardrail and refusal
  taxonomy your judge inferences inherit is
  [Part 2 guide 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md).
- **`#Playground`, the Foundation Models Instrument, the `fm` CLI and the Python SDK** as tools in their
  own right: [Part 5](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-05-prototyping-profiling-non-swift/README.md). That is also where Python readers go,
  since Evaluations has no non-Swift entry point.
- **Choosing and configuring the backend.** PCC eligibility, the managed
  `com.apple.developer.private-cloud-compute` entitlement and the quota API appear here only as costs you
  have to plan around; the full treatment is
  [Part 4 guide 1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md).
- **Context strategy and agentic orchestration** — the 4K budget, dynamic profiles, tool withdrawal per
  mode: [Part 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md).
- **The 26.0 / 26.2 / 26.4 / 27.0 ladder** that §18's argument rests on:
  [Part 1 guide 2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/references/02-platform-and-version-gating.md).
- **Migrating a shipping 26.x app**, including using an eval suite as the regression gate for that
  migration specifically: [Part 17](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md).
- **Non-text evaluation.** Apple says outright that you can evaluate *any* stochastic system and names
  classifiers and linear regression, and the generic protocol requirements support it — but no sample, doc
  example or session demonstrates one end to end, and the forum question about image-text evaluation
  (thread 833822) is **unanswered**. The Core ML / MLX bridge material is
  [Part 14](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-14-bridges-between-stacks/README.md); treat the evaluation half as unproven.
- **Running suites in CI and shipping operations.** `EvaluationResult.saveJSON(to:)` — which takes a
  *directory* and returns the written file's URL — and `loadJSONLines(from:)` are SDK-verified, and
  6.1 §12 shows the shape, but whether the report is reachable from `xcodebuild` output is a 🔴 GAP.
  [Part 15](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/README.md) is the operating story.

---

## Sources for this part

The load-bearing evidence is **Apple's Book Tracker sample project** — *Using Evaluations to evaluate an
intelligent feature*, 20 Swift files across five targets (the app, two test bundles, and two command-line
tools) at `MACOSX_DEPLOYMENT_TARGET = 27.0`, read on disk and outranking everything else wherever they
conflict. Almost every ✅ in these three guides is quoted from `BookTrackerEvaluations/BookTags.swift`,
`SearchBooks.swift` (the `ToolCallEvaluator` evaluation and all sixteen `TrajectoryExpectation`s),
`SyntheticBookTags.swift`, `HillClimbingEvaluations/ModelJudgeAlignmentEvaluation.swift` and its
hand-rolled `Statistics.swift`, `BookSampleGenerator/main.swift` and `DatasetExtractor/main.swift` — the
last of which is the only description anywhere of Xcode's `.xcevalresult` on-disk format. Second:
`/documentation/evaluations` (the framework index and full symbol inventory) plus its eight articles, and
on the FoundationModels side `updating-prompts-for-new-model-versions`, `systemlanguagemodel` and the
prompt-evaluation article. Third: four Apple Developer Forums threads — **833642** (an Apple Frameworks
Engineer: no model version pinning API, use Evaluations for regression testing), **833729** (Swift-only),
**832053** (`ModelJudgeEvaluator` scope and PCC), and **833822** (image-text evaluation, unanswered).
Fourth: WWDC26 sessions **298** *Meet the Evaluations framework*, **299** *Create robust evaluations for
agentic apps* and **335** *Improve your prompts by hill climbing with Evaluations*, with **319** for the
on-device/PCC comparison — all machine-transcribed spoken word, which is why sentence-level quotes are
treated as verified statements while any Swift identifier heard only in narration is marked 🟡. Where the
transcripts and the sample disagree — the evaluators property type, the `Evaluator` closure shape, the
metric factories, `info:` versus "notes", the judge model, and κ's provenance — **the sample wins in every
case**, and each guide's sources section says so explicitly. Since 2026-07-29 there is one source above
even the sample for *signatures*: the framework's own `.swiftinterface`, shipped inside the Xcode 27 beta
and captured into this repo at `notes/sdk-interfaces/Evaluations-27.0-macos.swiftinterface` (885 lines,
read end-to-end that day). Signature-level claims across the three guides now cite it as ✅
**SDK-verified** with line numbers. The sample remains the authority for *usage*.

[^missing-transcript]: Apple, [`ModelSubject.transcript`](https://developer.apple.com/documentation/evaluations/modelsubject/transcript): tool-call evaluators require a structured transcript and throw `EvaluationError.missingTranscript(evaluatorType:)` when it is `nil`.
