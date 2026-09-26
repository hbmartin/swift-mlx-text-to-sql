# Model judges, score dimensions, drift, and Cohen's kappa

**Part 6 · Evaluations · Reference 02**

**Version floor:** every symbol in this guide is **iOS 27.0 / iPadOS 27.0 / Mac Catalyst 27.0 /
macOS 27.0 / visionOS 27.0 / watchOS 27.0, all tagged Beta**, and every one of them requires
**Xcode 27**. There is no 26.x story here at all: the `Evaluations` module did not exist before this
cycle, so unlike Foundation Models — where 26.0, 26.4 and 27.0 all ship different surfaces — you
either have the whole framework or none of it. **tvOS is absent** from both the documentation
availability line and the session's spoken platform list; do not plan on it. The framework is also
**Swift-only**, confirmed by an Apple Frameworks Engineer on the developer forums, so a Python or
Objective-C test target cannot host an evaluation without a Swift interop layer.

One thing this guide has to correct before you read a line of code: **Cohen's kappa is not part of
the Evaluations framework.** It is hand-written Swift in Apple's sample project. Every session that
discusses judge alignment discusses κ, the number appears in Apple's own test assertions, and a
reasonable reader concludes it ships. It does not. §15 shows you what you have to write.

> ✅ **VERIFIED — interface check, 2026-07-29.** The framework ships inside Xcode 27, not the OS SDK
> (guide 01's distribution box has the full story), and its real macOS Swift interface is captured
> in this repo at `notes/sdk-interfaces/Evaluations-27.0-macos.swiftinterface`. This guide has been
> read against it end-to-end: claims marked ✅ **SDK-verified**
> (`Evaluations-27.0-macos.swiftinterface:<lines>`) cite it, and it closed three of this guide's
> GAPs — `ScoringMode`'s cases, `ModelJudgeError`'s cases, and `ModelJudgePrompt.reference`'s second
> parameter (§20). An interface settles spellings, signatures, defaults and case lists, never
> runtime behaviour — and it *confirms* the κ correction above: there is no agreement statistic
> anywhere in the module's interface. Absence from it means "not present in the Xcode 27 beta
> interface", not "does not exist".

---

## What this covers

The half of evaluation that cannot be expressed as an `if` statement — and then the harder,
stranger, more valuable half: proving that the thing doing the judging deserves to.

- When a criterion has to be qualitative, and Apple's one-line test for telling the difference.
- **A model judge is just another `Evaluator`** producing the same `Metric` type, so judges and
  code-based heuristics compose in a single `evaluators` block with no ceremony.
- Picking the judge model: the "at least as capable" rule from session 298 — and the fact that
  **Apple's own shipping sample does not follow it**, why that is defensible, and what makes it
  defensible.
- `ScoringScale` (`.numeric`, `.passFail`, `.custom`), `ScoreDimension`, and why an **even** number
  of levels is a structural choice rather than a stylistic one.
- **The single most useful technique in the framework: when you disagree with a score, split the
  question into two dimensions.** Apple's worked example splits "quality" into Relevance and
  Usefulness, and the two rationales then separate the diagnosis — relevance tells you *what kind*
  of tag is wrong, usefulness tells you *how* the wrong tags fail at browsing.
- `ModelJudgePrompt(instructions:evaluationTarget:reference:)` — including the correction that
  `reference` returns a **`[String: String]` dictionary of labelled sections**, not a string.
- Rationales as the primary debugging loop: *"You'll learn more from a single run than from hours of
  careful planning."*
- **Drift** — systematic judge/human disagreement that *widens as your dataset grows*, so a judge
  that looks fine on 13 samples can be badly wrong at 1,000.
- Why **accuracy is the wrong alignment measure** on a score-skewed dataset, and why your dataset is
  always score-skewed.
- **Cohen's kappa**: the formula, a complete implementation, the κ ≥ 0.6 bar, the two paradoxes that
  make κ misread, and the weighted variant Apple's sample does not use.
- **The meta-evaluation** — the cleverest construction in the corpus. Extract the previous run's
  results from Xcode's attachment, add your own ratings, freeze `subject(from:)` so it performs no
  inference at all, run the same judge over it, and aggregate with κ. Then hill-climb *the judge*
  until it can stand in for your judgement.
- The four documented iterations of that hill-climb, including the one where relevance improved and
  usefulness got worse.
- ⚠️ The silent failures: a positional join that misaligns without complaint, a `?? 0` that turns a
  missing expert score into a rating of zero, an undefined κ that reports as "no agreement", and a
  judge with no prompt at all that still returns confident numbers.

## What you need

- **Xcode 27** and a 27.0 SDK. There is no back-deployment path.
- An existing evaluation. This guide is about *upgrading* an evaluation with qualitative metrics and
  then calibrating them; it assumes you already have `Evaluation`, `dataset`, `subject(from:)`,
  `evaluators` and `aggregateMetrics(using:)` working. If you do not, read guide
  [`01-foundations-and-hill-climbing.md`](01-foundations-and-hill-climbing.md) in this part first.
- A real device or Mac for anything you intend to trust. Judge calls are model inferences and inherit
  every availability, guardrail and quota constraint from
  [`part-02/06-availability-errors-and-guardrails.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md).
- **A human willing to score 30–100 rows by hand.** There is no way around this. The entire second
  half of this guide is about extracting maximum leverage from that one afternoon of work.

---

## Contents

1. [When a metric has to be qualitative](#1-when-a-metric-has-to-be-qualitative)
2. [A judge is just another `Evaluator`](#2-a-judge-is-just-another-evaluator)
3. [Choosing the judge model](#3-choosing-the-judge-model)
4. [The four parts of a judge, and the one you write](#4-the-four-parts-of-a-judge-and-the-one-you-write)
5. [`ScoringScale`: numeric, pass/fail, custom](#5-scoringscale-numeric-passfail-custom)
6. [`ScoreDimension`: name, description, scale](#6-scoredimension-name-description-scale)
7. [The key technique: split the question](#7-the-key-technique-split-the-question)
8. [`ModelJudgePrompt`](#8-modeljudgeprompt)
9. [Rationales are the debugging loop](#9-rationales-are-the-debugging-loop)
10. [Pairwise judging](#10-pairwise-judging)
11. [Mixing judges and code evaluators](#11-mixing-judges-and-code-evaluators)
12. [Drift](#12-drift)
13. [Why accuracy is the wrong alignment measure](#13-why-accuracy-is-the-wrong-alignment-measure)
14. [Cohen's kappa](#14-cohens-kappa)
15. [Implementing kappa — the framework does not ship it](#15-implementing-kappa--the-framework-does-not-ship-it)
16. [The meta-evaluation, end to end](#16-the-meta-evaluation-end-to-end)
17. [Hill-climbing the judge: four iterations](#17-hill-climbing-the-judge-four-iterations)
18. [Overfitting the alignment score](#18-overfitting-the-alignment-score)
19. [⚠️ Silent failures in judge alignment](#19-️-silent-failures-in-judge-alignment)
20. [What is still unknown](#20-what-is-still-unknown)
21. [Quick reference](#21-quick-reference)
22. [Sources](#22-sources)

---

## 1. When a metric has to be qualitative

Apple's rule for deciding is one sentence long and it is worth memorising, because it saves you from
the two opposite mistakes: writing a judge for something a `count` would have answered, and writing a
regex for something that is irreducibly a matter of taste.

> ✅ **VERIFIED** — WWDC26 session 298, spoken verbatim (`298:275-278`): *"Use heuristics to measure
> quantifiable traits. These rule-of-thumb metrics are a great way to start understanding your
> feature. **The rule-of-thumb is: if you can measure it in code, then it's quantitative. And if you
> can only describe it in words, then you need a qualitative metric, using a `ModelJudgeEvaluator`.**"*

The running example across all three Evaluations sessions and the sample project is **Book Tracker**,
an app whose `BookTaggingService` generates tags for a book from a review the user wrote. Its
informal spec has five expectations, and the split falls out cleanly:

| Expectation | Kind | How |
|---|---|---|
| Generate 3–8 tags | quantitative | `subject.value.tags.count` |
| No multi-word tags (they break the UI) | quantitative | `tag.contains(" ")` |
| At least one tag identifies a literary genre | quantitative | membership in a known-genre set |
| Tags do not repeat the book's title | quantitative | string comparison |
| Tags are **informative, relevant to the book, and helpful for browsing your library** | **qualitative** | a model judge |

Three of five are `if` statements. The fifth is not, and the fifth is the one that determines whether
the feature is any good.

The failure that motivates the judge is worth reproducing, because it is the exact shape of bug that
a green test suite hides. Session 298 shows tags generated for an *Alice in Wonderland* review:

> ✅ **VERIFIED** — `298:191-198`: *"Six tags, single word or hyphenated, with tags identifying genre.
> **Every quantitative metric we built with Rob passed.** But look closer. **'Overrated' and
> 'pretentious' doesn't describe the book — they describe how the reader felt about it.** And
> **'whodunit' isn't even the right genre**. The model picked it up from 'riddles he never answers.'
> **It latched onto the language of the review without understanding the book.** Our metrics are
> passing, but they're not giving us the right signals back."*

Every heuristic is green. The feature is broken. That gap is the entire justification for the second
half of the framework, and Apple's own definition of a judge follows directly from it:

> ✅ **VERIFIED** — `298:203-204`: *"**A Model Judge is a language model used to score your feature's
> output. It gives you a subjective rating — the kind of judgment call a person would make — but
> applied consistently across your entire dataset.**"*

Note the two halves of that sentence, because the second half is what you are buying. A judge is not
more accurate than you; it is *more consistent than you*, and it is available at 3 a.m. against a
thousand samples. Session 335's closing remark makes the trade explicit:

> ✅ **VERIFIED** — `335:255-258`: *"**Models can generate ratings much faster than humans can. So by
> keeping them aligned, you get useful signal as your dataset grows to cover more and more use
> cases.**"*

"By keeping them aligned" is doing an enormous amount of work in that sentence. It is §12 onward.

### 1.1 The order to add things in

Book Tracker's own layering is the recommended sequence, and it is worth stating as a ladder because
each rung is cheaper than the one above it and catches a different class of defect:

1. **`#Playground`** — a `#Playground { }` block in the service file, two hand-written reviews, run
   inline in Xcode. Seconds. Catches "the model does something completely different from what I
   imagined."
2. **Heuristic `Evaluator`s over a curated `ArrayLoader`** — deterministic, no inference in the
   scoring path, cheap enough to run on every commit.
3. **`ModelJudgeEvaluator` with `ScoreDimension`s** — this guide, §2–§11.
4. **`SampleGenerator`** to reach coverage — guide 03 in this part.
5. **κ-calibration of the judge against human scores** — this guide, §12–§18.
6. **`.evaluates(evaluation, info:)`** so runs carry the prompt text and are diffable in the Compare
   view.

> ✅ **VERIFIED** — this ladder is Apple's, not ours: it is the file layout of the Book Tracker
> sample. `BookTaggingService.swift:76-101` is the `#Playground`; `BookTrackerEvaluations/BookTags.swift`
> is heuristics plus judge; `BookSampleGenerator/main.swift` is the generator; `HillClimbingEvaluations/`
> is the κ calibration.

Do not skip rung 2 to get to rung 3 faster. A judge costs an inference per sample per run; a
`count` costs nothing, and it is the `count` metric that caught Book Tracker's most instructive bug
(a `@Guide(.count(3...8))` that produced a 100% pass rate by generating exactly eight tags every
single time — range compliance perfect, distribution degenerate). Judges are for what heuristics
cannot see, not for what you could not be bothered to write.

---

## 2. A judge is just another `Evaluator`

This is the architectural fact that makes everything else easy, and it is stated more plainly in the
session than in the documentation:

> ✅ **VERIFIED** — `298:222-224`: *"In the Evaluations framework, a model judge is just another
> `Evaluator`. It conforms to the same protocol as the quantitative evaluators and produces the same
> `Metric` type. **So you can mix them freely within a single evaluation.**"*

Concretely, `ModelJudgeEvaluator` conforms to `EvaluatorProtocol` exactly as the closure-based
`Evaluator` does, so both are legal expressions inside the same `@EvaluatorsBuilder` block:

> ✅ **VERIFIED** — declarations from `/documentation/evaluations/evaluatorprotocol` and
> `/documentation/evaluations/modeljudgeevaluator`:
>
> ```swift
> protocol EvaluatorProtocol<Input, Subject> : Sendable {
>     associatedtype Input
>     associatedtype Subject
>     func metrics(subject: Self.Subject, input: Self.Input) async throws -> [Metric]
> }
>
> struct ModelJudgeEvaluator<Input> where Input : ModelSampleProtocol
> // Conforms: EvaluatorProtocol, Sendable
> ```

Note `metrics(subject:input:)` returns **`[Metric]`**, plural. That is why a multi-dimension judge
can emit a Relevance score *and* a Usefulness score from one call — it returns two `Metric`s from a
single invocation, and the documentation confirms the efficiency consequence:

> ✅ **VERIFIED** — `/documentation/evaluations/scoring-with-model-as-judge-evaluators`: *"The
> evaluator scores all dimensions in a single call to the model as judge, **so you get multiple
> metrics without extra latency.**"*

That is not a small detail. If you write two single-dimension judges you pay two inferences per
sample; one two-dimension judge pays one. On a 1,000-sample dataset that is the difference between a
coffee break and an overnight run.

Here is the shape, verbatim from Apple's shipping sample, with the heuristic evaluators left in place
so you can see that there is genuinely no seam between the two kinds:

> ✅ **VERIFIED** — `BookTrackerEvaluations/BookTags.swift:35-123`, an Apple sample project compiled
> against the 27.0 SDK. This is the highest-precedence evidence in the corpus.

```swift prelude:external-module
import Evaluations
import Foundation
import FoundationModels
import Testing
@testable import BookTracker

struct BookTaggingEvaluation: Evaluation {

    // Heuristic metrics — identifiers and result carriers at once.
    let tagCount = Metric("Tag Count")
    let tagTotal = Metric("Tag Total")
    let hasGenreTag = Metric("Has Genre Tag")
    let wordCount = Metric("Word Count")

    // Qualitative dimensions — each one carries its own Metric, reachable as `.metric`.
    let relevance = ScoreDimension(
        "Relevance",
        description: """
            Whether each tag describes a quality, theme, or tone
            of the book itself rather than incidental details or
            the reader's personal reactions.
            """,
        scale: .numeric([
            4: "Every tag describes the book itself",
            3: "Most tags describe the book",
            2: "Some tags describe personal reactions",
            1: "Tags don't meaningfully describe the book"
        ])
    )
    // …usefulness declared the same way…

    var evaluators: Evaluators {
        // Code-based: is the count in range?
        Evaluator { _, subject in
            let count = subject.value.tags.count
            if count >= 3 && count <= 8 {
                return tagCount.passing(rationale: "\(count) tags")
            }
            return tagCount.failing(rationale: "Got \(count) tags, expected 3–8")
        }

        // Code-based: record the raw count, so you can see the distribution.
        Evaluator { _, subject in
            tagTotal.scoring(Double(subject.value.tags.count))
        }

        // Code-based: single-word or hyphenated only.
        Evaluator { _, subject in
            for tag in subject.value.tags where tag.contains(" ") {
                return wordCount.failing(rationale: "Tag \(tag) contains multiple words")
            }
            return wordCount.passing()
        }

        // Model-based: exactly the same kind of thing, in the same block.
        ModelJudgeEvaluator(
            judge: SystemLanguageModel.default,
            dimensions: [relevance, usefulness],
            prompt: ModelJudgePrompt(
                instructions: """
                    You are evaluating tags generated for a personal book-tracking app where users
                    organize their library by browsing and filtering tags.
                    """,
                evaluationTarget: { value in
                    "\(value.tags.count) Generated tags: " + value.tags.joined(separator: ", ")
                },
                reference: { input, _ in
                    let expectedTags = input.expected?.tags.joined(separator: ", ")
                    return ["Expected Tags": expectedTags ?? "No expected tags defined"]
                }
            )
        )
    }
}
```

Four spellings in there are easy to get wrong and all four are confirmed by the sample:

- **`var evaluators: Evaluators`** — the associated type is a result-builder type named `Evaluators`,
  plural. It is *not* `some Evaluator`, which is what a reconstruction from the spoken session
  produced and which does not compile.
- **`Evaluator { input, subject in … }`** is a **two**-argument closure. First argument is the
  `ModelSample`, second is the `ModelSubject`. All of Book Tracker's heuristics discard the first
  as `_` — worth noticing, because it means a heuristic usually judges the output against a *rule*,
  while a judge usually judges it against the *input*.
- **`Metric` is both identifier and result carrier.** `let tagCount = Metric("Tag Count")` is the
  identity; `tagCount.passing(rationale:)` is a *new* `Metric` value with the result stored inside.
  You return the latter and aggregate against the former.
- **`subject.value`** is the typed model output (here a `BookTags`), reached through `ModelSubject`.

> ✅ **VERIFIED** — the five result factories, from `/documentation/evaluations/metric`:
> `passing(rationale:)`, `failing(rationale:)`, `scoring(_:rationale:)`, `ignore(rationale:)`, and
> the bare `passing()` / `failing()` forms. `ignore` is documented as *"excluded from aggregation"*.
> `Metric.rationale` is `String?` and `Metric.name` *"is used as the DataFrame column name"*.

That last point matters more than it looks: metric names become column headings in a `DataFrame`, and
they are what you type into `result.aggregateValue(...)` and read in the Xcode report. Name them the
way you want to read them at 6 p.m. on a Friday.

---

## 3. Choosing the judge model

### 3.1 The rule as stated

> ✅ **VERIFIED** — `298:208-210`: *"You can use a second model as a judge to evaluate your feature.
> **Your judge should be at least as capable as the model you're evaluating.** In our case, we can use
> a more capable model from **Private Cloud Compute**."*

And later in the same session:

> ✅ **VERIFIED** — `298:221`: *"And finally, we've specified **Private Cloud Compute as our judge
> model**, giving us a more capable evaluator than the on-device model we're evaluating."*

The principle is sound and you should hold it. A judge weaker than the system under test cannot
reliably detect the failures you care about; at best it adds noise, at worst it systematically
rewards the failure mode it shares with the feature.

### 3.2 What Apple's code actually does — and this is a real conflict

> 🔴 **SOURCES DISAGREE.** The session says PCC. **The shipping sample uses the on-device model as
> the judge for an on-device feature**, in both of its evaluations.

> ✅ **VERIFIED** — three call sites in the Book Tracker archive:
>
> | Site | Judge | File:line |
> |---|---|---|
> | Tag-quality evaluation | `judge: SystemLanguageModel.default` | `BookTags.swift:108` |
> | Same evaluation over the synthetic dataset | `judge: SystemLanguageModel.default` | `SyntheticBookTags.swift:98` |
> | Judge-alignment (κ) evaluation | `judge: SystemLanguageModel()` | `ModelJudgeAlignmentEvaluation.swift:213` |
>
> And the feature under test is built as
> `SystemLanguageModel(guardrails: .permissiveContentTransformations)` (`BookTaggingService.swift:40`).
> Same model family, judging itself.

Apple's documentation is consistent with the sample rather than the session: every example on
`/documentation/evaluations/scoring-with-model-as-judge-evaluators` passes
`judge: SystemLanguageModel.default`.

**Our evidence precedence puts compiling sample code above spoken session narration, so the honest
statement is: an on-device judge for an on-device feature is a shipped, Apple-authored pattern.**
Three things make it defensible, and they are worth understanding rather than just accepting:

1. **PCC is entitlement-gated and quota-metered.** A CI job that runs a 1,000-sample evaluation
   through a judge on Private Cloud Compute is spending a *per-user* quota on a machine that has no
   user. 🟡 **RECONSTRUCTED** — the entitlement requirement is attested in WWDC26 session 241
   narration (`241:43`) and appears in the docs index as
   `com.apple.developer.private-cloud-compute`; we have not read the entitlement's own
   documentation page. See [`part-04/01-private-cloud-compute.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md).
2. **The κ calibration is what buys back the capability gap.** This is the real answer. You do not
   need a judge that is *a priori* more capable if you can *demonstrate* that its ratings agree with
   an expert's at κ ≥ 0.6 on your dataset. That is precisely what `HillClimbingEvaluations/` exists
   to prove, and it is why Apple can ship an on-device judge with a straight face.
3. **A well-prompted small model on a narrow, well-specified rubric is a different task from open
   generation.** Scoring four tags against four written anchor levels is a classification problem
   with a lot of scaffolding, not a reasoning problem.

**Practical advice.** Start with `SystemLanguageModel.default` because it is free, offline and fast.
Then run the alignment evaluation in §16. If you cannot get κ above 0.6 after sharpening the
dimensions and adding a few worked examples, *that* is your signal to move the judge to PCC — and
you will have a measured reason rather than a vibe.

### 3.3 Passing a PCC model as the judge

> 🟡 **RECONSTRUCTED usage, ✅ SDK-verified type.** `ModelJudgeEvaluator`'s `judge:` parameter is
> declared **`any FoundationModels.LanguageModel`** on all four initialisers and both `pairwise`
> statics, with the promptless forms defaulting it to `SystemLanguageModel()`
> (`Evaluations-27.0-macos.swiftinterface:323-330`, checked 2026-07-29). So
> `judge: PrivateCloudComputeLanguageModel()` **typechecks** so long as that model conforms to
> `LanguageModel`. What remains unverified is everything past the type system: **we have still not
> seen a PCC judge in any compiling source or documentation example**, and nobody has reported how
> it behaves against quota, latency, or the judge's JSON-decoding path.
>
> Session 298 narrates PCC as the judge, and an Apple engineer on forum thread 832053 confirms
> `ModelJudgeEvaluator` works with PCC — but the code they posted sets up PCC as the *subject's*
> session, not the judge's:
>
> ```swift
> let session = LanguageModelSession(model: PrivateCloudComputeLanguageModel())
> let response = try await session.respond(to: "Analyze this document...")
> ```
>
> **Safe default until you have run it yourself:** write
> `judge: SystemLanguageModel.default`, calibrate with κ, and treat a PCC judge as an experiment you
> verify on hardware before you build a CI pipeline on it. If it misbehaves in practice, the
> fallback that certainly works is to make PCC the *subject* model and keep the on-device judge.

### 3.4 The judge must not be the same *session* as the feature

Not a documented rule, but a structural one that follows from how `subject(from:)` works. The
evaluation constructs the feature's session itself:

> ✅ **VERIFIED** — `SearchBooks.swift:525-563`, and the same pattern in `BookTags.swift`: the
> evaluation builds `SystemLanguageModel(guardrails: .permissiveContentTransformations)` inside
> `subject(from:)` because *that is how the app builds it* (`BookTaggingService.swift:40`).

The consequence is worth spelling out: **if your evaluation constructs the model differently from
your app — different guardrails, different instructions, different `GenerationOptions` — you are
evaluating a different system and your scores are about something you do not ship.** Book Tracker
avoids this by having the evaluation call `BookTaggingService.generateTags(for:)` directly rather
than reimplementing it. Do that.

---

## 4. The four parts of a judge, and the one you write

A model judge is a prompt. Understanding which parts of that prompt the framework assembles and which
part is yours is the difference between iterating productively and flailing.

> ✅ **VERIFIED** — `298:211-216`, the four components as narrated:
>
> 1. **The instruction** — *"tells the model it will be given book reviews, and how it should evaluate it."*
> 2. **The feature input** — *"the prompt given to the feature being judged, in our case, its the book review."*
> 3. **The feature output** — *"the tags our service generated."*
> 4. **The scoring guide** — *"tells the model how to evaluate and score the feature."*
>
> And then the load-bearing sentence: *"**The Evaluations framework handles most of this for you, so
> you can focus on the scoring guide.**"*

Mapped onto the API:

| Component | Who supplies it | Type |
|---|---|---|
| Instruction | you (optional) | `ModelJudgePrompt.instructions` |
| Feature input | **the framework**, from the `ModelSample` | — |
| Feature output | **the framework**, JSON-serialised from `subject.value` — overridable | `ModelJudgePrompt.evaluationTarget` |
| Reference material | you (optional) | `ModelJudgePrompt.reference` |
| **Scoring guide** | **you** | `[ScoreDimension]`, each with a `ScoringScale` |

> ✅ **VERIFIED** — `/documentation/evaluations/modeljudgeevaluator`: *"`ModelJudgeEvaluator` sends
> the query, response, and optional reference data to a judge model, which returns scores for one or
> more dimensions. **The response is automatically serialized as JSON**, because `OutputType` is
> `Codable`, or is customizable via `ModelJudgePrompt`."*

So the minimum viable judge is a name and a scale, and everything else has a default:

> ✅ **VERIFIED** — `/documentation/evaluations/modeljudgeprompt`: *"If you omit the
> `ModelJudgePrompt` entirely, the evaluator uses default instructions that ask the model as judge to
> rate the response using the scoring scale."* There is a `static var defaultInstructions: String` on
> both `ModelJudgeEvaluator` and `ModelJudgePrompt`.

### 4.1 The initialiser matrix

> ✅ **VERIFIED** — from `/documentation/evaluations/modeljudgeevaluator`:
>
> ```swift
> struct ModelJudgeEvaluator<Input> where Input : ModelSampleProtocol
>
> // Single dimension — the name and scale are given inline.
> init(_:scale:judge:scoringMode:)
> init(_:scale:judge:scoringMode:prompt:)
>
> // Multiple dimensions — each ScoreDimension carries its own name and scale.
> init(judge:dimensions:scoringMode:)
> init(judge:dimensions:scoringMode:prompt:)
>
> // Pairwise — see §10.
> static func pairwise(_:scale:judge:scoringMode:evaluationTarget:)
> static func pairwise(judge:dimensions:scoringMode:evaluationTarget:)
>
> // Members
> static var defaultInstructions: String
> func judgePrompt(for:output:)   // "Builds and returns the full judge prompt for
>                                 //  inspection, debugging, or logging."
> var dimensions
> var scoringMode
> ```
>
> ✅ **SDK-verified** — the interface fills in what the doc page left out
> (`Evaluations-27.0-macos.swiftinterface:317-340`): `judge:` is `any LanguageModel` and **defaults
> to `SystemLanguageModel()`** on the two promptless initialisers; `scoringMode:` **defaults to
> `.discrete`** on all four initialisers and both `pairwise` statics; `pairwise`'s
> `evaluationTarget:` is `((Input.ExpectedValue) -> String)? = nil`; and `judgePrompt(for:output:)`
> is `async throws` and returns a FoundationModels **`Prompt`**, not a plain string (`:331-333`).

Two things to take from that list.

**First, `judgePrompt(for:output:)` is the debugging tool nobody mentions.** It renders the assembled
prompt — your instructions, the framework's framing, the serialised output, the reference sections and
the scale anchors — as a `Prompt` you can print. Note it is `async throws`, so the call is
`try await evaluator.judgePrompt(for: sample, output: value)`. When a judge behaves inexplicably, print the prompt
before you change anything else. Half the time the answer is visible immediately: a reference section
that says "No expected tags defined" for every sample, an `evaluationTarget` that stringified a struct
into `BookTags(tags: ["a", "b"])`, an instruction that never mentions your app.

**Second, `scoringMode` is no longer a hole in our knowledge — its cases are pinned, its semantics
are not.**

> ✅ **SDK-verified — GAP closed (2026-07-29).** `ScoringMode` has exactly two cases:
>
> ```swift
> public enum ScoringMode : Sendable {
>     case discrete
>     case continuous
> }
> ```
>
> (`Evaluations-27.0-macos.swiftinterface:306-314`), and **`.discrete` is the default** on all four
> `ModelJudgeEvaluator` initialisers and both `pairwise` statics (`:323-330`). What the interface
> cannot settle is behaviour: the names read as "constrain the judge to the scale's defined values"
> versus "allow scores between the anchors" — consistent with the framework index's *"scoring
> constraint mode"* description, but that is a reading of two identifiers, not a documented fact.
>
> **Safe default unchanged:** omit the parameter, exactly as Apple's sample does at all three of its
> judge call sites — you get `.discrete`. Treat `.continuous` as a deliberate experiment, and check
> what lands in the DataFrame if you try it: scores between anchors would break any downstream
> statistic that assumes contiguous categories, κ included (§14.4).

---

## 5. `ScoringScale`: numeric, pass/fail, custom

The scale is the part of the judge you actually author, and its shape is a design decision with
measurable consequences.

> ✅ **VERIFIED** — `/documentation/evaluations/scoringscale`:
>
> ```swift
> struct ScoringScale                              // Sendable
> static func numeric(_:)                          // [Double: String] — level -> description
> static func passFail(passDescription:failDescription:)
> static func custom(_:)                           // a ScoreLevel-conforming enum type
> init(options:)
> var options                                      // "ordered from highest to lowest value"
> struct ScaleOption
> protocol ScoreLevel { var guideDescription: String { get }; var value: Double { get } }
> ```
>
> ✅ **SDK-verified** (`Evaluations-27.0-macos.swiftinterface:366-405`): `numeric(_ scale: [Double :
> String])`, `passFail(passDescription:failDescription:)` and `custom<Level>(_ level: Level.Type)
> where Level : ScoreLevel` are all real, as is `init(options: [ScaleOption])`. The full
> `ScoreLevel` protocol is `CaseIterable & Hashable & Sendable`, requiring `label`,
> `guideDescription` and `value: Double` — with a default implementation of `label`, which is why
> the enum example below gets away without writing one. `ScaleOption` is
> `init(label:guideDescription:value:)`.

All three forms, from Apple's documentation examples:

```swift prelude:guide-context
// 1. Numeric — a dictionary of level -> anchor text.
let quality = ScoringScale.numeric([
    4: "Every tag describes the book itself",
    3: "Most tags describe the book",
    2: "Some tags describe personal reactions",
    1: "Tags don't meaningfully describe the book"
])

// 2. Binary.
let safety = ScoringScale.passFail(
    passDescription: "The response is safe and appropriate",
    failDescription: "The response contains harmful content"
)

// 3. Your own ordered enum.
enum SafetyLevel: ScoreLevel {
    case safe, unsafe
    var guideDescription: String { self == .safe ? "Safe" : "Unsafe" }
    var value: Double { self == .safe ? 1 : 0 }
}
let typed = ScoringScale.custom(SafetyLevel.self)
```

> ⚠️ **A spelling discrepancy worth knowing about.** The documentation types `numeric(_:)`'s argument
> as **`[Double: String]`**; Apple's sample writes integer literals (`4:`, `3:`, `2:`, `1:`). Both are
> correct — Swift's integer literals coerce to `Double` in a `[Double: String]` context — so you can
> write `4:` and think "level four". Just do not be surprised when a signature dump says `Double`, and
> do not assume you are limited to whole numbers.

### 5.1 Why an even number of levels

This is the most quotable design rule in the framework, and it is stated twice — once in the session
and once, more precisely, in the docs.

> ✅ **VERIFIED** — `298:218-220`: *"We've defined a 'TagQuality' metric on a **1 to 4 scale**, with
> each level describing what that score means. **An even number of options prevents the judge from
> defaulting to a neutral middle score. Four levels provides just enough distinction without diluting
> the meaning of each rating.**"*

> ✅ **VERIFIED** — `/documentation/evaluations/designing-effective-model-judges`: *"**Use a small,
> even number of levels for subjective quality.** … an even number **removes the noncommittal middle**
> the model as judge can otherwise default to."*

The mechanism is worth stating plainly because it changes how you read your own results. Given a
1–5 scale and a hard case, a language model — like a human filling in a survey — will pick 3. Given
1–4 there is no 3-that-means-nothing; 3 means "most tags describe the book" and the judge has to
commit to *most* or *some*. Every sample becomes a decision. That is the entire trick.

The same article gives a scale-selection table:

> ✅ **VERIFIED** — `/documentation/evaluations/designing-effective-model-judges`, verbatim:
>
> | Scale | Best for | Reliability |
> |---|---|---|
> | Binary, for example pass or fail | Safety, compliance, format checks, factual correctness | Highest |
> | 1–4, or another even-numbered range | General quality, subjective dimensions like tone, clarity, helpfulness | Good |
> | Custom categories | Domain-specific distinctions, for example, safe, borderline, or unsafe | Varies by design |

And the corresponding warning, which is the mirror image of the even-number rule:

> ✅ **VERIFIED** — same article: *"**Start with binary scales for binary judgments.** … Forcing a
> multi-point judgment on a binary dimension **adds noise without adding signal, because the judge
> clusters around the middle.**"*

So: "is this safe?" is `.passFail`. "How good are these tags?" is `.numeric` with four levels. Do not
put safety on a 1–4 scale because you want a nice chart.

> 🔴 **An internal contradiction in Apple's own documentation, which you should know about before it
> confuses you.** The `designing-effective-model-judges` article insists on even-numbered scales. The
> `scoring-with-model-as-judge-evaluators` article's first `ScoreDimension` example is:
>
> ```swift
> ScoreDimension("Grammar", scale: .numeric([
>     5: "Flawless grammar throughout",
>     3: "Some errors but generally readable",
>     1: "Pervasive errors making text difficult to understand"
> ]))
> ```
>
> — three levels, with a middle. **Follow the advice article, not that example.** Every dimension in
> the Book Tracker sample archive uses four levels. Note also what that example demonstrates
> incidentally and correctly: **you do not have to define every integer in your range.** The judge
> sees only the anchors you write. A 5/3/1 scale is a three-point scale whose values happen to be
> spaced two apart, and it will produce scores of 5, 3 and 1 — which then breaks any downstream
> statistic that assumes contiguous categories, κ very much included (see §14.4).

### 5.2 Anchors must describe observable features

> ✅ **VERIFIED** — `/documentation/evaluations/designing-effective-model-judges`: *"Each level needs
> to describe **observable features** rather than restating a quality gradient. 'Tags accurately
> represent the book and are useful for browsing' gives the model as judge something concrete to
> check. **'Excellent quality' does not.**"*

This is the single highest-yield edit you can make to a badly-behaved judge, and it costs nothing.
Compare:

```swift prelude:guide-context
// Bad — a gradient restated four times. The judge has nothing to check,
// so it falls back on overall vibe and its scores will be unstable run to run.
.numeric([
    4: "Excellent",
    3: "Good",
    2: "Fair",
    1: "Poor"
])

// Good — each level names a countable property of the output.
.numeric([
    4: "Every tag describes the book itself",
    3: "Most tags describe the book",
    2: "Some tags describe personal reactions",
    1: "Tags don't meaningfully describe the book"
])
```

The second version tells the judge to *walk the tags and count*, which is how session 298 describes
authoring a level in the first place:

> ✅ **VERIFIED** — `298:245-249`: *"To score these tags, you'd walk through each one. Identify which
> tags are bad and which are good, based on whether or not they meaningfully describe the book. You'd
> repeat this for every tag. In this case, all of the tags are good, which earns a score of 4 on our 1
> to 4 scale. **You would repeat the same process to define each scale in the scoring guide.**"*

Write the procedure you would follow, then write down what each outcome of that procedure is worth.
That is a scoring guide.

---

## 6. `ScoreDimension`: name, description, scale

> ✅ **VERIFIED** — `/documentation/evaluations/scoredimension`:
>
> ```swift
> struct ScoreDimension                     // Sendable
> init(_ name: String, description: String?, scale: ScoringScale)
> var name: String                          // "used as the DataFrame column name"
> var metric: Metric                        // "A metric identifier derived from this dimension's name."
> var scale: ScoringScale
> var description: String?
> ```
>
> ✅ **SDK-verified** — `init(_ name: String, description: String? = nil, scale: ScoringScale)`;
> `description` defaults to `nil`, and `metric` is a computed property
> (`Evaluations-27.0-macos.swiftinterface:395-405`).

Three parts, confirmed independently by the session:

> ✅ **VERIFIED** — `298:250`: *"And that's our 'Relevance' metric with the **metric name,
> description, and scale** that the model judge can use."*

The `name` is positional. The `description` is what the dimension *means* in your app's terms. The
`scale` is how it is graded. And `.metric` is the bridge back to aggregation — it is how you write
`aggregator.computeMean(of: relevance.metric)` without declaring a separate `Metric` yourself.

> ✅ **VERIFIED** — `BookTags.swift:129-142`, the aggregation over a mixed evaluation:
>
> ```swift
> func aggregateMetrics(using aggregator: inout MetricsAggregator) {
>     aggregator.group("Heuristics") { aggregator in
>         aggregator.computeMean(of: tagCount)
>         aggregator.computeStandardDeviation(of: tagTotal)
>         aggregator.computeMean(of: tagTotal)
>         aggregator.computeVariance(of: tagTotal)
>         aggregator.computeMean(of: wordCount)
>         aggregator.computeMean(of: hasGenreTag)
>     }
>     aggregator.group("Quality") { group in
>         group.computeMean(of: relevance.metric)
>         group.computeMean(of: usefulness.metric)
>     }
> }
> ```
>
> Note the signature takes `inout MetricsAggregator`, and `.group(_:)` nests a sub-aggregator whose
> label becomes a heading in the Xcode report.

Two consequences of `name` being a DataFrame column name:

- **Names must be stable across runs** or the Compare view has nothing to compare. If you rename
  "Relevance" to "Topicality" mid-hill-climb you have thrown away your baseline.
- **Names must be unique.** Two dimensions with the same name collide in the same column. Nothing in
  our corpus says what happens then; do not find out.

### 6.1 The `description` is not decoration

The dimension's `description` is the sentence that tells the judge what the dimension *is*, separately
from what each score level *means*. Session 298 shows how to derive it — you write down what you
meant by the word:

> ✅ **VERIFIED** — `298:243-244`: *"When we say the tags are relevant we mean that **each tag
> describes a quality, theme, or tone of the book itself rather than small details or the reader's
> personal reactions.** And we can write that as the **description** for our `ScoreDimension`."*

That is a definition, and it is doing the work the word "relevant" failed to do. Which brings us to
the technique this whole guide is built around.

---

## 7. The key technique: split the question

If you take one thing from this guide, take this section.

### 7.1 The failure

Book Tracker's first judge was a single dimension called `TagQuality` on a 1–4 scale. Run against a
set of tags including *overrated*, *pretentious* and *whodunit*, it returned **3**, with a rationale
flagging only `whodunit` and `detective-fiction` as irrelevant. The developer disagreed: those
opinion tags should have been flagged too.

And then the session says the thing that reframes the entire activity:

> ✅ **VERIFIED** — `298:232-235`: *"And here's the thing: **by the scale we wrote, the judge is
> actually right. Every tag connects to something that the user wrote. The judge is faithfully
> following the scoring guide we provided. We meant something specific by relevant and useful for
> browsing, and the judge interpreted those words differently than we did.**"*

**The judge was not wrong. The rubric was ambiguous.** This is almost always true, and internalising
it changes your debugging posture from arguing with the model to editing your own writing.

### 7.2 The diagnosis

> ✅ **VERIFIED** — `298:238-241`: *"Looking back, the problem with our first model judge was that
> **it was too broad. It was asking two different questions.** … **When you find yourself disagreeing
> with a score, you should try and see if you can split the questions.** In our case, relevance and
> usefulness are actually two different metrics."*

`TagQuality` was conflating:

- **Relevance** — does this tag describe *the book*, as opposed to the reader's feelings about it or
  an incidental phrase lifted from the review?
- **Usefulness** — would this tag work as a *search term* when browsing a personal library?

Those are orthogonal. `psychological` is relevant to *Frankenstein* and useless for browsing.
`overrated` is neither. A single 1–4 score cannot express "right subject, wrong granularity", so the
judge picks a number in the middle and you learn nothing.

### 7.3 The fix, and why it works

```swift prelude:guide-context
let relevance = ScoreDimension(
    "Relevance",
    description: """
        Whether each tag describes a quality, theme, or tone
        of the book itself rather than incidental details or
        the reader's personal reactions.
        """,
    scale: .numeric([
        4: "Every tag describes the book itself",
        3: "Most tags describe the book",
        2: "Some tags describe personal reactions",
        1: "Tags don't meaningfully describe the book"
    ])
)

let usefulness = ScoreDimension(
    "Usefulness",
    description: "Whether each tag works as a search term for browsing a personal library.",
    scale: .numeric([
        4: "Every tag would help someone find this book while browsing",
        3: "Most tags are useful for browsing but a couple are too narrow or generic",
        2: "About half the tags are useful; the rest are too narrow or generic",
        1: "The tags would not help someone browse a library"
    ])
)

// One evaluator, two dimensions, one inference per sample.
ModelJudgeEvaluator(
    judge: SystemLanguageModel.default,
    dimensions: [relevance, usefulness],
    prompt: bookTagJudgePrompt
)
```

> ✅ **VERIFIED** — the `relevance` dimension above is verbatim from `BookTags.swift:43-56`. The
> `usefulness` anchor text is verbatim from Apple's documentation example on
> `/documentation/evaluations/scoring-with-model-as-judge-evaluators`, where the same two-dimension
> book-tagging judge appears with the first dimension named `Accuracy` rather than `Relevance`. Both
> spellings are Apple's; the sample's is the one to copy, since it is the one that compiles alongside
> the κ-calibration evaluation.

And now the payoff, which is the sentence that makes splitting worth the extra dimension:

> ✅ **VERIFIED** — `298:263-267`: *"In place of Quality we now have a relevance and usefulness
> score… **Notice how the two rationales separate the diagnosis. Relevance tells us what kind of tag
> is wrong. And Usefulness tells us how the wrong tags fail at browsing.**"*

Read that again with a debugger's eye. You now have a **two-dimensional error signature** per sample,
and each cell of the resulting matrix points at a different fix:

| Relevance | Usefulness | What it means | What to change in the *feature* |
|---|---|---|---|
| 4 | 4 | Good output | Nothing |
| 4 | 2 | Right subject matter, wrong granularity — tags like `quiet-steadiness`, `visual-dimension` | Tell the generator to prefer established vocabulary over phrases lifted from the review |
| 2 | 4 | Reader-reaction tags that happen to be browsable — `overrated`, `poignant` | Tell the generator to describe the book, not the review |
| 2 | 2 | Extractive noise | Instructions, or the model |
| 4 | 1 | Every tag is about the book and none is searchable | Almost always over-specificity; consider a controlled vocabulary |

That table is not in Apple's material — it is the natural reading of the two dimensions, and it is why
the split earns its keep. A single "quality: 3" gives you none of those rows.

### 7.4 When to split, and when to stop

**Split when:** you disagree with a score and can articulate two different reasons it might be
wrong; or when all your scores come out the same, which session 298 names explicitly as the symptom
of an over-broad question.

> ✅ **VERIFIED** — `298:282-285`: *"**Use rationales to drive your next change. If the scores are all
> the same, your question is too broad. If you can't isolate the problem, split the dimensions. And if
> the judge doesn't understand your app, add context.**"*

That is a three-line decision procedure and it is complete. Uniform scores → split. Cannot localise
the problem → split. Judge misunderstands your domain → `ModelJudgePrompt.instructions` (§8).

**Stop when** a dimension can no longer be decomposed into things you would fix differently. Two
dimensions that always move together are one dimension with extra latency — and the κ evaluation in
§16 will show you this directly, because their alignment scores will track each other exactly.

There is one hard-won instruction in Apple's calibration prompt that belongs here:

> ✅ **VERIFIED** — `ModelJudgeAlignmentEvaluation.swift:216-283`, the calibration judge's prompt
> contains the explicit instruction *"Score Relevance and Usefulness independently, even when one tag
> affects both."*

Because the judge scores both dimensions in a single inference, its Relevance answer is in context
when it writes its Usefulness answer, and it will anchor. Telling it not to is free and it works.

---

## 8. `ModelJudgePrompt`

Dimensions tell the judge *what to measure*. They do not tell it what your app is.

> ✅ **VERIFIED** — `298:253-257`: *"But dimensions alone aren't enough. **They tell the judge what to
> measure, but not how to think about your app.** Without that context, a judge evaluating tags for
> Book Tracker might treat a reader's criticism as a valid book descriptor. **It has no way to know
> that Book Tracker is a personal library, not a review platform.** And that's where the
> `ModelJudgePrompt` comes in."*

That example is precise and worth sitting with. `overrated` is a perfectly good tag *on Goodreads*.
It is a terrible tag in a personal library you are browsing, because you will never search for it. The
judge cannot know which app it is looking at unless you tell it.

### 8.1 The type

> ✅ **VERIFIED** — `/documentation/evaluations/modeljudgeprompt`:
>
> ```swift
> struct ModelJudgePrompt<Input> where Input : ModelSampleProtocol
>
> init(instructions:evaluationTarget:reference:)
>
> static var defaultInstructions: String
> var instructions: String   // "The system instructions for the judge model."
> var evaluationTarget       // closure: response -> String
> var reference              // closure: (input, response) -> [String: String] labeled sections
> ```
>
> ✅ **SDK-verified** — the exact declarations (`Evaluations-27.0-macos.swiftinterface:353-363`):
> `instructions` defaults to `ModelJudgePrompt.defaultInstructions`; `evaluationTarget` is
> `(@Sendable (Input.ExpectedValue) -> String)? = nil`; and `reference` is
> `(@Sendable (Input, Input.ExpectedValue) async throws -> [String : String])? = nil` — note the
> reference closure may be `async` and may `throw`, which no doc example uses.

> ⚠️ **CORRECTION — `reference` returns a dictionary, not a string.** This is the single most likely
> thing to get wrong from memory, and material in circulation has it as a `String`. It is
> `[String: String]`, and each pair becomes a *labelled section* of the prompt.
>
> ✅ **VERIFIED** twice over. Documentation: *"The `reference` closure receives the input sample and
> the model's response, and returns a `[String: String]` dictionary. **Each key-value pair becomes a
> labeled section in the judge's prompt.**"* Sample: `BookTags.swift:107-123`, reproduced below.

### 8.2 The worked example

> ✅ **VERIFIED** — `BookTags.swift:107-123`, verbatim:

```swift prelude:guide-context
ModelJudgeEvaluator(
    judge: SystemLanguageModel.default,
    dimensions: [relevance, usefulness],
    prompt: ModelJudgePrompt(
        instructions: """
            You are evaluating tags generated for a personal book-tracking app where users
            organize their library by browsing and filtering tags.
            """,
        evaluationTarget: { value in
            "\(value.tags.count) Generated tags: " + value.tags.joined(separator: ", ")
        },
        reference: { input, _ in
            let expectedTags = input.expected?.tags.joined(separator: ", ")
            return ["Expected Tags": expectedTags ?? "No expected tags defined"]
        }
    )
)
```

Three notes on that code, each of which will bite someone:

**`evaluationTarget` takes the *value*, not the sample.** Its parameter is your `@Generable` output
type (`BookTags`), and it returns the string the judge will read. Without it the judge gets JSON:
`{"tags":["gothic","horror","epistolary"]}`. That is not wrong, and for a flat struct it is fine. It
becomes wrong when your output type has fields the judge should not weigh, or when the JSON is large
enough to bury the part that matters. Note also that Apple's version prefixes the count —
`"3 Generated tags: gothic, horror, epistolary"` — which hands the judge a fact it would otherwise
have to derive.

**`reference` takes `(input, _)`.** The first parameter is the `ModelSample`, which is where the
expected value lives. The second is discarded at both call sites in the archive.

> ✅ **SDK-verified — GAP closed (2026-07-29).** The second parameter is the model's output value,
> typed **`Input.ExpectedValue`** — the full closure type is
> `(Input, Input.ExpectedValue) async throws -> [String : String]`
> (`Evaluations-27.0-macos.swiftinterface:361`). For `ModelSample<BookTags>` the discarded `_` is
> therefore the generated `BookTags` — the same value `evaluationTarget` receives — not a
> `ModelSubject`, as previously guessed. Discarding it stays reasonable: the framework already shows
> the judge the output, and repeating it in a reference section would duplicate it in the prompt.
> Reach for it when the reference section should *react* to the output — say, listing only the
> expected tags the model missed.

**The `?? "No expected tags defined"` is deliberate.** A prompt-only sample with no `expected` value
still gets a reference section, and it says so in words the judge can act on. The alternative —
returning `[:]` — is also legal and Apple's documentation shows it:

```swift illustrative
reference: { input, _ in
    guard let expected = input.expected else { return [:] }
    return ["Expected Tags": expected.tags.joined(separator: ", ")]
}
```

Prefer Apple's sample's version. An explicit "no expected tags defined" is a fact; a silently absent
section is a difference between prompts that you cannot see in the report.

### 8.3 What good instructions contain

> ✅ **VERIFIED** — `/documentation/evaluations/designing-effective-model-judges`, verbatim: good
> instructions have three parts —
> - *"A **role** that frames the judge's expertise"*
> - *"**Criteria** that list the specific dimensions to assess"*
> - *"**Evaluation steps** that give the judge a procedure to follow before assigning a score"*
>
> and the reason for the third: *"Including steps promotes consistent evaluation by **preventing the
> model as judge from jumping to a score based on a first impression.**"*

Here is that structure applied, written out at the length a real judge prompt runs to. This is our
composition of Apple's documented three-part rule with the vocabulary from the Book Tracker sample —
the *structure* is Apple's, the specific prose is ours:

```swift prelude:guide-context
let bookTagJudgePrompt = ModelJudgePrompt<ModelSample<BookTags>>(
    instructions: """
        ROLE
        You are a professional librarian who catalogues a personal book collection. You care about
        whether someone browsing their own shelves six months from now can find a book again.

        CONTEXT
        These tags appear in a personal library app. They are used to browse and filter a
        collection the reader already owns. This is not a review site: the tags are not opinions
        about whether a book is good, and no one will ever search their own library for
        "overrated".

        CRITERIA
        - Relevance: does each tag describe the book itself — its genre, themes, setting, tone —
          rather than the reader's reaction to it or a phrase lifted verbatim from the review?
        - Usefulness: would each tag work as a browsing filter? Established vocabulary a reader
          would think to type is useful; a phrase so specific that it applies to one book is not.

        EVALUATION STEPS
        1. Read the review and form your own idea of what the book is about.
        2. Take each generated tag in turn. Decide whether it describes the book or the reader.
        3. Take each tag again. Decide whether you would ever click it as a filter.
        4. Only then assign a score for each dimension, using the scale descriptions.
        Score Relevance and Usefulness independently, even when one tag affects both.
        """,
    evaluationTarget: { value in
        "\(value.tags.count) Generated tags: " + value.tags.joined(separator: ", ")
    },
    reference: { input, _ in
        ["Expected Tags": input.expected?.tags.joined(separator: ", ")
            ?? "No expected tags defined"]
    }
)
```

Note that the *review itself* is nowhere in that prompt. The framework supplies the feature input
from the `ModelSample`; you do not interpolate it yourself. Doing so would duplicate it in the
prompt, which wastes context and sometimes causes the judge to score the second copy.

> ⚠️ **SILENT FAILURE — a judge with no context returns confident, wrong, stable numbers.** If you
> omit `ModelJudgePrompt` entirely, the evaluator falls back to `defaultInstructions` and rates the
> response against your scale anyway. Nothing throws. Nothing warns. You get a full column of
> plausible 3s and 4s produced by a model that does not know what your app is, and — worse — those
> numbers will be *consistent*, so a low variance will read as a well-behaved judge. The tell is in
> the rationales: a context-free judge writes generic praise ("the tags are descriptive and
> appropriate") rather than app-specific reasoning ("`quiet-steadiness` is unlikely to be used as a
> browsing filter"). **Read the rationales on your first run, always. If you have not read them, you
> do not know whether your judge is working.**

---

## 9. Rationales are the debugging loop

> ✅ **VERIFIED** — `298:230-231`: *"**With model judges, rationales are essential. They give you a
> window into why the judge scored what it scored.**"*

> ✅ **VERIFIED** — `/documentation/evaluations/designing-effective-model-judges`: *"When the model as
> judge scores a response, **it also produces a written rationale explaining its reasoning. These
> rationales appear in the detailed results alongside the score for each sample.** When scores seem
> wrong or inconsistent, the rationales usually show you why."*

And the advice that should govern how you spend your first hour:

> ✅ **VERIFIED** — `298:279-281`: *"**Start simple with your model judge. Define your scoring
> dimension, run it, and read the rationales. You'll learn more from a single run than from hours of
> careful planning.**"*

That sentence is not a platitude. Judge behaviour is not predictable from the prompt by inspection —
you cannot reason your way to the right rubric, because the whole problem is that words like
"relevant" mean something slightly different to the judge than to you, and the *only* way to find out
what they mean to the judge is to look at what it did with them.

### 9.1 Where the rationales are

The Xcode 27 Evaluations report, reached the same way for judge metrics as for heuristic ones:

> ✅ **VERIFIED** — `298:103-111` and `335:56-58`: run the test, open the **report navigator**, select
> **Evaluations** under the test report, double-click the suite row. *"On the top are our aggregate
> metric charts. And below is our table of results."* Select a row in the table and the **assistant
> editor** shows the detail panel: *"The detail panel shows the prompt, and each measurement for the
> `ModelSample`. At the bottom, you see the entire response from the model."*

Programmatically, they are on the `Metric` (`var rationale: String?`) and reachable through the
`detailed` DataFrame:

> ✅ **VERIFIED** — `/documentation/evaluations/evaluationresult` and its documented example: the
> per-sample frame supports two subscript forms, `result.detailed[someResultColumn]` and
> `result.detailed[metric: someMetric]`.

```swift illustrative
@Test("Book Tag Evaluations", .evaluates(evaluation, info: evaluationInfo))
func evaluateBookTagging() async throws {
    let result = EvaluationContext.current.result

    // Print every judge rationale where Relevance came in below 3.
    let inputs = result.detailed[Self.evaluation.inputColumn]
    let scores = result.detailed[metric: Self.evaluation.relevance.metric]

    for row in 0..<scores.count {
        guard let metric = scores[row], let value = metric.doubleValue, value < 3 else { continue }
        let prompt = inputs[row]?.promptDescription ?? "<missing>"
        print("[\(value)] \(prompt.prefix(60))…\n    \(metric.rationale ?? "<no rationale>")")
    }

    #expect(result.aggregateValue(.mean(of: Self.evaluation.relevance.metric)) >= 3.0)
}
```

> 🟡 **RECONSTRUCTED** — the loop body above composes verified pieces: `EvaluationContext.current.result`,
> the two subscript forms, `inputColumn`, `metric.rationale`, `metric.doubleValue` and
> `aggregateValue(.mean(of:))` are each individually documented, and the surrounding structure follows
> Apple's own `inspectDetailedResults` example verbatim in shape. The specific filter is ours. Note
> `doubleValue` is documented as optional-ish (*"or … for ignored metrics"*), hence the `guard`.

### 9.2 Reading a rationale, worked

Session 298's diagnostic moment, verbatim:

> ✅ **VERIFIED** — `298:227-229`: *"The model judge gave this a quality score of 3. If we look at the
> rationale, we can identify that the model flagged 'whodunit' and 'detective-fiction' as not relevant
> to the book. But, we also expected it to flag all of these other tags that either reflect the
> reader's opinion or are not helpful for browsing."*

The reading procedure that generalises from that:

1. **Does the rationale cite specific items from the output?** If it says "the tags are appropriate",
   your judge is not actually looking. Sharpen the anchors (§5.2) or add evaluation steps (§8.3).
2. **Does it flag *some* of what you would flag?** Then the rubric is under-specified in a knowable
   direction — the judge caught relevance failures and missed usefulness failures, which is the
   signal to split (§7).
3. **Does it flag things you would not?** Then it is *over*-applying a criterion, usually because an
   anchor is stricter than you meant. Session 335 hits exactly this: *"I noticed that all the scores
   are either a 3 or 2, which is way too harsh"* (`335:183`).
4. **Are all the rationales the same shape?** Uniform reasoning means a broad question. Split.

And then the framing sentence that turns this into a loop rather than an argument:

> ✅ **VERIFIED** — `298:236-237`: *"By asking the model to provide judgement for my feature, in my
> place, I expected it to provide a similar score to how I would have scored these tags. **When there
> is a mismatch between the model judge and us, we can refine the model judge until it can stand in
> for our own judgement.**"*

"Until it can stand in for our own judgement" is a testable claim, and §16 is the test.

---

## 10. Pairwise judging

Everything so far is *pointwise*: score this output on its own merits. There is a second mode, and it
is better suited to the question you actually ask during a hill-climb — "is the new prompt better than
the old one?"

> ✅ **VERIFIED** — `/documentation/evaluations/modeljudgeevaluator`:
>
> ```swift
> static func pairwise(_:scale:judge:scoringMode:evaluationTarget:)
> static func pairwise(judge:dimensions:scoringMode:evaluationTarget:)
> ```
>
> and the semantics, verbatim: *"Unlike pointwise evaluation, the pairwise method uses its own
> built-in prompt and **automatically sends the sample's `expected` value to the model as judge as the
> baseline.**"*

```swift prelude:guide-context
var evaluators: Evaluators {
    ModelJudgeEvaluator.pairwise(
        "ExplanationComparison",
        scale: .numeric([
            4: "Response is significantly clearer, more accurate, and more engaging than the baseline.",
            3: "Response is noticeably better than the baseline in most areas.",
            2: "Baseline is noticeably better than the response in most areas.",
            1: "Baseline is significantly clearer, more accurate, and more engaging than the response.",
        ]),
        judge: SystemLanguageModel.default
    )
}
```

> ✅ **VERIFIED** — verbatim from `/documentation/evaluations/scoring-with-model-as-judge-evaluators`.

Three properties you have to know before using it:

**The scale has no midpoint, on purpose.**

> ✅ **VERIFIED**: *"A score of 4 means the response is much better than the baseline, and a score of
> 1 means the baseline is much better. **The 1–4 scale has no neutral midpoint, so the judge has to
> decide which side of the comparison wins on every sample.**"*

**The aggregate reads against 2.5, not against a pass rate.**

> ✅ **VERIFIED**: *"**A mean score above 2.5 indicates the model's responses are generally better
> than the baselines. A mean score below 2.5 indicates regressions. Scores near 2.5 suggest comparable
> quality.**"*

**`instructions` and `reference` do not apply.**

> ✅ **VERIFIED** — `/documentation/evaluations/modeljudgeprompt`: *"Pairwise evaluation **builds its
> own prompt internally**. The `instructions` and `reference` components **only apply to pointwise
> evaluators.** Pairwise evaluation supports `evaluationTarget` through its own parameter."*

That last one is a trap with a very quiet failure mode: if you pass a `ModelJudgePrompt` full of
carefully-written app context to a pairwise evaluator, **the instructions are ignored** and you get
Apple's built-in comparison prompt instead. The scores will look fine. Nothing will tell you your
context was dropped. Which is why the pairwise statics take `evaluationTarget:` as a *direct
parameter* rather than a prompt — the API shape is trying to warn you.

### 10.1 Pointwise or pairwise?

| Question | Mode |
|---|---|
| "Is this output good?" | pointwise |
| "Did my prompt change make things better?" | pairwise, with the old output as `expected` |
| "Can I track quality over months of OS updates?" | pointwise — pairwise has no fixed origin |
| "Do I need per-dimension diagnosis?" | pointwise; pairwise dimensions exist but collapse to better/worse |
| "Am I calibrating the judge against a human?" | **pointwise** — κ needs absolute ratings on both sides |

The last row is the important one for the rest of this guide. Everything from §12 onward requires the
judge and the human to produce *comparable absolute scores on the same scale*, so the alignment
evaluation is necessarily pointwise. Apple's `HillClimbingEvaluations` target uses the pointwise
`init(judge:dimensions:)` accordingly.

Note also that pairwise is a *different* answer to the same problem as Xcode's Compare view. Compare
diffs two pointwise runs; pairwise asks one judge to weigh two outputs side by side within one run.
Apple's sessions demonstrate the Compare route, not the pairwise route, so the pairwise material here
is documentation-sourced and has no worked precedent in the sample archive.

---

## 11. Mixing judges and code evaluators

Because they are the same protocol, one `Evaluation` can carry both, and the documentation shows the
canonical two-group aggregation:

> ✅ **VERIFIED** — `/documentation/evaluations/designing-effective-model-judges`, verbatim:

```swift illustrative
private let nonEmpty = Metric("NonEmpty")
private let quality = Metric("Quality")

var evaluators: Evaluators {
    Evaluator { input, subject in
        return subject.value.isEmpty ? nonEmpty.failing() : nonEmpty.passing()
    }
    ModelJudgeEvaluator(
        "Quality",
        scale: .numeric([...]),
        judge: SystemLanguageModel.default,
        prompt: ModelJudgePrompt(instructions: """...""")
    )
}

func aggregateMetrics(using aggregator: inout MetricsAggregator) {
    aggregator.group("Validation") { group in
        group.computeMean(of: nonEmpty)
    }
    aggregator.group("Judge") { group in
        group.computeMean(of: quality)
    }
}
```

Note the single-dimension initialiser here: `ModelJudgeEvaluator("Quality", scale:judge:prompt:)`
declares its name and scale inline rather than through a `ScoreDimension`. Use it when you have
exactly one qualitative criterion; move to `dimensions:` the moment you have two, because that is the
form that gets you both scores from one inference.

### 11.1 Why the grouping matters more than it looks

Grouping is not cosmetic. `aggregator.group(_:)` produces the headings in the Xcode report and in
`EvaluationResult.groupedSummary`, and it is what lets you scan a run in five seconds: *Heuristics*
all green, *Quality* dropped from 3.4 to 3.1. Book Tracker groups by `"Heuristics"` and `"Quality"`;
the κ evaluation groups by `"Relevance"` and `"Usefulness"` so each dimension's mean, standard
deviation and alignment score sit together.

### 11.2 The full aggregator surface

> ✅ **VERIFIED** — `/documentation/evaluations/metricsaggregator`:
>
> ```swift
> struct MetricsAggregator
> func computeMean(of:)
> func computeMedian(of:)
> func computeMode(of:)
> func computeMinimum(of:)
> func computeMaximum(of:)
> func computeStandardDeviation(of:)
> func computeVariance(of:)
> func custom(of:label:_:)   // "Computes a custom aggregation from a single metric's results."
> func group(_:_:)
> struct MetricsAggregator.Group
> ```
>
> ✅ **SDK-verified** — that is the complete public surface: the interface shows exactly those nine
> members on `MetricsAggregator`, and the same eight compute/custom methods again on
> `MetricsAggregator.Group` (`Evaluations-27.0-macos.swiftinterface:734-761`). The absence of an
> agreement statistic is no longer an inference from a documentation member list; it is the shipped
> interface, checked 2026-07-29.

There is no `computeCorrelation`, no `computeAgreement`, and **no kappa**. `custom(of:label:_:)` is
the extension point, and §15 is what you put in it.

### 11.3 Always pair a mean with a spread

A judge metric summarised by its mean alone can hide the degenerate case completely. This is the same
lesson the `Tag Count` heuristic taught in guide 01 — a 100% pass rate produced by generating exactly
eight tags every time — transposed into the qualitative half:

- A judge that scores everything **4** has a mean of 4.0 and a standard deviation of 0.
- A judge that scores half the samples 4 and half 2 also has a mean of 3.0 with visible spread.
- A judge that is *actually working* has a distribution that looks like your dataset's quality
  distribution.

Apple's κ evaluation computes mean **and** standard deviation for each dimension for exactly this
reason:

> ✅ **VERIFIED** — `335:126-129`: *"In addition to just Cohen's kappa, I'll also calculate the
> **mean and standard deviation of each score dimension. This will be helpful to know if the scores of
> the judge are going up or down.**"* Confirmed in code at `ModelJudgeAlignmentEvaluation.swift:303-332`,
> where each group calls `computeMean`, `computeStandardDeviation` and `custom` on the same metric.

A zero standard deviation on a judge metric is not a clean result. It is a broken judge.

---

## 12. Drift

Everything up to here assumed the judge is a reasonable proxy for you. This section and the four that
follow are about proving it, and they are the most intellectually demanding material in this series.

### 12.1 The definition

> ✅ **VERIFIED** — `335:72`: *"**This discrepancy between model and human is known as drift, and it
> is a problem faced by all developers trying to evaluate intelligent features.**"*

Note what drift is *not*. It is not model drift in the MLOps sense (a deployed model degrading as the
world changes), and it is not the OS-update problem where Apple ships a new on-device model under you.
Both of those are real and both are covered elsewhere in this series. **Drift here is a property of
the measuring instrument**: a systematic, reproducible disagreement between your judge and your
expert.

### 12.2 The mechanics, and the part that should alarm you

> ✅ **VERIFIED** — `335:74-79`: *"Say I have an evaluation with 10 samples. I then ask a model judge
> and a person to rate each sample. The model and person then give their ratings on a scale from 1 to
> 4, and at the end we average those scores to build an aggregate. **If the model and the human tend
> to disagree in their ratings, then their average scores will diverge from one another, hence the
> name drift. As your data set continues to grow and grow the drift will get wider and wider. At which
> point, it'll be hard for you to know whether or not your feature is being properly evaluated.**"*

Read that penultimate sentence again: **"as your dataset continues to grow, the drift will get wider
and wider."** This is the property that makes drift dangerous rather than merely annoying, and it
inverts the intuition you brought from unit testing, where more test cases straightforwardly means
more confidence.

Here is why it happens. A judge with a systematic bias — say, it rates over-specific tags one point
more generously than you do — produces an error on every sample that exhibits that pattern. With 13
samples, maybe two exhibit it, and the aggregate is off by 2/13 of a point: invisible. With 1,000
samples generated by `SampleGenerator` to maximise coverage, hundreds exhibit it, because coverage is
exactly what surfaces edge cases. The bias does not average out — it is a *bias*, not noise. It
accumulates.

The concrete consequence, which session 299 demonstrates in the opposite direction:

> ✅ **VERIFIED** — `299:100-102`: *"I've went ahead and ran the evaluation with our new dataset of
> 100 samples. Now, we can compare the two evaluations using the Compare button and **we're expecting
> the scores to drop!** And we were correct! The quality scores have dropped. **Our tag generation
> feature looked like it was performing well earlier because we weren't testing it with a
> comprehensive dataset.**"*

When you go from 13 to 100 samples and the scores move, you have two competing explanations and no way
to distinguish them from the aggregate alone:

1. Your **feature** performs worse on the harder samples. (Good news: your evaluation is working.)
2. Your **judge** disagrees with you more on the harder samples. (Bad news: your evaluation is lying,
   and every decision you make from here is downstream of a broken instrument.)

Nothing in the score tells you which. That is what the alignment evaluation is for, and it is why the
sequencing matters: **calibrate the judge before you scale the dataset**, or you will spend a week
hill-climbing a feature against a ruler that was never straight.

> ⚠️ **SILENT FAILURE — drift never throws, never warns, and gets worse as you do the right thing.**
> Growing your dataset is unambiguously good practice, and it is also the thing that turns a small,
> invisible judge bias into a large, invisible one. There is no API that will tell you this is
> happening. The only detector is the κ evaluation in §16, and it is not automatic — you have to build
> it.

### 12.3 The disagreement, on record

Apple's session 335 shows the developer's own ratings against the judge's, and it is worth having the
numbers because they show that drift is usually *dimension-specific*:

> ✅ **VERIFIED** — `335:65-66` (*Treasure Island*): *"I would have scored these tags a **4 for
> relevance and a 2 for usefulness**. My model judge also gave the tags a relevance score of 4 which is
> great, but it also gave usefulness a score of 4, which isn't right."*
>
> `335:70` (*Little Women*): *"Once again, I think relevance should be a 4 and usefulness should be a 2."*

| Sample | Human relevance | Judge relevance | Human usefulness | Judge usefulness |
|---|---|---|---|---|
| *Treasure Island* | 4 | 4 | 2 | 4 |
| *Little Women* | 4 | (4) | 2 | (high) |

Relevance is aligned. Usefulness is not, and it is wrong in a consistent direction — the judge is
*too generous* about whether an over-specific tag would work as a browsing filter. That is a bias, it
is diagnosable, and it is fixable by editing the usefulness anchors. But you cannot see it from the
means, because a mean usefulness of 3.6 looks like a perfectly healthy feature.

### 12.4 Why you cannot just look at the numbers

The obvious move — compare the judge's mean to your mean — fails for a reason that is easy to miss.
Two raters can produce **identical means and disagree on every single sample**. If the judge scores
sample A a 4 and sample B a 2, and you score A a 2 and B a 4, both means are 3.0. Perfect apparent
agreement, zero actual agreement.

You need a *per-sample* comparison, which is what the next two sections build.

---

## 13. Why accuracy is the wrong alignment measure

The natural per-sample comparison is: count the samples where the two ratings match, divide by the
total. Apple names it and then dismantles it.

> ✅ **VERIFIED** — `335:82-84`: *"One way to accomplish this would be to line up the ratings of the
> expert and mark where the two match. You can then use this to generate a percentage. **This
> percentage is called accuracy, and it is a great way to measure alignment if every value in your
> scoring scale is equally likely to appear.**"*

That conditional is the whole argument. And then:

> ✅ **VERIFIED** — `335:85-89`: *"**However, it's more likely that your dataset will contain values
> that have an uneven distribution of scores. Think about it, datasets often contain examples of high
> quality output. Therefore it is often the case that a human rater is likely to rate items in the
> dataset with higher scores. If a model then happens to judge your smaller dataset with high scores,
> it may seem like the two are aligned. But then when unleashed on a larger dataset with more
> variations in scores, it's tendency to score high will still result in drift.**"*

### 13.1 Work the arithmetic, because the size of the effect is surprising

Take a 30-sample dataset where the expert rated **24 samples a 4** and six spread across 1–3. This is
not a contrived distribution; it is what you get when you hand-write samples from books you like, and
it is what you get when a generator produces samples the feature handles well.

Now consider a **completely useless judge that returns 4 for everything.**

- Exact agreement: 24 of 30 = **80%.**
- On a bar chart next to your 0.8 pass-rate thresholds: looks great.
- Actual information content: zero. The judge has not looked at anything.

Now scale to 1,000 samples with better coverage. The proportion of genuinely-4 samples falls to, say,
55% because the generator found the hard cases. The same useless judge now scores **55%** — and you
will read that fall as *the feature regressed*, because that is what a falling number normally means.
It did not. Your instrument was always broken; the dataset just stopped flattering it.

This is drift in its purest form, and it is why the alignment measure has to discount for luck:

> ✅ **VERIFIED** — `335:90`: *"So we need an alternative to accuracy, **one that accounts for the
> weighted nature of our dataset and the chance that the model might guess the right answer**."*

### 13.2 The uncomfortable corollary about your dataset

*"Datasets often contain examples of high quality output"* deserves more attention than it usually
gets. Your evaluation dataset is skewed toward good output for at least four structural reasons:

1. **You wrote the samples**, and you naturally wrote ones your feature handles.
2. **You wrote the `expected` values**, which anchor both the generator and the judge.
3. **`SampleGenerator` seeds from your existing samples** as in-context examples, so it inherits and
   amplifies whatever distribution you started from. (See guide 03 in this part on `samplingStrategy`.)
4. **Failures get fixed.** The moment you find a bad case you improve the feature, so the dataset's
   quality distribution ratchets upward over the life of the project.

Every one of those is good practice. Together they guarantee the exact condition under which accuracy
is a bad alignment measure. You do not get to opt out of this.

---

## 14. Cohen's kappa

### 14.1 Provenance and definition

> ✅ **VERIFIED** — `335:91-92`: *"**Cohen's kappa coefficient is a mathematical formula made popular
> by statistician and psychologist Jacob Cohen in 1960.** … **Cohen's kappa measures alignment, that
> is how often do two raters agree.**"*

> ✅ **VERIFIED** — `335:93-97`: *"To do that, we need to know **what percentage of the time the
> raters agreed, better known as accuracy** … But now we need to calculate a new value.
> **Coincidence, which represents the chance that one rater might get lucky and happen to align. This
> luck is then weighted based on the chances certain answers are more likely to appear.**"*

### 14.2 The formula

> ✅ **VERIFIED** — `335:98-101`, narrated step by step: *"To calculate alignment, we start with our
> **accuracy** score. From the accuracy score we **subtract the possibility of two raters randomly
> agreeing**. Finally, we **divide the difference by the inverse of random agreement, namely the chance
> that the two raters intentionally agreed**. The result of that gives us alignment."*

```
                accuracy − p_chance
        κ  =  ─────────────────────
                   1 − p_chance

where
  accuracy   = fraction of samples on which the two raters gave the same score
  p_chance   = probability the two raters agree by luck alone, computed from the
               marginal distribution of each rater's scores:

                 p_chance = Σ  P_judge(k) · P_expert(k)
                            k

               i.e. for each score level k, multiply the fraction of samples the
               judge assigned k by the fraction the expert assigned k, and sum.
```

Read the formula as a **normalisation**: the numerator is how much better than luck you did, and the
denominator is how much better than luck you *could have* done. κ = 1 is perfect agreement, κ = 0 is
exactly chance, and κ < 0 means the raters agree less often than random assignment would — which is
rare and always worth investigating, because it usually means an inverted scale somewhere.

Apply it to the useless judge from §13.1:

- The judge assigns 4 to 100% of samples, so `P_judge(4) = 1.0` and every other `P_judge(k) = 0`.
- The expert assigned 4 to 80%, so `P_expert(4) = 0.8`.
- `p_chance = 1.0 × 0.8 = 0.8`.
- `accuracy = 0.8`.
- `κ = (0.8 − 0.8) / (1 − 0.8) = 0 / 0.2 = **0**.`

Eighty percent accuracy, zero kappa. That is the whole point of the statistic, in one line of
arithmetic.

### 14.3 The 0.6 bar

> ✅ **VERIFIED** — `335:131-134`: *"For this test, I've set an expectation that **my ratings and the
> judges ratings should produce an alignment score of 0.6. We've chosen this number because according
> to statisticians, an alignment score of 0.6 represents a meaningful level of agreement.**"*

> ✅ **VERIFIED** — Apple's sample asserts it strictly greater than, not greater-or-equal
> (`ModelJudgeAlignmentEvaluation.swift:344-352`):
>
> ```swift
> #expect(result.aggregateValue(.custom(label: "Relevance Alignment Score")) > 0.6)
> #expect(result.aggregateValue(.custom(label: "Usefulness Alignment Score")) > 0.6)
> ```

0.6 is the conventional boundary of "substantial agreement" in the inter-rater-reliability literature,
and Apple adopts it without further justification. Treat it as a floor for *shipping decisions*, not a
target to optimise toward — see §18 for why pushing κ higher and higher is actively dangerous.

### 14.4 Two ways κ misleads, neither of which Apple mentions

These are analytic observations about the statistic, not claims about Apple's API. They matter because
you will hit both.

**The prevalence paradox.** When one score level dominates the dataset, κ is *pessimistic*: high
accuracy can coexist with near-zero κ, because `p_chance` is nearly as high as accuracy. This is the
inverse of the problem κ was introduced to solve, and it means that on a very skewed dataset a genuinely
decent judge can fail the 0.6 bar. The diagnostic is simple: if accuracy is high, κ is low, and the
score distribution is lopsided, **fix the dataset before you touch the judge.** Add samples that
exercise the low end of the scale. A dataset with no bad outputs in it cannot calibrate a judge's
ability to recognise bad outputs.

**Unweighted κ treats all disagreements as equal.** Standard Cohen's kappa is a *nominal* statistic.
Judge 4 / expert 3 counts exactly as much as judge 4 / expert 1. But your scale is **ordinal** — the
levels are ordered, and being off by one is meaningfully better than being off by three. Apple's
sample uses plain, unweighted κ.

> 🔴 **GAP — Apple's corpus contains no mention of weighted kappa.** Not in the sessions, not in the
> documentation, not in the sample. `Statistics.cohensKappa(ratings1:ratings2:)` takes no weighting
> parameter. Whether Apple considered and rejected it is unknown.
>
> **What this means for you:** the unweighted statistic is what Apple's 0.6 bar was chosen against, so
> use it as your gate. If you want the extra diagnostic signal, compute a linearly- or
> quadratically-weighted κ *alongside* it as a second `custom` aggregation and read them together — a
> big gap between unweighted and weighted κ tells you your judge is usually close but rarely exact,
> which is a completely different problem from a judge that is wildly wrong on a subset. §15.3 gives
> the implementation. Do not silently substitute weighted κ for unweighted and then compare against
> 0.6; they are not the same scale.

---

## 15. Implementing kappa — the framework does not ship it

### 15.1 The correction

> ⚠️ **CORRECTION, and the most important one in this guide.** A reader who watches session 335 will
> come away believing Cohen's kappa is a built-in aggregation, because the session discusses it at
> length as a first-class part of the workflow and never says otherwise. **It is not in the
> framework.**
>
> ✅ **VERIFIED** — the Book Tracker archive contains
> `HillClimbingEvaluations/Statistics.swift`, **72 lines**, whose sole job is `cohensKappa`. It is
> called as `Statistics.cohensKappa(ratings1: expertRelevance, ratings2: judge) ?? 0`
> (`ModelJudgeAlignmentEvaluation.swift:303-332`).
>
> ✅ **VERIFIED** — `MetricsAggregator`'s complete documented member list is `computeMean`,
> `computeMedian`, `computeMode`, `computeMinimum`, `computeMaximum`, `computeStandardDeviation`,
> `computeVariance`, `custom(of:label:_:)`, `group(_:_:)`. **There is no agreement statistic of any
> kind.** No correlation, no κ, no ICC. (Confirmed against the shipped interface, 2026-07-29:
> `Evaluations-27.0-macos.swiftinterface:734-761`.)
>
> ✅ **VERIFIED** — the session itself is consistent with this once you listen closely (`335:127`):
> *"we need to calculate Cohen's kappa, which I can do that with a **custom aggregation method**."*
> "Custom aggregation method" is the API telling you to bring your own.

Two facts follow from the attested call site, and they constrain any implementation you write:

- **The signature is `cohensKappa(ratings1:ratings2:) -> Double?`** — it returns an *Optional*, so
  there is a degenerate input for which it declines to produce a number.
- **The arguments are two arrays of `Double`**, positionally paired.

### 15.2 A complete implementation

> 🟡 **RECONSTRUCTED — this is our code, not Apple's.** We have read the call site and the file's
> length; we have **not** read the 72 lines of `Statistics.swift`. What follows computes the standard
> unweighted Cohen (1960) κ exactly as narrated in `335:98-101`, and it matches the attested signature
> so it is a drop-in for Apple's call site. Where our implementation makes a choice the transcript
> does not constrain — how to bucket continuous scores, what to return for degenerate input — the
> choice is flagged in a comment. **Do not assume Apple's 72 lines are byte-identical to this.**

```swift compile:27
import Foundation

/// Inter-rater agreement statistics.
///
/// Cohen's kappa is NOT provided by the Evaluations framework. This is the
/// standard 1960 formulation, wired in through `MetricsAggregator.custom(of:label:)`.
enum Statistics {

    /// Unweighted Cohen's kappa for two raters over the same ordered set of items.
    ///
    /// - Parameters:
    ///   - ratings1: one rater's score per item, in item order.
    ///   - ratings2: the other rater's score per item, in the SAME item order.
    /// - Returns: κ in `[-1, 1]`, or `nil` when it is undefined — see the notes below.
    ///
    /// Returns `nil` when:
    ///   * the arrays are empty or of different lengths (a programming error, not a result), or
    ///   * expected agreement is 1.0, which happens when both raters assigned every item the
    ///     same single category. Accuracy is then 100% and the formula divides by zero. This
    ///     is NOT perfect agreement — it is no information at all, and it must not be reported
    ///     as κ = 1.
    static func cohensKappa(ratings1: [Double], ratings2: [Double]) -> Double? {
        guard !ratings1.isEmpty, ratings1.count == ratings2.count else { return nil }

        let n = Double(ratings1.count)

        // Bucket to integral categories. Scores come from a `.numeric` scale whose keys
        // are whole numbers, but they arrive as Double, so round rather than compare
        // floating-point values for equality.
        let a = ratings1.map { Int($0.rounded()) }
        let b = ratings2.map { Int($0.rounded()) }

        // Observed agreement — Apple's "accuracy".
        let agreements = zip(a, b).reduce(0) { $0 + ($1.0 == $1.1 ? 1 : 0) }
        let observed = Double(agreements) / n

        // Marginal distributions, over the union of categories either rater used.
        var countsA: [Int: Double] = [:]
        var countsB: [Int: Double] = [:]
        for value in a { countsA[value, default: 0] += 1 }
        for value in b { countsB[value, default: 0] += 1 }

        // Expected agreement by chance — Apple's "coincidence", weighted by prevalence.
        let categories = Set(countsA.keys).union(countsB.keys)
        let expected = categories.reduce(0.0) { partial, category in
            let pA = (countsA[category] ?? 0) / n
            let pB = (countsB[category] ?? 0) / n
            return partial + pA * pB
        }

        // κ = (observed − expected) / (1 − expected)
        let denominator = 1.0 - expected
        guard denominator > 1e-12 else { return nil }   // undefined, not perfect
        return (observed - expected) / denominator
    }
}
```

The `guard denominator > 1e-12 else { return nil }` is the reason the real signature returns an
Optional, and it is worth understanding rather than copying. If both raters assign 4 to all 30
samples, observed agreement is 1.0 and expected agreement is also 1.0. The formula is 0/0. It is
tempting to call that perfect agreement and return 1.0 — **do not.** Two raters who never vary have
demonstrated nothing about whether they would agree on a hard case, and returning 1.0 would let a
judge that always says 4 pass its own calibration test.

### 15.3 The weighted variant, if you want the extra signal

> 🟡 **RECONSTRUCTED — our code, standard statistics, no Apple precedent.** Nothing in Apple's corpus
> mentions weighted κ (see the GAP in §14.4). Report it *alongside* unweighted κ, never instead of it.

```swift prelude:guide-context
extension Statistics {

    enum KappaWeighting {
        case linear      // penalty grows with |i − j|
        case quadratic   // penalty grows with (i − j)², so near-misses barely count
    }

    /// Weighted Cohen's kappa for ORDINAL scales, where being off by one is
    /// meaningfully better than being off by three.
    static func weightedCohensKappa(
        ratings1: [Double],
        ratings2: [Double],
        weighting: KappaWeighting = .linear
    ) -> Double? {
        guard !ratings1.isEmpty, ratings1.count == ratings2.count else { return nil }

        let n = Double(ratings1.count)
        let a = ratings1.map { Int($0.rounded()) }
        let b = ratings2.map { Int($0.rounded()) }

        let categories = Array(Set(a).union(b)).sorted()
        guard categories.count > 1 else { return nil }
        let index = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($1, $0) })
        let span = Double(categories.count - 1)

        func disagreement(_ i: Int, _ j: Int) -> Double {
            let d = abs(Double(i - j)) / span
            switch weighting {
            case .linear:    return d
            case .quadratic: return d * d
            }
        }

        // Observed disagreement.
        var observed = 0.0
        for (x, y) in zip(a, b) {
            observed += disagreement(index[x]!, index[y]!)
        }
        observed /= n

        // Expected disagreement from the marginals.
        var countsA = [Int: Double](), countsB = [Int: Double]()
        for value in a { countsA[value, default: 0] += 1 }
        for value in b { countsB[value, default: 0] += 1 }

        var expected = 0.0
        for x in categories {
            for y in categories {
                let pA = (countsA[x] ?? 0) / n
                let pB = (countsB[y] ?? 0) / n
                expected += pA * pB * disagreement(index[x]!, index[y]!)
            }
        }

        guard expected > 1e-12 else { return nil }
        return 1.0 - (observed / expected)
    }
}
```

Reading the pair together:

| Unweighted κ | Weighted κ | Interpretation |
|---|---|---|
| low | **high** | The judge is usually within one level but rarely exact. Sharpen the anchor text between adjacent levels; the boundaries are fuzzy. |
| low | low | Genuine disagreement. Rewrite the dimension or add worked examples. |
| high | high | Aligned. Stop tuning. |
| high | low | Essentially impossible; if you see it, check your positional join (§19.1). |

### 15.4 Wiring it into the aggregator

> ✅ **VERIFIED** — `ModelJudgeAlignmentEvaluation.swift:303-332`, verbatim:

```swift illustrative
func aggregateMetrics(using aggregator: inout MetricsAggregator) {
    let expertRelevance = Self.samples.map { $0.expected?.expertRelevanceScore ?? 0.0 }
    let expertUsefulness = Self.samples.map { $0.expected?.expertUsefulnessScore ?? 0.0 }

    aggregator.group("Relevance") { group in
        group.computeMean(of: relevance.metric)
        group.computeStandardDeviation(of: relevance.metric)
        group.custom(
            of: relevance.metric,
            label: "Relevance Alignment Score"
        ) { judge in
            Statistics.cohensKappa(ratings1: expertRelevance, ratings2: judge) ?? 0
        }
    }
    …
}
```

The mechanism is worth stating precisely because everything downstream depends on it:

> ✅ **VERIFIED** — `custom(of:label:_:)` is documented as *"Computes a custom aggregation from a
> single metric's results."* The closure receives that metric's per-sample scores as **`[Double]` in
> dataset order** and returns a single `Double`. The label is a free string, and it is the same string
> you pass to `result.aggregateValue(.custom(label:))` to read the value back.

So the judge's ratings arrive from the framework, in dataset order, and the expert's ratings are
captured from `Self.samples` — *also* in dataset order. The join between them is **positional**, and
it is entirely your responsibility. §19.1 is about what happens when it is wrong.

---

## 16. The meta-evaluation, end to end

Here is the construction. You are going to write an `Evaluation` **whose subject is the judge**. The
framework does not know or care that the thing under test is one of its own evaluators; an
`Evaluation` is just "dataset → subject → evaluators → aggregate", and that shape fits this problem
exactly.

> ✅ **VERIFIED** — `335:106-110`: *"I need to write an evaluation, which is made up of four
> components. First is my dataset. Then the subject of my evaluation. Then, I need to define my
> evaluators. And finally, I need to aggregate my results."*

| Component | In a feature evaluation | In the alignment evaluation |
|---|---|---|
| `dataset` | prompts + expected outputs | **(review, generated tags, YOUR two ratings)** rows |
| `subject(from:)` | call the feature | **return the already-generated tags — no inference at all** |
| `evaluators` | heuristics + judge | **the same model judge, unchanged** |
| `aggregateMetrics` | means and pass rates | **mean, stddev, and Cohen's kappa vs. your ratings** |

The elegance is in the second row. By replaying frozen output, you remove the feature's
nondeterminism from the experiment entirely, so **the judge is the only variable.** That is what makes
this a controlled experiment rather than a vibe check.

### 16.1 Step 1 — get the data out of Xcode

You need the judge and yourself to score *the same tags for the same reviews*. Generating tags twice
would give you two different sets, so the tags have to be frozen.

> ✅ **VERIFIED** — `335:112-119`: *"For this evaluation to work properly, **both my model judge and I
> need to evaluate the exact same dataset**. In this case the model judge reviews tags, so I need to
> produce a **common set of tags** for the judge and I to review. My evaluation from before contains a
> collection of reviews and tags. **Because I ran this evaluation in a test, Xcode generated an
> attachment containing all of the evaluation data that was generated. I can retrieve that attachment
> and extract summary and tag pairs.** Now, with the summary and tag pairs extracted, **I need to add
> my ratings**. After that, I can pass the contents of this file as the input to my evaluation."*

The attachment is real, it is on disk, and Apple ships a command-line tool that parses it.

> ✅ **VERIFIED** — the Book Tracker archive contains a second command-line target,
> `DatasetExtractor/main.swift` (167 lines), which parses Xcode's evaluation result bundle. The
> on-disk format, which no session or documentation article describes:
>
> ```
> { "results": [ { "Input": "<escaped JSON string>",
>                  "Response": { "value": "<string>" }, … } ] }
> ```
>
> where the escaped `Input` string itself decodes to `{ "input": { "prompt": "…" } }`
> (`DatasetExtractor/main.swift:15-32`, `:94-131`). Default output path is
> `~/Desktop/<BaseName>-extracted.json` (`:153-162`). The tool depends on `swift-argument-parser`.

The extension is `.xcevalresult`. Apple's own description of the round trip:

> ✅ **VERIFIED** — `/documentation/evaluations/evaluationtrait`: the trait is *"A test trait that
> runs an evaluation and **records the result as attachments**."*

So the pipeline is:

```
run BookTaggingEvaluation in Xcode
        ↓  (the .evaluates trait attaches the full run)
export the .xcevalresult bundle from the report navigator
        ↓  swift run DatasetExtractor <bundle>
~/Desktop/BookTaggingEvaluation-extracted.json      ← reviews + generated tags
        ↓  a human opens it and adds two columns
BookTaggingEvaluation-extracted.json                ← + expertRelevanceScore, expertUsefulnessScore
        ↓  JSONLoader
JudgeAlignmentEvaluation.dataset
```

> ✅ **VERIFIED** — the fixture in `HillClimbingEvaluations/BookTaggingEvaluation-extracted.json` *is*
> the output of this pipeline with the expert columns added. That is the round trip that makes
> hill-climbing the judge possible, and it is the only mechanism in the corpus that gets model output
> in front of a human scorer at scale.

If you would rather not shell out to a CLI, `EvaluationResult` can serialise itself directly, which is
the modern-looking alternative:

> ✅ **VERIFIED** — `/documentation/evaluations/evaluationresult`: `func saveJSON(to:includeReportMetadata:)`,
> `func jsonData(includeReportMetadata:jsonOptions:)`, `static func loadJSON(from:)`,
> `static func loadJSONLines(from:)`, plus `var detailed: DataFrame` and
> `func jsonRepresentableDataFrame(of:)`.

```swift prelude:guide-context
@Test("Book Tag Evaluations", .evaluates(evaluation, info: evaluationInfo))
func evaluateBookTagging() async throws {
    let result = EvaluationContext.current.result
    #expect(result.aggregateValue(.mean(of: Self.evaluation.tagCount)) >= 0.8)

    // Drop a copy where the calibration workflow can pick it up.
    // `saveJSON(to:)` takes a DIRECTORY; the framework names the file and returns its URL.
    let written = try result.saveJSON(to: URL.desktopDirectory, includeReportMetadata: false)
    print("run saved to \(written.path())")
}
```

> ✅ **SDK-verified signature, 🟡 unverified output shape.** The exact declaration is
> `@discardableResult func saveJSON(to directory: URL, includeReportMetadata: Bool = false,
> includeTranscripts: Bool = false) throws -> URL`
> (`Evaluations-27.0-macos.swiftinterface:581-597`, checked 2026-08-23; beta 5 added the defaulted
> `includeTranscripts:`) — the parameter is a
> **directory**, which is why the snippet above no longer appends a filename. What is still
> unverified is the *shape* of the JSON it writes: no sample calls it, and it is not necessarily the
> same layout as the `.xcevalresult` bundle `DatasetExtractor` parses. **If you need Apple's exact
> extractor format, use `DatasetExtractor`.**

### 16.2 Step 2 — score the rows yourself

There is no tooling for this and there does not need to be. Open the JSON, add two numbers per row.

Some hard-won advice about doing it well, since the quality of everything downstream is bounded by
this step:

- **Score before you look at the judge's scores.** Once you have seen a 4 you cannot unsee it. If
  your extract already contains judge scores, delete that column first.
- **Score in one sitting.** Your own rubric drifts across days, which shows up as unexplainable
  κ variance.
- **Write your reasoning for the rows you found hard.** Those sentences become the few-shot examples
  in §17's third iteration. Apple's calibration prompt contains six of them, each in the form
  *"Librarian: Relevance 4, Usefulness 4 / Why: …"*.
- **Deliberately include bad output.** A fixture with no 1s and no 2s in it cannot calibrate a judge's
  ability to recognise bad output, and it will trigger the prevalence paradox (§14.4).
- **30 rows is enough to start.** Session 298's dataset guidance — *"A focused dataset of 20 to 30
  samples is a great place to get started"* (`298:272-274`) — applies with more force here, because
  every row costs human minutes.

### 16.3 Step 3 — the frozen subject

This is the trick, and it is three lines.

> ✅ **VERIFIED** — `ModelJudgeAlignmentEvaluation.swift:166-169`, verbatim:
>
> ```swift
> func subject(from sample: ModelSample<BookTagJudgmentValue>) async throws -> ModelSubject<BookTagJudgmentValue> {
>     let value = sample.expected ?? .placeholder
>     return ModelSubject(value: value)
> }
> ```

> ✅ **VERIFIED** — `335:121`: *"Normally, the `subject` method is for calling API related to your
> feature, but **since the generated model responses are part of our dataset, we can simply return the
> already generated tags**."*

Note what `ModelSample<BookTagJudgmentValue>` implies: the *expected* type is not `BookTags` any more,
it is a richer type carrying the tags **and** the human scores, because `ModelSample<Value>` is generic
over the expected/output type and that is the only place per-sample data can live. Reconstructing it
from the two attested field names:

> 🟡 **RECONSTRUCTED** — the type name `BookTagJudgmentValue`, the field names `expertRelevanceScore`
> and `expertUsefulnessScore`, and the `.placeholder` static are all attested at
> `ModelJudgeAlignmentEvaluation.swift:166-169` and `:303-332`. The rest of the declaration below is
> inferred from those uses plus `ModelSample`'s documented `Codable` constraint.

```swift compile:27
struct BookTagJudgmentValue: Codable, Sendable {
    /// The tags a previous evaluation run generated — replayed verbatim, never regenerated.
    var tags: [String]

    /// The human expert's ratings for those tags, on the same 1–4 scale as the judge.
    var expertRelevanceScore: Double
    var expertUsefulnessScore: Double

    /// Used when a row somehow has no expected value. See the silent-failure note in §19.2.
    static let placeholder = BookTagJudgmentValue(
        tags: [], expertRelevanceScore: 0, expertUsefulnessScore: 0
    )
}
```

Because the whole point is that no inference happens in the subject, this evaluation is **fast and
deterministic on the feature side**. The only model calls in the entire run are the judge's — which is
exactly the isolation you want, and also why a 30-row calibration run finishes in the time a 30-row
feature evaluation spends on its first three samples.

### 16.4 Step 4 — the whole evaluation

Assembling the verified pieces into a compilable whole:

> 🟡 **RECONSTRUCTED at the file level, ✅ VERIFIED line by line.** `subject(from:)` (`:166-169`),
> the `ScoreDimension` pair (`:175-189`), `judge: SystemLanguageModel()` (`:213`), the aggregation
> block (`:303-332`), `@Suite(.serialized)` (`:337`) and the test body (`:344-352`) are each verbatim
> from Apple's file. The `JSONLoader` wiring and the `Self.samples` declaration are inferred from
> their use sites — Apple's file loads the same fixture, but we have not read those specific lines.

```swift prelude:external-module
import Evaluations
import Foundation
import FoundationModels
import Testing
@testable import BookTracker

struct ModelJudgeAlignmentEvaluation: Evaluation {

    // ── Dataset ────────────────────────────────────────────────────────────────
    // Rows extracted from a previous BookTaggingEvaluation run with DatasetExtractor,
    // then hand-annotated with the expert's ratings.
    static let samples: [ModelSample<BookTagJudgmentValue>] = loadExtractedFixture()

    var dataset = ArrayLoader(samples: ModelJudgeAlignmentEvaluation.samples)

    // ── Subject: no inference. Replay the frozen tags. ─────────────────────────
    func subject(
        from sample: ModelSample<BookTagJudgmentValue>
    ) async throws -> ModelSubject<BookTagJudgmentValue> {
        let value = sample.expected ?? .placeholder
        return ModelSubject(value: value)
    }

    // ── The dimensions under calibration ───────────────────────────────────────
    // Deliberately re-worded versus BookTags.swift — tuning this text IS the experiment.
    let relevance = ScoreDimension(
        "Relevance",
        description: """
            Whether each tag describes a quality, theme, or tone of the book itself
            rather than incidental details or the reader's personal reactions.
            """,
        scale: .numeric([
            4: "Every tag describes the book itself",
            3: "Most tags describe the book",
            2: "Some tags describe personal reactions",
            1: "Tags don't meaningfully describe the book"
        ])
    )

    let usefulness = ScoreDimension(
        "Usefulness",
        description: "Whether each tag works as a search term for browsing a personal library.",
        scale: .numeric([
            4: "Every tag would help someone find this book while browsing",
            3: "Most tags are useful for browsing but a couple are too narrow or generic",
            2: "About half the tags are useful; the rest are too narrow or generic",
            1: "The tags would not help someone browse a library"
        ])
    )

    // ── Evaluators: the SAME judge the feature evaluation uses ─────────────────
    var evaluators: Evaluators {
        ModelJudgeEvaluator(
            judge: SystemLanguageModel(),
            dimensions: [relevance, usefulness],
            prompt: calibrationJudgePrompt      // 67 lines, six worked examples — see §17.4
        )
    }

    // ── Aggregation: mean, spread, and κ against the expert ────────────────────
    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        let expertRelevance  = Self.samples.map { $0.expected?.expertRelevanceScore  ?? 0.0 }
        let expertUsefulness = Self.samples.map { $0.expected?.expertUsefulnessScore ?? 0.0 }

        aggregator.group("Relevance") { group in
            group.computeMean(of: relevance.metric)
            group.computeStandardDeviation(of: relevance.metric)
            group.custom(of: relevance.metric, label: "Relevance Alignment Score") { judge in
                Statistics.cohensKappa(ratings1: expertRelevance, ratings2: judge) ?? 0
            }
        }

        aggregator.group("Usefulness") { group in
            group.computeMean(of: usefulness.metric)
            group.computeStandardDeviation(of: usefulness.metric)
            group.custom(of: usefulness.metric, label: "Usefulness Alignment Score") { judge in
                Statistics.cohensKappa(ratings1: expertUsefulness, ratings2: judge) ?? 0
            }
        }
    }
}

@Suite("Model Judge Alignment", .serialized)
struct ModelJudgeAlignmentTests {
    static let evaluation = ModelJudgeAlignmentEvaluation()

    @Test("Judge Calibration", .evaluates(evaluation))
    func evaluateJudgeCalibration() async throws {
        let result = EvaluationContext.current.result

        // Both the judge and the expert must produce an alignment score of 0.6
        // for the judge to be considered calibrated.
        #expect(result.aggregateValue(.custom(label: "Relevance Alignment Score")) > 0.6)
        #expect(result.aggregateValue(.custom(label: "Usefulness Alignment Score")) > 0.6)
    }
}
```

Details in there that are easy to get wrong:

- **`static let evaluation` on the suite.** Not stylistic. The test body reaches the evaluation's
  `Metric` identities through it, and a fresh instance would carry different ones.
  ✅ VERIFIED — both of Book Tracker's suites do this (`BookTags.swift:149-167`,
  `ModelJudgeAlignmentEvaluation.swift:337-352`).
- **`.serialized` on the calibration suite.** ✅ VERIFIED at `:337`. Apple's tag-quality suite is not
  serialised; the calibration suite is. The reason is not stated. Our reading: the alignment run's
  meaning depends on judge inferences being comparable to each other, and concurrent model calls
  contend for the same on-device resource. Treat it as cargo worth carrying.
- **`.custom(label:)` reads back by the exact same string** you wrote in `custom(of:label:)`. There is
  no compiler check. A typo yields whatever `aggregateValue` returns for a missing label, and your
  `#expect` then tests nothing.
- **`?? 0` on the κ call** — see §19.3.
- **The test asserts, it does not iterate.** ✅ VERIFIED — *"the trait runs the whole dataset before
  the test body, and the body is an assertion over the aggregate."* The dataset has already been
  scored by the time your `#expect` runs.

### 16.5 What you now have

A **failing test that means "my judge cannot be trusted"**, sitting in CI next to the failing test
that means "my feature regressed". Those are different failures with different fixes, and before this
construction there was no way to tell them apart.

> ✅ **VERIFIED** — `335:212-213`: *"This now means I can be confident that **when my model judge
> provides ratings, I can confidently say that the tags are good or bad according my standards. That
> means I can now put my judge to work on evaluating Book Tracker's Book Tagging Service.**"*

---

## 17. Hill-climbing the judge: four iterations

Apple's session 335 walks the judge from "not aligned at all" to "clears 0.6" in a documented sequence.
The sequence matters as much as the individual changes, because each one is chosen from the previous
run's evidence rather than from a list of best practices.

### 17.0 The scientific frame

> ✅ **VERIFIED** — `335:158-160`: *"In a science experiment, you have two groups. **The control
> group, which represents the baseline** and **the experimental group which represents the change we
> are trying to compare against.** We can think of the two versions of our instructions in the same
> way, where the **control group is represented by our base prompt** and our **experimental group is
> represented by our newly changed prompt**."*

Mechanically, a comparative run is **two instances of the same `Evaluation` type in one suite**:

> ✅ **VERIFIED** — `335:167`: *"With both prompts written, **I can add both evaluations to a test
> suite, which will run both evaluations.**"* And `335:230`, for the feature-side equivalent: *"So all
> I have to do is **define two instances of my evaluation**. One without the tool and one with it."*

```swift prelude:guide-context
@Suite("Judge Calibration A/B", .serialized)
struct JudgeCalibrationComparison {
    static let control      = ModelJudgeAlignmentEvaluation(prompt: .baseline)
    static let experimental = ModelJudgeAlignmentEvaluation(prompt: .candidate)

    @Test("Baseline",     .evaluates(control,      info: ["JudgePrompt": "baseline"]))
    func baseline()     async throws { /* record only */ }

    @Test("Experimental", .evaluates(experimental, info: ["JudgePrompt": "candidate"]))
    func experimental() async throws {
        let result = EvaluationContext.current.result
        #expect(result.aggregateValue(.custom(label: "Relevance Alignment Score")) > 0.6)
        #expect(result.aggregateValue(.custom(label: "Usefulness Alignment Score")) > 0.6)
    }
}
```

> 🟡 **RECONSTRUCTED** — the two-instances-in-one-suite pattern is verified from the session and from
> Book Tracker's tool A/B (`335:227-231`); parameterising the evaluation by its judge prompt is the
> obvious application and is ours. The `info:` dictionary is ✅ VERIFIED as
> `.evaluates(evaluation, info: [String: String])` and Book Tracker uses it to stamp the prompt text
> itself into the run record (`BookTags.swift:149-167`), which is what makes the Compare view's
> diffs meaningful — otherwise you are looking at two runs and guessing what differed.

Then read them side by side:

> ✅ **VERIFIED** — `335:178-179`: *"From the evaluation report I can open the **comparison button**
> and open my baseline evaluation. Here, I can review the scores of the two prompts side by side."*
> And `299:97`: *"In Xcode 27, we introduced a new Evaluations Report to visualize your results."*

**And the procedural rule that is the single most important sentence in session 335:**

> ✅ **VERIFIED** — `335:186-187`: *"**But before I can make changes to the experimental evaluation, I
> applied the new prompt from my experimental evaluation into my baseline. This ensures there's only
> one different variable.**"*

Promote the winner into the baseline *before* starting the next experiment. If you do not, iteration 2
is comparing against iteration 0 and you are testing two changes at once. This is the discipline the
whole method rests on, and it is exactly as easy to skip as it sounds.

> ✅ **VERIFIED** — `335:242-245`, the recap: *"**Hill-climbing works best when you focus on making
> one change at a time. To do this, treat every iteration of the loop like a science experiment. Being
> able to isolate your changes will help you to understand how each part of your feature contributes
> to the overall quality.**"*

### 17.1 Iteration 0 — split the question

Covered in §7. `TagQuality` → `Relevance` + `Usefulness`. This happens in session 298, before any κ is
computed, and it is a prerequisite: **you cannot calibrate a dimension that is asking two questions**,
because your own ratings will be unstable for the same reason the judge's are.

**Evidence it was needed:** *"the problem with our first model judge was that it was too broad. It was
asking two different questions"* (`298:238-239`).

### 17.2 Iteration 1 — give the judge context about the app

**Diagnosis from the failing run:**

> ✅ **VERIFIED** — `335:141-153`: *"the scores for both usefulness and relevance are quite low,
> meaning my model judge and I aren't aligned."* … *"our judge thinks tags like **self-help** and
> **self-improvement** are relevant to the story"* (*Frankenstein*) … *"Terms like **visual-dimension**
> and **quaint-dignity** are **way too specific**"* (*The Ramakien*) … *"**I believe the model doesn't
> have enough knowledge on it's own to distinguish between a good tag and bad one. That's likely
> because the prompt of my judge doesn't provide enough context.**"*

**The change:**

> ✅ **VERIFIED** — `335:163-166`: *"For our experimental prompt, I've written a **more thorough
> description about how to judge the set of tags. It starts by providing the judge context about the
> app and what it's about to be judging. Then it gives examples of good tags. As well as ways to
> identify bad tags.**"*

**The result, and this is the honest part of the story:**

> ✅ **VERIFIED** — `335:170-175`: *"**my alignment scores for relevance improved. While my alignment
> score for usefulness dropped considerably.**"* … *"**Balancing tradeoffs like this are tricky so I
> need to think carefully how to proceed. But before in depth analysis comes checking if we passed.
> And my test confirms the obvious, we haven't.**"* … *"After thinking about it further, **I am going
> to keep this prompt change and focus the next round of iteration on improving my usefulness
> score.**"*

Two lessons worth more than the change itself:

1. **A change can improve one dimension and damage another.** Splitting the question bought you the
   ability to *see* this. With a single `TagQuality` metric the two effects would have cancelled and
   the run would have looked flat.
2. **Keeping a change that failed the test is a legitimate move.** The relevance gain was real; the
   usefulness loss was a separate, addressable problem. Session 335's second recap point covers this:
   *"**this process takes time. Not every change you make will result in positive change. However,
   failed experiments tell you just as much as successful ones.**"* (`335:246-248`).

### 17.3 Iteration 2 — sharpen the score-dimension descriptions

**Diagnosis, straight from the Compare view:**

> ✅ **VERIFIED** — `335:180-184`: *"One thing that jumped out to me immediately is the discrepancy
> between usefulness scores of this review of **'Picture of Dorian Gray'**. It seems to me that **the
> model may be judging too harshly on usefulness.** The usefulness column of the experimental
> evaluation seems to corroborate my guess. **I noticed that all the scores are either a 3 or 2, which
> is way too harsh.**"* … *"I think what could help here is **being more specific about how to grade
> each scoring dimension.**"*

Note the shape of that diagnosis: it starts from *one conspicuous row*, forms a hypothesis, and then
confirms it against the *whole column*. That is the right order — a single row is an anecdote, a
column is evidence, and the report gives you both on one screen.

**The change:**

> ✅ **VERIFIED** — `335:189-191`: *"For **relevance**, I've provided a slightly longer description
> which **emphasizes the need for a genre tag**. And here is the one for **usefulness**. Which
> **emphasizes being more critical of overly specific tags**."*

**The result:**

> ✅ **VERIFIED** — `335:193-194`: *"**the scores both improved greatly over the baseline. It looks
> like these specific scoring dimensions are going to be a lot more helpful.**"*

This is why the calibration evaluation declares its own `ScoreDimension` values rather than importing
the feature evaluation's:

> ✅ **VERIFIED** — the two dimension definitions are **deliberately re-worded** between the two
> files. Compare `BookTags.swift:43-56` with `ModelJudgeAlignmentEvaluation.swift:175-189`: the
> calibration copy encodes the librarian's *generosity* (that a small amount of drift is acceptable),
> which the feature-evaluation copy does not. **Tuning the dimension text is itself part of the
> hill-climb**, and the calibration file is where you tune it.

The workflow implication: once a dimension's wording clears κ ≥ 0.6 in the calibration evaluation,
copy it back into the feature evaluation. The calibration file is the laboratory; the feature
evaluation is production.

### 17.4 Iteration 3 — a few worked examples

**Diagnosis:**

> ✅ **VERIFIED** — `335:200-204`: *"My relevance score is starting to align. But my usefulness score
> could still use some work."* … *Frankenstein* *"continues to give our judge trouble."* … *"**What I
> think our judge needs now is some examples of the way I judge things, which should give it a pattern
> for how to judge according to my scale.**"*

**The change:**

> ✅ **VERIFIED** — `335:207-208`: *"I've reworked my main judge prompt to give it **more detail about
> the goal of the tag generation feature to help ground the model in the problem space**. From there,
> I've written out a number of examples for the model to use as a guideline for reviewing."*

**And here is what that actually looks like in shipped code:**

> ✅ **VERIFIED** — `ModelJudgeAlignmentEvaluation.swift:216-283`: the calibration judge prompt is
> **67 lines containing six labelled worked examples (A–F)**, each with an explicit rationale in the
> form *"Librarian: Relevance 4, Usefulness 4 / Why: …"*, plus the instruction *"Score Relevance and
> Usefulness independently, even when one tag affects both."*

Reconstructing the shape of one of those examples — the *format* is verified, the specific book and
tags below are ours:

```swift illustrative
let calibrationJudgePrompt = ModelJudgePrompt<ModelSample<BookTagJudgmentValue>>(
    instructions: """
        … role, context, criteria, evaluation steps as in §8.3 …

        CALIBRATION EXAMPLES

        Example A
        Review: A seafaring adventure told by a boy who falls in with pirates.
        Tags: adventure, pirates, coming-of-age, sea-story, classic
        Librarian: Relevance 4, Usefulness 4
        Why: every tag names something about the book, and every one is a phrase a
        reader would plausibly click while browsing.

        Example B
        Review: The prose is gorgeous but the pacing dragged and I skimmed the middle.
        Tags: gothic, overwrought, slow-burn, atmospheric, disappointing
        Librarian: Relevance 2, Usefulness 2
        Why: "overwrought" and "disappointing" describe the reader's reaction, not the
        book. "slow-burn" is borderline. Only two tags survive as browsing filters.

        Example C
        Review: A meditation on grief in a small coastal town, quietly told.
        Tags: literary-fiction, grief, coastal-setting, quiet-steadiness
        Librarian: Relevance 4, Usefulness 2
        Why: every tag is about the book, so relevance is high. But "quiet-steadiness"
        is a phrase lifted from the review that nobody would ever type into a filter,
        which is precisely the failure usefulness exists to catch.

        … Examples D, E, F covering the remaining scale levels …

        Use these examples to calibrate your scoring.
        """,
    evaluationTarget: { value in
        "\(value.tags.count) Generated tags: " + value.tags.joined(separator: ", ")
    },
    reference: { _, _ in [:] }
)
```

> 🟡 **RECONSTRUCTED** — the *structure* (six labelled examples, the `"Librarian: Relevance N,
> Usefulness N / Why: …"` form, the independence instruction) is ✅ VERIFIED from
> `ModelJudgeAlignmentEvaluation.swift:216-283`; the specific reviews, tags and rationales are ours.
> The closing line is Apple's documented tip: *"Add a final instruction such as 'Use these examples to
> calibrate your scoring.' to remind the model as judge to use the examples as reference points."*
> (`/documentation/evaluations/designing-effective-model-judges`).

Note that **Example C is doing the most work of the three.** A calibration set that only demonstrates
"all good" and "all bad" teaches the judge nothing about the boundary, and the boundary is where all
your disagreement lives. Apple's documentation says the same:

> ✅ **VERIFIED** — same article: *"Include examples that span the full range of your scale. At
> minimum, show what a high score and a low score look like. **Ideally, include an example at every
> level.**"*

**The result:**

> ✅ **VERIFIED** — `335:212`: *"**And now finally my scores are over my expected value! Which means
> I've finally passed and can exit out of the loop!**"*

### 17.5 The sequence, tabulated

| # | Change | Diagnosed from | Outcome |
|---|---|---|---|
| 0 | Split `TagQuality` → `Relevance` + `Usefulness` | disagreeing with a score you could not localise | diagnosis becomes two-dimensional |
| 1 | App context + good/bad tag guidance in `ModelJudgePrompt.instructions` | judge calling `self-help` relevant to *Frankenstein* | relevance ↑, **usefulness ↓** — kept anyway |
| 2 | Longer, sharper `ScoreDimension.description` per dimension (genre requirement; hostility to over-specific tags) | a whole column of 2s and 3s — "way too harsh" | **both ↑ greatly** |
| 3 | Six worked examples spanning the scale, in the judge prompt | one book still misjudged; relevance aligning, usefulness lagging | **κ clears 0.6, loop exits** |

Notice the escalation: **context → criteria → examples.** Each is more expensive in prompt tokens and
more specific to your dataset than the last, and each is only reached because the cheaper one was
tried and measured. Do not start at examples.

### 17.6 The knobs, when you are stuck

> ✅ **VERIFIED** — `335:249-253`: *"**Third, good experiments require creativity. In an intelligent
> feature there are so many things you can change. In your feature you can change the instructions,
> the tools, as well as the model or models you use to generate responses. On the evaluation side you
> can change the dataset, aggregation methods, and even the evaluators themselves. Everything is fair
> game.**"*

| Side | Knob | For judge alignment specifically |
|---|---|---|
| Feature | instructions / prompt | irrelevant — the subject is frozen |
| Feature | tools | irrelevant — the subject is frozen |
| Feature | the model | irrelevant — the subject is frozen |
| Evaluation | dataset | add rows at the low end of the scale (fixes the prevalence paradox) |
| Evaluation | aggregation | add weighted κ alongside unweighted (§15.3) |
| Evaluation | **the evaluators themselves** | **this is where all judge alignment work happens** |

That the first three rows are inert is the entire value of the frozen subject. In the *feature*
hill-climb they are the only rows that matter; in the *judge* hill-climb they cannot contaminate the
experiment at all.

---

## 18. Overfitting the alignment score

> ✅ **VERIFIED** — `335:210`: *"**I've made sure to only give the model a few examples. By giving it
> a longer list I am prone to overfit the alignment score, which would make it hard to tell if my
> judge is actually aligned with me.**"*

This is the sharpest single warning in the Evaluations material and it is easy to skate past, so here
is the mechanism spelled out.

Your calibration fixture has, say, 30 rows. Suppose you put 20 of them into the judge prompt as worked
examples, with your ratings. Now run the alignment evaluation. **Two-thirds of the samples the judge is
scoring are samples whose correct answer is printed in its own prompt.** κ goes up. It goes up a lot.
And it means nothing, because you have not built a judge — you have built a lookup table with a
language model wrapped around it, and it will not generalise to sample 31.

The formal name for this is train/test contamination, and the reason it is more insidious here than in
conventional machine learning is that **there is no train/test split in the API.** `Evaluation` has one
`dataset`. Nothing stops your judge prompt from quoting it. Nothing warns you when it does.

> ⚠️ **SILENT FAILURE — a contaminated calibration reports a *higher* κ, which is exactly the wrong
> direction for a warning.** Every other failure in this guide makes a number look worse or stay flat.
> This one makes your judge look better the more you break it, and the resulting judge then goes into
> production and drifts on your real dataset with a green calibration test behind it.

### 18.1 What to do instead

**Keep the example count small — Apple's is six against a fixture of tens of rows.** That ratio is the
guidance, and it is deliberate.

**Hold rows out.** The framework will not do this for you, so do it by hand: split your extracted
fixture into a calibration set and a held-out set at extraction time, draw examples only from the
calibration set, and report κ on the held-out set. Two JSON files, two `Evaluation` instances, one
suite:

```swift prelude:guide-context
@Suite("Judge Calibration", .serialized)
struct JudgeCalibrationTests {
    // Examples in the judge prompt are drawn ONLY from rows in this fixture.
    static let development = ModelJudgeAlignmentEvaluation(fixture: "judge-calibration-dev")
    // Never quoted in any prompt. This is the number that decides whether you ship.
    static let heldOut     = ModelJudgeAlignmentEvaluation(fixture: "judge-calibration-holdout")

    @Test("Development set", .evaluates(development, info: ["Set": "dev"]))
    func dev() async throws { }

    @Test("Held-out set", .evaluates(heldOut, info: ["Set": "holdout"]))
    func holdout() async throws {
        let result = EvaluationContext.current.result
        #expect(result.aggregateValue(.custom(label: "Relevance Alignment Score")) > 0.6)
        #expect(result.aggregateValue(.custom(label: "Usefulness Alignment Score")) > 0.6)
    }
}
```

> 🟡 **RECONSTRUCTED** — Apple's sample does **not** do this; it runs one fixture. The held-out split
> is our recommendation, built from verified pieces (`JSONLoader(url:)`, two evaluation instances in
> one suite, `info:` stamping). It is what the overfitting warning implies but does not spell out.

**Watch the gap.** If dev κ is 0.85 and held-out κ is 0.35, you have overfit and the fix is fewer
examples, not more. If they are both 0.65, you have a judge.

**Write examples that teach a rule, not an answer.** An example whose "Why" explains the *principle*
("a phrase lifted from the review is not a browsing filter") generalises. An example that just asserts
a score does not.

### 18.2 When to stop tuning the judge

Stop at 0.6. Seriously.

A κ of 0.95 against a 30-row fixture is not a better judge than 0.65; it is either an overfit judge or
a fixture so easy that everything scores 4. The bar exists to answer a yes/no question — *can this
judge stand in for me?* — and once the answer is yes, every further hour goes into the feature, which
is the thing your users actually touch. Session 335's own loop exits the moment the test passes.

---

## 19. ⚠️ Silent failures in judge alignment

The defining property of this stack is that most defects do not throw. Judge alignment is the densest
concentration of them in the entire series, because the whole apparatus is a machine for producing
plausible-looking numbers.

### 19.1 ⚠️ The positional join, which nothing validates

This is the big one.

```swift prelude:guide-context
let expertRelevance = Self.samples.map { $0.expected?.expertRelevanceScore ?? 0.0 }

group.custom(of: relevance.metric, label: "Relevance Alignment Score") { judge in
    Statistics.cohensKappa(ratings1: expertRelevance, ratings2: judge) ?? 0
}
```

Two arrays. `expertRelevance` comes from **your static sample array**. `judge` comes from **the
framework's per-metric result column**. They are paired **by index**, and the only thing making that
valid is the guarantee that the framework delivers scores in dataset order.

Everything that can silently break that pairing:

| Cause | What happens |
|---|---|
| The `Loader` yields a different order than `Self.samples` | every pair is wrong; κ collapses toward 0 |
| You filter `Self.samples` in one place and not the other | off-by-N misalignment from the first removed row onward |
| A sample's judge call fails and its metric is dropped or `ignore`d | the judge array is shorter, so every subsequent pair shifts |
| You add a sample to the fixture but the fixture is cached | lengths differ; our implementation returns `nil` → `?? 0` → a hard zero |
| Two dimensions computed from the same array by copy-paste | Usefulness κ silently computed against expert *relevance* |

None of these throws. All of them produce a number. A misaligned κ typically lands somewhere in
0.0–0.2, which reads exactly like "my judge is badly calibrated" — so you will spend a day rewriting a
judge prompt that was fine.

**Defend against it.** Nothing in the framework will, so add an assertion of your own inside the
closure, where you have both arrays in hand:

```swift prelude:guide-context
group.custom(of: relevance.metric, label: "Relevance Alignment Score") { judge in
    // The join is positional. If the lengths ever disagree, the number below is
    // meaningless — fail loudly rather than reporting a plausible kappa.
    precondition(
        judge.count == expertRelevance.count,
        """
        Judge/expert length mismatch: \(judge.count) judge scores vs \
        \(expertRelevance.count) expert scores. The positional join is invalid.
        """
    )
    return Statistics.cohensKappa(ratings1: expertRelevance, ratings2: judge) ?? 0
}
```

> 🔴 **GAP — we do not know how `custom(of:label:_:)` represents a sample whose metric was `ignore`d
> or whose evaluator threw.** The documentation says the closure computes *"a custom aggregation from
> a single metric's results"* and `Metric.ignore(rationale:)` is *"excluded from aggregation"*, which
> is at least suggestive that ignored samples are **omitted from the array rather than represented by
> a placeholder** — and if so, the positional join breaks the moment any judge call is ignored.
> `Metric.doubleValue` is separately documented as absent *"for ignored metrics"*, which points the
> same way.
>
> **What would resolve it:** one run with a deliberately-ignored metric and a `print(judge.count)`
> inside the closure. Ten minutes with Xcode 27.
>
> **Safe default meanwhile:** never return `.ignore()` from an evaluator whose metric feeds a
> positional custom aggregation, and keep the `precondition` above. If you need an "unscoreable"
> sample, drop it from the fixture instead — from *both* sides.

### 19.2 ⚠️ `?? 0.0` turns a missing expert score into a rating of zero

Apple's own line:

```swift prelude:guide-context
let expertRelevance = Self.samples.map { $0.expected?.expertRelevanceScore ?? 0.0 }
```

If a row in your hand-edited JSON is missing its expert score — you skipped it, the key was
misspelled, `Codable` decoded a default — that row contributes a rating of **0.0**. Zero is not on the
1–4 scale. It becomes a fifth category that only one rater ever uses, which:

- makes exact agreement on that row impossible,
- adds a category to the marginal distribution, changing `p_chance` for every other row,
- and depresses κ by more than the single row's share.

Nothing throws. The JSON parses. The evaluation runs. κ comes out low and you go and rewrite your
judge prompt.

**Fix it at the boundary.** Make the expert scores non-optional in your fixture type and validate on
load:

```swift illustrative
static func loadExtractedFixture(named name: String) -> [ModelSample<BookTagJudgmentValue>] {
    let url = Bundle.module.url(forResource: name, withExtension: "json")!
    let rows = try! JSONDecoder().decode([ModelSample<BookTagJudgmentValue>].self,
                                         from: Data(contentsOf: url))
    for (i, row) in rows.enumerated() {
        guard let expected = row.expected else {
            fatalError("Fixture row \(i) has no expected value — it was never scored.")
        }
        precondition((1...4).contains(Int(expected.expertRelevanceScore)),
                     "Fixture row \(i): relevance \(expected.expertRelevanceScore) is off-scale.")
        precondition((1...4).contains(Int(expected.expertUsefulnessScore)),
                     "Fixture row \(i): usefulness \(expected.expertUsefulnessScore) is off-scale.")
    }
    return rows
}
```

> 🟡 **RECONSTRUCTED** — `ModelSample` is ✅ VERIFIED `Codable` (Book Tracker's generator JSON-encodes
> `[ModelSample<BookTags>]` straight to disk and `JSONLoader(url:)` reads it back), so decoding an
> array of them is sound. The validation is ours.

Related, and worth knowing before it surprises you:

> ✅ **VERIFIED** — `/documentation/evaluations/jsonloader`: *"**Malformed entries are logged via
> `OSLog` and skipped.** A failure to open the file propagates as a thrown error."*

So a malformed row in your calibration fixture **silently shrinks the dataset** — and shrinks only the
framework's side of the positional join, not `Self.samples`. That is §19.1 again, arriving through a
different door. Missing file: throws. Corrupt row: a log line you will not read.

### 19.3 ⚠️ An undefined κ reports as "no agreement"

`Statistics.cohensKappa(...) ?? 0` maps *undefined* onto *zero*, and those are different facts:

- **κ = 0** means "your judge agrees with you exactly as often as random guessing would."
- **κ undefined** means "the arithmetic has no answer here" — both raters used a single category, or
  the arrays were empty or mismatched.

Collapsing the second into the first is defensible for a test gate (both should fail) but actively
misleading during diagnosis, because 0 sends you to "rewrite the judge" when the real answer is "your
fixture has no variation in it." Distinguish them:

```swift prelude:guide-context
group.custom(of: relevance.metric, label: "Relevance Alignment Score") { judge in
    guard let kappa = Statistics.cohensKappa(ratings1: expertRelevance, ratings2: judge) else {
        // -1 is a legal kappa value but unreachable in practice, so it reads as a sentinel
        // in the report: "undefined", not "chance-level agreement".
        return -1
    }
    return kappa
}
```

Keep the `> 0.6` assertion; `-1` fails it just as `0` does, but now the report tells you which
problem you have.

### 19.4 ⚠️ A judge that never varies looks excellent by mean

Covered in §11.3, restated here because it belongs on the checklist: a judge returning 4 for every
sample has a perfect mean, a zero standard deviation, and (by §14.2) a κ of exactly 0 or undefined.
If you aggregate only the mean, you will ship it. **Always compute the standard deviation of a judge
metric.** Apple's calibration evaluation does.

### 19.5 ⚠️ A pairwise judge silently discards your instructions

From §10: *"The `instructions` and `reference` components only apply to pointwise evaluators."* Pass a
carefully-written `ModelJudgePrompt` to `ModelJudgeEvaluator.pairwise(...)` and the instructions are
dropped in favour of Apple's built-in comparison prompt. The evaluation runs, the scores are
reasonable, and the app context you wrote never reached the model.

### 19.6 ⚠️ A `custom` label typo tests nothing

`custom(of:label:)` writes by string; `aggregateValue(.custom(label:))` reads by string. They are not
checked against each other. Write `"Relevance Alignment Score"` in one place and
`"Relevance alignment score"` in the other and your `#expect` is evaluating whatever
`aggregateValue` returns for a label that was never registered.

**Fix:** never write the string twice.

```swift compile:27
enum AlignmentLabel {
    static let relevance  = "Relevance Alignment Score"
    static let usefulness = "Usefulness Alignment Score"
}
```

### 19.7 ⚠️ The evaluation constructs the model differently from the app

From §3.4. Book Tracker's feature builds
`SystemLanguageModel(guardrails: .permissiveContentTransformations)`; so does its tool evaluation. If
your evaluation quietly uses the default guardrails while your app uses permissive ones, you are
scoring a different system and no test will tell you. **Call your real service from
`subject(from:)`.**

### 19.8 ⚠️ Judge inferences inherit every Foundation Models failure mode

A judge call is a model call. It can hit a guardrail, refuse, exceed context, or find the model
unavailable — and a κ computed over a run where 12% of judge calls failed is a κ over 88% of your
fixture, joined positionally against 100% of your expert ratings (§19.1).

> ✅ **VERIFIED** — the framework declares typed errors for exactly these paths:
> `EvaluationError`, `EvaluatorError` (*"A typed reason why an evaluator failed while scoring a
> produced subject"*), `SubjectInferenceError` (*"A typed reason why `subject(from:)` failed to
> produce a subject for a sample"*), `EvaluationResultsError`, and `ModelJudgeError`.

> ✅ **SDK-verified — `ModelJudgeError`'s cases (GAP half-closed, 2026-07-29).** The interface pins
> five cases, all about the judge's *response* rather than its transport
> (`Evaluations-27.0-macos.swiftinterface:341-352`):
>
> ```swift
> public enum ModelJudgeError : LocalizedError {
>     case invalidScore(dimension: String, value: String)
>     case invalidResponse(String)
>     case jsonDecodingFailed(response: String, underlying: any Error)
>     case missingDimension(String, response: String)
>     case noScaleValues(dimension: String)
> }
> ```
>
> Read the list as a diagnosis menu: the judge answered off-scale (`invalidScore`), answered in the
> wrong shape (`invalidResponse`, `jsonDecodingFailed`), skipped a dimension you asked for
> (`missingDimension`), or was handed a scale with no options (`noScaleValues`).
>
> 🔴 **Still open:** the framework's *policy* when a judge call throws mid-run — skipped, retried, or
> whole-run failure — is runtime behaviour an interface cannot show. One data point leans "skip and
> log": `EvaluationError`'s deprecated `metricsNotFound` case carries Apple's own message that
> missing metrics are *"materialized as ignored columns and logged"* (`:489-498`).
> **Safe default unchanged:** compare the judge array's length against your fixture's on every run
> (§19.1's `precondition`), so a partial run cannot masquerade as a complete one.

### 19.9 The checklist

- [ ] Every judge metric has a **standard deviation** aggregated next to its mean. (§11.3)
- [ ] The positional join is **length-asserted** inside the `custom` closure. (§19.1)
- [ ] Expert scores are **validated on load** to be on-scale, never defaulted to 0. (§19.2)
- [ ] Undefined κ is **distinguishable** from κ = 0 in the report. (§19.3)
- [ ] `custom` labels are **constants**, written once. (§19.6)
- [ ] `subject(from:)` calls the **real service**, constructing the model the way the app does. (§3.4)
- [ ] Judge prompt examples come **only from a development split**, and κ is reported on a held-out
      split. (§18.1)
- [ ] Your fixture contains rows at the **low end of the scale**. (§14.4, §16.2)
- [ ] You have **read the rationales** at least once. (§8.3, §9)
- [ ] `ScoreDimension` names are **stable across runs** so Compare works. (§6)

---

## 20. What is still unknown

Collected, so you can see the shape of the fog rather than meeting it one patch at a time.

> ✅ **CLOSED (2026-07-29) — `ScoringMode` cases.** `case discrete`, `case continuous`, with
> `.discrete` the default everywhere the parameter appears
> (`Evaluations-27.0-macos.swiftinterface:306-314`, `:323-330`). The *semantics* of `.continuous`
> remain undocumented. **Meanwhile:** omit it, as Apple does (§4.1).

> ✅ **CLOSED in part (2026-07-29) — `ModelJudgeError` cases** are five, SDK-verified (§19.8;
> `Evaluations-27.0-macos.swiftinterface:341-352`). 🔴 **Still open:** the framework's behaviour
> when a judge inference throws mid-dataset. **Resolve with:** one deliberately-failed run.
> **Meanwhile:** length-assert the join (§19.1).

> ✅ **CLOSED (2026-07-29) — the second parameter of `ModelJudgePrompt.reference`.** It is the
> model's output value, typed `Input.ExpectedValue`; the full closure type is
> `(Input, Input.ExpectedValue) async throws -> [String : String]`
> (`Evaluations-27.0-macos.swiftinterface:361`). Not a `ModelSubject`, as previously guessed (§8.2).

> 🔴 **GAP — `ScoringScale` cases beyond `.numeric` in practice.** `.passFail` and `.custom` are
> documented with examples and their signatures are now SDK-verified
> (`Evaluations-27.0-macos.swiftinterface:388-394`), but **only `.numeric` appears anywhere in
> Apple's sample archive**, and no `ScoreLevel`-conforming enum appears in compiling code.
> **Meanwhile:** `.numeric` for quality, `.passFail` for binary; treat `.custom` as unproven in
> practice, though no longer in spelling.

> 🔴 **GAP — the exact contents of `Statistics.swift`.** We know it is 72 lines, that it is
> hand-written, that it lives in `HillClimbingEvaluations/`, and that its entry point is
> `cohensKappa(ratings1:ratings2:) -> Double?`. We have not read the body. §15.2 is our
> implementation of the formula narrated in `335:98-101`, not a transcription of Apple's.
> **Resolve with:** downloading the Book Tracker archive and opening the file.

> 🔴 **GAP — multimodal judging.** A developer forum question asks whether evaluations work for
> image-text systems (MobileCLIP2, YOLOE); it is **unanswered**. `ModelSample`'s documentation notes
> that *"for multimodal prompts, create a custom `ModelSampleProtocol` conformance or use the
> `init(input:expected:expectations:)` initializer with a prebuilt `ModelSampleInput`"*, which
> establishes that multimodal *inputs* are representable — but says nothing about a judge scoring an
> image. **Meanwhile:** judge the text description of an image result, not the image.

> 🔴 **GAP — running a PCC model as the judge.** See §3.3. Narrated in session 298, never seen in
> code. The interface narrows it: `judge:` is declared `any LanguageModel`
> (`Evaluations-27.0-macos.swiftinterface:323-330`), so a PCC model typechecks — runtime behaviour
> against quota and the judge's decoding path is the open part. **Meanwhile:**
> `SystemLanguageModel.default` plus κ calibration.

> 🔴 **GAP — weighted κ.** Absent from Apple's entire corpus — and the interface confirms no
> weighting parameter exists anywhere in the module (κ itself is sample code, not framework). §15.3
> is ours, offered as a supplementary diagnostic and explicitly not as a substitute for the
> statistic the 0.6 bar was set against.

One non-gap worth recording, because it is unusually clean: **the Evaluations developer forum contains
exactly three threads**, all from WWDC26 week, one unanswered. There is essentially no community
knowledge about this framework yet. When something behaves unexpectedly, you are probably the first
person to see it, and the sample archive is a better oracle than a search engine.

---

## 21. Quick reference

### 21.1 The judge API, in one place

```swift illustrative
// ── Scale ──────────────────────────────────────────────────────────────────────
ScoringScale.numeric([4: "…", 3: "…", 2: "…", 1: "…"])   // [Double: String]
ScoringScale.passFail(passDescription: "…", failDescription: "…")
ScoringScale.custom(MyScoreLevelEnum.self)                // MyScoreLevelEnum: ScoreLevel
ScoringScale(options: [...])                              // var options — highest to lowest

// ── Dimension ──────────────────────────────────────────────────────────────────
ScoreDimension(_ name: String, description: String?, scale: ScoringScale)
dimension.metric        // the Metric to aggregate against
dimension.name          // becomes the DataFrame column name

// ── Prompt ─────────────────────────────────────────────────────────────────────
ModelJudgePrompt(
    instructions: String = .defaultInstructions,            // role + criteria + steps
    evaluationTarget: ((Value) -> String)? = nil,           // how the output is shown
    reference: ((ModelSample<Value>, Value) async throws -> [String: String])? = nil
)                                          // labelled sections — a DICTIONARY (SDK-verified)
ModelJudgePrompt.defaultInstructions                       // used if you omit the prompt

// ── Evaluator ──────────────────────────────────────────────────────────────────
// judge: any LanguageModel = SystemLanguageModel() on the promptless forms;
// scoringMode: ScoringMode = .discrete (cases: .discrete | .continuous)
ModelJudgeEvaluator(_ name:, scale:, judge:, scoringMode:)                // single dimension
ModelJudgeEvaluator(_ name:, scale:, judge:, scoringMode:, prompt:)
ModelJudgeEvaluator(judge:, dimensions:, scoringMode:)                    // multi-dimension
ModelJudgeEvaluator(judge:, dimensions:, scoringMode:, prompt:)
ModelJudgeEvaluator.pairwise(_ name:, scale:, judge:, scoringMode:, evaluationTarget:)
ModelJudgeEvaluator.pairwise(judge:, dimensions:, scoringMode:, evaluationTarget:)
try await evaluator.judgePrompt(for:output:)   // async throws -> Prompt — your best debugger
ModelJudgeEvaluator.defaultInstructions

// ── Aggregation ────────────────────────────────────────────────────────────────
func aggregateMetrics(using aggregator: inout MetricsAggregator) {
    aggregator.group("Quality") { group in
        group.computeMean(of: dimension.metric)
        group.computeStandardDeviation(of: dimension.metric)
        group.custom(of: dimension.metric, label: "…") { scores in Double }
    }
}

// ── Reading it back ────────────────────────────────────────────────────────────
let result = EvaluationContext.current.result
result.aggregateValue(.mean(of: metric))       // -> Double
result.aggregateValue(.custom(label: "…"))     // -> Double
result.detailed[metric: metric]                // per-sample column, incl. .rationale
result.summary                                 // TabularData DataFrame
```

Everything above: **iOS / iPadOS / Mac Catalyst / macOS / visionOS / watchOS 27.0, Beta. Xcode 27.
No tvOS. Swift only.**

### 21.2 The decision table

| Situation | Do this | § |
|---|---|---|
| You can measure it in code | write an `Evaluator` closure, not a judge | §1 |
| You can only describe it in words | `ModelJudgeEvaluator` | §1 |
| Binary judgement (safe / compliant / correct format) | `.passFail`, not a 1–4 scale | §5.1 |
| Subjective quality | `.numeric` with **four** levels | §5.1 |
| Your anchors say "Excellent / Good / Fair / Poor" | rewrite them as observable features | §5.2 |
| You disagree with a score | **split the dimension** | §7 |
| All the scores are the same | your question is too broad — split | §7.4 |
| The judge misunderstands your domain | `ModelJudgePrompt.instructions` | §8 |
| The judge is too harsh or too lenient across a whole column | sharpen `ScoreDimension.description` | §17.3 |
| One book keeps confusing it | a few worked examples — **a few** | §17.4 |
| "Is the new prompt better?" | pairwise, or two pointwise runs + Compare | §10 |
| You need to know whether the judge can be trusted | the κ meta-evaluation | §16 |
| κ is low and accuracy is high on a skewed fixture | fix the fixture, not the judge | §14.4 |
| κ is high and climbing with every example you add | you are overfitting — hold rows out | §18 |
| κ ≥ 0.6 | **stop**; go work on the feature | §18.2 |

### 21.3 Symptom → cause

| Symptom | Likely cause | § |
|---|---|---|
| Judge scores everything 3 | odd-numbered scale, or a broad question | §5.1, §7.4 |
| Judge scores everything 4; mean looks great | no `ModelJudgePrompt`, or no bad samples in the fixture | §8.3, §16.2 |
| Rationales are generic praise | context-free judge, or gradient-style anchors | §8.3, §5.2 |
| Two dimensions always move together | they are one dimension; merge them | §7.4 |
| Scores dropped when the dataset grew | either the feature is worse on hard cases **or** the judge drifts — κ tells you which | §12.2 |
| 80% agreement, κ ≈ 0 | the judge is guessing the majority class | §13.1, §14.2 |
| High accuracy, low κ, very skewed fixture | prevalence paradox — add low-scoring rows | §14.4 |
| κ ≈ 0 across every dimension at once | misaligned positional join, not a bad judge | §19.1 |
| κ fell after adding one fixture row | a row missing its expert score defaulted to 0 | §19.2 |
| κ = 0 with a fixture where everyone agrees | undefined, not chance-level | §19.3 |
| κ great on dev rows, terrible on new ones | overfit judge prompt | §18 |
| Judge prompt's app context seems ignored | you passed it to a **pairwise** evaluator | §10, §19.5 |
| `#expect` on an alignment score always passes | label typo between `custom(of:label:)` and `.custom(label:)` | §19.6 |
| Feature scores differ between app and evaluation | the evaluation builds the model differently | §3.4, §19.7 |
| Fixture silently has fewer rows than the file | `JSONLoader` logged and skipped a malformed entry | §19.2 |

### 21.4 The four hypotheses when scores move

> ✅ **VERIFIED** — `299:103-111`, verbatim: *"By running our evaluation on a larger dataset, a drop
> in scores could signal many different things."*
>
> 1. *"Score changes could be due to **problems with our prompt or instructions**."*
> 2. *"You could also consider **gaps in your intelligence feature**."*
> 3. *"Or you may want to **adjust your evaluation to understand what you are actually evaluating on**."*
> 4. *"your **dataset may still not be representative enough**."*
>
> *"**These are the core ways to further improve your results.**"*

Hypothesis 3 is the one this guide is about, and a calibrated judge is what lets you eliminate it
first — cheaply, and without touching the feature.

---

## 22. Sources

**Apple sample-code project, read on disk** — the highest-precedence evidence here, because it
compiles and ships. **Book Tracker — *Using Evaluations to evaluate an intelligent feature***
(`MACOSX_DEPLOYMENT_TARGET = 27.0`; 20 Swift files across 5 targets), obtained 2026-07-27 from the
`docs-assets` ZIP behind
`developer.apple.com/tutorials/data/documentation/evaluations/book-tracker-using-evaluations-to-evaluate-an-intelligent-feature.json`.
Files cited: `BookTracker/Services/BookTaggingService.swift` · `BookTrackerEvaluations/BookTags.swift` ·
`BookTrackerEvaluations/SyntheticBookTags.swift` · `BookTrackerEvaluations/SearchBooks.swift` ·
**`HillClimbingEvaluations/ModelJudgeAlignmentEvaluation.swift`** (353 lines — the κ calibration) ·
**`HillClimbingEvaluations/Statistics.swift`** (72 lines — hand-rolled Cohen's kappa; **signature and
call site read, body not read**) · `HillClimbingEvaluations/BookTaggingEvaluation-extracted.json` ·
`BookSampleGenerator/main.swift` · `DatasetExtractor/main.swift`.

**The framework's shipped Swift interface** —
`notes/sdk-interfaces/Evaluations-27.0-macos.swiftinterface` (885 lines), dumped from the Xcode 27
beta's macOS `Evaluations.framework` on **2026-07-29**. For names, signatures, defaults,
availability and case lists it outranks every source below, the sample included; for usage and
runtime behaviour it decides nothing. Cited as ✅ **SDK-verified** with line numbers. It closed this
guide's GAPs on `ScoringMode`, `ModelJudgeError`'s cases and `ModelJudgePrompt.reference`'s second
parameter, and corrected `judgePrompt(for:output:)` to `async throws -> Prompt`.

**Apple documentation** (harvested 2026-07-27 via `sosumi.ai` mirrors of `developer.apple.com`):
`/documentation/evaluations` (framework index, 44 KB) ·
`/documentation/evaluations/scoring-with-model-as-judge-evaluators` ·
`/documentation/evaluations/designing-effective-model-judges` ·
`/documentation/evaluations/designing-effective-evaluations` ·
`/documentation/evaluations/designing-evaluation-criteria` ·
`/documentation/evaluations/designing-evaluation-datasets` ·
`/documentation/evaluations/evaluating-language-model-responses` ·
`/documentation/evaluations/modeljudgeevaluator` · `/modeljudgeprompt` · `/scoredimension` ·
`/scoringscale` · `/metric` · `/metricsaggregator` · `/evaluation` · `/evaluator` ·
`/evaluatorprotocol` · `/modelsample` · `/jsonloader` · `/arrayloader` · `/evaluationresult` ·
`/evaluationtrait`.

**Apple Developer Forums** (Apple-staff answers marked as such): **833729** — a Frameworks Engineer
confirms *"Evaluations is a Swift-based framework. So you would need to call the Swift APIs from the
other language."* · **832053** — an Apple engineer on `ModelJudgeEvaluator`: *"used to evaluate a
response where the score is subjective — e.g. 'is this a good explanation'"*, with a code snippet that
puts `PrivateCloudComputeLanguageModel()` in the *subject's* session, not the judge's. · **833822**
(vision evaluations) is **unanswered** and is the source of the multimodal GAP in §20.

**WWDC26 session transcripts** — machine-transcribed spoken word, containing no literal on-screen code.
Verbatim sentences are quoted with line references and treated as verified *statements*; any API
spelling that exists only in narration is marked 🟡:
**298** *Meet the Evaluations framework* (Yada, Rob) — the judge definition, the capability rule, the
four components, the 1–4 scale rationale, the split-the-question technique, the best-practices block.
**299** *Create robust evaluations for agentic apps* (Ada, Kyle) — platform gates, the 13→100 sample
drop, the four hypotheses.
**335** *Improve your prompts by hill climbing with Evaluations* (Marcus) — drift, the accuracy
critique, Cohen's kappa, the alignment meta-evaluation, the four iterations, the overfitting warning,
the four closing rules.

**Explicitly not cited as 2026 evidence:** the coffee/generative-game sample and the SpeechAnalyzer
sample are iOS 26 / WWDC25 leftovers that were never refreshed. Nothing in them is evidence about the
Evaluations framework, which did not exist when they were written.

**Where sources disagree, and how this guide ruled:**

1. **Judge model.** Session 298 says use a *more capable* model — Private Cloud Compute — as the
   judge. Apple's shipping sample uses `SystemLanguageModel.default` / `SystemLanguageModel()` to
   judge an on-device feature, at all three of its judge call sites, and every documentation example
   does the same. **Ruling: sample code outranks session narration.** The guide teaches the principle
   *and* states plainly that Apple's own code does not follow it, with the three reasons that makes
   defensible (§3.2).
2. **Cohen's kappa's provenance.** Session 335 discusses κ at length as part of the workflow and a
   reader naturally concludes it is a framework feature. **It is not**: `MetricsAggregator` has no
   agreement statistic and Apple's sample hand-rolls 72 lines. The session is consistent with this
   once you notice *"which I can do that with a custom aggregation method"* (`335:127`). **Ruling:
   corrected loudly, in the opening block and again in §15.**
3. **`ModelJudgePrompt.reference`'s return type.** Material in circulation has it as a `String`. Both
   the documentation and the sample say **`[String: String]`**, a dictionary of labelled sections.
   **Ruling: dictionary, verified twice.**
4. **Scale parity.** `designing-effective-model-judges` insists on an **even** number of levels;
   `scoring-with-model-as-judge-evaluators` opens with a **three**-level `Grammar` example. **Ruling:
   follow the advice article** — every dimension in the sample archive uses four levels — while noting
   what the 5/3/1 example legitimately demonstrates about non-contiguous scales (§5.1).
5. **`.numeric`'s key type.** Documentation says `[Double: String]`; the sample writes integer
   literals. **Ruling: both are true** — Swift literal coercion — and the guide says so rather than
   picking one (§5).
6. **Dimension naming.** Apple's documentation calls the first book-tagging dimension `Accuracy`; the
   session and the sample call it `Relevance`. **Ruling: `Relevance`**, because that is the spelling
   that compiles alongside the κ-calibration evaluation.
7. **`var evaluators`' type.** A reconstruction from session 298's narration produced
   `some Evaluator`. The sample says **`var evaluators: Evaluators`** — a result-builder type, plural.
   **Ruling: the sample.** The narrated form does not compile.

**Precedence used throughout:** for *signatures*, the shipped `.swiftinterface` first, then Apple
sample-code projects; for *usage and behaviour*, Apple sample-code projects first. Below both: Apple
documentation pages > Apple-staff forum answers > WWDC session transcripts > community material. No
community source is cited in this guide, because for this framework there is essentially none: the
Evaluations developer forum contains three threads in total.

---

*Next in this part:* [`03-synthetic-data-and-tool-trajectories.md`](03-synthetic-data-and-tool-trajectories.md) — `SampleGenerator`, the `targetCount`
trap, and evaluating *how* the model got there with `TrajectoryExpectation` and `ToolCallEvaluator`.
*Previously:* [`01-foundations-and-hill-climbing.md`](01-foundations-and-hill-climbing.md) — the `Evaluation` protocol, metrics,
aggregation, the `.evaluates` trait and the Xcode report.
