# Building blocks, Swift Testing integration, and evaluation-driven development

**Part 6 · Evaluations · Reference 01**

**Version floor:** the Evaluations framework is **new in the 27 cycle and does not back-deploy**. Every
symbol in it is marked **iOS 27.0+ · iPadOS 27.0+ · Mac Catalyst 27.0+ · macOS 27.0+ · visionOS 27.0+ ·
watchOS 27.0+**, and the whole framework index is tagged **Beta**. **There is no tvOS.** You need
**Xcode 27** — the `.evaluates` test trait and the Evaluations report are Xcode features, not just
library code. The feature you point it at can be older: `SystemLanguageModel` is iOS 26.0 (watchOS 27.0),
`tokenCount(for:)` and `contextSize` are **26.4**, and `PrivateCloudComputeLanguageModel`,
`Transcript.structuredTranscript` and `SystemLanguageModel(guardrails:)` are **27.0**. So you can
evaluate a 26.0-era feature, but you can only *run* the evaluation on 27.

> ✅ **VERIFIED — availability.** *"Everything in this framework is `iOS 27.0+ Beta, iPadOS 27.0+ Beta,
> Mac Catalyst 27.0+ Beta, macOS 27.0+ Beta, visionOS 27.0+ Beta, watchOS 27.0+ Beta` and tagged
> **Beta** on the index. Swift module name is `Evaluations` (`import Evaluations`)."*
> — `/documentation/evaluations` index. WWDC26 session 299 states the same thing out loud and
> **omits tvOS**: *"This framework is **new in Xcode 27** and supports **macOS, iOS, watchOS and
> visionOS**."* (`299:2`). The doc index adds iPadOS and Mac Catalyst; neither source lists tvOS.
> Do not claim tvOS support.

> ✅ **VERIFIED — Swift only.** An Apple Frameworks Engineer, answering forum thread 833729 (accepted):
> *"Evaluations is a Swift-based framework. So you would need to call the Swift APIs from the other
> language. For that, you can look at our documentation on language interoperability."* If you work in
> Python, Apple's guidance is the Python Foundation Models SDK plus your own scoring code — covered in
> [`../../part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md).

> ✅ **VERIFIED — distribution.** The framework ships **inside Xcode, not in the OS SDK** (Xcode 27
> beta, checked 2026-07-29). The macOS 27.0 and iOS 27.0 beta SDKs contain no public `Evaluations`
> module anywhere (`System/Library/Frameworks`, `SubFrameworks`, `usr/lib/swift`); the framework
> lives at `<Xcode>/Contents/Developer/Platforms/<Platform>.platform/Developer/Library/Frameworks/Evaluations.framework`
> — the same location and mechanism as `XCTest.framework` and Swift Testing's `Testing.framework`,
> and consistent with session 299's *"new in Xcode 27"* phrasing. It is present for every platform
> in the availability list and absent for AppleTVOS; its `.swiftinterface` annotates symbols
> `@available(anyAppleOS 27.0, *)` / `@available(tvOS, unavailable)` and imports `Testing`. Two
> practical consequences: `import Evaluations` resolves in **test targets** by default — a
> non-test target (Book Tracker ships two command-line tools that use the framework) has to reach
> the same platform `Developer/Library/Frameworks` directory through its search paths, as with
> XCTest — and if you go looking for the framework under `xcrun --show-sdk-path`, you will not
> find it. That absence is expected, not evidence the framework is missing.
>
> **Interface pass, 2026-07-29:** that captured interface (885 lines, checked into this repo at
> `notes/sdk-interfaces/Evaluations-27.0-macos.swiftinterface`) has now been read end-to-end
> against all three guides in this part. Claims marked ✅ **SDK-verified**
> (`Evaluations-27.0-macos.swiftinterface:<lines>`) cite it. An interface settles spellings,
> signatures, defaults, availability and case lists; it cannot settle runtime behaviour, and
> absence from it means "not present in the Xcode 27 beta interface", never "does not exist".

---

## What this covers

The bottom of Part 6: why a probabilistic feature cannot be unit-tested, what the Evaluations framework
puts in its place, and the working discipline — **hill climbing** — that the framework is shaped around.

- **Why the same input producing different outputs breaks the contract every unit test depends on**,
  in Apple's own words, and what "insufficient" actually means in practice.
- That Evaluations is **not an LLM framework**. It is a harness for any stochastic system — Apple names
  classifiers and linear regression models explicitly.
- **The five steps**, each mapped to exact API: `subject(from:)` → `dataset` → `evaluators` + `Metric` →
  `aggregateMetrics(using:)` → a Swift Testing `@Test`.
- The **corrected spellings**. `ModelSubject<T>` is the return type of `subject(from:)` and was absent
  from every reconstruction in circulation; `Evaluator` takes a **two-argument** closure collected in
  `var evaluators: Evaluators`; metric results come from `.passing()` / `.failing()` / `.scoring(_:)` /
  `.ignore()`, not from a `.pass` enum.
- **Swift Testing integration** — `@Suite`, `@Test`, the `.evaluates(_:)` / `.evaluates(_:info:)` trait,
  `EvaluationContext.current.result`, and `#expect` over an aggregate. Including the two things about
  the test body that are counter-intuitive: it runs *after* the whole dataset, and it never iterates
  samples.
- **The Xcode 27 Evaluations report** — where it lives, what the assistant editor shows per sample, and
  the **Compare** button that makes run-to-run diffing possible.
- **The attachment trick.** An evaluation run records its full generated data as an Xcode attachment.
  Session 335 reads that attachment back to build a *meta*-evaluation of its own judge. This is the
  single technique that makes judge calibration possible, and almost nobody knows it is there.
- **Hill climbing / evaluation-driven development** — develop → run → check → analyse → repeat, run as
  a controlled experiment: control vs experimental, **one variable at a time**, and the backport step
  that most people skip.
- The **non-prompt** hill-climb: adding a book-lookup tool to the tagging service, and the API-design
  move (`tools: [any Tool] = []`) that let the existing evaluation keep compiling.
- **Why any of this is structural.** There is no model version pinning API. An eval suite is the only
  defence you have when Apple ships a new on-device model in a point release.

Model judges, `ScoreDimension`, judge drift and Cohen's kappa, synthetic datasets with
`SampleGenerator`, and `ToolCallEvaluator` / `TrajectoryExpectation` each get their own guide elsewhere
in Part 6. This one gives you the frame they hang on, and names them where they belong.

## What you need

- **Xcode 27** and a 27 SDK. Nothing here compiles against Xcode 26. (The framework itself ships
  inside Xcode, like XCTest — see the distribution box above — so "a 27 SDK" gates the OS symbols
  you evaluate, not the `Evaluations` module.)
- A feature worth measuring, and a written list of what "good" means for it. If you cannot write that
  list, §1 is where to start, not §4.
- Familiarity with `@Generable`, `@Guide`, `LanguageModelSession` and `Tool`. See
  [`../../part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md)
  and [`../../part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md).
- Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`). Evaluations runs *inside* Swift
  Testing; it is not an alternative to it.
- **Apple's Book Tracker sample.** Almost every ✅ in this guide is quoted from it. It is at
  `/documentation/evaluations/book-tracker-using-evaluations-to-evaluate-an-intelligent-feature`.
  Download it before you read §4.

---

## Contents

1. [The contract that generative features break](#1-the-contract-that-generative-features-break)
2. [Evaluations is not an LLM framework](#2-evaluations-is-not-an-llm-framework)
3. [The five steps, and the four components](#3-the-five-steps-and-the-four-components)
4. [Step 1 — `subject(from:)`, the code under measurement](#4-step-1--subjectfrom-the-code-under-measurement)
5. [Step 2 — the dataset: `ModelSample` and the loaders](#5-step-2--the-dataset-modelsample-and-the-loaders)
6. [Step 3 — evaluators and metrics](#6-step-3--evaluators-and-metrics)
7. [Step 4 — `aggregateMetrics(using:)`](#7-step-4--aggregatemetricsusing)
8. [Step 5 — the test that runs it](#8-step-5--the-test-that-runs-it)
9. [The whole thing, in one file](#9-the-whole-thing-in-one-file)
10. [The quantitative / qualitative rule of thumb](#10-the-quantitative--qualitative-rule-of-thumb)
11. [The Xcode 27 Evaluations report](#11-the-xcode-27-evaluations-report)
12. [The attachment, and the meta-evaluation it unlocks](#12-the-attachment-and-the-meta-evaluation-it-unlocks)
13. [Hill climbing: the loop, and why it needs science](#13-hill-climbing-the-loop-and-why-it-needs-science)
14. [Control, experimental, one variable, backport](#14-control-experimental-one-variable-backport)
15. [Hill-climbing something that is not a prompt](#15-hill-climbing-something-that-is-not-a-prompt)
16. [Everything you can turn](#16-everything-you-can-turn)
17. [⚠️ The silent failures](#17-️-the-silent-failures)
18. [Why this framework exists: there is no model version pinning](#18-why-this-framework-exists-there-is-no-model-version-pinning)
19. [Quick reference](#19-quick-reference)
20. [Sources, and where they disagree](#20-sources-and-where-they-disagree)

---

## 1. The contract that generative features break

Every unit test you have ever written rests on one assumption, and it is so basic that you have
probably never articulated it: **the same input produces the same output**. That assumption is what
lets `#expect(sut.slug(for: "Hello World") == "hello-world")` mean anything. It is also what lets a
green test on your machine imply a green result on a customer's device.

A language model does not honour it.

> ✅ **VERIFIED** — WWDC26 session 298, *Meet the Evaluations framework*, opening argument, verbatim
> (`298:7-14`):
>
> *"Building app features with generative AI poses new testing challenges, because the same input can
> produce different outputs. **These models break a contract that is fundamental to software
> testing.**"*
>
> *"Consider traditional software, where a particular input always produces a particular output. You
> can easily verify this behavior with a unit test. You're guaranteed the same input will produce the
> same output on any device, including your customers'."*
>
> *"With intelligent software, you cannot rely on functional consistency to verify behavior. **Which
> means that unit tests are insufficient.** Unverified behavior can erode customer confidence."*

Two things in that passage deserve unpacking, because the word "insufficient" is doing a lot of work.

**First: it is not just sampling noise.** Apple's prompt-evaluation article names two independent
sources of variation, and the second one is the dangerous one:

> ✅ **VERIFIED** — `/documentation/foundationmodels/evaluating-prompts-to-measure-performance-and-improve-model-responses`:
> *"The response you get from a model **can vary even though you provide the same exact input**. This
> variation comes from the probabilistic nature of how the model generates text, **and from updates to
> the underlying model that you don't control.**"*

Temperature-zero decoding would flatten the first source. Nothing you can write in Swift flattens the
second. §18 is about that.

**Second: "insufficient" does not mean "useless".** A unit test still catches your `BookTags` decoder
crashing on an empty array, still catches a tool that throws on a nil argument, still catches the
plumbing. What it cannot do is express *"the tags are good."* The moment your assertion has to be about
the *content* of a model's output, hardcoding a string is not a weak test — it is a test that will fail
for reasons unrelated to quality, on a schedule you do not control, and whose failures teach you
nothing.

The framework's answer is to move the assertion up one level of abstraction. You stop asserting *"this
input produces this output"* and start asserting *"across this dataset, this measurable property holds
often enough."* The threshold is yours, and it is a design decision:

> ✅ **VERIFIED** (`298:95-96`): *"I expect the service to produce the correct number of tags 80% of
> the time. **Why 80%? If the service performance dips below 80%, I want to know and a failing test is
> great signal.**"*
>
> And, crucially (`298:115-116`): *"Remember back in our test definition? This is where we defined our
> **optimization target**. We're saying the feature behaves as expected, if the correct number of tags
> were generated, 80% of the time."*

That reframing is the whole idea. `#expect(rate >= 0.8)` is simultaneously a regression alarm and a
statement of intent — the number you are trying to move up. A test suite becomes a scoreboard.

### The three questions the framework is designed to answer

> ✅ **VERIFIED** (`298:19`), verbatim: *"We need to know: **how often does my app produce unexpected
> results? How often does the agent take an unexpected path to generate answers? And under what
> circumstances does the feature produce unsafe results?**"*

Note that the middle question is not about output at all — it is about *trajectory*, and it is the
explicit reason `TrajectoryExpectation` and `ToolCallEvaluator` exist. A model can hand you a
plausible-looking answer having never called the tool that would make the answer true. Tool-call
evaluation is covered in its own Part 6 guide; this one gets you to the point where adding it is a
three-line change.

### Where evaluations actually start: a `#Playground`

Before any of this, Apple's own demo does the least scalable thing possible, on purpose. Session 298
opens by dropping a `#Playground` macro into `BookTaggingService.swift` and *reading the output*:

> ✅ **VERIFIED** (`298:36-51`): *"Let's add a `#Playground` macro to `BookTaggingService.swift`."* …
> *"9 tags is more than I was expecting."* … *"I don't want the book's name as a tag, either."* …
> *"Multi-word tags are gonna be a problem in the UI, so we should avoid those as well."* … *"Okay,
> **we've just completed our first evaluation of the service. We created a list of expectations and
> used our human judgement to measure how the service performed.**"*

That is the definition of an evaluation, arrived at backwards:

> ✅ **VERIFIED** (`298:52`): *"Every evaluation measures how well an intelligent feature performs
> against our expectations."*

And the pivot (`298:53-55`): *"Unfortunately human judgement doesn't scale. But we've created a way to
automate and scale evaluations. All you have to do is add `import Evaluations`, and implement the
`Evaluation` protocol."*

The `#Playground` block is not a throwaway. It survives into the shipping sample:

> ✅ **VERIFIED** — Book Tracker keeps `import Playgrounds` and a `#Playground { … }` block in
> `BookTracker/Services/BookTaggingService.swift:76-101`, exercising two hand-written reviews,
> alongside a full evaluation suite in two separate test bundles. **The fast inner loop and the slow
> outer loop coexist.** Use the playground while you are typing; use the evaluation before you commit.

The five expectations that came out of that manual session became the spec for everything after
(`298:42-49`, `298:173`, `298:183`):

| # | Expectation | Measurable how? |
|---|---|---|
| 1 | Generate the correct **number** of tags (settled at 3–8) | code |
| 2 | Do **not** emit the book's title as a tag | code |
| 3 | **No multi-word** tags — they break the UI | code |
| 4 | Tags should identify a **literary genre** | code, against a known list |
| 5 | Tags should be **informative, relevant, and helpful for browsing** | not code — a model judge |

Four of five are heuristics. One is not. §10 is the rule that tells you which is which, and it is worth
memorising.

---

## 2. Evaluations is not an LLM framework

This is the most commonly missed fact about the framework, and it is stated outright in the first two
minutes of the introductory session:

> ✅ **VERIFIED** (`298:20-22`), verbatim: *"The Evaluations framework is a flexible system of provided
> types and protocols."* … *"This video will focus on evaluating intelligent features powered by
> language models. **But you can evaluate any stochastic system, such as classifiers and linear
> regression models.**"*

Structurally that claim holds up, because the coupling to Foundation Models is thinner than it looks.
`subject(from:)` calls *your* code and returns *your* value. Nothing in the protocol requires that a
model was involved:

> ✅ **VERIFIED** — the `Evaluation` protocol's own requirements
> (`/documentation/evaluations/evaluation`):
>
> ```swift
> protocol Evaluation : Sendable
>
> associatedtype Sample                     // "The type of input samples in the evaluation dataset."
> associatedtype SampleLoader               // "The type of the sample loader used to provide the evaluation dataset."
> var dataset: Self.SampleLoader { get }
>
> associatedtype Subject                    // "The type of the subject produced by the system under test."
> func subject(from sample: Self.Sample) async throws -> Self.Subject
>
> var name: String { get }                  // "The default name, derived from the type name."
> var evaluators: Self.Evaluators { get }
> typealias Evaluators                      // "Shorthand for the evaluator array type, resolved per-conformance."
> func aggregateMetrics(using aggregator: inout MetricsAggregator)
> ```
>
> ✅ **SDK-verified nuance:** in the shipped interface `name` is not a protocol *requirement* at all —
> it is a computed property in an extension (`Evaluations-27.0-macos.swiftinterface:482-487`), so a
> conformance never has to supply it; and the `evaluators` requirement carries the builder attribute
> directly — `@EvaluatorsBuilder var evaluators` (`:469-479`).

`Sample`, `Subject` and `SampleLoader` are all associated types. `ModelSample` and `ModelSubject` are
*the language-model-shaped conformances* of `SampleProtocol` / `EvaluationSubject`, not the protocol
itself. If you have an image classifier whose top-1 label wobbles between runs, or a recommender whose
ranking depends on a random seed, the same harness applies: a dataset of inputs, a subject that runs
your model, evaluators that score it, an aggregate, a threshold.

> 🔴 **GAP — non-text evaluation is unproven and Apple has not answered the question.** A developer
> asked on the Apple forums, verbatim: *"Are evaluations just for Text-text, or is there an efficient
> way to evaluate image-text, like for MobileClip2, or YOLOE?"* (thread 833822). **It received zero
> replies.** Separately, the `ModelSample` docs say multimodal prompts require *"a custom
> `ModelSampleProtocol` conformance or … the `init(input:expected:expectations:)` initializer with a
> prebuilt `ModelSampleInput`"* — so a hook exists, but no sample, doc example or session demonstrates
> a non-text evaluation end to end.
>
> **What would resolve it:** a compiling `SampleProtocol` conformance over a non-text input type, or an
> Apple answer on 833822. **Safe default meanwhile:** for a non-LLM system, drive it through the
> generic protocol requirements — your own `Sample` type, your own `Subject` type, plain `Evaluator`
> closures — and stay away from `ModelJudgeEvaluator`, `ToolCallEvaluator` and `SampleGenerator`, all
> three of which are constrained to `ModelSampleProtocol` (constraints ✅ SDK-verified —
> `Evaluations-27.0-macos.swiftinterface:166,311,840`).

The practical consequence of taking Apple at their word here: **an Evaluations suite is a reasonable
place to put your Core ML or MLX regression tests too.** You get the same report UI, the same
run-to-run comparison, and the same `.evaluates` plumbing. See Part 14 for the bridge material.

---

## 3. The five steps, and the four components

Apple describes the same construction two different ways in two different sessions. Both are correct;
they differ only in whether "run it" counts as a step.

> ✅ **VERIFIED** — session 298, verbatim (`298:58-63`): *"There are five steps to building and running
> an evaluation. **You define what code you're measuring. Then, define what data you're sending the
> code. Next, define what measurements you're making and how. Then, summarize your measurements. And
> then, finally, create a test to run your evaluation.**"*

> ✅ **VERIFIED** — session 335, verbatim (`335:106-110`): *"I need to write an evaluation, which is
> made up of four components. **First is my dataset. Then the subject of my evaluation. Then, I need to
> define my evaluators. And finally, I need to aggregate my results.**"*

And the documentation gives a third phrasing, which is the one to keep in your head because it names
the *purpose* of each part:

> ✅ **VERIFIED** — `/documentation/evaluations/evaluating-language-model-responses`, verbatim:
> *"- Provide input as a dataset of samples with expected outputs.
> - Define the subject, the intelligence-powered feature you are testing.
> - Add evaluators that score each response against metrics you define.
> - **Aggregate those scores into a metric summary you compare across runs.**"*

That last clause — *compare across runs* — is the tell. The aggregate is not decoration. It is the
number that hill climbing moves.

Mapped onto real API:

| Step | Question | API | Where it lives |
|---|---|---|---|
| 1 | What code am I measuring? | `func subject(from:) async throws -> ModelSubject<T>` | a method on your `Evaluation` |
| 2 | What data am I sending it? | `var dataset: some Loader` — `ArrayLoader` / `JSONLoader` of `ModelSample<T>` | a **stored** property |
| 3 | What am I measuring, and how? | `let m = Metric("…")` + `var evaluators: Evaluators` | properties on your `Evaluation` |
| 4 | How do I summarise it? | `func aggregateMetrics(using aggregator: inout MetricsAggregator)` | a method |
| 5 | How do I run it? | `@Test(.evaluates(evaluation))` + `EvaluationContext.current.result` | a Swift Testing suite |

All of steps 1–4 are requirements of one protocol, on one type. That is deliberate:

> ✅ **VERIFIED** — `/documentation/evaluations/designing-effective-evaluations`: *"In Evaluations, the
> `Evaluation` protocol captures these three attributes directly: it bundles **the feature under test,
> the test dataset, the evaluators, and the result aggregation into a single, runnable definition.**"*
> And, two lines later: *"**Treat evaluations as your living specification.**"*

### The shape, before the details

Here is the smallest complete conformance Apple publishes. Read it once now; §§4–8 take it apart.

> ✅ **VERIFIED** — verbatim from `/documentation/evaluations/evaluation`:
>
> ```swift
> struct MyEvaluation: Evaluation {
>     let metric = Metric("Match")
>
>     let dataset = ArrayLoader(samples: [
>         ModelSample(prompt: "One plus one is...", expected: "Two.")
>     ])
>
>     func subject(from sample: ModelSample<String>) async throws -> ModelSubject<String> {
>         ModelSubject(value: "Two.")
>     }
>
>     var evaluators: Evaluators {
>         Evaluator { sample, subject in
>             let metric = Metric("Match")
>             guard let expected = sample.expected else { return metric.ignore() }
>             return subject.value == expected ? metric.passing() : metric.failing()
>         }
>     }
>
>     func aggregateMetrics(using aggregator: inout MetricsAggregator) {
>         aggregator.computeMean(of: metric)
>     }
> }
> ```

Four things to notice, all of which contradict something that has been written about this framework:

1. `subject(from:)` returns **`ModelSubject<T>`**, not the raw value. This type was missing from every
   pre-sample reconstruction in circulation, including our own. It is not optional and it is not
   sugar — `ToolCallEvaluator` cannot work without its second initialiser (§6).
2. `dataset` is a **`Loader`**, not an array. `ArrayLoader(samples:)` wraps one.
3. `evaluators` is `Evaluators` — a *result-builder* type name — and the closure takes **two**
   arguments, `(sample, subject)`, in that order.
4. `aggregateMetrics` takes the aggregator **`inout`**, and the type is **`MetricsAggregator`**
   (plural "Metrics").

> ⚠️ Note the shadowing in Apple's own snippet: `let metric = Metric("Match")` is declared as a stored
> property **and again inside the closure**. Do not copy that habit — see §17.4 for why it is a hazard
> and what the safe form is.

---

## 4. Step 1 — `subject(from:)`, the code under measurement

This is where you call your feature. Apple's phrasing (`298:64-65`): *"we add the call to the
`BookTaggingService`, and return it's output inside of the `subject(from:)` method. **These generated
tags are the subject of our evaluation.**"*

> ✅ **VERIFIED** — Book Tracker, `BookTrackerEvaluations/BookTags.swift:17-30`, verbatim:
>
> ```swift
> import Evaluations
> import Foundation
> import FoundationModels
> import Testing
> @testable import BookTracker
>
> struct BookTaggingEvaluation: Evaluation {
>     func subject(from sample: ModelSample<BookTags>) async throws -> ModelSubject<BookTags> {
>         let result = try await BookTaggingService.generateTags(for: sample.promptDescription)
>         return ModelSubject(value: result)
>     }
> ```

Five load-bearing details in those six lines.

**`@testable import BookTracker`.** The evaluation lives in a test bundle and calls the app's real
service type. It is not a copy of your prompt; it is your app's code path. If you reimplement
`generateTags` inside the test target, you are evaluating the reimplementation.

**`ModelSample<BookTags>` is generic over the *expected* type, not the input.** This trips everyone up
once. The `BookTags` in the angle brackets is the shape of the *answer*, and the prompt is always text.

> ✅ **VERIFIED** — `ModelSample`'s declaration
> (`/documentation/evaluations/modelsample`):
>
> ```swift
> struct ModelSample<ExpectedValue> where ExpectedValue : Decodable, Encodable, Sendable
> // Conforms: ModelSampleProtocol, SampleProtocol, Codable, Sendable
> init(prompt:expected:instructions:generationSchema:expectations:)     // String-based
> init(prompt:expected:instructions:generationSchema:expectations:)     // FoundationModels `Prompt` overload
> init(input:expected:expectations:)                                    // prebuilt ModelSampleInput
> var prompt, promptDescription, instructions, instructionsDescription, input
> var expected, output
> var expectations                          // "The expected pattern of tool calls for this sample."
> var generationSchema                      // "The output schema for the model's response."
> ```

**Two ways to read the input back out.** `sample.promptDescription` is a `String`;
`sample.prompt` is a FoundationModels `Prompt`. Book Tracker uses both, in different evaluations —
`promptDescription` where the service signature takes a `String` (`BookTags.swift:19`) and `prompt`
where it goes straight into `session.respond(to:)` (`SearchBooks.swift:551`). Pick whichever matches
the function you are calling; do not stringify a `Prompt` by hand.

**`ModelSubject` wraps the output.**

> ✅ **VERIFIED** — `/documentation/evaluations/modelsubject`:
>
> ```swift
> protocol EvaluationSubject                // associatedtype Value; var value: Self.Value
>
> struct ModelSubject                       // "The subject type for language model evaluations."
> init(value: Value, transcript: StructuredTranscript?)
> var value: Value
> var transcript: StructuredTranscript?
> var toolCalls: [Transcript.ToolCall]
> ```
>
> Book Tracker uses **both** spellings: `ModelSubject(value:)` for the tagging evaluation
> (`BookTags.swift:20`) and `ModelSubject(value:transcript:)` for the tool-calling one
> (`SearchBooks.swift:562-566`).

**The transcript is opt-in, and it is what tool-call evaluation runs on.** If you ever intend to add
`ToolCallEvaluator`, pass it now. Because the accessor is declared by an Evaluations extension—not by
FoundationModels—the source file must import both modules:[^eval-structured-transcript-import]

```swift illustrative
import Evaluations
import FoundationModels
```

> ✅ **VERIFIED** — the canonical `subject(from:)` from
> `/documentation/evaluations/evaluating-language-model-responses`, verbatim including comments:
>
> ```swift
> func subject(from sample: ModelSample<Int>) async throws -> ModelSubject<Int> {
>     // Create the language model session; you can customize this with instructions and you can
>     // choose the model you want to use.
>     let session = LanguageModelSession()
>     // Create the model response the same way you do in your app.
>     let response = try await session.respond(to: sample.prompt, generating: Int.self)
>     // Return the model's response along with the transcript.
>     return ModelSubject(
>         value: response.content,
>         transcript: session.transcript.structuredTranscript
>     )
> }
> ```
>
> `Transcript.structuredTranscript` is an **Evaluations extension on
> `FoundationModels.Transcript`** (27.0+), returning `Evaluations.StructuredTranscript`. It is not a
> FoundationModels member, and it is unavailable at the use site unless that source file imports
> Evaluations.

Note the comment Apple wrote into their own sample: ***"Create the model response the same way you do
in your app."*** That is not filler. It is the single most consequential rule in this section, and
Book Tracker enforces it in a way that is easy to miss:

> ⚠️ **SILENT FAILURE — a mismatched model configuration evaluates a different system, and nothing
> tells you.** Book Tracker constructs its model with a non-default guardrail setting in the app
> service *and repeats it verbatim in the evaluation*:
>
> ```swift
> // BookTracker/Services/BookTaggingService.swift:40
> let session = LanguageModelSession(
>     model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
>     instructions: instructions
> )
> ```
> ```swift
> // BookTrackerEvaluations/SearchBooks.swift:553-555
> let model = SystemLanguageModel(
>     guardrails: .permissiveContentTransformations
> )
> ```
>
> ✅ Both call sites verified in the sample archive. Drop `guardrails:` from one of them and everything
> still compiles, still runs, and still produces a number — a number about a model you do not ship.
> Guardrail behaviour, `useCase:`, `GenerationOptions`, the instructions string, and which
> `LanguageModel` you pass are **all** part of the system under test.
>
> **The defence is structural, not vigilant.** Put session construction in exactly one place that both
> the app and the evaluation call. Book Tracker does this by making `generateTags` a `static func` on
> the service and calling *that* from `subject(from:)`; the only reason `SearchBooks.swift` rebuilds a
> session by hand is that it needs the transcript back, which the service does not return.

### Subjects that do no inference at all

`subject(from:)` is not obliged to call a model. Session 335 uses that fact to build a meta-evaluation
of its own judge, and the sample implements it:

> ✅ **VERIFIED** — `HillClimbingEvaluations/ModelJudgeAlignmentEvaluation.swift:166-169`:
>
> ```swift
> func subject(from sample: ModelSample<BookTagJudgmentValue>) async throws -> ModelSubject<BookTagJudgmentValue> {
>     let value = sample.expected ?? .placeholder
>     return ModelSubject(value: value)
> }
> ```
>
> Session 335 narrates the motive (`335:121`): *"Normally, the `subject` method is for calling API
> related to your feature, but **since the generated model responses are part of our dataset, we can
> simply return the already generated tags**."*

This is the **frozen-output** pattern, and it is worth naming because it generalises. Replaying a fixed
dataset through `subject(from:)` removes the feature's nondeterminism entirely, so the only thing
varying between runs is whatever you are actually studying — in 335's case, the judge. Use it whenever
you want to isolate one stochastic component from another. §12 walks the full workflow.

---

## 5. Step 2 — the dataset: `ModelSample` and the loaders

> ✅ **VERIFIED** — Book Tracker, `BookTags.swift:24-30`, verbatim including the doc comment:
>
> ```swift
>     /// Pairs each curated review with the maintainer's reference tags.
>     var dataset = ArrayLoader(samples:
>         Book.sampleBooks.map { book in
>             ModelSample(prompt: book.review, expected: BookTags(tags: book.tags))
>         }
>     )
> ```

Three corrections live in those five lines, and each one has been got wrong in reconstructions of this
API:

**`dataset` is a stored property, not computed.** `var dataset = ArrayLoader(…)`, no braces, no return.
Writing `var dataset: [ModelSample<BookTags>] { … }` will not satisfy the protocol.

**It is a `Loader`, not an array.** The protocol requirement is `var dataset: Self.SampleLoader`.

> ✅ **VERIFIED** — the loader surface (`/documentation/evaluations`):
>
> ```swift
> protocol Loader
> struct ArrayLoader<Sample> where Sample : SampleProtocol       // init(samples:)
> struct JSONLoader<Sample> where Sample : SampleProtocol        // init(url:)
> struct StreamLoader
> ```
>
> Book Tracker uses `ArrayLoader` for its 13 hand-curated books (`BookTags.swift:25`) and
> `JSONLoader` for the 100 synthetic ones — declared with an explicit type,
> `var dataset: JSONLoader<ModelSample<BookTags>>` (`SyntheticBookTags.swift:25`), reading back a file
> the `BookSampleGenerator` CLI wrote.

**`ModelSample(prompt:expected:)` is the two-argument form you will use most.** The `expected` value is
your *reference answer*, and it is optional in the sense that evaluators must handle its absence:

> ✅ **VERIFIED** — `/documentation/evaluations/generating-synthetic-evaluation-datasets`: *"For
> evaluations that score output without a reference answer, such as model-as-judge assessments of tone
> or fluency, **omit the expected value and generate prompt-only samples.**"* Every `Evaluator` in
> Apple's doc examples opens with `guard let expected = sample.expected else { return metric.ignore() }`
> for exactly this reason.

That `expected` value carries more weight than "the right answer", though. Session 298 makes an
argument for using it as a *style channel*:

> ✅ **VERIFIED** (`298:142`): *"If you want to teach the feature how to write tags like you, start by
> **including more of your personal style in the expected values of the samples**."*

It is also what a model judge compares against — `ModelJudgePrompt`'s `reference` closure reads
`input.expected` and hands it to the judge as labelled context (`BookTags.swift:118-121`).

### The `JSONLoader` file format, and its one sharp edge

> ✅ **VERIFIED** — `/documentation/evaluations/jsonloader`, verbatim:
> *"- If the first non-whitespace character is `[`, the file is treated as a **JSON array**
> (`[{...}, {...}]`) and decoded in one pass.
> - Otherwise, the file is treated as **JSONL** (JSON Lines), where each non-empty line is decoded as an
> individual sample.
> **Malformed entries are logged via `OSLog` and skipped.** A failure to open the file propagates as a
> thrown error."*

Read that last sentence twice. It is §17.1.

`ModelSample` is `Codable`, which is what makes the round trip work: Book Tracker's
`BookSampleGenerator` CLI JSON-encodes `[ModelSample<BookTags>]` straight to
`synthetic_book_samples.json` (`BookSampleGenerator/main.swift:82-86`), and `JSONLoader(url:)` reads it
back with no bespoke serialisation on either side. ✅ verified in the archive.

### How big should the dataset be?

The sessions give two numbers that look contradictory and are not.

> ✅ **VERIFIED** (`298:134`): *"**Good evaluations have thousands of samples** to extract trends, but
> also to exercise your feature in many different ways."*

> ✅ **VERIFIED** (`298:272-274`): *"**Start small. A focused dataset of 20 to 30 samples is a great
> place to get started.** Spec out your app by thinking about how you want the model to behave."*

The reconciliation is the workflow, not a compromise: hand-write 20–30, then scale with
`SampleGenerator`. Book Tracker is literally this — 13 curated books in `ArrayLoader`, expanded to 100
by a CLI, loaded back through `JSONLoader` as a *second* evaluation
(`SyntheticBookTags.swift`) that runs alongside the first rather than replacing it. Keeping both is the
right call: the curated set is deterministic and cheap and you know every row; the synthetic set is
where coverage lives.

And the reason coverage matters more than count:

> ✅ **VERIFIED** (`299:40`): *"**What matters far more than quantity is coverage! So instead of asking
> how many samples do I need? Ask yourself, have I covered the meaningful variety of ways this feature
> will actually be used?**"*

> ✅ **VERIFIED** (`299:22-23`): *"These 13 samples might feel like a reasonable starting point, but
> **this small dataset only give us a narrow window into how our feature performs. Our evaluation
> results could look great and still be completely misleading.**"*

That prediction was borne out on camera. Running the same evaluation against 100 samples instead of 13
made the quality scores **drop** (`299:100-102`), and the diagnosis was: *"Our tag generation feature
looked like it was performing well earlier because we weren't testing it with a comprehensive
dataset."* A small dataset does not give you a noisy estimate of quality — it gives you a *biased* one,
because the samples you thought of yourself are the samples your prompt already handles.

The dimensions of variety Apple names explicitly (`298:135-149`) are worth copying as a checklist:

| Dimension | What it means for your feature |
|---|---|
| Subject-matter variety | "We want the service to recognize different genres." |
| **Length** variety | "We can't assume every user will give it a verbose review." |
| Category variety | The axes real users browse by — fiction vs non-fiction, etc. |
| Form variety | "novels, short stories, and essays" |
| **Adversarial content** | *"Let's makes it hard on the model too. **Sprinkle in personal opinions**, so we can measure how well the service ignores those."* |
| Style-carrying expected values | see above — teach the feature your voice through `expected` |

The concrete personas the session wrote by hand are a good template because each targets one axis
(`298:144-149`): *The Secret Garden* reviewed "as though we were an avid gardener"; *Treasure Island* as
"a personal review from a mother reading it to her son. **Lots of personal opinions in this review**";
*Romance of the Three Kingdoms* from "a board game enthusiast [who] needed multiple paragraphs"; and a
Sherlock Holmes review from "a casual reader [who] described a famous British detective's sidekick in a
**single sentence**." Long, short, opinionated, off-centre. Four samples, four failure modes.

Dataset design — golden sets, user profiles, challenge cases — and `SampleGenerator` get their own
guide in this part. What you need here is: start at 20–30 hand-written rows in an `ArrayLoader`, make
them *different from each other*, and do not go near synthesis until the curated set is telling you
something.

---

## 6. Step 3 — evaluators and metrics

This is the part every reconstruction in circulation got wrong, so it is worth being pedantic.

### `Metric` is both the identifier and the result carrier

> ✅ **VERIFIED** — `/documentation/evaluations/metric`:
>
> ```swift
> struct Metric                             // Copyable, CustomStringConvertible, Equatable, Sendable
> init(_ name: String)
> func passing(rationale:) -> Metric
> func failing(rationale:) -> Metric
> func scoring(_:rationale:) -> Metric
> func ignore(rationale:) -> Metric         // "excluded from aggregation"
> var name: String                          // "used as the DataFrame column name"
> var value: Metric.Value
> var doubleValue
> var rationale: String?
> enum Metric.Value
> ```
>
> And the design note, verbatim: *"The factory methods (`passing`, `failing`, `scoring`, `ignore`)
> **return a new `Metric` with the result stored inside.**"*

So `Metric` is not an enum of verdicts and it is not a bag of numbers. `let tagCount = Metric("Tag
Count")` declared as a stored property is the **identifier** — the thing you aggregate by and the
DataFrame column name. `tagCount.passing(rationale: "6 tags")` is a **result value** you return from an
evaluator. Same type, two roles.

The five factories, all observed in shipping Apple code:

| Factory | Meaning | Seen at |
|---|---|---|
| `.passing()` | boolean success | `BookTags.swift:88` |
| `.passing(rationale:)` | success + a string that shows up in the report | `BookTags.swift:38` |
| `.failing()` | boolean failure | doc example |
| `.failing(rationale:)` | failure + explanation | `BookTags.swift:40` |
| `.scoring(_ value: Double)` | a *number*, not a verdict | `BookTags.swift:46` |
| `.ignore()` / `.ignore(rationale:)` | **excluded from aggregation** for this sample | doc example |

`.ignore()` deserves a moment. It is how you say "this sample cannot be scored on this metric" without
poisoning the average with a false failure — most commonly when `sample.expected` is nil. Do not reach
for `.failing()` there; a missing reference answer is not a defect in the feature.

### `Evaluator` takes a two-argument closure, and the metric is not a parameter

> ✅ **VERIFIED** — Book Tracker, `BookTags.swift:35-104`, verbatim:
>
> ```swift
>     let tagCount = Metric("Tag Count")
>     let tagTotal = Metric("Tag Total")
>     let hasGenreTag = Metric("Has Genre Tag")
>     let wordCount = Metric("Word Count")
>
>     var evaluators: Evaluators {
>         // Tag count is within the required 3–8 range.
>         Evaluator { _, subject in
>             let count = subject.value.tags.count
>             if count >= 3 && count <= 8 {
>                 return tagCount.passing(rationale: "\(count) tags")
>             }
>             return tagCount.failing(rationale: "Got \(count) tags, expected 3–8")
>         }
>
>         // Records raw tag count.
>         Evaluator { _, subject in
>             let count = subject.value.tags.count
>             return tagTotal.scoring(Double(count))
>         }
>
>         // Tags must be single-word or hyphenated.
>         Evaluator { _, subject in
>             for tag in subject.value.tags where tag.contains(" ") {
>                 return wordCount.failing(rationale: "Tag \(tag) contains multiple words")
>             }
>             return wordCount.passing()
>         }
>         …
>     }
> ```

Compare that against what was circulating before the sample shipped —
`var evaluators: some Evaluator { Evaluator(tagCount) { output, sample in … .pass } }` — and count the
errors: the property type, the metric-as-init-argument, the closure argument order, and the result
spelling. Four out of four wrong. If you have code or documentation that looks like that, it was
reconstructed from spoken narration and it does not compile.

The corrected shape:

- **`var evaluators: Evaluators`** — plural, and it is a `typealias` on the protocol, resolved per
  conformance. It is fed by a result builder.
- **`Evaluator { input, subject in … }`** — two arguments. First is the `ModelSample`; second is the
  `ModelSubject`. All four heuristics in Book Tracker discard the first as `_`, which is exactly why
  the order is easy to get backwards: you rarely see both used.
- **The metric is captured, not passed.** The closure returns `someMetric.passing()`; nothing hands the
  metric to `Evaluator`'s initialiser.
- **`subject.value`** is your typed output — `BookTags`, in this case, so `subject.value.tags` is a
  `[String]`.

> ✅ **VERIFIED** — the underlying protocol and the concrete struct
> (`/documentation/evaluations/evaluatorprotocol`, `/documentation/evaluations/evaluator`):
>
> ```swift
> protocol EvaluatorProtocol<Input, Subject> : Sendable
> associatedtype Input
> associatedtype Subject
> func metrics(subject: Self.Subject, input: Self.Input) async throws -> [Metric]
>
> struct Evaluator<Input>
>   where Input : SampleProtocol,
>         Input.ExpectedValue : Decodable, Input.ExpectedValue : Encodable, Input.ExpectedValue : Sendable
> ```
>
> Note that `metrics(subject:input:)` returns **`[Metric]`** — plural. That is how one evaluator can
> emit several metrics from one pass, which is what `ModelJudgeEvaluator` does with multiple
> `ScoreDimension`s.
>
> ✅ **SDK-verified** — both match the interface, and the interface also pins the closure type the
> docs never printed: `Evaluator.init(_ evaluate: (Input, ModelSubject<Input.ExpectedValue>) async
> throws -> Metric)` — sample first, subject second, returning one `Metric`
> (`Evaluations-27.0-macos.swiftinterface:295-303`; the protocol at `:650-656`).

If a closure is not enough — you need stored state, or you want to emit several metrics — conform
directly:

> ✅ **VERIFIED** — verbatim from `/documentation/evaluations/evaluatorprotocol`:
>
> ```swift
> struct MyEvaluator<Input: SampleProtocol>: EvaluatorProtocol
> where Input.ExpectedValue: Sendable & Codable {
>     let metric = Metric("Quality")
>
>     func metrics(
>         subject: ModelSubject<Input.ExpectedValue>,
>         input: Input
>     ) async throws -> [Metric] {
>         return [metric.scoring(1.0)]
>     }
> }
> ```

### The result builder, and the `if/else` you cannot write

> ✅ **VERIFIED** — `/documentation/evaluations/evaluatorsbuilder`:
>
> ```swift
> @resultBuilder EvaluatorsBuilder
> static func buildBlock(any EvaluatorProtocol<Sample, Subject>...) -> [any EvaluatorProtocol<Sample, Subject>]
> static func buildExpression(any EvaluatorProtocol<Sample, Subject>) -> any EvaluatorProtocol<Sample, Subject>
> static func buildOptional([any EvaluatorProtocol<Sample, Subject>]?) -> [any EvaluatorProtocol<Sample, Subject>]
> ```

> ✅ **SDK-verified — still no `buildEither`, so the branching rule stands**
> (`Evaluations-27.0-macos.swiftinterface:659-666`, checked 2026-08-23): the members are
> `buildExpression`, `buildOptional` and four pairwise `buildPartialBlock` overloads — beta 5
> replaced the earlier capture's single variadic `buildBlock` (a source-compatible builder-protocol
> swap; checked 2026-07-29 the list was `buildExpression`/`buildBlock`/`buildOptional`). Under
> Swift's result-builder rules a bare `if` still works and an `if/else` still does not — we still
> have not compiled the negative case, but the
> member list is no longer an inference from a documentation page; it is the shipped interface.
> **Safe default stands:** write two bare `if`s with complementary conditions rather than an
> `if/else`, or hoist the branch outside the builder and build the evaluator list in a helper.

### Evaluators are per-sample; aggregation is per-run

> ✅ **VERIFIED** (`298:77-78`), verbatim: *"**Evaluators run over a single sample at a time.** But we
> can measure trends and look for patterns measured over all of our samples in the
> `aggregateMetrics(using:)` method."*

That boundary is not negotiable and it determines what you *can* express. Anything that needs to see
the whole corpus — a distribution, a variance, an agreement statistic against a second rater — belongs
in step 4, not here. §7 and §12 are both consequences of this rule.

### Model judges are evaluators, and that is the important architectural fact

> ✅ **VERIFIED** (`298:222-224`), verbatim: *"In the Evaluations framework, **a model judge is just
> another `Evaluator`. It conforms to the same protocol as the quantitative evaluators and produces the
> same `Metric` type. So you can mix them freely within a single evaluation.**"*

Which is why Book Tracker's `evaluators` block ends with a `ModelJudgeEvaluator(judge:dimensions:prompt:)`
sitting directly underneath four `Evaluator { _, subject in … }` closures, in the same result builder,
scored in the same run, landing in the same report. Apple's docs show the same mixing pattern:

> ✅ **VERIFIED** — `/documentation/evaluations/designing-effective-model-judges`, verbatim:
>
> ```swift
> private let nonEmpty = Metric("NonEmpty")
> private let quality = Metric("Quality")
>
> var evaluators: Evaluators {
>     Evaluator { input, subject in
>         return subject.value.isEmpty ? nonEmpty.failing() : nonEmpty.passing()
>     }
>     ModelJudgeEvaluator(
>         "Quality",
>         scale: .numeric([...]),
>         judge: SystemLanguageModel.default,
>         prompt: ModelJudgePrompt(instructions: """...""")
>     )
> }
> ```

The judge's design — scales, dimensions, prompts, drift, calibration — is a separate guide. The thing
to take from here is only that adding one is *additive*: you do not restructure anything.

---

## 7. Step 4 — `aggregateMetrics(using:)`

Per-sample metrics are the raw data. The aggregate is the number you assert on, chart, and compare
across runs — so this method is where an evaluation stops being a log and becomes a measurement.

> ✅ **VERIFIED** — Book Tracker, `BookTags.swift:129-142`, verbatim:
>
> ```swift
>     func aggregateMetrics(using aggregator: inout MetricsAggregator) {
>         aggregator.group("Heuristics") { aggregator in
>             aggregator.computeMean(of: tagCount)
>             aggregator.computeStandardDeviation(of: tagTotal)
>             aggregator.computeMean(of: tagTotal)
>             aggregator.computeVariance(of: tagTotal)
>             aggregator.computeMean(of: wordCount)
>             aggregator.computeMean(of: hasGenreTag)
>         }
>         aggregator.group("Quality") { group in
>             group.computeMean(of: relevance.metric)
>             group.computeMean(of: usefulness.metric)
>         }
>     }
> ```

> ✅ **VERIFIED** — the full aggregator surface (`/documentation/evaluations/metricsaggregator`):
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
> func custom(of:label:_:)                 // "Computes a custom aggregation from a single metric's results."
> func group(_:_:)                         // "Creates a group of related metrics."
> struct MetricsAggregator.Group
> ```

Four things worth stating outright.

**The parameter is `inout`.** `func aggregateMetrics(using aggregator: inout MetricsAggregator)`. Get
this wrong and you get a protocol-conformance error that does not obviously point at the `inout`.

**The type is `MetricsAggregator` — plural "Metrics".** Not `MetricAggregator`. This one is a
transcription hazard: nobody can hear the `s`.

**`computeMean` over a pass/fail metric gives you a pass *rate*.** This is the mechanism behind every
`>= 0.8` threshold in this guide. `passing()` and `failing()` reduce to 1 and 0, and the mean of that
across the dataset is "how often did it pass." You do not compute a percentage yourself.

**`.group(_:)` nests a sub-aggregator and gives the report its section headings.** Note that Book
Tracker shadows the outer name inside the first closure (`{ aggregator in }`) and renames it in the
second (`{ group in }`) — both compile; the second reads better.

### Pairing a pass/fail metric with a scored one

Look again at what Book Tracker does with tag counts. There are **two** metrics over the same quantity:

- `tagCount` — pass/fail, "is the count within 3–8?"
- `tagTotal` — `.scoring(Double(count))`, "what *is* the count?"

and `tagTotal` is aggregated three ways: mean, standard deviation, variance. That is not
belt-and-braces. It is the fix for a failure the session hit live:

> ✅ **VERIFIED** (`298:127-130`), verbatim: *"All right, I made the change and I re-ran the evaluation.
> My test passed, and my TagCount passes a 100% of the time. **But I notice a potentially strange
> behavior: after my change, the service always generates eight tags.** Hmmm."*
>
> And after expanding the dataset (`298:158-159`): *"my TagCount average is still 100%, and **the
> service generated eight tags for all of them**. Now we know there's a weird behavior in the service."*

> ⚠️ **SILENT FAILURE — a green pass-rate over a range metric hides a degenerate distribution.** A
> `(3...8).contains(n)` metric reads 100% whether the model produces a healthy spread of 3, 5, 4, 7, 6
> or the same value every single time. Adding `@Guide(.count(3...8))` fixed the *range* and quietly
> collapsed the *distribution* to a constant 8 — arguably a worse feature, reported as a perfect score.
> Nothing threw, nothing warned, and the test went green.
>
> **The fix is a second metric, not a smarter first one:**
>
> ```swift
> let tagCount = Metric("Tag Count")   // pass/fail: is it in range?
> let tagTotal = Metric("Tag Total")   // score:     what is it?
> ```
> ```swift
> aggregator.computeMean(of: tagCount)               // range compliance
> aggregator.computeMean(of: tagTotal)               // central tendency
> aggregator.computeStandardDeviation(of: tagTotal)  // ← the one that catches it
> aggregator.computeVariance(of: tagTotal)
> ```
>
> A standard deviation of 0 over a metric that should vary is the signal. Session 298's own summary of
> the fix (`298:163-166`): *"First, I define a new Metric, **'TagTotal'**, that will record the number
> of generated tags… Then, we record a measurement using a **scoring value, instead of a pass/fail
> value**. Using the 'TagTotal' and 'TagCount' metrics we evaluate **range compliance and the
> distribution** of generated tags."*
>
> **Generalise it:** any time you write a metric of the form "is X within bounds", write a second one
> that records X, and aggregate its spread. Three of Book Tracker's six heuristic aggregations exist to
> serve this one idea.

### Custom aggregation: statistics the framework does not ship

`custom(of:label:_:)` hands you the raw per-sample scores for one metric and takes back a single
`Double`. Book Tracker uses it for the only genuinely statistical thing in the archive:

> ✅ **VERIFIED** — `HillClimbingEvaluations/ModelJudgeAlignmentEvaluation.swift:303-332`, verbatim:
>
> ```swift
>     func aggregateMetrics(using aggregator: inout MetricsAggregator) {
>         let expertRelevance = Self.samples.map { $0.expected?.expertRelevanceScore ?? 0.0 }
>         let expertUsefulness = Self.samples.map { $0.expected?.expertUsefulnessScore ?? 0.0 }
>
>         aggregator.group("Relevance") { group in
>             group.computeMean(of: relevance.metric)
>             group.computeStandardDeviation(of: relevance.metric)
>             group.custom(
>                 of: relevance.metric,
>                 label: "Relevance Alignment Score"
>             ) { judge in
>                 Statistics.cohensKappa(ratings1: expertRelevance, ratings2: judge) ?? 0
>             }
>         }
>         …
>     }
> ```

Two facts about that block matter more than the statistics.

**The closure receives `[Double]` in dataset order.** That ordering guarantee is the only reason the
positional join against `expertRelevance` is valid — row *i* of the judge's scores lines up with row
*i* of the human's. If the framework reordered rows, this pattern would be silently wrong. It does not,
and Apple's sample depends on it.

**Cohen's kappa is hand-rolled.**

> ✅ **VERIFIED — the framework ships no agreement statistic.** `Statistics.cohensKappa` is **72 lines
> of ordinary Swift** in `HillClimbingEvaluations/Statistics.swift`, written by the sample. There is no
> κ in the `MetricsAggregator` member list, no κ in the framework's symbol inventory, and session 335
> says so obliquely (`335:127`): *"we need to calculate Cohen's kappa, which I can do that with a
> **custom aggregation method**."* If you want judge-alignment measurement, **you are writing the
> statistic yourself.** Everyone who has read the session assumes otherwise; it is not there.

`custom(of:label:_:)` is a general escape hatch, not a κ-specific one. Anything you can compute from a
metric's per-sample scores — a percentile, a trimmed mean, a Gini coefficient, a count of samples below
a floor — goes here, and comes back out of the result by the same label (§8).

---

## 8. Step 5 — the test that runs it

Evaluations does not have a runner. Swift Testing is the runner.

> ✅ **SDK-verified — with one footnote: the library *can* drive itself.** The interface exposes
> `Evaluation.run(info: [String : String] = [:]) async throws -> EvaluationResult`
> (`Evaluations-27.0-macos.swiftinterface:490-494`) — presumably what the `.evaluates` trait calls
> internally, and the hook a command-line harness would use to run an evaluation outside a test.
> No Apple sample or doc article calls it; running through the trait is what gets you the Xcode
> report and the attachment (§11–§12). Treat `run(info:)` as the escape hatch, not the norm.
>
> ✅ **Probe-verified, 2026-07-31 — the escape hatch works, offline, under XCTest.** The probe
> suite's five Evaluations probes (`probes/`, run on the 27.0 sim runtime) all drive
> `Evaluation.run(info:)` programmatically from XCTest cases — no Swift Testing trait, no Xcode
> report, **no model** (canned subjects) — and get real `EvaluationResult`s back. Every measured
> Evaluations finding in this guide (§8.2, §8.4, §17.4, §17.5, §17.7) came through this path, which
> is itself the existence proof that the runner has no hidden dependency on the trait, the report
> UI, or a live language model.

> ✅ **VERIFIED** (`298:83`): *"Evaluations integrates with **Swift Testing**, so you can run your
> evaluations in your app's test targets."*

> ✅ **VERIFIED** — Book Tracker, `BookTags.swift:149-167`, verbatim including the doc comment:
>
> ```swift
> @Suite("Book Tag Evaluations")
> struct BookTagEvaluationTests {
>     static let evaluation = BookTaggingEvaluation()
>
>     /// Metadata recorded alongside each run.
>     static let evaluationInfo: [String: String] = [
>         "Prompt": BookTaggingService.instructions,
>         "ModelName": "SystemLanguageModel",
>         "AppVersion": "1.0",
>         "Feature": "Automatic tag generation from book reviews"
>     ]
>
>     @Test("Book Tag Evaluations", .evaluates(evaluation, info: evaluationInfo))
>     func evaluateBookTagging() async throws {
>         let result = EvaluationContext.current.result
>
>         let rangeMetric = BookTagEvaluationTests.evaluation.tagCount
>         #expect(result.aggregateValue(.mean(of: rangeMetric)) >= 0.8)
>     }
> }
> ```

That is nineteen lines and there are five non-obvious things in it.

### 8.1 The trait is `.evaluates`, and the second label is `info:`

> ✅ **VERIFIED** — `/documentation/evaluations/evaluationtrait`:
>
> ```swift
> struct EvaluationTrait          // conforms to Testing.TestScoping, Testing.TestTrait, Testing.Trait
> // "A test trait that runs an evaluation and records the result as attachments."
> ```
>
> Both spellings appear in the sample: **`.evaluates(evaluation)`** bare (`SearchBooks.swift:572`,
> `ModelJudgeAlignmentEvaluation.swift:344`) and **`.evaluates(evaluation, info: evaluationInfo)`**
> (`BookTags.swift:161`).
>
> ✅ **SDK-verified** — one declaration, not two: `static func evaluates(_ evaluation: any
> Evaluation, info: [String : String] = [:], recordTranscripts: Bool = false)`
> (`Evaluations-27.0-macos.swiftinterface:418-420`; beta 5 added the defaulted
> `recordTranscripts:`, checked 2026-08-23); the bare form is the defaulted `info:`.

⚠️ The parameter is **`info:`**, taking `[String: String]`. Session 298 describes it as *"a notes
dictionary"* in narration (`298:88-89`) and every reconstruction spelled it `notes:`. **It is `info:`.**
The sample and the documentation agree; the transcript is a paraphrase, not an API.

Note also the trait's own doc sentence: *"records the result as **attachments**."* That is §12.

### 8.2 The evaluation must be a `static let` on the suite

Not stylistic. The test body needs to reach the *same* `Metric` values the evaluation used, and it does
that by reading them off the evaluation instance: `BookTagEvaluationTests.evaluation.tagCount`. A fresh
`BookTaggingEvaluation()` constructed inside the test body would be a different instance.

> ✅ **Probe-verified, 2026-07-31 — `Metric` identity is BY NAME.** (was a 🔴 GAP; `probes/`
> `eval.metric-identity`, run offline on the 27.0 sim runtime via `Evaluation.run(info:)`.) Two
> evaluators each constructing a **fresh** `Metric("Match")` instance produce **one** detailed
> column and **one** `"Mean of Match"` summary column — and
> `aggregateValue(.mean(of: Metric("Match")))` through yet another fresh instance works, returning
> 0.5. That 0.5 is the second half of the finding: **same-named metrics from different evaluators
> POOL into one aggregate** (both evaluators' values averaged together). Apple's minimal example
> constructing `Metric("Match")` inside the evaluator closure was the correct reading; Book
> Tracker's hold-the-instance structure is a style choice, not a requirement.
>
> **The safe default barely changes, and the reason sharpens:** declare each metric exactly once as
> a stored property and reference it everywhere — no longer because instance identity might matter
> (it does not), but because name-keyed pooling means a *typo'd or duplicated* name silently forks
> or merges columns (§17.4). Fresh instances with the same name are safe; same names for different
> measurements are the hazard.

### 8.3 The dataset runs *before* the test body, and the body never iterates

This is the single most counter-intuitive part of the integration, and it is what makes the code look
so short.

> ✅ **VERIFIED** — `EvaluationContext` (`/documentation/evaluations/evaluationcontext`):
>
> ```swift
> struct EvaluationContext
> static var current: EvaluationContext
> let result: EvaluationResult
> ```

The trait runs the entire evaluation — every sample, every evaluator, the aggregation — and *then* runs
your test function with the finished `EvaluationResult` sitting in `EvaluationContext.current`. Your
body is an assertion over aggregates. There is no `for sample in …` anywhere in the suite.

⚠️ A consequence for the shape of the function: **the result does not arrive as a parameter.** A test
signature like `func f(results: EvaluationResults) async throws` — which is what several
reconstructions of this API show — does not exist. The signature is a plain
`func f() async throws`, and the type is `EvaluationResult`, **singular**.

### 8.4 Reading values back out: `aggregateValue(_:)`

> ✅ **VERIFIED** — `EvaluationResult` (`/documentation/evaluations/evaluationresult`):
>
> ```swift
> struct EvaluationResult                   // Sendable
> var summary: DataFrame                    // "Aggregated statistics for each metric in the evaluation."
> var detailed: DataFrame                   // "Individual results for each sample in the evaluation."
> let evaluationInfo: [String : String]     // "such as the model name, prompt version, or dataset"
> let evaluationID: String
> let resultID: UUID
> var reportMetadata: [String : any Sendable]
> func aggregateValue(_ op: AggregationOperation) -> Double
> var startTime, endTime, duration
> var groupedSummary                        // "A formatted description of summary metrics organized by groups."
> func jsonRepresentableDataFrame(of:)
> func saveJSON(to:includeReportMetadata:)
> func jsonData(includeReportMetadata:jsonOptions:)
> static func loadJSON(from:)
> static func loadJSONLines(from:)          // "Loads an array of evaluation results from a JSONL file on disk."
> init(jsonData:)
> enum EvaluationResult.DataFrameKind
> struct ResultColumn
> ```
>
> ✅ **SDK-verified** — that member list matches the shipped interface
> (`Evaluations-27.0-macos.swiftinterface:530-610`, checked 2026-08-23) with one beta-5 delta the
> docs page has not caught up to: `saveJSON` and `jsonData` each gained a defaulted
> `includeTranscripts: Bool = false` parameter. The interface also fixes two details the docs left
> loose: `saveJSON(to:)`'s parameter is labelled **`to directory:`** — it takes a directory, writes
> a file into it, and returns the file's URL (`@discardableResult`) — and `jsonData`'s options
> default to `[.prettyPrinted, .sortedKeys]` (`:581-610`).

`aggregateValue` takes an `AggregationOperation` and returns a `Double`. Two forms are attested in
shipping code:

```swift prelude:guide-context
// Built-in statistic, keyed by the Metric you aggregated:
#expect(result.aggregateValue(.mean(of: rangeMetric)) >= 0.8)          // BookTags.swift:165

// Custom statistic, keyed by the label you gave `custom(of:label:)`:
#expect(result.aggregateValue(.custom(label: "Relevance Alignment Score")) > 0.6)
                                                        // ModelJudgeAlignmentEvaluation.swift:348
```

✅ both verified in the sample. Note the symmetry: whatever you asked for in `aggregateMetrics` is what
you can read here, addressed the same way you registered it.

> ✅ **Probe-verified, 2026-07-31 — what `aggregateValue` returns when there is nothing to read:
> `-1.0`, always.** (`probes/` `eval.mean-over-all-ignored` and the empty-`aggregateMetrics` run,
> 27.0 sim runtime.) An evaluation whose `aggregateMetrics(using:)` registers nothing yields an
> **empty `summary` DataFrame**, and `aggregateValue` returns **`-1.0` for every metric you ask
> about** — the same `-1.0` you get for a mean over all-ignored samples (§17.5). `-1.0` is the
> framework's universal "no value" sentinel: it never throws, never traps, and never tells you
> *why* there was no value. Assert row counts (§17.1) alongside every `aggregateValue` assertion.

`summary` and `detailed` are **TabularData `DataFrame`s**, which is a much bigger door than
`aggregateValue` alone. If you want to *inspect* rather than assert:

> ✅ **VERIFIED** — verbatim from `/documentation/evaluations/evaluationresult`:
>
> ```swift
> @Test(.evaluates(Self.evaluation))
> func inspectDetailedResults() async throws {
>     let result = EvaluationContext.current.result
>
>     // Read typed columns out of the per-sample DataFrame.
>     let inputs   = result.detailed[Self.evaluation.inputColumn]
>     let expected = result.detailed[Self.evaluation.expectedColumn]
>     let scores   = result.detailed[metric: Self.evaluation.exactMatch]
>
>     // Surface the prompts where the model's count disagreed with the expected count.
>     for row in 0..<scores.count where scores[row]?.value == .failing {
>         let prompt = inputs[row]?.promptDescription ?? "<missing>"
>         let target = expected[row].map(String.init) ?? "?"
>         print("Missed (expected \(target)): \(prompt)")
>     }
>
>     #expect(scores.count == 5)
> }
> ```
>
> Note the **two subscript forms**: `detailed[someResultColumn]` for the typed input/expected/response
> columns declared on the `Evaluation` (`inputColumn`, `responseColumn`, `expectedColumn`), and
> `detailed[metric: someMetric]` for a metric's per-sample results.

That is your escape hatch for anything the report UI will not show you, and — with
`saveJSON(to:)` / `loadJSONLines(from:)` — for keeping a run history in CI outside Xcode.

### 8.5 `info:` is what makes runs diffable

The `info` dictionary is free-form `[String: String]` and it lands on the result as
`evaluationInfo`. What Book Tracker puts in it is the interesting part:

```swift illustrative
"Prompt": BookTaggingService.instructions,
```

✅ verified, `BookTags.swift:151`. **The entire instructions string is stamped into the run record.**
Not a version number, not a hash — the text. So when you open two runs side by side three weeks later,
the report can tell you not just that the score moved but *what the prompt said* on each side. That is
the difference between a comparison and a diff, and it costs one line.

Copy the whole dictionary shape; every key earns its place:

| Key | Why |
|---|---|
| `"Prompt"` | the actual instructions text — the thing you are most likely to be changing |
| `"ModelName"` | which backend produced these numbers |
| `"AppVersion"` | ties a run to a build |
| `"Feature"` | human-readable, so a stranger reading the report knows what they are looking at |

Add `"Dataset"` if you have more than one, and `"OSBuild"` if you care about §18 — which you should.

### 8.6 Serialised suites

> ✅ **VERIFIED** — `@Suite("…", .serialized)` is used for the judge-calibration suite in Book Tracker
> (`ModelJudgeAlignmentEvaluation.swift:337`), while the plain tagging suite is not serialised
> (`BookTags.swift:149`).

Swift Testing runs tests in parallel by default. Two evaluations racing each other for the on-device
model is not obviously wrong, but it is obviously slower and it makes timing noise. The sample's split
suggests the rule: **serialise suites where several evaluations contend for the same model**, leave a
single-evaluation suite alone. The OS also limits concurrent Foundation Models requests independently
of anything you do (Apple, forum thread 833642), so parallelism buys less than you would hope.

---

## 9. The whole thing, in one file

Below is a complete, copyable evaluation of a tag-generation feature. **Every API spelling in it is ✅
verified** against Book Tracker or Apple's documentation, cited in the preceding sections; the glue
between them — the `knownGenres` set, the title-tag check, the specific rationale strings — is ordinary
Swift and is mine. Where a fragment is quoted verbatim from the sample it is noted in a comment.

The feature under test first. This is the app's real code, in the app target:

```swift compile:27
// BookTracker/Services/BookTaggingService.swift
import Foundation
import FoundationModels

@Generable
struct BookTags: Codable, Equatable {
    // ✅ verbatim, BookTaggingService.swift:14-15 — note the two-argument @Guide form:
    // a description AND a variadic guide, with .count taking a ClosedRange.
    @Guide(description: "Descriptive tags capturing themes, genres, moods, and topics from the review",
           .count(3...8))
    var tags: [String]
}

struct BookTaggingService {

    /// Kept as a `static let` so the evaluation can stamp it into the run record verbatim.
    static let instructions = """
        You are a librarian and literary analyst. Generate tags for a book from a reader's review.

        Rules:
         - Return between 3 and 8 tags.
         - Every tag must be a single word, or two words joined by a hyphen.
         - At least one tag must name a literary genre.
         - Describe the book, not the reader's opinion of it.
         - Never use the book's title or the author's name as a tag.
        """

    /// The known genre vocabulary the UI browses by. The evaluation reads this too,
    /// so the metric and the feature can never drift apart.
    static let knownGenres: Set<String> = [
        "romance", "gothic", "horror", "mystery", "adventure", "historical-fiction",
        "science-fiction", "fantasy", "biography", "essay", "satire", "epic"
    ]

    // ✅ the session construction is verbatim in shape from BookTaggingService.swift:38-45.
    // `guardrails:` is NOT optional decoration — see §4.
    static func generateTags(for review: String) async throws -> BookTags {
        let session = LanguageModelSession(
            model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
            instructions: instructions
        )
        let response = try await session.respond(
            to: Prompt("Generate tags for this review:\n\n\(review)"),
            generating: BookTags.self
        )
        return response.content
    }
}
```

Now the evaluation, in the test bundle:

```swift prelude:external-module
// BookTrackerEvaluations/BookTags.swift
import Evaluations
import Foundation
import FoundationModels
import Testing
@testable import BookTracker

struct BookTaggingEvaluation: Evaluation {

    // ── Step 1: what code am I measuring? ────────────────────────────────────
    // ✅ verbatim, BookTags.swift:18-21
    func subject(from sample: ModelSample<BookTags>) async throws -> ModelSubject<BookTags> {
        let result = try await BookTaggingService.generateTags(for: sample.promptDescription)
        return ModelSubject(value: result)
    }

    // ── Step 2: what data am I sending it? ───────────────────────────────────
    // ✅ verbatim, BookTags.swift:24-30. A STORED property, wrapping an ArrayLoader.
    /// Pairs each curated review with the maintainer's reference tags.
    var dataset = ArrayLoader(samples:
        Book.sampleBooks.map { book in
            ModelSample(prompt: book.review, expected: BookTags(tags: book.tags))
        }
    )

    // ── Step 3: what am I measuring, and how? ────────────────────────────────
    // ✅ metric names verbatim, BookTags.swift:35-38
    let tagCount    = Metric("Tag Count")      // pass/fail: is the count in 3...8?
    let tagTotal    = Metric("Tag Total")      // score:     what IS the count?
    let wordCount   = Metric("Word Count")     // pass/fail: single-word or hyphenated?
    let hasGenreTag = Metric("Has Genre Tag")  // pass/fail: at least one known genre?
    let referenceOverlap = Metric("Reference Overlap") // pass/fail: agrees with reference tags

    var evaluators: Evaluators {
        // Tag count is within the required 3–8 range.  ✅ verbatim, BookTags.swift:60-66
        Evaluator { _, subject in
            let count = subject.value.tags.count
            if count >= 3 && count <= 8 {
                return tagCount.passing(rationale: "\(count) tags")
            }
            return tagCount.failing(rationale: "Got \(count) tags, expected 3–8")
        }

        // Records raw tag count.  ✅ verbatim, BookTags.swift:69-72
        // Scored, not pass/fail — this is the one that catches a collapsed distribution.
        Evaluator { _, subject in
            let count = subject.value.tags.count
            return tagTotal.scoring(Double(count))
        }

        // Tags must be single-word or hyphenated.  ✅ verbatim, BookTags.swift:75-80
        Evaluator { _, subject in
            for tag in subject.value.tags where tag.contains(" ") {
                return wordCount.failing(rationale: "Tag \(tag) contains multiple words")
            }
            return wordCount.passing()
        }

        // At least one tag names a known literary genre.
        // Concept attested at 298:169-171; this implementation is ordinary Swift.
        Evaluator { _, subject in
            let genres = subject.value.tags.filter {
                BookTaggingService.knownGenres.contains($0.lowercased())
            }
            return genres.isEmpty
                ? hasGenreTag.failing(rationale: "No genre among: \(subject.value.tags.joined(separator: ", "))")
                : hasGenreTag.passing(rationale: "Genre tags: \(genres.joined(separator: ", "))")
        }

        // At least one generated tag agrees with the maintainer's reference tags.
        // This is the one evaluator that needs the FIRST closure argument —
        // everything above discards it as `_`.
        Evaluator { input, subject in
            // No reference answer means nothing to compare against: exclude the sample
            // from this metric rather than failing it.
            guard let expected = input.expected else { return referenceOverlap.ignore() }
            let reference = Set(expected.tags.map { $0.lowercased() })
            let hits = subject.value.tags.filter { reference.contains($0.lowercased()) }
            return hits.isEmpty
                ? referenceOverlap.failing(rationale: "No overlap with reference tags")
                : referenceOverlap.passing(rationale: "Matched: \(hits.joined(separator: ", "))")
        }
    }

    // ── Step 4: how do I summarise it? ───────────────────────────────────────
    // ✅ shape and method names verbatim, BookTags.swift:129-142. Note `inout`.
    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.group("Heuristics") { group in
            group.computeMean(of: tagCount)                 // range-compliance RATE
            group.computeMean(of: wordCount)
            group.computeMean(of: hasGenreTag)
            group.computeMean(of: referenceOverlap)
        }
        aggregator.group("Distribution") { group in
            group.computeMean(of: tagTotal)                 // average number of tags
            group.computeStandardDeviation(of: tagTotal)    // ← 0 here means degenerate output
            group.computeVariance(of: tagTotal)
        }
    }
}
```

And the suite that runs it:

```swift prelude:external-module
// BookTrackerEvaluations/BookTagTests.swift
import Evaluations
import Testing
@testable import BookTracker

@Suite("Book Tag Evaluations")
struct BookTagEvaluationTests {

    // Must be `static let` — the test body reaches through it for Metric identity.
    static let evaluation = BookTaggingEvaluation()

    /// Metadata recorded alongside each run.  ✅ verbatim, BookTags.swift:151-156
    static let evaluationInfo: [String: String] = [
        "Prompt": BookTaggingService.instructions,
        "ModelName": "SystemLanguageModel",
        "AppVersion": "1.0",
        "Feature": "Automatic tag generation from book reviews"
    ]

    @Test("Book Tag Evaluations", .evaluates(evaluation, info: evaluationInfo))
    func evaluateBookTagging() async throws {
        // The trait has already run every sample through every evaluator and aggregated
        // the results. This body never iterates the dataset.
        let result = EvaluationContext.current.result

        let evaluation = BookTagEvaluationTests.evaluation

        // The optimization target: correct tag count at least 80% of the time.
        #expect(result.aggregateValue(.mean(of: evaluation.tagCount)) >= 0.8)

        // Single-word tags are a hard UI constraint, so hold this one higher.
        #expect(result.aggregateValue(.mean(of: evaluation.wordCount)) >= 0.95)

        // Every book should get at least one genre tag.
        #expect(result.aggregateValue(.mean(of: evaluation.hasGenreTag)) >= 0.9)

        // A standard deviation of zero means the model is emitting a constant count.
        // Passing range compliance with a collapsed distribution is a regression, not a win.
        #expect(result.aggregateValue(.standardDeviation(of: evaluation.tagTotal)) > 0)
    }
}
```

> ✅ **SDK-verified — `.standardDeviation(of:)` is a real case, and the case list is now closed.**
> `AggregationOperation`'s cases are `mean(of:)`, `median(of:)`, `mode(of:)`, `minimum(of:)`,
> `maximum(of:)`, `standardDeviation(of:)`, `variance(of:)` — each taking a `Metric` — plus
> `custom(label:)` (`Evaluations-27.0-macos.swiftinterface:431-444`, checked 2026-07-29). The enum
> mirrors the `compute…` registration methods one-for-one, so anything you can register in
> `aggregateMetrics(using:)` you can read back through `aggregateValue(_:)` with the matching case.
> Only `.mean(of:)` and `.custom(label:)` appear in shipping Apple code; the rest are now verified
> spellings rather than inferences.

Run it with ⌘U. What you get is not a green checkmark; it is a report. §11.

---

## 10. The quantitative / qualitative rule of thumb

Five expectations went into §1's table. Four of them became `Evaluator` closures in §9. The fifth —
*"tags should be informative, relevant to the book, and helpful for browsing your library"* — did not,
and no amount of cleverness will turn it into one.

Apple states the dividing line as a rule, and it is worth memorising verbatim because it settles an
argument you will otherwise have with yourself on every metric:

> ✅ **VERIFIED** (`298:275-278`), verbatim: *"**Use heuristics to measure quantifiable traits.** These
> rule-of-thumb metrics are a great way to start understanding your feature. **The rule-of-thumb is: if
> you can measure it in code, then it's quantitative. And if you can only describe it in words, then
> you need a qualitative metric, using a `ModelJudgeEvaluator`.**"*

Applied to the five expectations:

| Expectation | Measurable in code? | Mechanism |
|---|---|---|
| 3–8 tags | yes — `.count` | `Evaluator` + `Metric` |
| No title as a tag | yes — string comparison | `Evaluator` + `Metric` |
| No multi-word tags | yes — `contains(" ")` | `Evaluator` + `Metric` |
| Identifies a genre | yes — set membership against a known list | `Evaluator` + `Metric` |
| **Informative, relevant, helpful for browsing** | **no** | **`ModelJudgeEvaluator`** |

The test for "measurable in code" is not "could I write *some* code for this". It is whether the code
you would write is the thing you actually mean. You *could* write a regex for "informative". It would
not measure informativeness; it would measure whether the tag matched your regex, and you would spend a
month tuning the regex instead of the feature.

The failure this rule is protecting you from is documented, on camera, and it is the reason model
judges exist at all. Session 298 ran the heuristics against a review of *Alice in Wonderland*:

> ✅ **VERIFIED** (`298:191-198`), verbatim: *"Six tags, single word or hyphenated, with tags
> identifying genre. **Every quantitative metric we built with Rob passed.**"*
>
> *"But look closer. **'Overrated' and 'pretentious' doesn't describe the book — they describe how the
> reader felt about it.** And **'whodunit' isn't even the right genre**. The model picked it up from
> 'riddles he never answers.' **It latched onto the language of the review without understanding the
> book.** Our metrics are passing, but they're not giving us the right signals back."*

Four green metrics and a bad feature. That is not a bug in the metrics — each one measured exactly what
it claimed to. It is a gap in *coverage of the spec*, and it is only visible because someone read the
output.

Two practical corollaries:

**Heuristics first, always.** They are deterministic, they cost nothing, they run in milliseconds, and
they will catch the majority of your early regressions. Apple's ladder starts here for a reason. A
model judge that you add before you have a working heuristic layer is a judge whose disagreements you
cannot interpret.

**A green board is not a finished loop.** Session 335 opens on exactly this state — every expectation
met, output still not good enough:

> ✅ **VERIFIED** (`335:52`): *"In this case, **my Evaluation met all of my expectations; however,
> because I know the tags aren't as good as I'd like them to be, I need to investigate further.**"*

When your tests pass and your output is bad, the defect is in your *measurements*, not your feature.
Either you are missing a metric, or the metric you have is asking the wrong question, or — if it is a
judge — your rubric says something other than what you meant. Sessions 298 and 335 spend most of their
runtime on that third case; it gets the model-judge guide in this part.

---

## 11. The Xcode 27 Evaluations report

> ✅ **VERIFIED** (`299:97`): *"**In Xcode 27, we introduced a new Evaluations Report to visualize your
> results.**"*

Running an evaluation produces a test result like any other, but the interesting output is not in the
test navigator. It is a separate report:

> ✅ **VERIFIED** — `/documentation/evaluations/evaluating-language-model-responses`, verbatim: *"When
> the run finishes, open the **Report navigator** and select the **Evaluations** item beneath the test
> run to open the evaluation report."*
>
> Session 298 narrates the same path (`298:103-105`): *"Click on the **report navigator**, and then
> select **Evaluations** in the test report."* … *"Here's the evaluation report for the test suite.
> Let's **double click the row** to find out more."*

### The layout

> ✅ **VERIFIED** (`335:56-58`), verbatim: *"This brings up the Evaluation detail view. **On the top are
> our aggregate metric charts. And below is our table of results.**"*

So: **charts of your aggregate metrics on top, a per-sample results table underneath.** Those charts
are exactly what you registered in `aggregateMetrics(using:)` — which is the concrete reason the
grouping in §7 matters. `aggregator.group("Heuristics")` and `aggregator.group("Distribution")` are not
bookkeeping; they are the sections of the chart area.

Session 298's summary of what that produced for Book Tracker (`298:175-176`): *"We track our three
expectations using **five aggregate metrics**. Here, we can see the **distribution of tags**, along
with **range compliance** and **containing genre tags**."* Three expectations, five charts — because
tag count contributes both a compliance rate and a distribution.

### The results table, and the assistant editor

> ✅ **VERIFIED** (`298:106-111`), verbatim: *"my TagCount metric only passed 50% of the time."* …
> *"a quick look at the **full results table** shows me that my 'Pride & Prejudice' sample produced a
> failure. But my 'Dracula' sample produced the correct number of tags."* … *"I can **select each row
> in the table** to see more details, using the **assistant editor** in Xcode."* … *"**The detail panel
> shows the prompt, and each measurement** for the ModelSample. **At the bottom, you see the entire
> response from the model.**"*

Three things per row, then:

1. **The prompt** — the sample's input, as sent.
2. **Each measurement** — every metric that fired for that sample, *with its rationale string*. This is
   what those `rationale:` arguments in §6 buy you. `tagCount.failing(rationale: "Got 9 tags, expected
   3–8")` is the difference between a red cell and a diagnosis.
3. **The full model response** — at the bottom, in full, not truncated.

For a model judge, the rationale is not garnish; it is the payload:

> ✅ **VERIFIED** (`298:230-231`): *"**With model judges, rationales are essential. They give you a
> window into why the judge scored what it scored.**"* And from
> `/documentation/evaluations/designing-effective-model-judges`: *"When the model as judge scores a
> response, **it also produces a written rationale explaining its reasoning. These rationales appear in
> the detailed results alongside the score for each sample.** When scores seem wrong or inconsistent,
> the rationales usually show you why."*

Session 335's whole analysis phase is done in this panel (`335:143`): *"To do that, **I need to open
the assistant and view the results in detail.**"* If you are hill climbing and you are not reading
individual rows, you are guessing.

### Compare: the button the loop is built on

> ✅ **VERIFIED** — `/documentation/evaluations/evaluating-language-model-responses`: *"For a
> **side-by-side view**, choose **Compare** and select a run for each side."*
>
> ✅ **VERIFIED** (`299:100-101`): *"I've went ahead and ran the evaluation with our new dataset of 100
> samples. Now, we can compare the two evaluations using the **Compare** button and **we're expecting
> the scores to drop!**"*
>
> ✅ **VERIFIED** (`335:156`): *"Fortunately, **in Xcode 27, we've made so you can compare the results
> of two evaluations against each other.**"* And (`335:178-179`): *"From the evaluation report I can
> open the **comparison button** and open my baseline evaluation. **Here, I can review the scores of
> the two prompts side by side.**"*

Two distinct uses appear in the sessions and they are worth separating:

- **Run-to-run** — same evaluation, two points in time. "Did my change help?"
- **Evaluation-to-evaluation** — two `Evaluation` instances in one suite, one run. "Which of these two
  configurations is better?" This is the control/experimental pattern (§14) and it is why session 335
  runs both evaluations in the same suite: *"With both prompts written, **I can add both evaluations to
  a test suite, which will run both evaluations.**"* (`335:167`).

The comparison is only as informative as the `info:` you stamped on each run. A side-by-side of two
numbers tells you which is bigger. A side-by-side of two numbers *plus the two prompt texts* tells you
why — and lets you find the run again in three weeks. §8.5.

Session 335 reads the comparison view at the row level, not just the summary:

> ✅ **VERIFIED** (`335:180-183`): *"One thing that jumped out to me immediately is the discrepancy
> between usefulness scores of this review of **'Picture of Dorian Gray'**… **I noticed that all the
> scores are either a 3 or 2, which is way too harsh.**"*

That diagnosis — a clustered score distribution meaning a badly calibrated rubric, not a bad feature —
is only visible if you look at the spread of individual rows. Aggregates hide it.

> 🔴 **GAP — no screenshots, no keyboard shortcuts, no export path from the report UI.** Everything
> above is reconstructed from spoken narration plus two doc sentences. We cannot tell you what the
> Compare picker looks like, whether it can diff more than two runs, whether it can pin a run as a
> permanent baseline, whether the charts are exportable, or whether the report is reachable from
> `xcodebuild` output in CI. **What would resolve it:** Xcode 27 on a Mac and twenty minutes.
> **Safe default meanwhile:** do not build a workflow that depends on a UI affordance nobody has
> confirmed. `EvaluationResult.saveJSON(to:)` and `loadJSONLines(from:)` (§8.4) are ✅ documented API,
> and a run history you write yourself as JSONL will outlive any report-navigator behaviour.

---

## 12. The attachment, and the meta-evaluation it unlocks

This is the least-known part of the framework and the one that makes the hardest thing in Part 6 —
calibrating a model judge against a human — actually possible. Teach it, because reading the session
without noticing it leaves you stuck.

### Every run writes its data out

> ✅ **VERIFIED** — `EvaluationTrait`'s own documentation, verbatim: *"A test trait that runs an
> evaluation and **records the result as attachments**."*
>
> ✅ **VERIFIED** (`335:115-118`), verbatim: *"My evaluation from before contains a collection of
> reviews and tags. **Because I ran this evaluation in a test, Xcode generated an attachment containing
> all of the evaluation data that was generated. I can retrieve that attachment and extract summary and
> tag pairs.** Now, with the summary and tag pairs extracted, **I need to add my ratings**. After that,
> I can pass the contents of this file as the input to my evaluation."*

So: you do not have to instrument anything to capture what your feature produced. **Running the
evaluation already captured it.** Every prompt, every response, every measurement, for every sample.

### The on-disk format

Book Tracker ships a second command-line target whose entire job is to parse that artefact, which is
how we know its shape at all:

> ✅ **VERIFIED** — `DatasetExtractor/main.swift`, a 167-line CLI target in the Book Tracker archive
> that parses **Xcode's `.xcevalresult` bundle**. The structure (`main.swift:15-32`, `:94-131`):
>
> ```
> { "results": [ { "Input": "<escaped JSON string>",
>                  "Response": { "value": "<string>" }, … } ] }
> ```
>
> where the escaped `Input` string decodes to `{ "input": { "prompt": "…" } }`. Default output is
> `~/Desktop/<BaseName>-extracted.json` (`:153-162`). The tool depends on **`ArgumentParser`**.
>
> **This format is documented nowhere else** — not in a session, not in a doc article. The sample is
> the only source.

Note the closing comment the sample's author left, which is a genuinely useful Swift fact and not
about evaluations at all (`DatasetExtractor/main.swift:165-167`):

```swift prelude:guide-context
// @main cannot be used in main.swift — Swift's implicit top-level entry point and
// @main are mutually exclusive. Calling .main() explicitly is the equivalent.
DatasetExtractorCommand.main()
```

### The round trip

Put those pieces together and you get the workflow that session 335's judge calibration is built on:

```
  1.  Run BookTaggingEvaluation in Xcode           (⌘U)
        ↓  Xcode writes an attachment
  2.  Export the .xcevalresult bundle
        ↓
  3.  swift run DatasetExtractor <bundle>
        ↓  ~/Desktop/BookTaggingEvaluation-extracted.json
  4.  A human expert scores every row              ← the only manual step
        ↓  adds expertRelevanceScore / expertUsefulnessScore columns
  5.  Ship the scored file back into the test bundle
        ↓  BookTaggingEvaluation-extracted.json
  6.  ModelJudgeAlignmentEvaluation reads it as its dataset
        ↓  subject(from:) does NO inference — it replays the frozen output
        ↓  the SAME ModelJudgeEvaluator scores each row
  7.  aggregateMetrics computes Cohen's kappa between judge and human
        ↓
  8.  #expect(result.aggregateValue(.custom(label: "…")) > 0.6)
```

> ✅ **VERIFIED** — the bundled fixture `HillClimbingEvaluations/BookTaggingEvaluation-extracted.json`
> **is literally the output of that pipeline plus the expert columns**, and
> `ModelJudgeAlignmentEvaluation.swift` reads it as its dataset. Step 6's no-inference subject is quoted
> in §4; step 7's custom aggregation is quoted in §7; step 8's assertion is quoted in §8.4.

Three properties of this loop are what make it work, and each is a technique on its own:

**The judge and the human score identical rows.** Not "the same prompts" — the same *outputs*.

> ✅ **VERIFIED** (`335:112-113`): *"For this evaluation to work properly, **both my model judge and I
> need to evaluate the exact same dataset**. In this case the model judge reviews tags, so I need to
> produce a **common set of tags** for the judge and I to review."*

If you re-ran the feature to generate fresh output for the judge, you would be measuring the judge and
the feature's nondeterminism at once, and you could not attribute a disagreement to either.

**The subject does no inference**, so the meta-evaluation is fast, free, and repeatable. You can hill
climb the judge's prompt a dozen times in an afternoon without burning a single feature inference.

**The evaluator is the *same* `ModelJudgeEvaluator` instance-shape as production.**

> ✅ **VERIFIED** (`335:123-124`): *"my evaluator is **the exact same model judge evaluator as in our
> book tags evaluation. This is where the judge provides its rating.**"*

⚠️ With one wrinkle the sample makes visible and the session does not mention: the two
`ScoreDimension` definitions are **deliberately re-worded** between `BookTags.swift:43-56` and
`ModelJudgeAlignmentEvaluation.swift:175-189` (✅ both in the archive). The calibration copy encodes the
human's *generosity* — "small drift … is acceptable". **Tuning the dimension text is itself part of the
hill climb**, so "the same evaluator" means the same *type and role*, not a byte-identical prompt.

The mechanics of κ, the 0.6 threshold, drift, and the six labelled worked examples in Book Tracker's
67-line judge prompt belong to the model-judge guide in this part. What belongs here is the structural
move: **an evaluation's output is data, and data can be the input to another evaluation.** Once you see
that, "evaluate your evaluators" stops sounding recursive and starts sounding obvious.

> ✅ **VERIFIED** (`335:255-256`): *"Finally, watch out for drift. **It can feel a bit meta to evaluate
> your evaluators but a well tuned model evaluator will save you time in the long run.**"*

### Doing it without the CLI

You do not have to reproduce `DatasetExtractor` to get the round trip. `EvaluationResult` can write
itself out from inside the test body:

```swift prelude:guide-context
@Test("Book Tag Evaluations", .evaluates(evaluation, info: evaluationInfo))
func evaluateBookTagging() async throws {
    let result = EvaluationContext.current.result
    #expect(result.aggregateValue(.mean(of: Self.evaluation.tagCount)) >= 0.8)

    // Keep a durable, diffable record independent of Xcode's report UI.
    // `saveJSON(to:)` takes a DIRECTORY; the framework names the file and returns its URL.
    let runsDirectory = URL.documentsDirectory.appending(path: "runs")
    let written = try result.saveJSON(to: runsDirectory, includeReportMetadata: true)
    print("run saved to \(written.path())")
}
```

> ✅ **SDK-verified signature, 🟡 unverified usage.** The exact declaration is
> `@discardableResult func saveJSON(to directory: URL, includeReportMetadata: Bool = false,
> includeTranscripts: Bool = false) throws -> URL`
> (`Evaluations-27.0-macos.swiftinterface:581-597`, checked 2026-08-23; beta 5 added the defaulted
> `includeTranscripts:`) — the parameter is a
> **directory**, not a file path, which is why the snippet above no longer builds a filename from
> `evaluationID`/`resultID` by hand. The same block pins the rest of the round trip:
> `static loadJSON(from:)`, `init(jsonData:)`, an async `static loadJSONLines(from:)`, and — easy to
> miss because it hangs off `Collection` — `[EvaluationResult].saveJSONLines(to:includeReportMetadata:)`
> for appending a run history as JSONL (`:598-610`). No sample calls any of them, and whether
> `saveJSON`'s output matches the `.xcevalresult` shape `DatasetExtractor` parses is still unknown —
> the `.xcevalresult` route remains the one with a compiling reference implementation.

Either way, the durable-record habit is what turns a test suite into a time series, and a time series is
what §18 needs.

---

## 13. Hill climbing: the loop, and why it needs science

Everything so far builds one measurement. Hill climbing is what you do with it.

> ✅ **VERIFIED** (`335:8`), verbatim: *"The Evaluations framework also allows you to **hill climb,
> which is a process of iteratively improving the quality of your feature using the scores of your
> evaluation as a guide**."*

The loop has three named phases (`335:9-12`), verbatim:

1. **Develop** — *"making some change you want to measure against your existing feature."*
2. **Evaluate** — *"Once all your changes are made, you then need to run the evaluation. And see if the
   results have passed your expectations."*
3. **Analyze** — *"From there, you analyze the results to understand how your feature could be further
   improved."*

Session 298 gives the same loop a name once you organise your work around it:

> ✅ **VERIFIED** (`298:181`), verbatim: *"**When you take our hill-climbing feedback loop, and center
> your development process around it, we call it evaluation-driven development.**"*

And the term "hill climbing" is introduced at the exact moment someone forms a hypothesis and tests it
(`298:123-126`): *"This is an interesting theory. Let's make that change. Then re-run the evaluation to
see if I'm right. **We call this process hill-climbing.**"*

Two prerequisites, stated up front by the session and worth honouring:

> ✅ **VERIFIED** (`335:17-18`): *"this video is about the process of hill-climbing an **existing**
> evaluation. That means **you've already written the foundations of an evaluation pipeline**, which
> provides a wholistic understanding of the strengths and weaknesses of your intelligence-powered
> feature."*

You cannot climb a hill you cannot measure. If §§4–9 are not done, iterating on your prompt is not hill
climbing; it is the same vibes-based tuning you were doing before, with more ceremony.

The second prerequisite is the one people skip:

> ✅ **VERIFIED** (`335:13-14`), verbatim: *"Leveraging the hill-climbing process is a great way to
> systematically improve your feature, but **effective hill-climbing takes a little bit more than just
> following the loop. It also takes a little bit of… Science!**"*

### One full turn of the loop, as it actually happened

Session 298's first iteration is short enough to reproduce end to end, and it is instructive because it
*succeeded and created a new problem*:

| Phase | What happened | Evidence |
|---|---|---|
| Measure | `TagCount` passes 50% of the time | `298:106` |
| Analyse | The failing sample generated 9 tags; the passing one 7 | `298:107-108` |
| Hypothesise | *"I have a hunch… **I could specify a `count` property in that `@Guide`, which can take a range.**"* | `298:119-122` |
| Develop | Add `.count(3...8)` to the `@Guide` on `BookTags.tags` | ✅ shipped in `BookTaggingService.swift:14-15` |
| Evaluate | *"My test passed, and my TagCount passes a 100% of the time."* | `298:127-128` |
| Analyse | *"**But I notice a potentially strange behavior: after my change, the service always generates eight tags.**"* | `298:129-130` |
| Next turn | Add a **scored** `TagTotal` metric and aggregate its spread | `298:163-166` |

That is the loop working correctly. The change was right, the metric went green, and the *analysis
step* caught what the metric could not see. Skipping analysis because the board is green is how you
ship a feature that emits eight tags forever.

Note the belt-and-braces that fell out of it, which Book Tracker keeps in the shipping code: the 3–8
range is asserted **three times** — in the `@Guide`, in the instructions prose, and in a heuristic
`Evaluator`. ✅ all three verified in the archive. The implicit lesson is the sample's, not ours: **a
`@Guide` is a hint, not a guarantee, so measure it anyway.** (More on the limits of guides in
[`../../part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md).)

### The instructions become a changelog

> ✅ **VERIFIED** (`298:177-180`): *"Using our hill-climbing methodology, we've iterated on our
> instructions for the service. Here's where we started at the beginning. After several updates to our
> evaluation and multiple runs through our loop. **And we can track each change to our instructions, by
> an expectation we added to our evaluation to verify that change.**"*

Read that last clause carefully, because it is a discipline you can adopt today and it costs nothing:
**every line you add to your instructions should have an expectation that verifies it.** A rule in the
prompt with no metric behind it is an assertion you have never tested. Book Tracker's instructions and
its five heuristics line up nearly one-to-one, which is not an accident.

The reverse is also true and is the reason `info: ["Prompt": …]` exists: when a score moves, you want
to see the prompt text on both sides of the comparison, not a version number you have to go look up.

---

## 14. Control, experimental, one variable, backport

The "science" in §13 is not a metaphor. Session 335 lays out the experimental design explicitly.

> ✅ **VERIFIED** (`335:158-160`), verbatim: *"In a science experiment, you have two groups. **The
> control group, which represents the baseline** and **the experimental group which represents the
> change we are trying to compare against.** We can think of the two versions of our instructions in
> the same way, where the **control group is represented by our base prompt** and our **experimental
> group is represented by our newly changed prompt**."*

Mechanically, that means **two `Evaluation` instances in one suite**:

> ✅ **VERIFIED** (`335:167`): *"With both prompts written, **I can add both evaluations to a test
> suite, which will run both evaluations.**"* And (`335:230`): *"So all I have to do is **define two
> instances of my evaluation**. One without the tool and one with it."*

Which is why §15's evaluation takes its variable as an *initialiser parameter* rather than hardcoding
it. Parameterise the thing you are varying; instantiate it twice.

```swift illustrative
@Suite("Tag Quality — prompt experiment")
struct TagPromptComparison {
    static let control      = BookTaggingEvaluation(instructions: Prompts.baseline)
    static let experimental = BookTaggingEvaluation(instructions: Prompts.candidate)

    @Test("control", .evaluates(control, info: ["Prompt": Prompts.baseline]))
    func baseline() async throws { … }

    @Test("experimental", .evaluates(experimental, info: ["Prompt": Prompts.candidate]))
    func candidate() async throws { … }
}
```

> 🟡 **RECONSTRUCTED** — the two-instance-in-one-suite pattern is ✅ attested twice in session 335 and
> every symbol above (`.evaluates(_:info:)`, `static let`) is ✅ verified, but **no sample file shows
> two evaluations in a single suite with an `info:` on each.** Book Tracker's control/experimental pair
> lives across two test bundles rather than one suite. The shape is right; treat the exact layout as
> provisional.

### Rule 1 — one variable at a time

> ✅ **VERIFIED** (`335:242-245`), verbatim: *"**Hill-climbing works best when you focus on making one
> change at a time. To do this, treat every iteration of the loop like a science experiment. Being able
> to isolate your changes will help you to understand how each part of your feature contributes to the
> overall quality. Knowing how each part works individually will also help you to know where you might
> need to make changes to resolve a bug or unwanted pattern later down the line.**"*

The second half of that quote is the underrated part. One-variable-at-a-time is not only about
attribution today; it is about being able to *localise a regression six months from now*. If you
changed four things and the score went up, you have learned that four things together are better than
nothing, which is almost no information.

### Rule 2 — backport the winner into the baseline before the next experiment

This is the procedural detail that makes rule 1 actually hold, and it is the single most skippable
step in the whole method:

> ✅ **VERIFIED** (`335:186-187`), verbatim: *"**But before I can make changes to the experimental
> evaluation, I applied the new prompt from my experimental evaluation into my baseline. This ensures
> there's only one different variable.**"*

Think about what happens if you skip it. Round 1: baseline B vs experimental B+*x*. The experimental
wins, so you keep *x*. Round 2: you add *y* to the experimental — but the baseline is still B. You are
now comparing B against B+*x*+*y*, and a win tells you nothing about *y*. Two rounds in, your "control"
is a historical artefact and every subsequent comparison is measuring the accumulated diff.

So the cycle is four steps, not three:

```
   1. run control vs experimental                (one variable apart)
   2. decide: keep the change, or discard it
   3. IF KEPT: copy the change INTO the control  ← the step everyone skips
   4. make the next change in the experimental   (again one variable apart)
```

Note that step 2 is a *judgement*, not a threshold. Session 335's first iteration produced a genuinely
mixed result and was kept anyway:

> ✅ **VERIFIED** (`335:170-175`): *"**my alignment scores for relevance improved. While my alignment
> score for usefulness dropped considerably.**"* … *"**Balancing tradeoffs like this are tricky so I
> need to think carefully how to proceed. But before in depth analysis comes checking if we passed. And
> my test confirms the obvious, we haven't.**"* … *"After thinking about it further, **I am going to
> keep this prompt change and focus the next round of iteration on improving my usefulness score.**"*

A failing test did not end the loop; it directed the next iteration. That is the correct relationship
between the suite and your judgement — the numbers tell you *where* to look, and you decide what to do.

### Rule 3 — failed experiments are results

> ✅ **VERIFIED** (`335:246-248`), verbatim: *"**Second, this process takes time. Not every change you
> make will result in positive change. However, failed experiments tell you just as much as successful
> ones.**"*

A change that moved nothing tells you the model was never attending to that part of the prompt. A
change that made things worse tells you which direction the gradient points. Both are information you
did not have this morning, and both are cheap because the evaluation is automated. The thing to avoid
is the un-run experiment — the change you reasoned about, convinced yourself of, and shipped.

### Rule 4 — three iterations, and what each one taught

Session 335's three prompt iterations are a good template because each targets a different *kind* of
deficiency:

| # | Change | Result | Lesson |
|---|---|---|---|
| 1 | *"a more thorough description about how to judge… context about the app… examples of good tags. As well as ways to identify bad tags"* (`335:163-166`) | relevance ↑, usefulness ↓ (`335:170-171`) | **Context helps unevenly.** Trade-offs are normal; pick which score to chase next. |
| 2 | *"being more specific about how to grade each scoring dimension"* — relevance *"emphasizes the need for a genre tag"*, usefulness *"emphasizes being more critical of overly specific tags"* (`335:184-191`) | *"the scores both improved greatly over the baseline"* (`335:193-194`) | **Sharpen the rubric before you sharpen the prompt.** Vague criteria produce clustered scores. |
| 3 | few-shot: *"examples of the way I judge things, which should give it a pattern for how to judge according to my scale"* (`335:204-208`) | *"finally my scores are over my expected value! Which means I've finally passed and can exit out of the loop!"* (`335:212`) | **Examples beat description** once the description is already specific. |

And the warning attached to iteration 3, which applies to every few-shot prompt you will ever write:

> ⚠️ ✅ **VERIFIED** (`335:210`), verbatim: *"**I've made sure to only give the model a few examples. By
> giving it a longer list I am prone to overfit the alignment score, which would make it hard to tell
> if my judge is actually aligned with me.**"*

Overfitting to your own eval is the failure mode that a passing suite cannot detect, because the suite
is the thing you overfit to. The defences are the ordinary ones: keep the example count small, keep
some samples out of the prompt entirely, and grow the dataset (§5) faster than you grow the prompt.

---

## 15. Hill-climbing something that is not a prompt

Every worked hill-climb up to this point has changed a string. Session 335 closes by changing the
feature's *architecture* instead, and it is the more interesting example because of what it forced on
the API design.

> ✅ **VERIFIED** (`335:214`): *"So far we've seen how to hill climb on prompts… now I'd like to show
> you how to improve your feature through **something other than your prompts**."*

The hypothesis:

> ✅ **VERIFIED** (`335:217-221`), verbatim: *"What I want to do is **give the model some more context
> about the book it's generating tags for.** I think the additional context will help the model generate
> more relevant and useful tags. Better still, **Book Tracker already has the data needed for this
> because we store the author's name and book title when they write their review.** So, to help the tag
> generator, **I've created a tool to get additional information on the book, which provides the book
> title and author if they are available. Adding this tool is a form of hill-climbing because we are
> attempting to improve the quality of our feature through an incremental change.**"*

Note what the tool actually does: it returns data **the app already has**. This is not retrieval from
the internet; it is handing the model context it was previously being denied. That is often the highest
-value tool you can add, and it is invisible if you only ever tune prompts.

### The API-design move

Here is the part worth stealing, and it is one line:

> ✅ **VERIFIED** (`335:224-225`), verbatim: *"**`BookTaggingService` now takes a list of tools as
> input. I also set the default to an empty array so my existing evaluation won't need any changes.**"*

```swift prelude:guide-context
struct BookTaggingService {
    static func generateTags(
        for review: String,
        tools: [any Tool] = []          // ← the whole trick
    ) async throws -> BookTags {
        let session = LanguageModelSession(
            model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
            tools: tools,
            instructions: instructions
        )
        let response = try await session.respond(
            to: Prompt("Generate tags for this review:\n\n\(review)"),
            generating: BookTags.self
        )
        return response.content
    }
}
```

> 🟡 **RECONSTRUCTED** — the `tools:` parameter with an `= []` default and its motive are ✅ quoted
> verbatim from `335:224-225`; the surrounding body is §9's ✅-verified session construction with
> `tools:` threaded through. `LanguageModelSession(model:tools:instructions:)` is ✅ verified in Book
> Tracker (`SearchBooks.swift:556-560`). The exact signature of the shipped `generateTags` after this
> change is not in our corpus.

Three things follow from that default, and they are all worth naming as a design lesson rather than a
trick:

**The existing evaluation kept compiling and kept meaning the same thing.** `subject(from:)` calls
`generateTags(for:)` with no `tools:` argument, gets an empty array, and produces exactly the behaviour
it produced yesterday. Your baseline did not move.

**The control group is now free.** Before the change, "no tools" was the only possible configuration.
After it, "no tools" is a *value you can pass*, which means control and experimental differ by an
argument rather than by a git branch. Session 335's suite is two instances of one evaluation type:

> ✅ **VERIFIED** (`335:227-229`), verbatim: *"Here is the new evaluation I wrote. **It's exactly the
> same as the other evaluation. The only difference is I now pass my new lookup tool in the tools
> array.**"*

```swift illustrative
struct BookTaggingWithToolsEvaluation: Evaluation {
    let tools: [any Tool]                       // the ONE variable

    func subject(from sample: ModelSample<BookTags>) async throws -> ModelSubject<BookTags> {
        let result = try await BookTaggingService.generateTags(
            for: sample.promptDescription,
            tools: tools
        )
        return ModelSubject(value: result)
    }

    // …dataset, evaluators, aggregateMetrics: byte-identical to BookTaggingEvaluation
}

@Suite("Tag quality — book-lookup tool")
struct TagToolComparison {
    static let control      = BookTaggingWithToolsEvaluation(tools: [])
    static let experimental = BookTaggingWithToolsEvaluation(tools: [BookLookupTool()])
    …
}
```

**Defaulted parameters are how you make a feature A/B-able without forking it.** Generalise past tools:
`model: any LanguageModel = SystemLanguageModel(…)`, `instructions: String = Self.instructions`,
`options: GenerationOptions = .init()`. Every one of those becomes a hill you can climb, and every one
of them keeps every existing caller — including your evaluation suite — working untouched. If you are
about to duplicate an evaluation file to change one thing, add a parameter instead.

### What the experiment found, and the honest ending

> ✅ **VERIFIED** (`335:233-234`): *"**my service which uses tools met all my expectations**, so things
> are looking good. **But, my dataset for Book Tracker contains only 13 book and review pairs, that
> doesn't cover the wide variety of books and reviews a user might submit for tagging.**"*

> ✅ **VERIFIED** (`335:236-237`): *"I can see that **the service with the tool is performing better,
> however it does seem like my tool isn't being called in all the places I think it needs to. What I
> really need is a way to tell whether or not my tool has been called in the right situations.**"*

Two open problems, and each one is the subject of another guide in this part:

- *"only 13 book and review pairs"* → **synthetic data**. `SampleGenerator` and `makeSamples`, and the
  reality check that arrives when you go from 13 to 100 and the scores drop (`299:100-102`).
- *"whether or not my tool has been called in the right situations"* → **trajectory evaluation**.
  `ToolCallEvaluator(allPass:percentagePass:)`, `TrajectoryExpectation`, `ToolExpectation` and the nine
  `ArgumentMatcher` cases including `.naturalLanguage(argumentName:criteria:)`.

The second one is worth previewing here only because of the framing, which is the best sentence in
session 299:

> ✅ **VERIFIED** (`299:122-124`), verbatim: *"**Here's the thing. A model might give you a
> reasonable-sounding answer without ever calling the right tool. The final output can look correct
> while the path to get there isn't right.**"*

An output-only evaluation of a tool-using feature is a partial evaluation, and it is partial in exactly
the direction that hides your worst bugs. Once you have added a tool as a hill-climb, you need to
measure the trajectory too — and because `ModelSubject(value:transcript:)` is already sitting in the
API you have been using since §4, that turns out to be a small change.

---

## 16. Everything you can turn

The knobs are not just prompt text, and session 335's recap is the most complete enumeration anyone has
published:

> ✅ **VERIFIED** (`335:249-253`), verbatim: *"**Third, good experiments require creativity. In an
> intelligent feature there are so many things you can change. In your feature you can change the
> instructions, the tools, as well as the model or models you use to generate responses. On the
> evaluation side you can change the dataset, aggregation methods, and even the evaluators themselves.
> Everything is fair game.**"*

| Side | Knob | What changing it looks like | Where it is covered |
|---|---|---|---|
| Feature | **Instructions** | rewrite the prompt; add examples; add a reasoning field | §13–14; Part 2 guide 1 |
| Feature | **Tools** | add, remove, or re-describe a tool | §15; Part 2 guide 3 |
| Feature | **Model** | `SystemLanguageModel()` → `PrivateCloudComputeLanguageModel()`; a different `useCase:`; a BYO backend | Part 4 |
| Feature | **Guides & schema** | `@Guide(.count(3...8))`; simplify a `@Generable` type | Part 2 guide 2 |
| Feature | **Guardrails / options** | `SystemLanguageModel(guardrails:)`, `GenerationOptions` | Part 2 guide 6 |
| Evaluation | **Dataset** | more samples; more coverage; adversarial rows; synthetic expansion | §5; the datasets guide |
| Evaluation | **Aggregation methods** | add a standard deviation; add a `custom(of:label:)` statistic | §7 |
| Evaluation | **The evaluators themselves** | tighten a heuristic; split a judge dimension; reword a scale | §6; the judge guide |

Two of those deserve a warning label.

**Changing the model changes everything at once.** Swapping `SystemLanguageModel` for
`PrivateCloudComputeLanguageModel` changes capability, context window, latency, cost, availability and
privacy posture simultaneously, and it is the least "one variable" change on the list. Do it as its own
experiment, never bundled with a prompt change. (Session 298 makes the *judge*-side version of this
argument explicitly: *"**Your judge should be at least as capable as the model you're evaluating.**"* —
`298:208-210`.) Also note that Book Tracker's tagging service deliberately stays on-device for a
product reason, not a technical one:

> ✅ **VERIFIED** (`298:207`): *"Our BookTaggingService runs on-device because it needs to be fast and
> local for every user interaction."* And (`335:216`): *"readers tend to be in all kinds of places when
> cataloging books, so **using the on-device model ensures they can generate tags no matter where they
> are**."*

**Changing the evaluators moves the goalposts.** Tightening a heuristic or rewording a scale changes
what "0.85" *means*, which invalidates comparison against every earlier run. That is sometimes exactly
right — session 335 spends three iterations doing precisely this to its rubric — but be deliberate
about it, and stamp something in `info:` that lets future-you tell metric-change runs from
feature-change runs. A `"EvalVersion"` key costs nothing.

### What to do when a change makes scores drop

Session 299 enumerates the four candidate explanations, and the order is not accidental — check them in
this order (`299:103-110`), verbatim:

1. *"Score changes could be due to **problems with our prompt or instructions**. You could refine one or
   both to better capture your needs."*
2. *"You could also consider **gaps in your intelligence feature**."*
3. *"Or you may want to **adjust your evaluation to understand what you are actually evaluating on**."*
4. *"your **dataset may still not be representative enough** and need to capture more variation."*

> ✅ **VERIFIED** (`299:111`): *"**These are the core ways to further improve your results.**"*

The one people jump to is 1 and the one that is usually true early on is 4. A drop that appears the
moment you expand the dataset is almost never a regression — it is your first honest measurement.

---

## 17. ⚠️ The silent failures

The defining property of this stack is that most defects do not throw. An evaluation framework has a
particularly nasty version of the problem, because **a broken evaluation still produces a number**, and
a number is exactly the thing you have decided to trust.

Here they are collected, worst first.

### 17.1 A corrupt dataset shrinks your evaluation instead of failing it

> ⚠️ **SILENT FAILURE — `JSONLoader` skips malformed rows and only tells `OSLog`.**
>
> ✅ **VERIFIED** — `/documentation/evaluations/jsonloader`, verbatim: *"**Malformed entries are logged
> via `OSLog` and skipped.** A failure to open the file propagates as a thrown error."*

Read the asymmetry: a *missing file* throws, and your test goes red. A file with 100 rows of which 63
fail to decode **loads 37 rows, runs cleanly, and reports an aggregate over 37 samples.** Your test
still passes. Your report still renders. The dataset you thought you were measuring against silently
became a third of itself, biased toward whichever rows happened to survive.

This bites hardest exactly where it is most likely: the synthetic-data workflow (§5) writes JSON with
one tool and reads it with another, across a schema you are actively changing. Rename a property on
your `@Generable` expected type, forget to regenerate, and `JSONLoader` will quietly hand you an empty
dataset.

**The defence is a count assertion, and it belongs in every suite that uses `JSONLoader`:**

```swift prelude:guide-context
@Test("Synthetic Book Tags", .evaluates(evaluation, info: evaluationInfo))
func evaluateSynthetic() async throws {
    let result = EvaluationContext.current.result

    // Guard the dataset before you trust anything computed from it.
    let scored = result.detailed[metric: Self.evaluation.tagCount]
    #expect(scored.count == 100, "JSONLoader dropped rows — check OSLog for decode failures")

    #expect(result.aggregateValue(.mean(of: Self.evaluation.tagCount)) >= 0.8)
}
```

The `detailed[metric:]` subscript and `scores.count` are ✅ verified in Apple's own
`inspectDetailedResults` example (§8.4), where the last line is literally `#expect(scores.count == 5)`.
Apple wrote the defence into the doc sample without calling it one.

### 17.2 A perfect pass rate over a collapsed distribution

Covered in full in §7. Restated here because it is the one that will actually happen to you: a
`(3...8).contains(n)` metric reads **100%** whether the model produces a healthy spread or the identical
value on every sample. `@Guide(.count(3...8))` fixed the range and collapsed the output to a constant 8,
and the board went green (`298:127-130`).

**Rule:** every "is X in range" metric needs a companion `.scoring(X)` metric with a standard deviation
in the aggregate. A σ of 0 where you expect variance is the alarm.

### 17.3 Evaluating a differently-configured system

Covered in §4. `SystemLanguageModel(guardrails: .permissiveContentTransformations)` appears in **both**
Book Tracker's app service and its evaluation (✅ both call sites verified). Drop it from one and
everything compiles, runs, and reports a number about a model you do not ship. The same applies to
`instructions`, `useCase:`, `GenerationOptions`, and which `LanguageModel` you construct.

**Rule:** exactly one function builds the session. The app calls it and the evaluation calls it. If
your `subject(from:)` contains a `LanguageModelSession(...)` literal, ask why the app cannot call the
same code — and if the answer is "I need the transcript back", change the service to return it rather
than duplicating the constructor.

### 17.4 Two `Metric`s with the same name, or one metric constructed twice

Apple's minimal `Evaluation` example (§3) declares `let metric = Metric("Match")` as a stored property
and then **shadows it inside the evaluator closure** with a locally constructed `Metric("Match")`. Book
Tracker never does this, and its test body deliberately reaches through `static let evaluation` to get
the *instance*.

> ✅ **Probe-verified, 2026-07-31 — identity is by NAME, so the merge arm is the live hazard.**
> (was a 🔴 GAP; `probes/` `eval.metric-identity`, 27.0 sim runtime — full result in §8.2.) Two
> metrics with the same string **silently merge into one column and one pooled aggregate**, and
> nothing throws. The instance arm of the old dilemma is dead: a locally constructed
> `Metric("Match")` is found by `aggregateMetrics` and `aggregateValue` just fine.
>
> **Safe default unchanged, sharper reason:** one stored property per metric, unique names,
> referenced everywhere. The thing to police is the *name*: two evaluators reusing a name
> unintentionally pools unrelated measurements into one mean, silently.

### 17.5 An aggregate computed over nothing

`.ignore()` excludes a sample from a metric's aggregation, and the idiom Apple shows for it is
`guard let expected = sample.expected else { return metric.ignore() }`. Now consider a prompt-only
dataset — which Apple explicitly recommends for judge-scored evaluations (§5) — run through an
evaluator written for a reference-carrying one. **Every sample ignores. The metric aggregates over zero
values.**

> ✅ **Probe-verified, 2026-07-31 — the answer is a `-1.0` sentinel.** (was a 🔴 GAP; `probes/`
> `eval.mean-over-all-ignored`, 27.0 sim runtime: an evaluator returning `.ignore()`
> unconditionally over 4 detailed rows yields `aggregateValue(.mean(of:)) == -1.0`.) Not zero, not
> NaN, no trap. The good news: `#expect(mean >= threshold)` fails loudly for any sane positive
> threshold. The bad news: **`-1.0` is also what `aggregateValue` returns for a metric that was
> never registered at all** (the probe suite confirmed that too, on an evaluation with empty
> `aggregateMetrics`), so a `-1.0` cannot tell you *which* of the two nothings you measured.
>
> **The safe default therefore stands unchanged:** if you mix reference-carrying and prompt-only
> samples, assert the scored row count as in §17.1 before asserting the aggregate. The sentinel
> saves you from a false green; only the row-count assertion tells you what actually ran.

### 17.6 A green suite over a bad feature

Not an API defect — a coverage defect, and the most common one. Four heuristics passed on tags that
included "overrated", "pretentious" and a wrong genre (`298:191-198`). Session 335 opens on a fully
green evaluation whose author knows the output is not good enough (`335:52`).

**Rule:** when tests pass and output is bad, fix the measurement, not the feature. Re-read §10 and ask
which of your five expectations has no metric behind it.

### 17.7 A failing sample that vanishes instead of failing

> ✅ **Probe-verified, 2026-07-31 — per-sample `subject(from:)` failures drop silently, and the
> score improves.** (was a 🔴 GAP; `probes/` `eval.subject-throws`, 27.0 sim runtime.) The exact
> resolving experiment was run: 5 samples, `subject(from:)` throwing on 2 of them. The run
> **completed** — no abort, no test failure from the throws alone — the failed samples still occupy
> detailed rows (`detailedRows=5`), and they are **EXCLUDED from the aggregate**: the mean over the
> 3 survivors came back **1.0** with 2/5 failing. The "silently improved score" hazard is no longer
> a hypothesis; it is reproduced fact.
>
> Background that predicted the drop-silently arm, kept for the record: the interface pass
> (2026-07-29) pinned `SubjectInferenceError.failed(reason: String)` and
> `EvaluatorError.failed(evaluator:evaluatorType:reason:)`
> (`Evaluations-27.0-macos.swiftinterface:505-527`), and `EvaluationError`'s deprecated
> `metricsNotFound(names:)` case carries Apple's own statement that *"missing metrics are
> materialized as ignored columns and logged."*
>
> This matters because guardrail false positives are real and rate-dependent, and because the
> on-device model refresh in 26.4 explicitly retuned them. A run that silently drops its five
> hardest samples reports an *improved* score — measured, not imagined.
>
> **The safe default is now a hard rule:** assert the scored row count (§17.1) in every test body.
> It is the one check that catches every member of this family, and the probe shows nothing else
> will.

### The pattern behind all seven

Six of these seven are the same shape: **something reduced the number of samples, or the meaning of a
sample, and the aggregate still computed.** An aggregate is a lossy summary and it cannot tell you what
went into it.

So make the *denominator* an assertion, not an assumption. One line at the top of every test body:

```swift prelude:guide-context
#expect(result.detailed[metric: Self.evaluation.someAlwaysFiringMetric].count == expectedSampleCount)
```

It costs nothing, it survives every unresolved GAP above, and it converts four silent failures into
loud ones.

---

## 18. Why this framework exists: there is no model version pinning

Everything in this guide has been presented as a development technique. It is also, structurally, the
only insurance policy available to you — and that is not our framing, it is Apple's.

> ✅ **VERIFIED — Apple Frameworks Engineer, developer forums thread 833642**, answering a direct
> question about model versioning: **there is no pinning API and no version-retrieval API.** The
> recommended mitigation named in the same answer is **the Evaluations framework, to catch regressions
> between OS updates.**

Sit with the shape of that. You cannot ask which model version you are running. You cannot request a
specific one. And the model does change:

> ✅ **VERIFIED** — `/documentation/foundationmodels/systemlanguagemodel`, verbatim: *"Apple
> periodically updates `SystemLanguageModel` in routine OS updates... Currently there are **3 model
> versions** that align with:
> - iOS, iPadOS, macOS, and visionOS **26.0 - 26.3**
> - iOS, iPadOS, macOS, and visionOS **26.4**
> - iOS, iPadOS, macOS, visionOS, **and watchOS 27.0**"*

Three model versions in roughly a year, delivered by point releases your users install automatically.
And the changes were not cosmetic. Apple's own release notes for 26.4, verbatim:

> ✅ **VERIFIED** — FoundationModels release notes: *"Use the latest on-device large language model that
> **improves instruction-following and tool-calling abilities**. **Because the model changes when a
> person updates to iOS 26.4, iPadOS 26.4, macOS 26.4, and visionOS 26.4, test your prompts with the new
> model**…"*

Plus a separate round of guardrail retuning:

> ✅ **VERIFIED** (`241:17-19`): *"You may have noticed adjustments in **iOS 26.4 to reduce the number
> of false [positives]**… continuing to make even more improvements in iOS 27."*

Any of those is capable of moving your feature's behaviour, in either direction, on a device you do not
control, on a day you did not choose.

### What Apple offers instead of pinning

Two things, and they are complementary rather than alternative.

**Version-gated prompts.** The Foundation Models documentation has an entire article on rewriting a
prompt per model version, and its examples are worth internalising:

> ✅ **VERIFIED** — `/documentation/foundationmodels/updating-prompts-for-new-model-versions`, verbatim:
>
> ```swift
> if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) {
>     return String(localized: "support-ticket-summarizer-v1.1", table: "Prompts")
> } else {
>     return String(localized: "support-ticket-summarizer-v1.0", table: "Prompts")
> }
> ```
>
> *"Order the availability attribute from the newest version to the oldest version… The availability of
> the Foundation Models framework starts at 26.0, so you don't need to check for versions prior to
> that."*

Note what that pattern concedes: **prompts are version-specific artefacts**, like any other piece of
code with an availability annotation. Which brings us to the sentence in that article that is really
about Evaluations:

> ✅ **VERIFIED**, verbatim: *"Because the older model is only included as part of the beta program,
> **it's essential to produce a record of what output your prompt produces with the prior model.**"*

A record of what output your prompt produces. That is an evaluation run. That is `info:` with the prompt
text stamped in it, saved as JSON, kept.

**An evaluation suite as the regression gate.** This is the load-bearing one. When 27.1 or 28.0 lands,
you do not reason about whether the model changed — you re-run the suite against the new OS and read
the diff. The pieces you need are already assembled:

- The **dataset** is stable, so the inputs are identical across OS versions.
- The **metrics** are defined independently of the model, so the criteria are identical. Apple says
  exactly this: *"Because you define your metrics before tuning prompts or switching models, **every
  change is measured against the same criteria.**"* (✅ `/documentation/evaluations/evaluating-language-model-responses`.)
- The **`info:` dictionary** records which prompt, which model, which build produced each run.
- The **Compare** view (§11) diffs two runs side by side.
- `EvaluationResult.saveJSON(to:)` / `loadJSONLines(from:)` keep a history that outlives an Xcode
  install.

Add `"OSBuild"` and `"ModelVersionBand"` keys to your `info:` today. You cannot query the model version,
but you *can* record the OS build that produced a run, and that is a sufficient proxy for the three-band
table above:

```swift illustrative
static let evaluationInfo: [String: String] = [
    "Prompt": BookTaggingService.instructions,
    "ModelName": "SystemLanguageModel",
    "OSBuild": ProcessInfo.processInfo.operatingSystemVersionString,
    "AppVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
    "Feature": "Automatic tag generation from book reviews"
]
```

> 🟡 **RECONSTRUCTED** — `.evaluates(_:info:)` taking `[String: String]` is ✅ verified, and every key
> above is free-form. The specific choice of `operatingSystemVersionString` is ours; nothing in Apple's
> material suggests a canonical key set beyond the four Book Tracker uses.

### The wider claim

There is one more reason to care, and it generalises past the built-in model. The whole 2026 stack is
built on the premise that you might swap backends —
`SystemLanguageModel`, `PrivateCloudComputeLanguageModel`, an MLX model, a Core AI bundle, an
OpenAI-compatible endpoint — behind one session API (Part 4). Every one of those substitutions is a
behaviour change you cannot reason your way through. The only honest way to make that choice is to
measure both, on your dataset, against your criteria.

Which is why Evaluations is a *cross-cutting* part of this series rather than a corner of Part 2. It is
not a testing convenience. It is the instrument that makes every other choice in the stack decidable —
and, given the absence of a pinning API, the only thing standing between a routine OS update and a
feature that quietly got worse.

---

## 19. Quick reference

### The whole protocol, on one screen

```swift illustrative
import Evaluations

struct MyEvaluation: Evaluation {                       // Sendable
    let accuracy = Metric("Accuracy")                   // identifier + result carrier

    var dataset = ArrayLoader(samples: [                // STORED, and a Loader
        ModelSample(prompt: "…", expected: MyOutput(…))
    ])

    func subject(from sample: ModelSample<MyOutput>)    // generic over the EXPECTED type
        async throws -> ModelSubject<MyOutput> {
        let value = try await MyFeature.run(sample.promptDescription)
        return ModelSubject(value: value)               // or (value:transcript:) for tool evals
    }

    var evaluators: Evaluators {                        // result-builder type, plural
        Evaluator { input, subject in                   // TWO args: (sample, subject)
            subject.value.isGood ? accuracy.passing() : accuracy.failing(rationale: "…")
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {   // inout
        aggregator.group("Quality") { group in
            group.computeMean(of: accuracy)             // pass/fail mean = pass RATE
        }
    }
}

@Suite("My Feature")
struct MyFeatureTests {
    static let evaluation = MyEvaluation()              // MUST be static let
    static let info = ["Prompt": MyFeature.instructions, "ModelName": "SystemLanguageModel"]

    @Test("My Feature", .evaluates(evaluation, info: info))
    func run() async throws {
        let result = EvaluationContext.current.result    // dataset already ran
        #expect(result.aggregateValue(.mean(of: Self.evaluation.accuracy)) >= 0.8)
    }
}
```

### Version floor

| Symbol | Earliest OS | Notes |
|---|---|---|
| Everything in `Evaluations` | **27.0** — iOS / iPadOS / Mac Catalyst / macOS / visionOS / watchOS | Beta. **No tvOS.** No back-deployment. |
| The `.evaluates` trait, the Evaluations report | **Xcode 27** | Report is an Xcode feature, not library code |
| `Transcript.structuredTranscript` | **27.0** (Evaluations extension) | requires `import Evaluations`; required for `ToolCallEvaluator` |
| `PrivateCloudComputeLanguageModel` | **27.0** | needs an entitlement; see Part 4 guide 1 |
| `SystemLanguageModel(guardrails:)` | **27.0** | `.permissiveContentTransformations` used by Book Tracker |
| `SystemLanguageModel` | **26.0** (watchOS **27.0**) | three model versions: 26.0–26.3, 26.4, 27.0 |
| `contextSize`, `tokenCount(for:)` | **26.4** | back-deployed attribute on `contextSize` |
| `Tool` | **26.0** (watchOS **27.0**) | |

### The corrections, if you have older material

| Spelling in circulation | ✅ Actual |
|---|---|
| `var evaluators: some Evaluator` | **`var evaluators: Evaluators`** |
| `Evaluator(metric) { output, sample in … }` | **`Evaluator { input, subject in … }`** — metric captured, not passed; args in that order |
| `.pass` / `.fail` / `.score(_)` | **`metric.passing()` / `.failing()` / `.scoring(_)` / `.ignore()`**, each with an optional `rationale:` |
| `subject(from:) -> T` | **`subject(from:) async throws -> ModelSubject<T>`** |
| `var dataset: [ModelSample] { … }` | **`var dataset = ArrayLoader(samples: …)`** — stored, and a `Loader` |
| `MetricAggregator` | **`MetricsAggregator`**, passed **`inout`** |
| `aggregator.average(of:)` | **`aggregator.computeMean(of:)`** |
| `.evaluates(evaluation, notes: …)` | **`.evaluates(evaluation, info: [String: String])`** |
| `func test(results: EvaluationResults)` | **`func test() async throws`** + `EvaluationContext.current.result` (type is `EvaluationResult`, singular) |
| `results.aggregateValue(for: "TagCount")` | **`result.aggregateValue(.mean(of: metric))`** / **`.custom(label:)`** |
| framework-provided Cohen's kappa | **hand-rolled** — 72 lines in the sample's `Statistics.swift` |

### The five steps

| # | Question | API |
|---|---|---|
| 1 | What code am I measuring? | `func subject(from:) async throws -> ModelSubject<T>` |
| 2 | What data am I sending it? | `var dataset = ArrayLoader(samples:)` / `JSONLoader(url:)` of `ModelSample<T>` |
| 3 | What am I measuring, and how? | `let m = Metric("…")` + `var evaluators: Evaluators` |
| 4 | How do I summarise it? | `func aggregateMetrics(using: inout MetricsAggregator)` |
| 5 | How do I run it? | `@Test(.evaluates(evaluation, info:))` + `EvaluationContext.current.result` |

### The hill-climbing cycle

```
develop → run → check expectations → analyse → repeat

  · control vs experimental, as two instances of ONE parameterised Evaluation
  · exactly ONE variable different
  · when the experimental wins, BACKPORT it into the control before the next round
  · a failed experiment is a result
  · a green board is not the end of the loop
```

### The rule of thumb

> *"If you can measure it in code, then it's quantitative. And if you can only describe it in words,
> then you need a qualitative metric, using a `ModelJudgeEvaluator`."* — `298:277-278`

### Checks to put in every test body

```swift prelude:guide-context
let result = EvaluationContext.current.result

// 1. The denominator. Catches JSONLoader drops, ignored samples, and subject failures.
#expect(result.detailed[metric: Self.evaluation.alwaysFires].count == expectedRowCount)

// 2. The optimization target.
#expect(result.aggregateValue(.mean(of: Self.evaluation.primary)) >= 0.8)

// 3. The distribution, wherever you have a range metric.
//    (.standardDeviation(of:) is an SDK-verified AggregationOperation case — §9.)
#expect(result.aggregateValue(.standardDeviation(of: Self.evaluation.primaryTotal)) > 0)
```

---

## 20. Sources, and where they disagree

### Evidence used, in precedence order

0. **The framework's shipped Swift interface** — `Evaluations-27.0-macos.swiftinterface` (885
   lines), dumped from the Xcode 27 beta's macOS `Evaluations.framework` on **2026-07-29** into
   `notes/sdk-interfaces/` in this repo. For *names, signatures, defaults, availability and case
   lists* it outranks everything below, including the sample; for *usage and runtime behaviour* it
   decides nothing. Cited inline as ✅ **SDK-verified** with line numbers.
1. **Apple sample code — Book Tracker**
   (`/documentation/evaluations/book-tracker-using-evaluations-to-evaluate-an-intelligent-feature`).
   20 Swift files, `MACOSX_DEPLOYMENT_TARGET = 27.0`, five targets: the app, two test bundles
   (`BookTrackerEvaluations`, `HillClimbingEvaluations`) and two command-line tools
   (`BookSampleGenerator`, `DatasetExtractor`). **This is the strongest evidence in the corpus and it
   outranks everything below wherever they conflict.** Files cited here: `BookTags.swift` (200 lines),
   `SearchBooks.swift` (578), `SyntheticBookTags.swift` (133),
   `ModelJudgeAlignmentEvaluation.swift` (353), `Statistics.swift` (72),
   `BookTracker/Services/BookTaggingService.swift` (101), `BookSearchTools.swift` (267),
   `BookSampleGenerator/main.swift` (87), `DatasetExtractor/main.swift` (167).
2. **Apple documentation** — `/documentation/evaluations` (framework index, full symbol inventory) and
   its articles: `evaluating-language-model-responses`, `designing-effective-evaluations`,
   `designing-evaluation-criteria`, `designing-evaluation-datasets`, `designing-effective-model-judges`,
   `scoring-with-model-as-judge-evaluators`, `evaluating-tool-calling-behavior`,
   `generating-synthetic-evaluation-datasets`. Plus, on the FoundationModels side,
   `updating-prompts-for-new-model-versions`, `systemlanguagemodel`, and
   `evaluating-prompts-to-measure-performance-and-improve-model-responses`.
3. **Apple Developer Forums** — thread **833642** (Frameworks Engineer: no model version pinning API,
   use Evaluations for regression testing), thread **833729** (Frameworks Engineer, accepted: Evaluations
   is Swift-only), thread **832053** (Apple Engineer, recommended: `ModelJudgeEvaluator` scope, and that
   it works against `PrivateCloudComputeLanguageModel`), thread **833822** (unanswered: image-text
   evaluation).
4. **WWDC26 session transcripts** — **298** *Meet the Evaluations framework* (Yada, Rob), **299**
   *Create robust evaluations for agentic apps* (Ada, Kyle), **335** *Improve your prompts by hill
   climbing with Evaluations* (Marcus), **241** (framework overview), **334** (Swift vs Python for
   evaluation). Cited as `<session>:<line>`. These are machine-transcribed spoken word: sentence-level
   quotes are reliable, **Swift identifiers heard aloud are not**.

### Where the sources disagree, and how it was ruled

Every disagreement below is the same kind: a session transcript's *spoken* API name versus the sample's
*written* one. **The sample wins in every case.** They are listed because reconstructions built from the
transcripts are in wide circulation, and several of them look entirely plausible.

| Claim | Session transcript | Book Tracker / docs | Ruling |
|---|---|---|---|
| Evaluators property | `var evaluators: some Evaluator` (reconstruction from `298:73`) | `var evaluators: Evaluators` | **Sample.** `Evaluators` is a protocol `typealias`; `EvaluatorsBuilder` is the result builder. |
| Evaluator closure | `Evaluator(metric) { output, sample in }` | `Evaluator { input, subject in }` | **Sample.** Two args, `(sample, subject)`, metric captured not passed. |
| Metric results | `.pass` / `.fail` / `.score(_)` | `.passing()` / `.failing()` / `.scoring(_)` / `.ignore()` | **Sample + docs.** |
| Subject return type | the raw output type | `ModelSubject<T>` | **Sample.** `ModelSubject` was absent from every pre-sample symbol list, including ours. |
| Dataset | `var dataset: [ModelSample] { … }` | `var dataset = ArrayLoader(samples:)` | **Sample.** Stored, and a `Loader`. |
| Aggregator type | `MetricAggregator`, by value | `MetricsAggregator`, `inout` | **Sample + docs.** |
| Aggregation call | `aggregator.average(of:)` | `aggregator.computeMean(of:)` | **Docs + sample.** |
| Trait label | `.evaluates(eval, notes:)` (`298:85-89`) | `.evaluates(eval, info:)` | **Sample + docs.** "notes" is narration, not a label. |
| Test signature | `func f(results: EvaluationResults)` | `func f() async throws` + `EvaluationContext.current.result` | **Sample + docs.** No such parameter exists; the type is singular. |
| Reading an aggregate | `results.aggregateValue(for: "TagCount")` | `result.aggregateValue(.mean(of: metric))` | **Sample + docs.** Keyed by `AggregationOperation`, not by string. |
| Cohen's kappa | implied to be available (`335:91-101`) | hand-rolled, 72 lines, `Statistics.swift` | **Sample.** The framework ships **no** agreement statistic. `335:127` agrees on close reading: *"a custom aggregation method"*. |
| The attachment round trip | *"I can retrieve that attachment and extract summary and tag pairs"* (`335:115-118`) — sounds like an in-Xcode gesture | a **167-line `ArgumentParser` CLI** parsing an exported `.xcevalresult` bundle | **Sample.** There is real work here that the narration compresses to one sentence. Budget for it. |
| Judge model | *"we've specified Private Cloud Compute as our judge model"* (`298:221`) | `judge: SystemLanguageModel.default` in `BookTags.swift:108`; `SystemLanguageModel()` in `ModelJudgeAlignmentEvaluation.swift:213` | **Both true, different runs.** The *capability* rule (`298:208-210`) stands; the shipped sample judges on-device. Apple confirmed on thread 832053 that PCC works as a judge. |
| Dataset size | *"Good evaluations have thousands of samples"* (`298:134`) vs *"20 to 30 samples is a great place to get started"* (`298:273`) | 13 curated → 100 synthetic | **Not a conflict — a workflow.** Hand-write 20–30, expand with `SampleGenerator`, keep both suites. |
| Generator type name | `SyntheticGenerator` (`299:91`) | `SampleGenerator` (3 of 4 mentions, plus `BookSampleGenerator/main.swift`) | **`SampleGenerator`.** One transcription slip. |
| Sample type name | `ModelSamples` (`299:35`) | `ModelSample<T>` | **`ModelSample`.** `ModelSampleProtocol` also exists; `ModelSamples` does not. |
| Platforms | *"macOS, iOS, watchOS and visionOS"* (`299:2`) | index adds iPadOS + Mac Catalyst | **Both.** The session's list is incomplete, not wrong. **Neither lists tvOS.** |

### Still open

Consolidated from the 🔴 boxes above, updated after the 2026-07-29 interface pass. Closed items are
kept and marked, so you can see what moved:

1. **Non-text / multimodal evaluation** (§2). Hook exists (`ModelSampleInput` and the generic
   protocols, all present in the interface); no compiling example anywhere; the forum question is
   unanswered. **Open.**
2. **`Metric` identity — by name or by instance?** (§8.2, §17.4). **Closed, probe-verified
   2026-07-31:** by NAME, and same-named metrics pool into one aggregate (`probes/`
   `eval.metric-identity`, 27.0 sim runtime).
3. **`AggregationOperation`'s full case list** (§9). **Closed:** seven statistic cases plus
   `custom(label:)`, ✅ SDK-verified (`Evaluations-27.0-macos.swiftinterface:431-444`).
4. **What an all-`.ignore()` metric aggregates to** (§17.5). **Closed, probe-verified 2026-07-31:**
   the `-1.0` sentinel — indistinguishable from an unregistered metric, so keep asserting row
   counts (`probes/` `eval.mean-over-all-ignored`, 27.0 sim runtime).
5. **What happens to a run when `subject(from:)` throws for some samples** (§17.7). **Closed,
   probe-verified 2026-07-31:** the run continues and failed samples are excluded from the
   aggregate while still occupying detailed rows — the silently-improved-score hazard is reproduced
   fact (`probes/` `eval.subject-throws`, 27.0 sim runtime).
6. **`if/else` inside the `evaluators` builder** (§6). **Effectively closed:** the interface confirms
   `buildExpression` / `buildOptional` / four `buildPartialBlock` overloads — beta 5 swapped out the
   variadic `buildBlock` — and no `buildEither` (`:659-666`), so a bare `if`
   builds and an `if/else` should not. Not compile-tested.
7. **The Evaluations report UI beyond four narrated sentences** (§11) — no screenshots, no CI story,
   no confirmation that Compare handles more than two runs. **Open.**
8. **`EvaluationResult.saveJSON(to:includeReportMetadata:includeTranscripts:)`'s exact signature** (§12). **Closed:** it
   takes a *directory* and returns the written file's URL, ✅ SDK-verified (`:581-597`). Whether its
   output matches the `.xcevalresult` shape is still open.
9. **`ScoreDimension.scale` cases other than `.numeric`** — `.passFail(passDescription:failDescription:)`
   and `.custom(_:)` signatures are now ✅ SDK-verified (`:392-393`), but no sample exercises them;
   every dimension in Book Tracker is a 4-point numeric scale. **Usage still unproven.**
10. **`ModelJudgePrompt.reference`'s second closure parameter.** **Closed:** it is the model's output
    value, typed `Input.ExpectedValue` — the full closure type is
    `(Input, Input.ExpectedValue) async throws -> [String : String]`, ✅ SDK-verified (`:349-357`).
    Not the `ModelSubject`, as previously guessed.

### Where to go next in Part 6

- **Model judges** — `ScoreDimension`, `ScoringScale` (`.numeric` / `.passFail` / `.custom`),
  `ModelJudgePrompt(instructions:evaluationTarget:reference:)`, `ScoringMode`, pairwise judging, and
  why an even-numbered scale removes the noncommittal middle.
- **Judge drift and calibration** — Cohen's kappa, why plain accuracy is not enough on a skewed dataset,
  the 0.6 threshold, and the `DatasetExtractor` round trip from §12.
- **Datasets and synthetic generation** — `makeSamples(_:targetCount:sessionProvider:validator:)`,
  `SampleGenerator`'s `sessionProvider` / `samplingStrategy` / `validator`, the `targetCount`
  inclusive-count gotcha, and why the validator cannot check corpus-level properties.
- **Tool-call and trajectory evaluation** — `ToolCallEvaluator(allPass:percentagePass:)`,
  `TrajectoryExpectation`'s four initialisers, `ToolExpectation`, and all nine `ArgumentMatcher` cases.

### Elsewhere in the series

- [`../../part-01-orientation-and-gating/references/02-platform-and-version-gating.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/references/02-platform-and-version-gating.md) — the 26.0 / 26.4 / 27.0 ladder in full.
- [`../../part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md) — `@Generable`, `@Guide`, and why a guide is a hint.
- [`../../part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md) — the `Tool` protocol, and the transcript anatomy `StructuredTranscript` mirrors.
- [`../../part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md) — PCC as a judge or a generator, and the entitlement it needs.
- [`../../part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md) — what to do when Evaluations' Swift-only constraint blocks you.

[^eval-structured-transcript-import]: Apple documents [`StructuredTranscript`](https://developer.apple.com/documentation/evaluations/structuredtranscript) in the Evaluations framework and uses `session.transcript.structuredTranscript` in its [language-model evaluation flow](https://developer.apple.com/documentation/evaluations/evaluating-language-model-responses). The captured Xcode 27 interface provides the ownership detail the abbreviated sample omits: `notes/sdk-interfaces/Evaluations-27.0-macos.swiftinterface:288-291` declares the accessor in an `extension FoundationModels.Transcript`, with return type `Evaluations.StructuredTranscript`; the FoundationModels interface contains no declaration. Therefore `import Evaluations`, rather than framework linkage alone, brings the accessor into scope.
