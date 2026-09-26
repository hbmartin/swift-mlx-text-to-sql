# `SampleGenerator`, synthetic datasets, and evaluating tool trajectories

**Part 6 · Evaluations · Reference 03**

**Version floor:** the entire `Evaluations` framework is **iOS 27.0 · iPadOS 27.0 · Mac Catalyst 27.0 ·
macOS 27.0 · visionOS 27.0 · watchOS 27.0**, every symbol tagged **Beta**, and it requires **Xcode 27**.
**tvOS is not on the list** — neither Apple's framework index nor WWDC26 session 299 mentions it, so do
not plan a tvOS evaluation target. One sub-floor matters and is easy to miss: the bridge that makes tool
evaluation possible, **`Transcript.structuredTranscript`, is `iOS 27.0 / iPadOS 27.0 / macOS 27.0 /
visionOS 27.0 / watchOS 27.0` and *omits Mac Catalyst*** — so the framework is available under Catalyst
but the trajectory half of it is not. `PrivateCloudComputeLanguageModel`, which is what you will
realistically point the sample generator at, is **27.0** and needs a **managed entitlement** you have to
be granted. The `@Guide(.count(3...8))` constraint used throughout the examples is **26.0**.

> ✅ **VERIFIED — interface check, 2026-07-29.** The framework ships inside Xcode 27, not the OS SDK
> (guide 01's distribution box has the full story), and its real macOS Swift interface is captured in
> this repo at `notes/sdk-interfaces/Evaluations-27.0-macos.swiftinterface`. This guide has been read
> against it end-to-end. Claims marked ✅ **SDK-verified**
> (`Evaluations-27.0-macos.swiftinterface:<lines>`) cite it; it closed six of this guide's GAPs
> (`SamplingStrategy`'s cases, the `SampleGenerator` overloads, `TrajectoryExpectation`'s initialiser
> set *and* its accessors, `allowsAdditionalToolCalls`'s default, the bare-vs-wrapped argument value)
> and corrected one signature (`validator` is `async throws`). An interface settles spellings,
> signatures, defaults, availability and case lists — never runtime behaviour — and absence from it
> means "not present in the Xcode 27 beta interface", not "does not exist".

---

## What this covers

The second half of an evaluation practice: getting *enough* data to evaluate on, and evaluating the
*path* your feature takes rather than only its final answer.

- **Synthetic datasets.** The two entry points — the `makeSamples(_:targetCount:sessionProvider:validator:)`
  array method and the `SampleGenerator` actor — what each one's parameters really mean, and why
  `targetCount: 100` over 13 seeds produces **87** new samples and not 100.
- **`sessionProvider` is a factory, not a session.** It can be called more than once in a single run, and
  the replacement session starts with no memory of the first. Instructions that assume one invocation
  quietly stop applying halfway through your dataset.
- **What a `validator` can and cannot see.** It runs on one sample in isolation. "Reviews must be at
  least 100 characters" is checkable there; "reviews should vary in length" is not, and writing the
  second one produces a validator that returns `true` for everything.
- **The finding that justifies the whole exercise:** expanding Book Tracker's dataset from 13 to 100
  samples made the quality scores **drop**. The feature was never as good as the small dataset said. A
  score drop on expansion is a *signal*, and this guide enumerates the four things it can mean.
- **Tool trajectories.** `TrajectoryExpectation` in all four of its initialiser forms, `ToolExpectation`,
  `.anyOrder(_:)`, `allowsAdditionalToolCalls`, `disallowed`, and the complete nine-case
  `ArgumentMatcher` vocabulary — including `.naturalLanguage(argumentName:criteria:)`, which puts a
  language model in charge of deciding whether the argument the model passed satisfies a prose criterion.
- **The wiring people get wrong:** `ToolCallEvaluator(allPass:percentagePass:)` inspects
  `ModelSubject.transcript`, and that transcript only exists if *you* passed
  `session.transcript.structuredTranscript` into `ModelSubject(value:transcript:)` inside `subject(from:)`.
- **Synthesising tool-evaluation datasets**, which works because `ToolExpectation` and `ArgumentMatcher`
  are themselves `Generable` — and the one thing that makes it fail: the generating model has never heard
  of your tools.

## What you need

- **Xcode 27** and an OS 27 run destination. Evaluations runs inside **Swift Testing**, in a test target.
- A feature already under evaluation. This guide is the *third* rung of the ladder; it assumes you have a
  hand-written dataset, at least one heuristic `Evaluator`, and probably a `ModelJudgeEvaluator`. If you
  do not, read
  [`01-foundations-and-hill-climbing.md`](01-foundations-and-hill-climbing.md) first.
- Familiarity with `Tool`, `@Generable` and `Transcript` from
  [Part 2 ▸ `03-tools-and-tool-calling.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md).
- For synthetic generation at any scale, **`PrivateCloudComputeLanguageModel`** — which means the managed
  `com.apple.developer.private-cloud-compute` entitlement, a network connection, and an honest look at
  §6 before you queue up a thousand samples.

---

## Contents

1. [The thirteen-sample lie](#1-the-thirteen-sample-lie)
2. [Two doors into synthetic data](#2-two-doors-into-synthetic-data)
3. [⚠️ `targetCount` counts the samples you already have](#3-️-targetcount-counts-the-samples-you-already-have)
4. [`SampleGenerator`, parameter by parameter](#4-samplegenerator-parameter-by-parameter)
5. [⚠️ `sessionProvider` is a factory and it may be called twice](#5-️-sessionprovider-is-a-factory-and-it-may-be-called-twice)
6. [Paying for generation: entitlement, quota, and why it lives in a CLI target](#6-paying-for-generation-entitlement-quota-and-why-it-lives-in-a-cli-target)
7. [`samplingStrategy`: random or sliding window](#7-samplingstrategy-random-or-sliding-window)
8. [⚠️ The validator runs alone](#8-️-the-validator-runs-alone)
9. [Where the samples go: `samples`, `invalidSamples`, JSON, `JSONLoader`](#9-where-the-samples-go-samples-invalidsamples-json-jsonloader)
10. [The reality check: expansion makes your scores drop](#10-the-reality-check-expansion-makes-your-scores-drop)
11. [Coverage beats count](#11-coverage-beats-count)
12. [Why the final answer is not enough](#12-why-the-final-answer-is-not-enough)
13. [`TrajectoryExpectation`: four shapes](#13-trajectoryexpectation-four-shapes)
14. [`ToolExpectation`, `anyOrder`, and additional calls](#14-toolexpectation-anyorder-and-additional-calls)
15. [The nine argument matchers](#15-the-nine-argument-matchers)
16. [`disallowed`: evaluating what the model must *not* do](#16-disallowed-evaluating-what-the-model-must-not-do)
17. [⚠️ Wiring it up: `ToolCallEvaluator` and the transcript you must remember to pass](#17-️-wiring-it-up-toolcallevaluator-and-the-transcript-you-must-remember-to-pass)
18. [Synthesising tool-evaluation datasets](#18-synthesising-tool-evaluation-datasets)
19. [One suite, two kinds of confidence](#19-one-suite-two-kinds-of-confidence)
20. [Quick reference](#20-quick-reference)
21. [Sources](#21-sources)

---

## 1. The thirteen-sample lie

Apple's Book Tracker sample ships an array called `sampleBooks` with thirteen entries in it — *Pride
& Prejudice*, *Dracula*, *The Secret Garden*, *Treasure Island*, *Romance of the Three Kingdoms*,
*Frankenstein*, *Moby Dick*, and friends. Each one has a review and a hand-written set of reference
tags. Thirteen is a perfectly sensible number of examples to write by hand, and it is what every real
evaluation starts from.

It is also the number that will lie to you.

> ✅ **VERIFIED** — WWDC26 session 299, on the thirteen-sample dataset (`299:22-23`):
> *"These 13 samples might feel like a reasonable starting point, but **this small dataset only give us
> a narrow window into how our feature performs. Our evaluation results could look great and still be
> completely misleading.**"*

The mechanism is not subtle. Thirteen samples that you wrote yourself, about books you chose, in review
styles you find natural, measured against tags you would have written — that is thirteen draws from a
distribution centred exactly on your own habits. Your feature will look excellent on it, because your
feature was tuned against it, and because you are not an adversarial user.

> ✅ **VERIFIED** — the variety argument, verbatim (`299:24-28`): *"There are countless books. Hundreds
> of genres. And a wide variety of ways a user might review what they just read. We're also talking
> about the real world where **summaries can be vague or incomplete.** Thirteen samples can't capture
> all of that."*

Session 298 puts the same point as a hard number and then, twenty minutes later, appears to contradict
itself:

> ✅ **VERIFIED** — `298:134`: *"**Good evaluations have thousands of samples** to extract trends, but
> also to exercise your feature in many different ways."*
>
> ✅ **VERIFIED** — `298:272-274`: *"**Start small. A focused dataset of 20 to 30 samples is a great
> place to get started.** Spec out your app by thinking about how you want the model to behave."*

These are not in conflict once you see the sequencing: **20–30 by hand, thousands by generation.** The
hand-written set is your specification — you can only write a sample if you have decided what correct
looks like. The generated set is your *coverage*. The rest of this guide's first half is about the
machinery that gets you from one to the other, and about the thing that happens when you arrive, which
is that your scores get worse.

There is a second reason to care, and it has nothing to do with statistics. Apple does not offer model
version pinning. The on-device model changes underneath you when the OS updates — the 26.4 refresh
explicitly improved "instruction-following and tool-calling abilities", which is another way of saying
it changed behaviour you had already measured. A thirteen-sample evaluation cannot distinguish "the
model got better" from "the model got different in a way that happens to miss my thirteen books". A
representative dataset can. See
[Part 1 ▸ `02-platform-and-version-gating.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/references/02-platform-and-version-gating.md)
for the version story; the point here is that dataset size is a *regression-detection* property, not
only a statistical one.

---

## 2. Two doors into synthetic data

The framework gives you two ways in, and they are the same machinery with different amounts of ceremony.

**Door one — a method on your existing array.** If you already have `[ModelSample<T>]`, you can ask it
to grow.

> ✅ **VERIFIED** — Apple's `generating-synthetic-evaluation-datasets` article, as harvested from
> `/documentation/evaluations`: *"The framework adds a **`makeSamples(_:targetCount:sessionProvider:validator:)`**
> method to any array of `ModelSample` values. Call this method with a prompt that describes what to
> generate, and it returns new samples as an **asynchronous stream**."*

Note what that sentence settles. `makeSamples` is an **extension on `Array`**, so the "dataset" is the
receiver, not an argument. The three things session 299 describes as required are all there — the prompt
is the first positional parameter, the dataset is `self`, and `targetCount` is a label — but they are not
three parameters.

> ✅ **VERIFIED** — the requirement, spoken (`299:31`): *"**The `makeSamples` API requires three
> components: a prompt, a dataset, and a target count**, which is the number of samples you'd like to
> synthetically generate **including the dataset you provide**."*
>
> ✅ **SDK-verified — the signature (2026-07-29).** The interface declares `makeSamples` twice, as
> extensions on `Array`: once `where Element == ModelSample<T>, T : Generable` and once
> `where Element : ModelSampleProtocol, Element : Generable`, both as
> `makeSamples(_ prompt: Prompt, targetCount: Int, sessionProvider: (@Sendable () ->
> LanguageModelSession)? = nil, validator: ((Element) async throws -> Bool)? = nil) -> some
> AsyncSequence<Element, any Error>` (`Evaluations-27.0-macos.swiftinterface:883-894`). So the
> `for try await` shape below is right, `sessionProvider` and `validator` are optional here too,
> and — worth noticing — **`makeSamples` has no `samplingStrategy` parameter**; that knob is
> `SampleGenerator`-only. No sample project calls it, so usage remains unexercised even though the
> signature is settled.

```swift prelude:guide-context
import Evaluations
import FoundationModels

var expandedDataset = Book.sampleBooks.map { book in
    ModelSample(prompt: book.review, expected: BookTags(tags: book.tags))
}

for try await sample in expandedDataset.makeSamples(
    Prompt("""
        Generate a diverse range of book reviews and corresponding tags.
        Cover a wide range of genres, time periods, cultures, and reader personas.
        Do not repeat books already in the dataset.
        """),
    targetCount: 100
) {
    expandedDataset.append(sample)
}
```

Two behaviours are worth knowing before you decide this is enough:

> ✅ **VERIFIED** — the default model (`299:42-43`): *"**By default, the framework uses the on device
> model for generation.** The on-device model is a great option in most cases, but you might want to
> bring your own model, or customize the instructions the model operates under."*

The on-device model has a **4K context window**. Generation is a long conversation in which each batch of
new samples is produced in the presence of examples, and the session is reused across batches (§5). 4K is
not much room for that. This is the single biggest practical reason to move to door two.

**Door two — the `SampleGenerator` actor.** Everything `makeSamples` does, plus the parameters
`makeSamples` does not expose.

> ✅ **VERIFIED** — `299:45`: *"For more complex configurations beyond the prompt, dataset, and target
> count, the framework provides the **`SampleGenerator`** Which gives you **full control over the
> generation process**."*

> ✅ **VERIFIED** — declaration, from `/documentation/evaluations/samplegenerator`:
>
> ```swift
> actor SampleGenerator<SampleType> where SampleType : ModelSampleProtocol
>
> init(_:samples:targetCount:sessionProvider:samplingStrategy:validator:)   // two overloads
> var samplingStrategy: SampleGenerator.SamplingStrategy
> var validator                     // "An optional closure that decides whether a generated sample is valid."
> func run() -> AsyncStream         // "Runs the generator and returns a stream of newly synthesized samples."
> var samples                       // "All samples — initial and generated — from the most recent run."
> var invalidSamples                // "Samples that the validator rejected during the most recent run."
> enum SampleGenerator.SamplingStrategy
> ```
>
> ✅ **SDK-verified** — with two touch-ups from the interface
> (`Evaluations-27.0-macos.swiftinterface:855-882`): `samplingStrategy` and `validator` are
> *Optionals*, and `run()` returns `some AsyncSequence<SampleType, any Error>` rather than a literal
> `AsyncStream` — which is why the loops below are `for try await`.

It is an **actor**. That is not decoration: `samples` and `invalidSamples` are `await`-ed properties,
and the generator is safe to hold while a `for try await` loop is draining `run()`.

Which door to use is not really a judgement call. If you are generating more than a handful of samples,
or you want a bigger model, or you want to reject bad output, you need `SampleGenerator`. Apple's own
sample uses `SampleGenerator` for a 100-sample run and never calls `makeSamples` anywhere in the archive.

---

## 3. ⚠️ `targetCount` counts the samples you already have

This is the first thing everyone gets wrong, it is stated once in the session and once in the docs, and
it changes your bill.

> ✅ **VERIFIED** — `299:36`: *"And for the target count, I've set it to one hundred samples to start!
> **Remember, the targetCount is the size of the full resulting dataset, including the samples we
> started with, so the model will actually generate 87 new ones.**"*

Thirteen seeds, `targetCount: 100`, **87 generated**. Not 100. Not 113.

> ⚠️ **SILENT FAILURE — this one does not throw, it just under-delivers.** If you pass
> `targetCount: 1000` believing you asked for a thousand *new* samples, you get a thousand *total*, and
> your loop terminates normally having produced 987. Nothing warns you. The way this actually bites is
> the reverse: someone with 800 existing samples passes `targetCount: 200` intending "add 200 more",
> and the run appears to do nothing at all — because the target is already met. There is no error and no
> log line to tell you why the stream ended immediately.
>
> **The safe habit:** never write a literal. Write the arithmetic, so the intent is in the source.

```swift prelude:guide-context
let seeds = Book.sampleBooks.map { book in
    ModelSample(prompt: book.review, expected: BookTags(tags: book.tags))
}

// Say what you mean: "generate 87 more".
let newSamplesWanted = 87
let targetCount = seeds.count + newSamplesWanted   // 100
```

> ✅ **Probe-verified, 2026-07-31 — an unreachable target neither throws nor loops forever: the
> generator gives up after its internal retry budget and finishes short.** (was a 🔴 GAP; `probes/`
> `eval.generator-unreachable-target`, run on the 27.0 sim runtime.) The exact experiment was run —
> a validator returning `false` unconditionally against a positive `targetCount` — and the run
> `finished(produced=0)`: no error and no hang. On stable macOS 27 and the physical iPhone run on
> 2026-09-16, the same impossible-validator case again produced zero, but invoked the provider
> **three** times and recorded **17** invalid samples. The earlier simulator recorded one provider
> invocation and 4–5 rejects. Therefore neither invocation count nor observed reject count is a
> portable restatement of `.random(retries: 5)`; both are runtime-dependent diagnostics. The
> under-delivery failure mode above extends all the way down: an impossible
> validator produces an empty dataset *silently*, but `invalidSamples` tells you rejects happened.
>
> **Safe defaults, updated:** still treat generation runs as wall-clock-bounded and drive them from
> a `^C`-able CLI (§6) — but now also **check `invalidSamples` and the produced count after every
> run**; a high reject count with a short yield means your validator, not the model, set your
> dataset size.

---

## 4. `SampleGenerator`, parameter by parameter

Apple's Book Tracker sample ships the generator as its own **command-line tool target**, not as a test.
That is a design decision worth copying and we will come back to it in §6. Here is the call, as it
appears on disk.

> ✅ **VERIFIED** — `BookSampleGenerator/main.swift:13-74`, from the Book Tracker sample archive
> (*Using Evaluations to evaluate an intelligent feature*, macOS 27.0 deployment target). The `…`
> markers are elisions in the harvested transcription of the file, not in the source — the instruction
> string is longer than what is reproduced here, and §5 shows what belongs in it.

```swift illustrative
import Evaluations
import Foundation
import FoundationModels

let prompt = Prompt("""
        Generate diverse range of book reviews and corresponding tags.
        Cover a wide range of genres, time periods, cultures, and
        reader personas. Do not repeat books already in the dataset.
        """)

let dataset = Book.sampleBooks.map { book in
    ModelSample(prompt: book.review, expected: BookTags(tags: book.tags))
}

let targetCount = 100

var expandedDataset: [ModelSample<BookTags>] = dataset

let generator = SampleGenerator<ModelSample<BookTags>>(
    prompt,
    samples: dataset,
    targetCount: targetCount,
    // Uses Private Cloud Compute for larger, more diverse generations.
    sessionProvider: {
        LanguageModelSession(
            model: PrivateCloudComputeLanguageModel(),
            instructions: """
            You are a synthetic data generator for a book-tracking app's evaluation suite.
            …
            Rules:
            - Review must be at least 100 characters long.
            …
            """
            )
    },
    // Reject samples that violate the rules defined in the instructions.
    validator: { sample in
        guard let book = sample.expected else { return false }
        guard sample.promptDescription.count >= 100 else { return false }
        guard (3...8).contains(book.tags.count) else { return false }
        guard book.tags.allSatisfy({ $0 == $0.lowercased() }) else { return false }
        return true
    }
)

for try await sample in generator.run() {
    // Access results during iteration.
    expandedDataset.append(sample)
}

// Access results after iteration.
let allSamples = await generator.samples
let invalidSamples = await generator.invalidSamples
```

Read that once for shape, then read it again for the eight things it settles.

**The first parameter has no label.** `SampleGenerator<S>(_ prompt: Prompt, samples:targetCount:…)`.
The prompt is positional; the dataset arrives under `samples:`, not `dataset:`. The documentation lists
**two overloads** of the initialiser — and the earlier guess about what distinguishes them was wrong.

> ✅ **VERIFIED** — `/documentation/evaluations/samplegenerator`:
> `init(_:samples:targetCount:sessionProvider:samplingStrategy:validator:)` — *two overloads*.
>
> ✅ **SDK-verified — GAP closed, and the old inference corrected (2026-07-29).** Both overloads take
> a **`Prompt`** first; they differ by *generic constraint*, not by prompt type
> (`Evaluations-27.0-macos.swiftinterface:870-871`). One is
> `init<T>(…) where SampleType == ModelSample<T>, T : Generable` — the everyday form, for
> `ModelSample`-shaped datasets whose expected value is `@Generable` — and the other is
> `init(…) where SampleType : Generable`, for a custom `ModelSampleProtocol` conformance that is
> itself generable. An earlier revision of this guide inferred a `String`/`Prompt` pair by analogy
> with `ModelSample`; there is no `String`-prompt variant. Use `Prompt("…")`, as the compiling
> sample does. Both overloads default `samplingStrategy: … = .random()` and leave
> `sessionProvider` / `validator` as `nil`.

**The generic parameter is the *sample* type, not the value type.** `SampleGenerator<ModelSample<BookTags>>`,
constrained `where SampleType : ModelSampleProtocol`. So the generator produces whole samples — prompt,
expected value, and (as §18 shows) trajectory expectations — not just outputs. That is also why you can
generate tool-evaluation data at all.

**`prompt` and `instructions` are different jobs, and the sample uses both.** The `prompt` says *what to
produce* ("diverse range of book reviews and corresponding tags… do not repeat books already in the
dataset"). The `sessionProvider`'s `instructions` say *who the model is and what the rules are* ("You are
a synthetic data generator for a book-tracking app's evaluation suite… Review must be at least 100
characters long"). If you put everything in the prompt, §5's context-exhaustion behaviour will eventually
throw the rules away.

**`run()` yields only valid samples.** The `for try await` body appends unconditionally and the resulting
`expandedDataset` is clean, because rejected samples never enter the stream. They are still retained —
see `invalidSamples` below.

**`samples` and `invalidSamples` are `await`-ed.** `SampleGenerator` is an actor. Both are described by
Apple as covering "the most recent run", and session 299 adds that they are live:

> ✅ **VERIFIED** — `299:91-95`: *"as generation progresses, **valid samples are collected in the
> `samples` property**… **Any sample that fails these validators gets set aside automatically as
> `invalidSamples`.** **Both are updated in real time throughout the run, so you can access them at any
> point.** Either during iteration to check progress or after the loop completes. You can then use these
> results directly in your app or **save the dataset locally**."*

⚠️ Note the asymmetry that trips people up when they refactor: **`samples` contains the seeds too**
("All samples — initial and generated — from the most recent run"), while the `for try await` loop yields
only *new* ones. Apple's CLI therefore initialises `expandedDataset` **with `dataset` already in it** and
appends the new ones — which produces the same content as `await generator.samples`, by two different
routes. Pick one. Doing both silently doubles your dataset.

**`validator` receives the whole sample — and it is `async throws`, not a plain predicate.** The
declared type is `(@Sendable (SampleType) async throws -> Bool)?` — ✅ SDK-verified
(`Evaluations-27.0-macos.swiftinterface:861,870-871`), correcting this guide's earlier "synchronous,
non-throwing" description — so a validator *may* await a model call or throw. Apple's own validator
is a synchronous, non-throwing closure, which satisfies the type; what the generator does with a
validator that actually throws (reject the sample, or fail the run) is runtime behaviour the
interface cannot settle, so keep validators non-throwing unless you have tested it. The sample's
four `guard`s are the reference implementation and §8 is about what belongs in there.

**Batch size is not yours to set.**

> ✅ **VERIFIED** — `299:52`: *"The framework **handles batch size automatically** which is the number of
> samples processed during generation."*

> 🔴 **GAP — the batch size is neither documented nor observable.** No API exposes it, and no session or
> doc page states a number. It matters because it determines how quickly you exhaust a context window
> (§5) and how bursty your PCC quota consumption is (§6). **Resolving it needs an Instruments trace of a
> generation run, or an SDK header comment.** Meanwhile: assume it is larger than you would have chosen,
> and prefer the model with the larger context window.

---

## 5. ⚠️ `sessionProvider` is a factory and it may be called twice

This is the most important paragraph in session 299 and the least likely to be read carefully, because
it is delivered as an aside about context windows.

> ✅ **VERIFIED** — `299:53-57`, verbatim and in full:
>
> *"**The generator calls your `sessionProvider` once at the start of a run and then reuses that session
> across batches** which helps the model maintain context as generation progresses."*
>
> *"But a session has a limit for how large it can grow. The one exception is if you're making a lot of
> requests, giving it a large prompt, or getting large outputs, **You can exhaust the session's context
> window mid-run which will throw an error. In that case, the generator calls `sessionProvider` again to
> get a fresh one to continue generation but this won't contain context from the previous session. So
> make sure your instructions in your `sessionProvider` is self-contained and doesn't assume it'll only
> be called once.**"*

Unpack the lifecycle, because there are three distinct facts in there:

1. **One session, reused across batches.** Not one session per sample and not one per batch. Continuity
   is deliberate — the model can see what it has already produced and avoid repeating itself. That is
   *why* the sample's prompt can say "do not repeat books already in the dataset" and have it mean
   something.
2. **Continuity is also the failure mode.** A session that accumulates every batch is a session that
   grows monotonically. On the on-device model that is 4K of context; on PCC it is 32K. Either way, a
   long enough run reaches the ceiling.
3. **The recovery is automatic, silent, and lossy.** The generator catches the context error, calls your
   `sessionProvider` again, and continues. Your run does not fail. Your samples do not stop arriving.
   The only thing that changed is that the model has forgotten every sample it has generated so far.

> ⚠️ **SILENT FAILURE — your dataset changes character halfway through and nothing tells you.**
> After the invisible session swap, "do not repeat books already in the dataset" refers to a dataset the
> new session has never seen. Anything you established by *conversation* rather than by *instructions* is
> gone. The symptom is a dataset whose second half is measurably less diverse than its first — duplicate
> books, drifting review style, tag vocabulary collapsing toward whatever the instructions happen to
> mention. No error, no log line, no property to inspect. **It looks exactly like a mediocre generator
> prompt.**
>
> Three defences, in order of how much they buy you:
>
> - **Write self-contained instructions.** Every rule the samples must obey belongs in
>   `sessionProvider`'s `instructions`, where it is re-established on every invocation — not in the
>   `prompt`, and never in a preamble you rely on the model remembering.
> - **Never close over run-scoped mutable state in the closure.** A `var callCount` or a
>   "first call configures X" flag inside `sessionProvider` is a bug: the closure is not called once.
> - **Detect it after the fact.** Deduplicate on a stable key when the run ends, and compare the
>   distribution of the first half of the run against the second. If they differ, you got swapped.

Here is the shape to write. The instruction text is deliberately complete and repetitive — it is the only
thing guaranteed to survive a session swap.

```swift prelude:guide-context
import Evaluations
import FoundationModels

// A factory. Assume it will be called more than once. Assume each session
// starts with no memory of anything the previous one produced.
let makeGenerationSession: @Sendable () -> LanguageModelSession = {
    LanguageModelSession(
        model: PrivateCloudComputeLanguageModel(),
        instructions: """
            You are a synthetic data generator for a book-tracking app's evaluation suite.
            Each sample is one reader's free-text review of a book, plus the tags a
            librarian would file it under.

            Rules — apply every one of these to every sample you generate:
            1. The review must be at least 100 characters long.
            2. Reviews vary in length: some are a single sentence, some are several
               paragraphs.
            3. Cover a wide range of genres, time periods, cultures, and reader personas.
            4. Some reviews contain the reader's personal opinions and digressions.
               Tags must still describe the book, not the reader's reaction.
            5. Produce between 3 and 8 tags per review.
            6. Tags are lowercase, and single words or hyphenated compounds.

            Do not produce a review for a book you have already covered in this run.
            """
    )
}

let generator = SampleGenerator<ModelSample<BookTags>>(
    prompt,
    samples: seeds,
    targetCount: seeds.count + 87,
    sessionProvider: makeGenerationSession,
    validator: isValidBookSample
)
```

Notice rule 2. It is in the instructions, it is not in the validator, and §8 explains why that split is
forced on you rather than chosen.

> 🔴 **GAP (bounded half ✅ probe-verified 2026-07-31) — is the context error observable?** Session
> 299 says exhaustion "will throw an error" and that the generator then calls `sessionProvider`
> again. What we still do not know is whether that error is surfaced anywhere you can see — no
> delegate or callback is listed on `/documentation/evaluations/samplegenerator`, and observing the
> exhaustion path needs an unbounded generation run (out of scope for the probe suite). What the
> probe run *did* establish (`probes/` `eval.generator-unreachable-target`, 27.0 sim runtime): the
> counting techniques below genuinely work — `sessionProviderInvocations` is countable from the
> factory exactly as shown (the probe measured `=1` on a bounded run), and validator rejects are
> visible via the `invalidSamples` property. Meanwhile the advice stands: **count `sessionProvider`
> invocations yourself.** A counter incremented inside the factory — printed, not branched on —
> turns an invisible event into a line of output, and costs nothing.

```swift prelude:guide-context
// Observability, not control flow. Never branch on this value.
let invocations = OSAllocatedUnfairLock(initialState: 0)

let makeGenerationSession: @Sendable () -> LanguageModelSession = {
    invocations.withLock { $0 += 1; print("sessionProvider invocation #\($0)") }
    return LanguageModelSession(model: PrivateCloudComputeLanguageModel(),
                                instructions: generatorInstructions)
}
```

---

## 6. Paying for generation: entitlement, quota, and why it lives in a CLI target

Apple's sample points the generator at Private Cloud Compute and says why in a code comment: *"Uses
Private Cloud Compute for larger, more diverse generations."* Session 299 gives the same reason out loud.

> ✅ **VERIFIED** — `299:48`: *"For our synthetic data generation, I'll use the
> **`PrivateCloudComputeLanguageModel`** since **the context size is larger** and then I'll add custom
> instructions to focus generation on specific books, genres and moods."*

The context-size argument is the one that actually matters, and §5 is why: a bigger window means more
batches before the session is swapped out from under you. **4K on-device versus 32K on PCC** is the
difference between a swap every few batches and possibly no swap at all.

> ✅ **VERIFIED** — the on-device/PCC comparison, WWDC26 session 319 (`319:38-45`), matching Apple's
> written table byte for byte: privacy on both; **offline** on-device only; **no request limits**
> on-device versus a **daily limit per user** on PCC; **4K versus 32K** context; reasoning unsupported
> on-device, three levels on PCC.

Then comes the part nobody puts in the sample code.

### 6.1 The entitlement is managed, and there is an eligibility bar

> ✅ **VERIFIED** — `com.apple.developer.private-cloud-compute` is a **managed entitlement**: you request
> it and Apple grants it; you cannot simply add the key. Confirmed three independent ways in our corpus —
> the entitlement doc path `/documentation/BundleResources/Entitlements/com.apple.developer.private-cloud-compute`,
> Apple's Origami setup notes ("Add the **managed** `com.apple.developer.private-cloud-compute`
> entitlement"), and shipping entitlement plists in a real third-party app.
>
> ✅ **VERIFIED** — the written doc states only *"To develop with PCC you must meet certain eligibility
> requirements."* Session 319 says the bar out loud (`319:26-27`): *"**This model is available for apps
> with less than 2M downloads.** And you can **apply on the developer website today**."*
>
> ⚠️ **The session and the docs do not say the same thing**, and this is a genuine conflict in the
> corpus rather than a transcription artefact. Precedence rules say the written doc outranks the
> session — but the doc is *vaguer*, not contradictory, so the honest reading is: the "certain
> eligibility requirements" the doc gestures at include the < 2M-downloads bar the session states.
> A developer forum thread asking whether a standard Developer Program account can apply was
> **unanswered** in our captured feed.

The practical consequence for this guide: **if your PCC application has not been granted, door two's
sample generator falls back to the on-device model**, with its 4K window, and §5's silent session swap
becomes the normal case rather than the edge case.

### 6.2 PCC quota is per-user, and generation is not free

> ✅ **VERIFIED** — `319:24-25`: *"**Each user gets a daily limit.** And users can **upgrade to iCloud+**
> to get higher limits."* And `319:113`: PCC requests *"are counted with your user's iCloud account."*
>
> ✅ **VERIFIED** — the quota API, from Apple's *Using Private Cloud Compute* article and corroborated by
> shipping code:
>
> ```swift
> let model = PrivateCloudComputeLanguageModel()
>
> if model.quotaUsage.isLimitReached {
>     // The daily quota is spent. `quotaUsage.resetDate` says when it returns.
> } else if case .belowLimit(let info) = model.quotaUsage.status,
>           info.isApproachingLimit {
>     // Warn before you spend the rest of it.
> }
>
> if let suggestion = model.quotaUsage.limitIncreaseSuggestion {
>     suggestion.show()   // presents system UI
> }
> ```
>
> The thrown form is `PrivateCloudComputeLanguageModel.Error.quotaLimitReached(_:)`.
>
> ✅ **VERIFIED, and worth memorising** — *"Unlike rate limiting, where a person waits for a period of
> time before trying again, exceeding the daily quota means a person either waits for their usage quota
> to refresh or they upgrade."* Quota is **orthogonal to availability**: the model can report
> `.available` and still throw `quotaLimitReached`.

> 🔴 **GAP — whose quota does an evaluation run spend?** This is the most consequential unanswered
> question in the whole Evaluations story and it is unanswered *by Apple*, not merely by us. Generating
> 87 samples over PCC, or running a 100-sample `ModelJudgeEvaluator` whose `judge:` is a PCC model, is
> hundreds of PCC requests. Nothing in session 299, session 335, the `/documentation/evaluations` pages,
> or the Book Tracker sample says whether those requests are billed against the developer's signed-in
> iCloud account, whether a test target is treated differently, or whether there is any allowance for
> evaluation traffic at all.
>
> **What would resolve it:** an Apple-staff answer on the Developer Forums, or a documented statement on
> the PCC page. Neither exists in our corpus as of **2026-07-27**.
>
> **Safe default meanwhile:** treat generation as a **manual, occasional, attended** operation performed
> by a human on a signed-in Mac — which is exactly what Apple's sample does — and check
> `quotaUsage.isLimitReached` *before* starting a long run rather than discovering it at sample 60.

```swift compile:27 imports:Foundation,FoundationModels
// Fail fast rather than halfway through a 100-sample run.
let pcc = PrivateCloudComputeLanguageModel()
guard case .available = pcc.availability else {
    print("PCC unavailable; generation aborted."); exit(1)
}
guard !pcc.quotaUsage.isLimitReached else {
    print("PCC daily quota already reached; resets \(pcc.quotaUsage.resetDate)."); exit(1)
}
```

### 6.3 Why the generator is a command-line tool and not a test

Look again at where Apple put the thing.

> ✅ **VERIFIED** — the Book Tracker target layout, from the sample archive:
>
> ```
> BookTracker/                        (app)
> BookTrackerEvaluations/             (test bundle #1)
>   BookTags.swift                    heuristic + model-judge evaluation
>   SyntheticBookTags.swift           the same evaluation over a JSONLoader dataset
>   SearchBooks.swift                 ToolCallEvaluator + 16 TrajectoryExpectations
>   synthetic_book_samples.json       100 generated samples, checked in
> HillClimbingEvaluations/            (test bundle #2)
> BookSampleGenerator/main.swift      CLI: SampleGenerator over PCC
> DatasetExtractor/main.swift         CLI: parse .xcevalresult → JSON
> ```

**Generation is not part of the test run.** It is a separate executable that a human runs, that writes
`synthetic_book_samples.json`, and that JSON is **committed to the repository**. The test bundle reads it
back with `JSONLoader`. Session 299 says the CLI framing is intentional:

> ✅ **VERIFIED** — `299:15`: *"The Evaluations framework exposes APIs that let you **define sample
> generation entirely in code**, so you can build your own generation pipeline, **run it from the command
> line**, or plug it directly into your existing workflows."*

Four reasons this separation is right, and only the first is about money:

- **Cost and quota.** A test suite that regenerates its dataset on every run spends PCC quota on every
  run, for no benefit.
- **Determinism.** An evaluation whose dataset changes between runs cannot be compared between runs, and
  comparison across runs is the entire point of the Xcode evaluation report's **Compare** button. Hill
  climbing requires that exactly one variable moves; a regenerated dataset moves the wrong one.
- **Reviewability.** A committed JSON file goes through code review. Somebody can read the 100 generated
  reviews and notice that eleven of them are about *Frankenstein*.
- **Time.** Generation is minutes of model inference. Tests should not be.

The rule to take away: **synthetic data is an artefact you produce, inspect, and commit — not a step in
your test.**

---

## 7. `samplingStrategy`: random or sliding window

The generator shows the model examples drawn from your existing samples, so it knows what shape of output
you want. `samplingStrategy` controls *which* examples.

> ✅ **VERIFIED — the parameter exists** and is part of the initialiser:
> `init(_:samples:targetCount:sessionProvider:samplingStrategy:validator:)`, with a settable
> `var samplingStrategy: SampleGenerator.SamplingStrategy` and a nested
> `enum SampleGenerator.SamplingStrategy` described as *"how the generator selects existing samples as
> examples in the generation prompt"* (`/documentation/evaluations/samplegenerator`).

> ✅ **VERIFIED — the two strategies and their semantics**, from session 299:
>
> **Random** (`299:61-62`): *"This strategy **selects a random subset of your initial samples as examples
> to show the model making sure there are no duplicates**. This keeps the output varied without requiring
> us to think carefully about the order of our initial samples."*
>
> **Sliding window** (`299:64-65`): *"This strategy **steps through your initial samples sequentially,
> skipping duplicates as it goes. If your dataset has meaningful order, consider using this sliding
> window strategy.**"*
>
> **The default is random** (`299:66-67`): *"For our generator, we'll use the random strategy because our
> initial samples are not meaningfully ordered. **And since it's the default strategy we don't need to
> explicitly define it here.**"*

Corroborating that default: Apple's `BookSampleGenerator/main.swift` **omits `samplingStrategy` entirely**
and gets random behaviour.

> ✅ **SDK-verified — GAP closed (2026-07-29).** The cases are:
>
> ```swift
> public enum SamplingStrategy : Sendable {
>     case random(retries: Swift.Int = 5)
>     case slidingWindow
> }
> ```
>
> (`Evaluations-27.0-macos.swiftinterface:874-877`), and the initialiser's default is
> `samplingStrategy: … = .random()` (`:870-871`) — confirming the session's "random is the default"
> from the shipped declaration rather than from an omitted argument. Two things no document
> mentioned: the case is **`.slidingWindow`**, one word, camel-cased; and `.random` carries a
> **`retries: Int = 5`** associated value whose semantics no source states — the name reads as "how
> many re-draws before giving up on a non-duplicate example set", but that is a reading of an
> identifier, not a documented behaviour.
>
> **The advice stands: omit the parameter** unless your dataset is genuinely ordered. The default is
> random, and code that does not name the case cannot name it wrong — but if you do write it, the
> spellings above are no longer guesses.

### When order is actually meaningful

"Meaningful order" is rarer than it sounds, and it is worth being precise about, because choosing sliding
window for a dataset that does not have it just makes your in-context examples worse:

- **Curriculum-shaped datasets** — samples deliberately ordered easy-to-hard, where you want the
  generator to expand the hard end as thoroughly as the easy end. Random sampling over a curriculum will
  over-represent whichever difficulty band is larger.
- **Datasets partitioned by section** — the first 30 samples are one product area, the next 30 another.
  Sliding window walks the partitions; random blends them, and the model starts producing hybrids that
  belong to no partition.
- **Chronological or versioned datasets** — samples collected across releases, where late samples reflect
  behaviour you now want and early ones do not.

If none of those describe your data, your data is not ordered, and you want random. The Book Tracker
dataset — thirteen novels in no particular sequence — is the canonical unordered case.

---

## 8. ⚠️ The validator runs alone

Start from why a validator exists at all. You already wrote the rules into the instructions. Session 299
is blunt about what that buys you:

> ✅ **VERIFIED** — `299:72-74`: *"That's where the **`validator` closure** comes in hand. The validator
> lets you **define your own logic to accept or reject every generated sample**. We've already defined a
> set of rules in the instructions in the session provider earlier, **but that doesn't guarantee the
> output will actually follow the rules.**"*

Prompt rules are aspirational. The validator is the enforcement layer. This is the same lesson the Book
Tracker feature itself teaches at a different layer — the 3-to-8-tag constraint appears in the `@Guide`,
*again* in the instructions prose, *and again* as a heuristic `Evaluator` — because a guide is a hint and
not a guarantee. Belt, braces, and a measurement.

Now the constraint that shapes everything you can write in there:

> ✅ **VERIFIED** — `299:81`: *"**the validation closure validates per sample generation in isolation and
> doesn't have context to the other samples.**"*
>
> ✅ **VERIFIED** — `299:82`, the consequence, spotted out loud while reviewing the rule list:
> *"Reviewing these rules, I can tell that **the diversity of reviews will require more judgement beyond
> a simple validation check** and **the length of reviews requires assessing across all samples**."*

The validator sees one sample. Not the batch, not the corpus, not what it accepted a moment ago. Sort
every rule you have written into two bins before you write a line of code.

### 8.1 The two bins

Here are the five rules the session's generator instructions carry, sorted:

| # | Rule (as written in the instructions) | Validator-checkable? | Why |
|---|---|---|---|
| 1 | *"the review must be at least 100 characters long"* | ✅ yes | a property of one sample |
| 2 | *"cover a wide range of genres, moods, and tones"* | ❌ no | a property of the *set* — and a judgement call even then |
| 3 | *"the review needs to vary in length"* | ❌ no | "varies" is meaningless for a single sample |
| 4 | *"generate between 3 and 8 book tags"* | ✅ yes | a property of one sample |
| 5 | *"tags must be lowercase"* | ✅ yes | a property of one sample |

Three of five. That ratio is typical, and the two that fall out are the two you care most about, which
is the whole problem.

The rule of thumb that generalises: **if the rule contains a comparative or a plural — "varies", "a
range of", "diverse", "not too many of the same", "balanced across" — it is a corpus property and it does
not belong in the validator.** If the rule is a predicate over one object, it does.

> ⚠️ **SILENT FAILURE — the vacuous validator.** The failure here is not that a cross-sample rule
> *errors*. It is that there is no way to express one, so the version you actually write is trivially
> true and passes everything. Real examples that have the exact shape of a check and the semantics of a
> no-op:
>
> ```swift
> // ❌ "Reviews must vary in length." There is one sample. It has one length.
> //    This is `true` for every non-empty review ever generated.
> validator: { sample in sample.promptDescription.count > 0 }
>
> // ❌ "Cover a wide range of genres." One sample has one genre. Every sample
> //    that has any tag at all satisfies this.
> validator: { sample in !(sample.expected?.tags.isEmpty ?? true) }
> ```
>
> Both appear in review as reasonable code. Both accept a dataset of a hundred identical 400-word
> reviews of *Dracula*. Nothing throws, `invalidSamples` is empty — which *looks like success* — and the
> evaluation you then run over that dataset reports excellent scores, because a hundred copies of one
> sample is an easy dataset.
>
> **The tell is an empty or near-empty `invalidSamples` collection.** A validator that never rejects
> anything is either unnecessary or vacuous. Check it every run.

### 8.2 The validator you should write

This is Apple's, restated with the guards named so the intent survives review.

> ✅ **VERIFIED** — the four guards are exactly those in `BookSampleGenerator/main.swift:74`; the naming
> and comments are this guide's.

```swift prelude:guide-context
import Evaluations

/// Per-sample rules only. Anything comparative belongs in §8.3.
let isValidBookSample: @Sendable (ModelSample<BookTags>) -> Bool = { sample in
    // A sample with no reference tags cannot serve this evaluation.
    guard let book = sample.expected else { return false }
    // Rule 1: reviews under 100 characters are not reviews.
    guard sample.promptDescription.count >= 100 else { return false }
    // Rule 4: the tag-count contract the feature is held to.
    guard (3...8).contains(book.tags.count) else { return false }
    // Rule 5: tags are lowercase, because the UI treats them as identifiers.
    guard book.tags.allSatisfy({ $0 == $0.lowercased() }) else { return false }
    return true
}
```

> ⚠️ **SILENT FAILURE — copying that first guard into a prompt-only generator rejects 100% of output.**
> `guard let book = sample.expected else { return false }` is correct *for this evaluation*, because
> Book Tracker compares generated tags against reference tags. But Apple explicitly supports datasets
> with no expected value:
>
> > ✅ **VERIFIED** — `/documentation/evaluations`, on dataset design: *"For evaluations that score
> > output without a reference answer, such as model-as-judge assessments of tone or fluency, **omit the
> > expected value and generate prompt-only samples.**"*
>
> If you are building a prompt-only dataset — the normal case for a pure model-judge evaluation — and
> you paste that guard in, **every generated sample is rejected**. The run completes. `run()` yields
> nothing. `samples` contains only your seeds. `invalidSamples` fills up with output that was fine.
> There is no error, and the shape of the failure ("my generator produced nothing") points you at the
> model, the prompt, and your entitlement — everywhere except the one line responsible.

### 8.3 Corpus rules go in a post-run audit

The rules that fell out of the validator did not stop mattering. They move to a pass over the finished
dataset, where you *do* have all the samples. This is ordinary Swift; the framework has no opinion about
it.

```swift prelude:guide-context
import Foundation

struct CorpusReport {
    var count: Int
    var duplicatePromptCount: Int
    var lengthP10: Int, lengthMedian: Int, lengthP90: Int
    var distinctTags: Int
    var tagsAppearingOnce: Int
    var mostCommonTagShare: Double
}

func audit(_ samples: [ModelSample<BookTags>]) -> CorpusReport {
    let prompts = samples.map(\.promptDescription)
    let lengths = prompts.map(\.count).sorted()
    func pct(_ p: Double) -> Int {
        lengths.isEmpty ? 0 : lengths[min(lengths.count - 1, Int(p * Double(lengths.count)))]
    }

    var tagCounts: [String: Int] = [:]
    for sample in samples {
        for tag in sample.expected?.tags ?? [] { tagCounts[tag, default: 0] += 1 }
    }
    let totalTagUses = tagCounts.values.reduce(0, +)

    return CorpusReport(
        count: samples.count,
        duplicatePromptCount: prompts.count - Set(prompts).count,
        lengthP10: pct(0.10), lengthMedian: pct(0.50), lengthP90: pct(0.90),
        distinctTags: tagCounts.count,
        tagsAppearingOnce: tagCounts.values.filter { $0 == 1 }.count,
        mostCommonTagShare: totalTagUses == 0 ? 0
            : Double(tagCounts.values.max() ?? 0) / Double(totalTagUses)
    )
}
```

What to look at, and what each number is telling you:

- **`duplicatePromptCount > 0`** — the generator repeated itself. If the duplicates cluster in the back
  half of the run, you very likely got a §5 session swap.
- **`lengthP90 / lengthP10` near 1** — rule 3 was ignored. Every review is the same length, because
  the model settled into a template. Fix it in the instructions, not the validator.
- **`mostCommonTagShare` above about 0.1** — one tag is doing all the work. Usually `"classic"` or
  `"fiction"`; usually a sign that the seed set was thematically narrow and the generator faithfully
  amplified it.
- **`tagsAppearingOnce` close to `distinctTags`** — the opposite failure: the model is inventing a
  bespoke vocabulary per sample, which makes the tags useless as browse terms and makes any
  expected-vs-actual comparison meaningless.

Print this after every generation run, next to `invalidSamples.count`. It takes thirty seconds to read
and it is the only thing standing between you and a hundred synthetic reviews that are all the same
review.

---

## 9. Where the samples go: `samples`, `invalidSamples`, JSON, `JSONLoader`

Generation ends with data in memory. Getting it onto disk and back into an evaluation is three lines,
and there is one trap on the way back in.

### 9.1 `invalidSamples` is a debugging surface, not a bin

> ✅ **VERIFIED** — `/documentation/evaluations/samplegenerator`: `samples` is *"All samples — initial and
> generated — from the most recent run"*; `invalidSamples` is *"Samples that the validator rejected
> during the most recent run."* Both are actor-isolated; both are described by session 299 as updated in
> real time.

The rejects are the most useful diagnostic the generator produces, and almost nobody reads them. Each one
is an instruction-following failure with the exact text that failed attached to it. Two rejects for
short reviews means the model is drifting terse; forty rejects for uppercase tags means the instruction
about lowercase is not landing and belongs somewhere more prominent.

```swift prelude:guide-context
let rejects = await generator.invalidSamples
print("accepted \(await generator.samples.count), rejected \(rejects.count)")

// Which rule is failing? Re-run the guards individually over the rejects.
let tooShort  = rejects.filter { $0.promptDescription.count < 100 }
let badCount  = rejects.filter { !(3...8).contains($0.expected?.tags.count ?? 0) }
let uppercase = rejects.filter { ($0.expected?.tags ?? []).contains { $0 != $0.lowercased() } }
print("too short: \(tooShort.count), bad tag count: \(badCount.count), uppercase: \(uppercase.count)")
```

A rejection rate of zero means §8's vacuous validator. A rejection rate above roughly a third means your
instructions and your validator disagree with each other, and you are paying for model output you throw
away — fix the instructions rather than loosening the validator.

### 9.2 Writing the dataset out

> ✅ **VERIFIED** — `ModelSample` conforms to `Codable`, and Apple's CLI JSON-encodes
> `[ModelSample<BookTags>]` straight to `synthetic_book_samples.json`
> (`BookSampleGenerator/main.swift:82-86`), which `JSONLoader(url:)` reads back.

```swift prelude:guide-context
let output = URL.desktopDirectory.appending(path: "synthetic_book_samples.json")
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]   // reviewable diffs
try encoder.encode(expandedDataset).write(to: output)
print("wrote \(expandedDataset.count) samples to \(output.path())")
```

`.sortedKeys` and `.prettyPrinted` are not cosmetic. This file is going into version control, and the
point of committing it (§6.3) is that a human can review it and a diff can show what changed between
generation runs.

### 9.3 Reading it back — and the loader that swallows your data

> ✅ **VERIFIED** — the two concrete loaders are `ArrayLoader(samples:)` and `JSONLoader(url:)`, and
> `dataset` is a **stored** property on the `Evaluation`, not a computed one. Apple's sample runs the
> *same* evaluation over both: `BookTags.swift:37` uses `ArrayLoader` over the thirteen curated books,
> and `SyntheticBookTags.swift:25` declares `var dataset: JSONLoader<ModelSample<BookTags>>` over the
> generated hundred.

```swift prelude:guide-context
import Evaluations

struct SyntheticBookTaggingEvaluation: Evaluation {
    // Same subject, same evaluators, same aggregation as the curated evaluation.
    // The only thing that changes is where the samples come from.
    var dataset = JSONLoader<ModelSample<BookTags>>(
        url: Bundle.module.url(forResource: "synthetic_book_samples",
                               withExtension: "json")!
    )

    func subject(from sample: ModelSample<BookTags>) async throws -> ModelSubject<BookTags> {
        let result = try await BookTaggingService.generateTags(for: sample.promptDescription)
        return ModelSubject(value: result)
    }
    // … evaluators and aggregateMetrics identical to the curated evaluation …
}
```

That "identical except for the dataset" property is what makes §10's comparison legitimate. If you also
changed the evaluators when you changed the dataset, you learn nothing from the difference.

> ⚠️ **SILENT FAILURE — `JSONLoader` skips malformed rows and only whispers about it.**
>
> ✅ **VERIFIED** — Apple's `JSONLoader` documentation: if the first non-whitespace character is `[` the
> file is decoded as a JSON array in one pass; otherwise it is treated as **JSONL**, one sample per
> non-empty line. And then: *"**Malformed entries are logged via `OSLog` and skipped.** A failure to open
> the file propagates as a thrown error."*
>
> So a missing file throws — loudly, correctly. A file full of rows your `Codable` conformance cannot
> decode does **not** throw. It produces a smaller dataset. Your evaluation runs, your metrics compute,
> your test passes, and the number of samples behind those metrics is whatever survived. The classic way
> to hit it: you add a field to your `@Generable` output type, regenerate nothing, and every previously
> generated row now fails to decode. **A 100-sample evaluation quietly becomes a 0-sample evaluation and
> the aggregate still reports a number.**
>
> **The defence is one assertion**, and it belongs in every evaluation that loads from disk:
>
> ```swift
> @Test("Synthetic dataset is intact", .evaluates(Self.evaluation))
> func syntheticDatasetEvaluation() async throws {
>     let result = EvaluationContext.current.result
>     // Guard the dataset before you trust anything computed from it.
>     #expect(result.detailed.rows.count == 100)
>     #expect(result.aggregateValue(.mean(of: Self.evaluation.tagCount)) >= 0.8)
> }
> ```
>
> 🟡 **RECONSTRUCTED** — `result.detailed` is ✅ verified as a TabularData `DataFrame` of per-sample
> results; `.rows.count` is the ordinary `DataFrame` spelling for its row count but is not attested in
> any Apple sample we have read. If your build disagrees, count the metric column instead:
> `result.detailed[metric: Self.evaluation.tagCount].count`, which **is** attested.

---

## 10. The reality check: expansion makes your scores drop

This is the finding that justifies the entire chapter, and Apple presents it without flinching: they
expanded the dataset, re-ran the evaluation, **and the scores got worse**. They also say they *expected*
that before they ran it.

> ✅ **VERIFIED** — `299:98-102`, the whole passage:
>
> *"This is the **BookTaggingEvaluation** with the 13 initial samples. As you can see we got **pretty
> high scores for tag quality evaluating both relevance and usefulness**."*
>
> *"I've went ahead and ran the evaluation with our new dataset of 100 samples. Now, we can compare the
> two evaluations using the **Compare** button and **we're expecting the scores to drop!** And we were
> correct! The quality scores have dropped. **Our tag generation feature looked like it was performing
> well earlier because we weren't testing it with a comprehensive dataset.**"*

Sit with the last sentence. The feature did not get worse. **The feature was never as good as the
thirteen-sample evaluation said it was.** Nothing about the tagging service changed between those two
runs — same instructions, same `@Guide`, same model, same judge. The only thing that changed was how
honestly it was being asked.

This is the same illusion Apple hits earlier in the series at a smaller scale, and the two are worth
holding together because the shape is identical. In session 298 they add `@Guide(.count(3...8))`, re-run,
and the `TagCount` pass rate goes to 100% —

> ✅ **VERIFIED** — `298:127-130`: *"All right, I made the change and I re-ran the evaluation. My test
> passed, and my TagCount passes a 100% of the time. **But I notice a potentially strange behavior: after
> my change, the service always generates eight tags.** Hmmm."*

— a perfect green metric sitting on top of a degenerate distribution. And in session 335:

> ✅ **VERIFIED** — `335:52`: *"In this case, **my Evaluation met all of my expectations; however,
> because I know the tags aren't as good as I'd like them to be, I need to investigate further.**"*

**A passing evaluation is a claim about your evaluation, not about your feature.** Small datasets,
coarse metrics and unaligned judges all produce green. Expanding the dataset is one of the few moves
that reliably converts a false green into information.

### 10.1 What a drop can mean — the four hypotheses

Session 299 enumerates them, and this list is the thing to have open when you are staring at a
comparison view wondering what to do next.

> ✅ **VERIFIED** — `299:103-111`: *"By running our evaluation on a larger dataset, a drop in scores
> could signal many different things. Consider what this signal could suggest."*
>
> 1. *"Score changes could be due to **problems with our prompt or instructions**. You could refine one
>    or both to better capture your needs."*
> 2. *"You could also consider **gaps in your intelligence feature**."*
> 3. *"Or you may want to **adjust your evaluation to understand what you are actually evaluating on**."*
> 4. *"your **dataset may still not be representative enough** and need to capture more variation. You
>    can continue to increase the dataset or include more edge cases using the synthetic data APIs."*
>
> *"**These are the core ways to further improve your results.**"*

They are listed in the order Apple gives them, but they are not equally likely, and each one has a
different tell. Here is how to actually discriminate between them.

**Hypothesis 1 — the prompt or instructions are the problem.**
*The tell:* the drop is concentrated in sample categories your instructions never anticipated. Sort the
detailed results by score and read the bottom twenty. If the failures share a *kind* — every long review
fails, every review containing the reader's opinions fails — that is an instruction gap, not a model
limitation.
*The move:* change one sentence of the instructions, re-run, compare. This is hill climbing, and
[`01-foundations-and-hill-climbing.md`](01-foundations-and-hill-climbing.md) covers the
discipline — one variable at a time, promote the winner into the baseline before starting the next
experiment.

**Hypothesis 2 — the feature has a real gap.**
*The tell:* the failures share a *capability*, not a phrasing. In Book Tracker's case the gap was
information: the model was tagging from the review text alone, with no knowledge of the actual book.
The fix was not a better prompt but a new tool.

> ✅ **VERIFIED** — `335:217-221`: *"What I want to do is **give the model some more context about the
> book it's generating tags for.**… **Book Tracker already has the data needed for this because we store
> the author's name and book title when they write their review.** So, to help the tag generator,
> **I've created a tool to get additional information on the book**… **Adding this tool is a form of
> hill-climbing because we are attempting to improve the quality of our feature through an incremental
> change.**"*

*The move:* add the capability, and make it A/B-able rather than mandatory:

> ✅ **VERIFIED** — `335:224-225`: *"**`BookTaggingService` now takes a list of tools as input. I also
> set the default to an empty array so my existing evaluation won't need any changes.**"*

```swift illustrative
struct BookTaggingService {
    // Defaulting to [] means the existing evaluation compiles and behaves
    // identically, so the two runs differ in exactly one variable.
    static func generateTags(
        for review: String,
        tools: [any Tool] = []
    ) async throws -> BookTags { /* … */ }
}
```

**Hypothesis 3 — the evaluation is measuring the wrong thing.**
*The tell:* you read the low-scoring rows and disagree with the score. This is the most common outcome
and the most misread. The instinct is that the judge is broken. The corrected instinct:

> ✅ **VERIFIED** — `298:232-235`: *"And here's the thing: **by the scale we wrote, the judge is actually
> right. Every tag connects to something that the user wrote. The judge is faithfully following the
> scoring guide we provided. We meant something specific by relevant and useful for browsing, and the
> judge interpreted those words differently than we did.**"*

*The move:* if the scores are all the same, your question is too broad; if you cannot isolate the
problem, split the dimensions; if the judge does not understand your app, add context (`298:282-285`).
And if your judge is scoring differently from you *systematically*, you have drift, and you need to
calibrate the judge against human ratings before you trust any of this — the Cohen's-kappa work in
session 335. **That statistic is hand-rolled, not shipped**: `Statistics.cohensKappa` is 72 lines of
ordinary Swift in Apple's own sample, and the framework provides no agreement metric.

**Hypothesis 4 — the dataset is still not representative.**
*The tell:* the new samples are not actually varied — §8.3's audit shows a duplicate cluster, a collapsed
length distribution, or one tag carrying 20% of the mass. A hundred samples drawn from a narrow
generator is thirteen samples with extra steps.
*The move:* generate again with a *different* prompt aimed at the gap, and append. §11 is about how to
decide which gap.

### 10.2 The one move that is always wrong

**Do not shrink the dataset back.** It is remarkable how tempting this is at 5pm on a Friday: the
thirteen-sample evaluation is green, the hundred-sample one is not, the thirteen-sample one is *also*
committed and runs faster. Deleting the hundred does not restore the quality it revealed you never had;
it restores your ignorance of it.

The related, subtler version: quietly loosening a judge's scoring scale so the hundred-sample run goes
green again. That is not hill climbing, it is moving the hill.

### 10.3 Running the comparison properly

Two evaluations, same everything except the dataset, both in one suite.

> ✅ **VERIFIED** — `335:167`: *"With both prompts written, **I can add both evaluations to a test suite,
> which will run both evaluations.**"* And `335:230`: *"So all I have to do is **define two instances of
> my evaluation**. One without the tool and one with it."*
>
> ✅ **VERIFIED** — the comparison UI, from Apple's documentation: *"When the run finishes, open the
> **Report navigator** and select the **Evaluations** item beneath the test run to open the evaluation
> report."* and *"For a side-by-side view, choose **Compare** and select a run for each side."*

```swift prelude:guide-context
import Testing
import Evaluations

@Suite("Tagging: curated vs synthetic")
struct DatasetScaleComparison {
    // Both must be `static let` so the test bodies can reach the same Metric identities.
    static let curated   = BookTaggingEvaluation()            // 13 hand-written samples
    static let synthetic = SyntheticBookTaggingEvaluation()   // 100 generated samples

    // `info:` stamps run metadata into the record, which is what makes two runs
    // legible side by side weeks later.
    static let curatedInfo: [String: String] = [
        "Dataset": "curated-13", "Prompt": BookTaggingService.instructions,
        "ModelName": "SystemLanguageModel", "AppVersion": "1.0"
    ]
    static let syntheticInfo: [String: String] = [
        "Dataset": "synthetic-100", "Prompt": BookTaggingService.instructions,
        "ModelName": "SystemLanguageModel", "AppVersion": "1.0"
    ]

    @Test("Curated", .evaluates(curated, info: curatedInfo))
    func curatedDataset() async throws {
        let result = EvaluationContext.current.result
        #expect(result.aggregateValue(.mean(of: Self.curated.tagCount)) >= 0.8)
    }

    @Test("Synthetic", .evaluates(synthetic, info: syntheticInfo))
    func syntheticDataset() async throws {
        let result = EvaluationContext.current.result
        // Deliberately a lower bar than the curated run. This is the honest number.
        #expect(result.aggregateValue(.mean(of: Self.synthetic.tagCount)) >= 0.7)
    }
}
```

> ✅ **VERIFIED** — `.evaluates(_:)` and `.evaluates(_:info:)` both exist; the evaluation must be a
> `static let` on the suite so the test body reaches the same `Metric` identities; the trait runs the
> whole dataset **before** the body, and the body is an assertion over the aggregate, reached through
> `EvaluationContext.current.result`. The test function never iterates samples.
> (`BookTags.swift:149-167`; the bare form at `SearchBooks.swift:572`.)

Two details that pay for themselves later. Apple's sample stamps **the prompt text itself** into `info:` —
so when you open a six-week-old run you can see what the feature was actually told to do. And note the
different thresholds above: the synthetic suite is allowed to be lower. Holding a representative dataset
to a number you derived from an unrepresentative one just reproduces the original lie with more steps.

---

## 11. Coverage beats count

"How many samples do I need" is the question everyone asks, and Apple's answer is a redirect.

> ✅ **VERIFIED** — `299:37-40`, in sequence:
>
> *"Now you might be wondering how much data is enough? And the answer is, **it depends.**"*
>
> *"Synthetic data generation is often an **iterative process of defining an initial dataset, generating
> synthetic data, validating the samples, then, analyzing whether or not the data is representative
> enough and continuing this cycle until you are confident!**"*
>
> *"**What matters far more than quantity is coverage! So instead of asking how many samples do I need?
> Ask yourself, have I covered the meaningful variety of ways this feature will actually be used?**"*

That last sentence is the one to write on the wall. A thousand samples drawn from one narrow generator
prompt tell you one thing a thousand times. Sixty samples that between them cover six genres, four review
lengths, two literacy registers and a handful of adversarial cases tell you sixty different things.

And the starting size, which does not contradict "thousands of samples" once you read it as a *starting*
size:

> ✅ **VERIFIED** — `298:272-274`: *"**Start small. A focused dataset of 20 to 30 samples is a great place
> to get started.** Spec out your app by thinking about how you want the model to behave."*

### 11.1 The dimensions to cover

Session 298 walks through them explicitly while building the Book Tracker dataset by hand, and the list
generalises well beyond book reviews.

> ✅ **VERIFIED** — `298:135-149`:
>
> - **Genre variety** — *"We want the service to recognize different genres."*
> - **Length variety** — *"We can't assume every user will give it a verbose review, so our reviews
>   should be different lengths."*
> - **Category variety** — *"You browse for fiction and non-fiction using different categories, your
>   samples should represent that variety."*
> - **Form variety** — *"novels, short stories, and essays."*
> - **Adversarial content** — *"Let's makes it hard on the model too. **Sprinkle in personal opinions**,
>   so we can measure how well the service ignores those in the reviews."*
> - **Style transfer through the expected values** — *"If you want to teach the feature how to write tags
>   like you, start by **including more of your personal style in the expected values of the samples**."*

The hand-written personas they used are worth stealing as a template, because each one is a *dimension*
wearing a costume: *The Secret Garden* reviewed "as though we were an avid gardener"; *Treasure Island*
as "a personal review from a mother reading it to her son. Lots of personal opinions in this review";
*Romance of the Three Kingdoms* where "this board game enthusiast needed multiple paragraphs"; and a
Sherlock Holmes review where "this casual reader described a famous British detective's sidekick in a
**single sentence**."

Four samples, four axes moved: domain expertise, emotional register, length, and brevity to the point of
under-specification.

### 11.2 Turn the dimensions into a matrix, then generate per cell

The mistake that produces a hundred near-identical samples is running **one** generator with **one**
prompt and hoping variety falls out. It does not; a language model asked for "diverse" output converges
on its own idea of diverse, which is narrow and stable.

Write the matrix first, then run a generation pass per row. Each pass is cheap — it is the same
generator with a different `prompt`, and you append its output to the same array.

```swift prelude:guide-context
struct CoverageCell {
    let label: String       // goes into the run log, and eventually into `info:`
    let prompt: Prompt
    let wanted: Int
}

let cells: [CoverageCell] = [
    CoverageCell(
        label: "terse-casual",
        prompt: Prompt("""
            Generate book reviews of one or two sentences, written casually, often
            without naming the book's genre. Cover a wide range of genres and eras.
            """),
        wanted: 20),
    CoverageCell(
        label: "long-enthusiast",
        prompt: Prompt("""
            Generate multi-paragraph reviews by domain enthusiasts who bring outside
            expertise to the book — a gardener, a strategist, a historian.
            """),
        wanted: 20),
    CoverageCell(
        label: "opinion-heavy-adversarial",
        prompt: Prompt("""
            Generate reviews dominated by the reader's personal reactions — bored,
            moved, irritated — where the book's actual subject is mentioned only in
            passing. Expected tags must still describe the book, never the reaction.
            """),
        wanted: 20),
    CoverageCell(
        label: "nonfiction-and-essays",
        prompt: Prompt("""
            Generate reviews of non-fiction: essay collections, memoirs, history,
            popular science. Tags should suit browsing a non-fiction shelf.
            """),
        wanted: 20),
]

var corpus = seeds
for cell in cells {
    let generator = SampleGenerator<ModelSample<BookTags>>(
        cell.prompt,
        samples: corpus,                              // grows each round: no repeats
        targetCount: corpus.count + cell.wanted,      // §3: seeds are included
        sessionProvider: makeGenerationSession,       // §5: self-contained instructions
        validator: isValidBookSample                  // §8: per-sample rules only
    )
    for try await sample in generator.run() { corpus.append(sample) }
    print("\(cell.label): corpus now \(corpus.count), rejected \(await generator.invalidSamples.count)")
}
```

Three properties of that loop are deliberate. Passing the **growing** corpus as `samples:` on each round
means later rounds can see earlier output and avoid repeating it. Computing `targetCount` from
`corpus.count` keeps §3 from biting. And the per-cell label printed alongside the reject count tells you
which axis your generator is bad at, which is information you cannot get from a single undifferentiated
run.

### 11.3 The categories Apple names but we could not read

> 🔴 **GAP — the dataset-design article was not harvested in full.** Apple ships an article at
> `/documentation/evaluations/designing-evaluation-datasets` ("Designing datasets to test your feature")
> whose topic list includes **golden sets, user profiles, and challenge cases** — three named dataset
> categories that are almost certainly the intended vocabulary for exactly what §11.2 improvises. Our
> corpus captured the topic names and not the article body.
>
> **What would resolve it:** fetching that one page. It is a single document and it is public.
>
> **Safe default meanwhile:** the three names map onto structures you can build without the article, and
> which nothing in the corpus contradicts — a small hand-written **golden set** you never regenerate and
> always report separately; **persona-shaped** generation cells as in §11.2; and a **challenge set** of
> deliberately hard and adversarial samples, kept as its own dataset so its scores are not averaged away
> into the easy ones. Do not quote definitions of those three terms — including the ones in this
> paragraph — as Apple's until someone reads the page.

The last part of that is the operational point regardless of terminology: **keep your hard cases in a
separate evaluation.** If ten adversarial samples live inside a hundred-sample dataset, a feature that
fails all ten still scores 90%. As their own evaluation with their own threshold, they fail loudly.

---

## 12. Why the final answer is not enough

Everything up to here has been about *what the model produced*. The second half of this guide is about
*how it got there*, and the argument for caring is one sentence long.

> ✅ **VERIFIED** — `299:122-124`: *"**Here's the thing. A model might give you a reasonable-sounding
> answer without ever calling the right tool. The final output can look correct while the path to get
> there isn't right.**"*

That is not a hypothetical. A model asked "which gothic books are in my library?" can produce a fluent,
confident, correctly-formatted list of gothic novels **from its training data**, having never touched
your library. Every output evaluation you have written will pass it. The list is wrong in the only way
that matters — the books are not the user's books — and no amount of judging the prose will reveal it.

Session 298 flagged this as one of the framework's three founding questions:

> ✅ **VERIFIED** — `298:19`: *"We need to know: how often does my app produce unexpected results?
> **How often does the agent take an unexpected path to generate answers?** And under what circumstances
> does the feature produce unsafe results?"*

### 12.1 What a tool evaluation actually checks

> ✅ **VERIFIED** — `299:130-133`: *"That's why we need tool evaluations. **They let you verify the how,
> not just the what.**"* and *"**The model should call the correct tools, with the correct arguments in
> the order you expect. And along the way, you'll double check that there weren't any unexpected tool
> calls in the middle.**"*

Four checks, and they map one-to-one onto the API you are about to meet:

| Check | Expressed as |
|---|---|
| the correct tools were called | `ToolExpectation("searchBooks")` in `ordered:` or `unordered:` |
| with the correct arguments | `arguments: [ArgumentMatcher]` on the expectation |
| in the order you expect | `TrajectoryExpectation(ordered:)`, plus `allowsAdditionalToolCalls` |
| and nothing unexpected happened | `disallowed:` |

And the framing that makes it intuitive:

> ✅ **VERIFIED** — `299:151-152`: *"You can think of a trajectory expectation check like **going over the
> list of decisions you made when planning a route. Cars, bikes, and buses are all tools that have their
> time and place in getting somewhere, but you can evaluate their utility for each segment in a specific
> trip.**"*

### 12.2 Ordering is not pedantry

The reason `ordered:` exists is not tidiness. It is that some orders are *impossible*, and a model that
produces an impossible order has a bug you will otherwise diagnose as "the answer was a bit off".

> ✅ **VERIFIED** — `299:169-172`: *"**For multistep tasks, order matters.** Here the model must **first
> call 'searchBooks', then call 'getBookDetails'**. **If an agent tries to get details first, it doesn't
> have a `bookId` yet — that's a bug. Trajectory expectations catch it because we're checking the
> journey, not just the destination.**"*

A `getBookDetails` call issued before any `searchBooks` call has to have invented its `bookId`. The tool
will either fail, or — worse — succeed against a plausible-looking identifier that belongs to something
else. The final answer may still read fine. The trajectory is the only place the defect is visible.

### 12.3 Your tools do not need to do anything

One practical relief before the API: evaluation-time tools can be stubs.

> ✅ **VERIFIED** — Apple's `evaluating-language-model-responses` article: *"Tool-calling evaluation
> measures **whether the model selects the right tool with the right arguments, not what the tool does
> when called**. Your tools don't need to perform real actions during evaluation, so simple stubs like
> this one work well."*

So a tool evaluation does not need your database, your network, or your user's data. It needs tools with
the right **names, descriptions and argument schemas**, because those are what the model sees and reasons
about. Apple's own sample nevertheless passes real (in-memory) book data into its tools, which is the
better default when the tool's *output* shapes the next decision in the trajectory: a stub that returns
nothing plausible can cause the model to abandon a chain you were trying to measure.

---

## 13. `TrajectoryExpectation`: four shapes

A trajectory expectation is attached to a **sample**, not to an evaluator. Each sample carries the prompt
and the trajectory that prompt ought to produce.

> ✅ **VERIFIED** — `299:149-150`: *"**The main component of a tool evaluation is a trajectory
> expectation.** A session transcript has tool calls among the prompts and responses. **A
> `TrajectoryExpectation` checks the order and kind of each tool call in a language model session.**"*
> And `299:153-154`: *"The expectation **looks for all of the tool calls. Then for each one, runs it
> against the expectations you write into your evaluations.**"*

> ✅ **VERIFIED** — where it attaches: `ModelSample(prompt:expected:instructions:expectations:)`, and
> Apple's own type documentation for the property — *"The expected pattern of tool calls for this
> sample."* (`/documentation/evaluations/modelsample`; call site at `SearchBooks.swift:46-74`.)

Note the **plural** on the label — `expectations:` — while the value is a single
`TrajectoryExpectation`. That is a real spelling, not a typo in this guide, and it is the kind of thing
that costs ten minutes if you guess.

### 13.1 The initialiser surface

> ✅ **VERIFIED** — the parameter spellings, from `/documentation/evaluations/trajectoryexpectation`:
>
> ```swift
> struct TrajectoryExpectation
> init(ordered:)
> init(ordered:allowsAdditionalToolCalls:)
> init(ordered:unordered:disallowed:)
> init(expected:arguments:)              // single-tool convenience
> ```
>
> ✅ **VERIFIED** — the forms actually exercised in Apple's Book Tracker sample, which contains **16
> trajectory expectations** across `SearchBooks.swift`:
>
> | Form | Where |
> |---|---|
> | `TrajectoryExpectation(unordered: [ToolExpectation])` | `SearchBooks.swift:66` |
> | `TrajectoryExpectation(ordered: [ToolExpectation], allowsAdditionalToolCalls: true)` | `:140-154` |
> | `TrajectoryExpectation(unordered: [...], disallowed: [ToolExpectation("findSimilarBooks")])` | `:344-359` |
> | `TrajectoryExpectation(expected: "searchBooks", arguments: [...])` | `:413-418` |

> ✅ **SDK-verified — GAP closed (2026-07-29).** The declaration has exactly **four initialisers**,
> and the reconciliation is "both": defaults *and* dedicated overloads
> (`Evaluations-27.0-macos.swiftinterface:258-261`):
>
> ```swift
> init(ordered: [ToolExpectation] = [], unordered: [ToolExpectation] = [],
>      allowsAdditionalToolCalls: Bool = true)
> init(ordered: [ToolExpectation] = [], unordered: [ToolExpectation] = [],
>      disallowed: [ToolExpectation])
> init(unordered: [ToolExpectation])
> init(expected toolName: String, arguments: [ArgumentMatcher] = [])
> ```
>
> So the sample's `(unordered:)` hits the dedicated third form; `(unordered:disallowed:)` is the
> second form with `ordered:` defaulted; and the combination this guide previously warned against
> inventing — `(ordered:disallowed:)` — is in fact legal, the second form with `unordered:`
> defaulted. Note what is *not* expressible: `disallowed:` and `allowsAdditionalToolCalls:` never
> appear in the same initialiser, so you cannot combine an explicit disallow-list with the strict
> no-additional-calls mode in one expectation.

### 13.2 Unordered — "it happened, I don't care when"

> ✅ **VERIFIED** — `299:156-160`: *"Our prompt is 'Find books tagged gothic'. We expect one tool call
> 'searchBooks'. This is a `TrajectoryExpectation`. It describes the tool calls we expect to see in the
> model's transcript. **The `unordered` here means we don't care when this tool call happens, just that
> it happens.**"*

> ✅ **VERIFIED** — verbatim from `SearchBooks.swift:46-74`:

```swift illustrative
    ModelSample(
        prompt: "gothic",
        expected: BookResults(books: [ … ]),
        instructions: BookAssistant.instructions,
        expectations: TrajectoryExpectation(unordered: [
            ToolExpectation(
                "searchBooks",
                arguments: [
                    .exact(argumentName: "tag", value: .string("gothic"))
                ]
            )
        ])
    ),
```

This is the shape you will write most often, and it is the right default. Most single-step features have
exactly one tool that must be reached; insisting on a position in the sequence adds a constraint you do
not actually hold.

### 13.3 Ordered — "first this, then that"

> ✅ **VERIFIED** — verbatim from `/documentation/evaluations/trajectoryexpectation`:
>
> ```swift
> TrajectoryExpectation(ordered: [
>     ToolExpectation("authenticate"),
>     ToolExpectation("processResults"),
> ])
> ```

Applied to the Book Tracker assistant, the ordering constraint from §12.2 becomes:

```swift illustrative
ModelSample(
    prompt: "Tell me when the gothic books in my library were published",
    expected: BookResults(books: [ … ]),
    instructions: BookAssistant.instructions,
    expectations: TrajectoryExpectation(
        ordered: [
            ToolExpectation("searchBooks"),
            // getBookDetails cannot run first: it has no bookId until searchBooks
            // has produced one. Ordering here encodes a data dependency.
            ToolExpectation("getBookDetails", arguments: [.keyOnly(argumentName: "bookId")]),
        ],
        allowsAdditionalToolCalls: true
    )
)
```

`.keyOnly(argumentName: "bookId")` is doing real work in that example: it asserts the model **supplied**
a `bookId` without asserting *which* one, because the id is whatever `searchBooks` happened to return.
That is exactly the case Apple documents the matcher for (§15).

### 13.4 Combined — ordered *and* unordered *and* disallowed

The richest documented form puts all three constraints on one trajectory. It is the shape to reach for
when part of the work has a real dependency and part of it does not.

> ✅ **VERIFIED** — verbatim from `/documentation/evaluations/trajectoryexpectation`:
>
> ```swift
> TrajectoryExpectation(
>     ordered: [
>         ToolExpectation("findActivities"),
>         ToolExpectation("estimateTravelTime"),
>     ],
>     unordered: [ToolExpectation("getWeather")],
>     disallowed: [ToolExpectation("deleteData")]
> )
> ```

Read that as three separate assertions over one transcript: *`findActivities` must precede
`estimateTravelTime`*; *`getWeather` must appear, anywhere*; *`deleteData` must never appear*. The weather
lookup genuinely has no ordering relationship to the other two, so pinning it to a position would make
the expectation fail on a correct trajectory.

### 13.5 The single-call shorthand

> ✅ **VERIFIED** — verbatim from the documentation:
>
> ```swift
> TrajectoryExpectation(expected: "getWeather", arguments: [
>     .exact(argumentName: "location", value: "Paris, France")
> ])
> ```
>
> and from the sample at `SearchBooks.swift:413-418`, the same form with the app's own tool.

For a one-tool feature this collapses two nested literals into one. It also removes the decision about
ordered-versus-unordered, which for a single call is meaningless.

---

## 14. `ToolExpectation`, `anyOrder`, and additional calls

`ToolExpectation` is the per-call element inside a trajectory. It is small, and two of its three members
are the interesting ones.

> ✅ **VERIFIED** — from `/documentation/evaluations/toolexpectation`:
>
> ```swift
> struct ToolExpectation                    // conforms to Generable
> init(_ name: String, arguments: [ArgumentMatcher])
> static func anyOrder(_:) -> ToolExpectation
> var name, arguments, isAnyOrderGroup
> ```
>
> ✅ **VERIFIED — the name-only form compiles**: `ToolExpectation("findSimilarBooks")` appears at
> `SearchBooks.swift:344-359`, so `arguments:` is defaulted.
>
> ✅ **SDK-verified** — `init(_ name: String, arguments: [ArgumentMatcher] = [])`: the default is in
> the declaration, and `name`, `arguments` and `isAnyOrderGroup` are read-only public properties
> (`Evaluations-27.0-macos.swiftinterface:212-239`). The `Generable` conformances are in the shipped
> interface too — `ToolExpectation` at `:240-244`, `ArgumentMatcher` at `:213-217`.

The `Generable` conformance in that first line is not a curiosity; it is what §18 is built on. A type the
model can generate is a type a `SampleGenerator` can synthesise.

### 14.1 `anyOrder(_:)` — a group that occupies one position

The awkward case in any ordered sequence is "these two both have to happen here, but I don't care which
is first". `anyOrder(_:)` returns a `ToolExpectation` that stands in for a *set* of calls at a single
position in the ordered list.

> ✅ **VERIFIED** — verbatim from the documentation, including the surrounding ordered sequence:
>
> ```swift
> TrajectoryExpectation(ordered: [
>     ToolExpectation("authenticate"),
>     .anyOrder([
>         ToolExpectation("fetchData"),
>         ToolExpectation("fetchMetadata"),
>     ]),
>     ToolExpectation("processResults"),
> ], allowsAdditionalToolCalls: false)
> ```
>
> ✅ **VERIFIED** — Apple's own description: *"For ordered sequences where multiple tools must all be
> called at the same position but their relative order doesn't matter, use `anyOrder(_:)`."*

That is a genuinely common agentic shape: authenticate first, gather in parallel, then process. Without
`anyOrder` you would have to write two samples with two orderings and accept a false failure whenever the
model picked the other one. The `isAnyOrderGroup` property is how you can tell such a group apart from an
ordinary expectation when you are inspecting one — relevant in §18, where you are validating generated
expectations rather than writing them.

### 14.2 `allowsAdditionalToolCalls`

An ordered expectation lists the calls you require. Real transcripts often contain calls you did not list
— a retry, a lookup the model decided it needed, a second `searchBooks` with a refined query.
`allowsAdditionalToolCalls` decides whether those are tolerated or fatal.

> ✅ **VERIFIED — both values appear in Apple's material, and they disagree with each other.** The
> documentation's `anyOrder` example passes **`false`**. The Book Tracker sample passes **`true`**
> (`SearchBooks.swift:140-154`). Both compile; they encode different intentions.

> ✅ **SDK-verified — the default is `true`** (`allowsAdditionalToolCalls: Bool = true`,
> `Evaluations-27.0-macos.swiftinterface:258`, checked 2026-07-29), so an ordered expectation that
> omits the parameter is *permissive*: unlisted calls are tolerated. Two adjacent facts from the
> same declaration: the stored property behind the label is spelled **`allowsAdditionalCalls`** — no
> "Tool" — so that is the name you read back when inspecting an expectation (`:257`); and the
> parameter exists only on the `ordered:unordered:` initialiser, never alongside `disallowed:`
> (§13.1).
>
> ✅ **Probe-verified, 2026-07-31 — `false` IS enforced.** (was 🔴 still-open; `probes/`
> `eval.allowsAdditionalCalls-false`, run on the 27.0 sim runtime with canned transcripts.) A
> trajectory containing an unexpected extra call under `allowsAdditionalToolCalls: false` **fails
> `allPass`** (control `allPass=1.0`, with-extra-call `allPass=0.0`) and **halves
> `percentagePass`** (1.0 → 0.5) — the flag is a real prohibition, not advisory. The finer reading
> question — whether an extra call *outside* the listed span is treated differently from one
> interleaved between listed calls — was not separately distinguished by the probe; if that
> distinction matters to your suite, test your own shape.
>
> **The habit still worth keeping: write it explicitly wherever the distinction matters.** Omission
> means `true` — but an explicit value documents your intent to the next reader. Use `true` when
> you are asserting "these steps happened in this order" and `false` when you are asserting "this
> is the whole trajectory and nothing else belongs in it" — the second being much stronger, much
> more brittle, and appropriate mainly for cost-sensitive or safety-sensitive flows — and now known
> to actually bite.

```swift prelude:guide-context
// "Search, then fetch details. The model may also do other things." — permissive.
TrajectoryExpectation(
    ordered: [ToolExpectation("searchBooks"), ToolExpectation("getBookDetails")],
    allowsAdditionalToolCalls: true
)

// "Exactly these calls, in this order, and nothing else." — strict.
// Use where an extra call costs money, mutates data, or leaks context.
TrajectoryExpectation(
    ordered: [ToolExpectation("authenticate"), ToolExpectation("processResults")],
    allowsAdditionalToolCalls: false
)
```

---

## 15. The nine argument matchers

Getting the right tool called is half of it. The other half is what the model passed. `ArgumentMatcher`
is the enum you build those assertions from, and it is bigger than the sessions let on.

> ✅ **VERIFIED** — the complete table, verbatim from `/documentation/evaluations/argumentmatcher`
> (`enum ArgumentMatcher`, conforming to `Generable, Codable, Sendable`):
>
> | Case | Apple's rule, verbatim |
> |---|---|
> | `.exact(argumentName:value:)` | *"Value must equal the expected value exactly. Use for identifiers, enum values, and precise inputs."* |
> | `.keyOnly(argumentName:)` | *"Argument must be present with any value. Use when you care that the model provides the parameter but any value is acceptable."* |
> | `.oneOf(argumentName:allowedValues:)` | *"Value must be one of the allowed options. Use for ambiguous prompts with multiple valid interpretations."* |
> | `.range(argumentName:minimum:maximum:)` | *"Numeric value must fall within bounds (inclusive). Use for quantities where a range is acceptable."* |
> | `.pattern(argumentName:regex:)` | *"String must match a regular expression. Use for structured formats: emails, dates, IDs."* |
> | `.contains(argumentName:substring:)` | *"String must contain a substring. Use when the argument references a concept but phrasing varies."* |
> | `.hasPrefix(argumentName:prefix:)` | *"String must start with a prefix. Use for paths, URLs, or namespaced values."* |
> | `.hasSuffix(argumentName:suffix:)` | *"String must end with a suffix. Use for file extensions or domain-specific endings."* |
> | `.naturalLanguage(argumentName:criteria:)` | *"**A language model judges whether the value satisfies the criteria.** Use when correctness is subjective or hard to express with string operations, for example, validating that a query argument is 'a weather-related question'."* |
>
> ✅ **SDK-verified** — all nine case spellings and argument labels match the shipped interface
> exactly (`Evaluations-27.0-macos.swiftinterface:180-212`). One typing detail the table cannot
> show: `.range`'s bounds are `minimum: Double?, maximum: Double?` — plain optional doubles, not
> wrapped values — which is why the sample writes `minimum: 1, maximum: 3` bare (§15.2).

**Nine, not seven.** Seven of them are exercised in Apple's Book Tracker sample; `.pattern` and
`.hasPrefix` are documented but do not appear in the archive. Session 299 mentions `pattern` out loud,
so all three sources agree it exists — but if you are the sort of reader who trusts compiling code over
prose, note which two you would be the first to try. Their spellings, at least, are no longer in
doubt: both cases are in the shipped interface (`:181,183`); the untested part is behaviour, not
naming.

> ✅ **VERIFIED** — the seven exercised in `SearchBooks.swift`, with the sample's own line numbers:
>
> | Matcher | As written in the sample | Line |
> |---|---|---|
> | `.exact` | `.exact(argumentName: "tag", value: .string("gothic"))` | `:71` |
> | `.naturalLanguage` | `.naturalLanguage(argumentName: "mood", criteria: "Should relate to uplifting, hopeful, or positive feelings.")` | `:96-99` |
> | `.keyOnly` | `.keyOnly(argumentName: "bookId")` | `:150` |
> | `.oneOf` | `.oneOf(argumentName: "tag", allowedValues: [.string("strategy"), .string("epic"), .string("political intrigue")])` | `:172-176` |
> | `.contains` | `.contains(argumentName: "tag", substring: "histor")` | `:202` |
> | `.hasSuffix` | `.hasSuffix(argumentName: "genre", suffix: "fiction")` | `:517` |
> | `.range` | `.range(argumentName: "limit", minimum: 1, maximum: 3)` | `:327` |

Look at `.contains(argumentName: "tag", substring: "histor")` for a moment. It accepts `history`,
`historical`, `historical-fiction` and `prehistoric`, and it exists because the *concept* is stable while
the model's morphology is not. That is the entire design philosophy of this enum: **assert the thing you
actually care about, at the loosest granularity that still fails when the model is wrong.** An `.exact`
match on a free-text argument is a test that fails on Tuesdays.

### 15.1 `.naturalLanguage` — a judge inside your assertion

This is the headline capability and the reason the whole matcher enum is `Generable`.

> ✅ **VERIFIED** — `299:163-166`: *"**An exact match isn't always what you want.** If the prompt is
> 'Find something cheerful', the model might pass **uplifting, happy, cheerful — any of those are
> fine**. The **`.naturalLanguage`** matcher **checks whether the value matches the intent, not the exact
> string**."*

```swift illustrative
ModelSample(
    prompt: "show me something cheerful",
    expected: BookResults(books: [ … ]),
    instructions: BookAssistant.instructions,
    expectations: TrajectoryExpectation(unordered: [
        ToolExpectation("searchBooks", arguments: [
            // Passes for "cheerful", "uplifting", "happy", "hopeful", "warm"…
            .naturalLanguage(
                argumentName: "mood",
                criteria: "Should relate to uplifting, hopeful, or positive feelings."
            )
        ])
    ])
)
```

Three things to internalise about it:

**It costs a model call.** A `.naturalLanguage` matcher is a small judge invocation per argument per
sample. On a 100-sample tool evaluation with two such matchers each, that is 200 extra inferences on top
of the 100 feature invocations. It is the reason a tool evaluation runs slower than an output evaluation,
and it is worth reserving for arguments that genuinely need it.

**It is not deterministic.** You have put a language model inside your assertion. Two runs over identical
transcripts can disagree at the margin. Write `criteria:` the way you would write a scoring dimension —
concrete, observable, and narrow — for the same reason: *"Should relate to uplifting, hopeful, or
positive feelings"* names three specific qualities, where *"a good mood value"* would name none. Apple's
judge-design guidance applies verbatim here: each level of a rubric should describe **observable
features** rather than restating a gradient.

**Prefer a cheaper matcher when one exists.** If the acceptable set is enumerable, `.oneOf` is
deterministic, free, and self-documenting. Reach for `.naturalLanguage` when the space is genuinely open.

> ✅ **SDK-verified — you can choose the matching model.** `ToolCallEvaluator` has a second
> initialiser, `init(allPass:percentagePass:argumentMatchModel: any LanguageModel)`
> (`Evaluations-27.0-macos.swiftinterface:172`), that names the model used to judge
> `.naturalLanguage` matchers. Neither the docs harvest nor the sample mentions it — Book Tracker
> uses the two-parameter form, which leaves the choice to the framework. An availability quirk in
> the same block: the *two*-parameter form is `@available(watchOS, unavailable)` (`:169-171`) while
> the `argumentMatchModel:` form is not, so on watchOS you apparently must name the matching model
> explicitly.

### 15.2 The value-wrapping footgun

> ⚠️ **Two spellings of the same argument value appear in Apple's own material** — the
> `/documentation/evaluations/trajectoryexpectation` page writes
> `.exact(argumentName: "location", value: "Paris, France")` (a bare string), while the
> `evaluating-language-model-responses` article and the Book Tracker sample write
> `.exact(argumentName: "letter", value: .string("r"))` (a wrapped case).
>
> ✅ **SDK-verified — both compile, and the GAP is closed (2026-07-29).** The matcher's value type is
> **`ArgumentValue`**, an enum with exactly four cases — `.string`, `.int`, `.double`, `.bool` —
> conforming to `ExpressibleByStringLiteral`, `ExpressibleByIntegerLiteral`,
> `ExpressibleByFloatLiteral` and `ExpressibleByBooleanLiteral`
> (`Evaluations-27.0-macos.swiftinterface:15-81`). So the doc page's bare `"Paris, France"` is
> legal — the string-literal conformance does the wrapping, and `42`, `3.5` and `true` literals work
> the same way. **`StructuredValue` is a different, richer type** — seven cases including `.null`,
> `.array` and `.dictionary` (`:82-100`) — which `ArgumentValue` bridges *into* via its
> `structuredValue` property (`:22-24`); an earlier revision of this guide conflated the two. There
> is no `.array` or `.dictionary` matcher value: an argument you can match on is a string, an int, a
> double or a bool.
>
> **House style stays with the wrapped form**, `.string("gothic")` — it is what all sixteen of the
> sample's trajectory expectations use, and it survives being moved into a context where literal
> inference does not apply. But the bare literal is not an error, and `.int` / `.double` / `.bool`
> are SDK-verified cases, not inferences — merely unexercised in Apple's archive.

Note also that `.range(argumentName:minimum:maximum:)` takes bare numbers in the sample
(`minimum: 1, maximum: 3`) rather than wrapped values — so the wrapping convention is per-case, not
universal.

---

## 16. `disallowed`: evaluating what the model must *not* do

Almost every instruction-following test people write is positive: did it do the thing. Negative
instructions — *don't*, *only*, *never*, *without* — are harder to follow and much harder to notice
failing, because a violation still produces a fluent answer.

> ✅ **VERIFIED** — `299:173-176`: *"**Sometimes what an agent shouldn't do is just as important.** If a
> prompt includes ideas like **don't look for similar books**, the model should follow instructions.
> **The `disallowed` parameter specifies tools that must not appear in the transcript.** If an agent
> calls 'findSimilarBooks' anyway — that's a failure."*

> ✅ **VERIFIED** — the form, from `SearchBooks.swift:344-359`:
> `TrajectoryExpectation(unordered: [...], disallowed: [ToolExpectation("findSimilarBooks")])`.

```swift illustrative
ModelSample(
    prompt: "Find cheerful books, but don't look for similar books",
    expected: BookResults(books: [ … ]),
    instructions: BookAssistant.instructions,
    expectations: TrajectoryExpectation(
        unordered: [
            ToolExpectation("searchBooks", arguments: [
                .naturalLanguage(argumentName: "mood",
                                 criteria: "Should relate to uplifting, hopeful, or positive feelings.")
            ])
        ],
        // The negative half of the instruction, made measurable.
        disallowed: [ToolExpectation("findSimilarBooks")]
    )
)
```

`disallowed:` takes `[ToolExpectation]` rather than `[String]`, which means a disallowed entry can carry
argument matchers too. That opens a second, more precise class of assertion: *this tool may be called,
but never with these arguments*.

> ✅ **Probe-verified, 2026-07-31 — `arguments` on a `disallowed` entry DO narrow the prohibition.**
> (was a 🔴 GAP; `probes/` `eval.disallowed-arguments-narrowing`, run on the 27.0 sim runtime with
> canned transcripts.) A call to the disallowed tool with **different** arguments than the matchers
> **passes** (`allPass=1.0`); a call **matching** the matchers **fails** (`allPass=0.0`). The
> narrowed form means exactly what the type suggests: *this tool may be called, but never with
> these arguments*.
>
> **When to still prefer the hand-written form:** the declarative matcher is now trustworthy, but a
> separate `Evaluator` over `subject.toolCalls` remains the right tool when the prohibition is
> conditional on other calls or needs a rationale string richer than a matcher can carry:
>
> ```swift
> let noDestructiveDeletes = Metric("No Destructive Deletes")
>
> Evaluator { _, subject in
>     let violated = subject.toolCalls.contains { $0.toolName == "deleteBooks" }
>     return violated
>         ? noDestructiveDeletes.failing(rationale: "deleteBooks was called")
>         : noDestructiveDeletes.passing()
> }
> ```
>
> ✅ **VERIFIED** — `ModelSubject` exposes `var toolCalls: [Transcript.ToolCall]`
> (`/documentation/evaluations/modelsubject`), so a hand-written evaluator can inspect the trajectory
> directly whenever the declarative form does not reach.

### What to put in `disallowed`

Three categories earn it, and they are worth being systematic about because each corresponds to a real
production incident class:

- **Negative instructions in the prompt itself** — the *"but don't look for similar books"* case. If your
  feature accepts free-text user requests, some of them will contain constraints, and the model's
  compliance with those constraints is a measurable property of your feature rather than a hope.
- **Tools that cost money or mutate state.** A read-only question should never reach a write tool. This
  is where `disallowed` earns its keep even when no user instruction mentions it, and where
  `allowsAdditionalToolCalls: false` (§14.2) is worth its brittleness.
- **Tools that were removed from a mode.** If a dynamic profile withdraws a tool in some state, an
  evaluation of that state should assert the tool is genuinely gone rather than merely unmentioned. See
  [Part 3 ▸ `04-agentic-orchestration.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/references/04-agentic-orchestration.md)
  for how modes withdraw tools in the first place.

---

## 17. ⚠️ Wiring it up: `ToolCallEvaluator` and the transcript you must remember to pass

All sixteen of Book Tracker's trajectory expectations are scored by a single evaluator declared in one
line. The whole evaluation is 39 lines, and every one of them is load-bearing.

> ✅ **VERIFIED** — `SearchBooks.swift:525-563`, verbatim:

```swift illustrative
struct SearchToolEvaluations: Evaluation {
    var dataset = samples

    let pass = Metric("All Passed")
    let percent = Metric("Percentage Passed")

    var evaluators: Evaluators {
        ToolCallEvaluator(allPass: pass, percentagePass: percent)
    }

    var registeredTools: [any Tool] = [
        SearchBooksTool(books: Book.sampleBooks.map(\.snapshot)),
        GetBookDetailsTool(books: Book.sampleBooks.map(\.snapshot)),
        FindSimilarBooksTool(books: Book.sampleBooks.map(\.snapshot))
    ]

    func subject(from sample: ModelSample<BookResults>) async throws -> ModelSubject<BookResults> {
        let model = SystemLanguageModel(
            guardrails: .permissiveContentTransformations
        )
        let session = LanguageModelSession(
            model: model,
            tools: registeredTools,
            instructions: BookAssistant.instructions
        )

        let response = try await session.respond(to: sample.prompt, generating: BookResults.self)

        return ModelSubject(
            value: response.content,
            transcript: session.transcript.structuredTranscript
        )
    }
```

### 17.1 Two metrics, because "did it pass" is not one question

> ✅ **VERIFIED** — `/documentation/evaluations/toolcallevaluator`:
>
> ```swift
> struct ToolCallEvaluator<Input>
>   where Input : ModelSampleProtocol, Input.Expectation == TrajectoryExpectation
> init(allPass:percentagePass:)             // both are Metric values
> ```
>
> and the documented usage, verbatim:
>
> ```swift
> let toolsAllPass = Metric("Tools All Pass")
> let toolsPercentagePass = Metric("Tools Percentage Pass")
>
> let evaluator = ToolCallEvaluator<ModelSample<String>>(
>     allPass: toolsAllPass, percentagePass: toolsPercentagePass
> )
> ```
>
> ✅ **SDK-verified** — the declaration matches:
> `struct ToolCallEvaluator<Input> : EvaluatorProtocol where Input : ModelSampleProtocol,
> Input.Expectation == TrajectoryExpectation`, with `allPass` / `percentagePass` stored as `Metric`
> and a second initialiser taking `argumentMatchModel: any LanguageModel` — the model that scores
> `.naturalLanguage` matchers (§15.1). One quirk: the two-parameter form is
> `@available(watchOS, unavailable)`; the `argumentMatchModel:` form is not
> (`Evaluations-27.0-macos.swiftinterface:164-179`).

`allPass` is strict — the whole trajectory matched or it did not. `percentagePass` is partial credit, and
it is the one that tells you *how wrong* a failure was. A feature at 40% all-pass and 92% percentage-pass
is missing one expectation per sample and is one prompt sentence away from working. A feature at 40% and
45% is calling the wrong tools entirely. Aggregate both:

```swift prelude:guide-context
    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.group("Trajectory") { group in
            group.computeMean(of: pass)       // strict pass rate
            group.computeMean(of: percent)    // how close the failures came
            group.computeStandardDeviation(of: percent)
        }
    }
```

> ✅ **VERIFIED** — `computeMean(of:)` over a pass/fail metric yields a **pass rate**, which is why
> thresholds like `>= 0.8` are written against it (`BookTags.swift:129-142`; `MetricsAggregator` members
> from `/documentation/evaluations/metricsaggregator`).

### 17.2 The line everyone forgets

`ToolCallEvaluator` does not run your session. **You** run it, inside `subject(from:)`, and you hand the
evaluator the trajectory by attaching it to the subject.

> ✅ **VERIFIED** — the two halves of the bridge:
> `ModelSubject.init(value: Value, transcript: StructuredTranscript?)` and
> `Transcript.structuredTranscript`, which is `iOS 27.0+ / iPadOS 27.0+ / macOS 27.0+ / visionOS 27.0+ /
> watchOS 27.0+ Beta` — **no Mac Catalyst**. `StructuredTranscript` itself carries
> `toolCalls: [Transcript.ToolCall]`, `toolOutputs`, `instructionText`, `prompts` and `responses`.
>
> ✅ **SDK-verified** — `ModelSubject.init(value: Value, transcript: StructuredTranscript? = nil)`;
> the `= nil` default is exactly what makes the omission compile. The error case is real too:
> `EvaluationError.missingTranscript(evaluatorType: String)`
> (`Evaluations-27.0-macos.swiftinterface:634-646`, `:495-504`; `StructuredTranscript`'s five fields
> and memberwise init at `:276-285`).

Note that `transcript:` is **optional**. It compiles when you omit it. That is the failure.

> ⚠️ **LOUD SETUP FAILURE — a tool evaluation with no transcript.** Write
> `ModelSubject(value: response.content)` instead of `ModelSubject(value:transcript:)` and the source
> still builds, but `ToolCallEvaluator` cannot score the subject: it throws
> `EvaluationError.missingTranscript(evaluatorType:)` when `transcript` is `nil`.[^missing-transcript]
> No empty trajectory or metric report is produced.
>
> ✅ **VERIFIED** — the requirement, stated plainly in our sample-code analysis of Book Tracker: the
> transcript *"is passed as `session.transcript.structuredTranscript`… Without it, `ToolCallEvaluator`
> has nothing to inspect."* Apple's `ModelSubject.transcript` documentation specifies the typed error
> used for that rejection.[^missing-transcript]
>
> **Safe default: construct the subject at one reviewed boundary and always pass the transcript:**
>
> ```swift
> return ModelSubject(
>     value: response.content,
>     transcript: session.transcript.structuredTranscript
> )
> ```
>
> Add a negative harness that deliberately omits `transcript:` and expects
> `EvaluationError.missingTranscript`; that distinguishes framework setup failures from genuine
> trajectory-score regressions.[^missing-transcript]

### 17.3 Construct the model the way your feature does

The two-line `SystemLanguageModel(guardrails: .permissiveContentTransformations)` in `subject(from:)` is
not incidental.

> ✅ **VERIFIED** — the same initializer with the same argument appears in **both** the shipping feature
> (`BookTracker/Services/BookTaggingService.swift:40`) and the evaluation
> (`SearchBooks.swift:525-563`). If they differed, the evaluation would be measuring a different system
> from the one your users run.

This generalises past guardrails. Instructions, `GenerationOptions`, the model itself, the tool set,
whether the response is guided by a `@Generable` type — every one of those changes behaviour, and every
one of them has to match. The cleanest way to guarantee it is to not have two call sites at all: have
`subject(from:)` call the *same function your app calls*, as `BookTaggingEvaluation` does
(`BookTags.swift:17-30`, a one-line body that calls `BookTaggingService.generateTags(for:)`). Where the
tool evaluation has to build its own session — because it needs the transcript back — keep the
construction in one factory shared by both.

```swift illustrative
enum BookAssistant {
    static let instructions = "…"

    // One construction site, used by the app AND by the evaluation.
    static func makeSession(tools: [any Tool]) -> LanguageModelSession {
        LanguageModelSession(
            model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
            tools: tools,
            instructions: instructions
        )
    }
}
```

### 17.4 What tool evaluation buys, with a number

> ✅ **VERIFIED, Apple-published** — from the figure captions in Apple's
> `evaluating-language-model-responses` article: the letter-counting evaluation scores **Exact Match 58%**
> without the tool and **100%** with it, across **12 responses**.
>
> ⚠️ Attribute that carefully. It is Apple's own demonstration on a deliberately model-hostile task
> (counting letters in a word), on a **12-sample** dataset, with no hardware, OS build or date stated. It
> demonstrates that the framework measures the lift; it is not a benchmark, and 58% → 100% is not a
> number to expect on your feature.

`registeredTools` is worth one closing note: it is a **plain stored property on the evaluation**, named by
the sample's author, not a protocol requirement. There is no framework-blessed place to put your tools.
The pattern — build the session yourself inside `subject(from:)`, from a property you can vary between
two instances of the evaluation — is exactly what makes the with-tool/without-tool comparison in §10.1
possible.

---

## 18. Synthesising tool-evaluation datasets

Sixteen hand-written trajectory expectations is a lot of typing, and sixteen is not many. The framework's
answer is the same one as §2 — generate them — and it works for a reason that is worth stating precisely.

> ✅ **VERIFIED** — `299:181-182`: *"**Trajectory expectations are generable too.** Expanding a dataset
> for your tool evaluations can be quite complex, and with the Evaluations framework we've made it a lot
> easier to do just that! **Since our Tool Call evaluation leverages `ModelSample` and
> `TrajectoryExpectation` that are generable, we can synthetically generate more samples using Sample
> generator like before.**"*
>
> ✅ **VERIFIED** — corroborated at the type level: **`ToolExpectation` conforms to `Generable`**, and
> **`ArgumentMatcher` conforms to `Generable, Codable, Sendable`**
> (`/documentation/evaluations/toolexpectation`, `…/argumentmatcher`). Apple's own note on why:
> *"`ToolExpectation` and `ArgumentMatcher` both conform to `Generable` — which is how `.naturalLanguage`
> matching is fed to a judge model."* ✅ **SDK-verified** — and `TrajectoryExpectation` itself is
> `Generable` too (`Evaluations-27.0-macos.swiftinterface:271-275`), so a whole trajectory is a
> generable value, not just its parts.

So a language model can emit a whole sample — user prompt, expected result, *and* the trajectory of tool
calls that prompt ought to produce. Which leads directly to the one thing that makes this fail.

### 18.1 ⚠️ The generating model has never heard of your tools

> ✅ **VERIFIED** — `299:184-185`: *"**Keep in mind when creating synthetic data for tool evaluations,
> the model doesn't know what tools you've defined or what order the tools need to be called in. So here
> I've specified the available tools explaining their purpose, any order expectations, and other context
> the model might need.**"*

This is obvious once said and invisible until then. The session generating your data is **not** the
session that has your tools registered — it has no `tools:` array, no `ToolDefinition` entries in its
transcript, and no way to discover any of it. Ask it for trajectories and it will invent tool names that
sound like yours: `search_books`, `bookSearch`, `findBooks`, `lookupBook`. Every one of those samples is
garbage, and every one of them *looks* like a valid sample right up until the evaluator compares it
against a transcript containing `searchBooks`.

The generation instructions therefore have to carry a written specification of your tool surface. Not a
summary — the names exactly as spelled, the arguments, and the dependencies between them.

```swift compile:27
let toolSpec = """
    The app exposes exactly three tools. Use these names verbatim; do not invent others.

    1. searchBooks(tag:mood:genre:query:limit:)
       Searches the user's personal library. All arguments are optional; choose the
       ones the request implies. Returns matching books with their IDs.
    2. getBookDetails(bookId:)
       Returns metadata for one book. REQUIRES a bookId, which only searchBooks can
       produce, so getBookDetails must always be preceded by searchBooks.
    3. findSimilarBooks(bookId:)
       Semantic similarity search. Also requires a bookId from searchBooks.

    Ordering rules:
      - Any call to getBookDetails or findSimilarBooks must come after a searchBooks call.
      - A request that only names a genre, tag or mood needs searchBooks alone.

    For each sample produce: a realistic user request in one sentence, and the
    trajectory of tool calls that request should produce.
    """
```

Two additional prompts pay off here. Ask for **negative instructions** explicitly — *"about one sample in
six should ask the assistant not to do something, such as 'find gothic books but don't look for similar
ones'"* — because a model asked only for requests will produce only positive ones, and §16 will have
nothing to score. And ask for **under-specified requests**, because those are where trajectory bugs
actually live.

### 18.2 The three validators

> ✅ **VERIFIED** — `299:187-188`: *"We can also specify validation metrics here as well! Here I've made
> sure **there's always an expectation** and I've also made sure the **synthetic samples include at least
> one tool**. And lastly **any tools called are actual tools we've already defined**."*

Those three, in order: an expectation exists; it contains at least one tool call; every tool it names is
one you registered. The third is the one that catches §18.1's invented names, and it is not optional.

> ✅ **SDK-verified — GAP closed (2026-07-29): the lists are public vars.** `TrajectoryExpectation`
> exposes `var ordered: [ToolExpectation]`, `var unordered: [ToolExpectation]`,
> `var disallowed: [ToolExpectation]` and `var allowsAdditionalCalls: Bool` — all public, all
> mutable (`Evaluations-27.0-macos.swiftinterface:253-257`) — so a generated expectation *can* be
> validated directly: walk `ordered + unordered + disallowed`, read each `ToolExpectation.name`, and
> check it against your registered set. The reconstruction circulating from session narration,
> `expectation.toolCalls`, is still wrong — no such member is in the Xcode 27 beta interface
> (`ModelSubject.toolCalls` is real; that is a different type). Note the property spelling:
> **`allowsAdditionalCalls`**, without "Tool", versus the init label `allowsAdditionalToolCalls`.
>
> **The pattern below still earns its keep.** Generating into a `@Generable` type you own remains
> the better workflow even now that direct inspection is possible: it is where you enforce ordering
> rules *at generation time* (rule 4 below), and it keeps the generating model filling in a
> deliberately small schema instead of `TrajectoryExpectation`'s full generality.

```swift compile:27
import Evaluations
import FoundationModels

/// A trajectory in a shape we control and can inspect.
@Generable
struct PlannedTrajectory: Codable, Sendable {
    @Guide(description: "Tool names in the order they must be called, using the exact names given",
           .count(1...4))
    var orderedToolNames: [String]

    @Guide(description: "Tool names that must NOT appear, if the request forbids something")
    var disallowedToolNames: [String]
}

@Generable
struct PlannedSample: Codable, Sendable {
    @Guide(description: "A realistic one-sentence request a reader might type")
    var request: String
    var trajectory: PlannedTrajectory
}

let knownTools: Set<String> = ["searchBooks", "getBookDetails", "findSimilarBooks"]

let plannedValidator: @Sendable (ModelSample<PlannedSample>) -> Bool = { sample in
    // 1. There is an expectation at all.
    guard let plan = sample.expected else { return false }
    // 2. It includes at least one tool.
    guard !plan.trajectory.orderedToolNames.isEmpty else { return false }
    // 3. Every tool named is one we actually registered — both lists.
    let named = Set(plan.trajectory.orderedToolNames + plan.trajectory.disallowedToolNames)
    guard named.isSubset(of: knownTools) else { return false }
    // 4. Your own domain rule: bookId-consuming tools need a prior search.
    if let firstDependent = plan.trajectory.orderedToolNames.firstIndex(where: {
        $0 == "getBookDetails" || $0 == "findSimilarBooks"
    }) {
        guard plan.trajectory.orderedToolNames[..<firstDependent].contains("searchBooks") else {
            return false
        }
    }
    return true
}
```

Rule 4 is a bonus the indirection buys you: an ordering constraint checked *at generation time*, so an
impossible trajectory never enters the dataset in the first place. A generated sample that expects
`getBookDetails` before `searchBooks` would otherwise become a test that can never pass and that you would
eventually "fix" by loosening the expectation — teaching yourself the wrong lesson.

### 18.3 Converting plans into samples

The final step is mechanical, it is where you decide ordered-versus-unordered, and it is the only place
`TrajectoryExpectation` needs to be constructed.

```swift prelude:guide-context
func makeToolSample(from plan: PlannedSample) -> ModelSample<BookResults> {
    let ordered = plan.trajectory.orderedToolNames.map { ToolExpectation($0) }
    let disallowed = plan.trajectory.disallowedToolNames.map { ToolExpectation($0) }

    let expectation: TrajectoryExpectation
    if ordered.count == 1 && disallowed.isEmpty {
        // One call: order is meaningless, so don't assert it. (§13.2)
        expectation = TrajectoryExpectation(unordered: ordered)
    } else if disallowed.isEmpty {
        // A real sequence: assert it, but tolerate extra calls. (§14.2)
        expectation = TrajectoryExpectation(ordered: ordered, allowsAdditionalToolCalls: true)
    } else {
        expectation = TrajectoryExpectation(unordered: ordered, disallowed: disallowed)
    }

    return ModelSample(
        prompt: plan.request,
        expected: BookResults(books: []),      // filled in by the run; not asserted here
        instructions: BookAssistant.instructions,
        expectations: expectation
    )
}
```

> ⚠️ Only the call shapes attested in Apple's sample appear in that function, deliberately. The
> combined `(ordered:unordered:disallowed:)` form is an SDK-verified initialiser (§13.1) and would
> let you collapse the branches — but it is not exercised in any compiling sample we have read, and
> this is generated data you will not read line by line. Prefer the shapes with a shipping
> precedent.

Run it through the same generator as everything else:

```swift prelude:guide-context
let planGenerator = SampleGenerator<ModelSample<PlannedSample>>(
    Prompt("""
        Generate diverse requests a reader might make of a personal-library assistant,
        together with the tool trajectory each request should produce.
        Vary between single-step lookups, multi-step requests that need book details,
        and requests that forbid an action.
        """),
    samples: plannedSeeds,
    targetCount: plannedSeeds.count + 60,
    sessionProvider: {
        LanguageModelSession(
            model: PrivateCloudComputeLanguageModel(),
            instructions: toolSpec          // §18.1 — self-contained, per §5
        )
    },
    validator: plannedValidator             // §18.2
)

var plans = plannedSeeds
for try await sample in planGenerator.run() { plans.append(sample) }
let toolSamples = plans.compactMap(\.expected).map(makeToolSample)
print("generated \(toolSamples.count) tool samples, rejected \(await planGenerator.invalidSamples.count)")
```

And then read the rejects (§9.1). On a first run against a tool spec, the rejection rate is your measure
of how clearly you described your own tools — which is the same skill as writing tool `description`s the
model will honour, and fails for the same reasons.

> ✅ **VERIFIED** — the closing claim, `299:189`: *"**The synthetic data APIs are a powerful way to expand
> your existing dataset beyond your capabilities! And the more representative your data, the more your
> scores reflect reality.**"*

---

## 19. One suite, two kinds of confidence

The two halves of this guide are not alternatives. Session 299 ends by putting them together, and it is
the right closing thought.

> ✅ **VERIFIED** — `299:190-195`: *"Earlier we built book tagging evaluation, **it checks what the model
> produces**. Tag count, genre coverage, quality scores. Now we have tool evaluations — **they check how
> the model gets there**. The right tools, right arguments and right order. **Run both in the same
> evaluation suite and you'll have built end-to-end confidence in your feature.**"*

They also mix at the level of a single evaluation, because `ToolCallEvaluator` is just another
`EvaluatorProtocol` conformer. Apple's documented letter-counting evaluation does exactly this:

> ✅ **VERIFIED** — verbatim from `evaluating-language-model-responses`:
>
> ```swift
> var evaluators: Evaluators {
>     // Score tool calls against the trajectory expectations defined on each sample.
>     ToolCallEvaluator(allPass: toolsAllPass, percentagePass: toolsPercentagePass)
>     // Also check whether the final output matches the expected answer.
>     Evaluator { input, subject in
>         guard let expected = input.expected else { return exactMatch.ignore() }
>         return subject.value == expected ? exactMatch.passing() : exactMatch.failing()
>     }
> }
> ```

That is the whole architectural claim of the framework, and session 298 states it for model judges in
words that apply identically here:

> ✅ **VERIFIED** — `298:222-224`: *"In the Evaluations framework, a model judge is just another
> `Evaluator`. It conforms to the same protocol as the quantitative evaluators and produces the same
> `Metric` type. **So you can mix them freely within a single evaluation.**"*

Heuristics, model judges and trajectory checks are three kinds of evidence about one feature, they
produce one kind of `Metric`, and they land in one report. The four-way combination is what "end-to-end
confidence" actually means in practice:

| Evaluator | Answers | Costs |
|---|---|---|
| heuristic `Evaluator` | *is the output structurally correct?* | nothing; deterministic |
| `ModelJudgeEvaluator` | *is the output any good?* | one judge call per sample |
| `ToolCallEvaluator` | *did it get there the right way?* | one feature run per sample, plus a judge call per `.naturalLanguage` matcher |
| your own `EvaluatorProtocol` | anything the above three cannot express | whatever you write |

The suite that ships is the one where all four run on a dataset that is honest about how your feature
will be used — which is where this guide started, and why the score drop in §10 was good news.

---

## 20. Quick reference

### 20.1 API surface, with version floor and evidence class

Everything in the `Evaluations` framework is **iOS 27.0 · iPadOS 27.0 · Mac Catalyst 27.0 · macOS 27.0 ·
visionOS 27.0 · watchOS 27.0**, tagged **Beta**, **no tvOS**, **Xcode 27**. The column below records
where each spelling comes from, because that is what tells you how much to trust it.

| Symbol / spelling | Evidence |
|---|---|
| `actor SampleGenerator<SampleType> where SampleType : ModelSampleProtocol` | ✅ docs |
| `SampleGenerator(_:samples:targetCount:sessionProvider:samplingStrategy:validator:)` — two overloads, differing by generic constraint (`ModelSample<T>` vs a custom `Generable` sample type), both `Prompt`-first | ✅ SDK-verified (`swiftinterface:870-871`) |
| `SampleGenerator<ModelSample<T>>(_ prompt: Prompt, samples:targetCount:sessionProvider:validator:)` | ✅ Apple sample code (`BookSampleGenerator/main.swift:13-74`) |
| `sessionProvider: (@Sendable () -> LanguageModelSession)? = nil` (a factory; may be invoked more than once) | ✅ SDK-verified (`swiftinterface:870-871`) + sample code + session 299 |
| `validator: ((S) async throws -> Bool)? = nil` — may await and throw; the sample's is sync | ✅ SDK-verified (`swiftinterface:861-862, :870-871`) + sample code |
| `generator.run()` — async sequence of **valid** samples only | ✅ sample code |
| `await generator.samples` — initial **and** generated | ✅ docs + sample code |
| `await generator.invalidSamples` — validator rejects | ✅ docs + sample code |
| `enum SampleGenerator.SamplingStrategy` — `.random(retries: Int = 5)` (default `.random()`) · `.slidingWindow` | ✅ SDK-verified (`swiftinterface:853-856`) |
| `[ModelSample].makeSamples(_:targetCount:sessionProvider:validator:)` → `some AsyncSequence` — no `samplingStrategy` parameter | ✅ SDK-verified (`swiftinterface:862-873`) · no sample calls it |
| `targetCount` = size of the **final** dataset, seeds included | ✅ session 299 (`299:36`) |
| `ModelSample(prompt:expected:instructions:expectations:)` | ✅ sample code (`SearchBooks.swift:46-74`) |
| `ModelSample.promptDescription` / `.prompt` / `.expected` / `.expectations` | ✅ docs + sample code |
| `ModelSample: Codable` | ✅ sample code |
| `ArrayLoader(samples:)` · `JSONLoader(url:)` · `dataset` is a **stored** property | ✅ sample code |
| `JSONLoader` accepts JSON array **or** JSONL; malformed rows skipped via `OSLog` | ✅ docs |
| `func subject(from:) async throws -> ModelSubject<T>` | ✅ sample code |
| `ModelSubject(value:)` / `ModelSubject(value:transcript:)` / `.toolCalls` | ✅ docs + sample code |
| `Transcript.structuredTranscript` → `StructuredTranscript` | ✅ docs · **omits Mac Catalyst** |
| `StructuredTranscript(toolCalls:toolOutputs:instructionText:prompts:responses:)` | ✅ docs |
| `ToolCallEvaluator<Input>(allPass:percentagePass:)` where `Input.Expectation == TrajectoryExpectation` | ✅ docs + sample code · watchOS-unavailable per SDK |
| `ToolCallEvaluator(allPass:percentagePass:argumentMatchModel:)` — names the model that scores `.naturalLanguage` matchers | ✅ SDK-verified (`swiftinterface:163-166`) — in no doc or sample |
| `TrajectoryExpectation(unordered:)` | ✅ sample code (`SearchBooks.swift:66`) |
| `TrajectoryExpectation(ordered:allowsAdditionalToolCalls:)` | ✅ sample code (`:140-154`) |
| `TrajectoryExpectation(unordered:disallowed:)` | ✅ sample code (`:344-359`) |
| `TrajectoryExpectation(expected:arguments:)` | ✅ sample code (`:413-418`) + docs |
| the full initialiser set — `(ordered:unordered:allowsAdditionalToolCalls:)` / `(ordered:unordered:disallowed:)` / `(unordered:)` / `(expected:arguments:)`, with `ordered:` / `unordered:` defaulting to `[]` | ✅ SDK-verified (`swiftinterface:252-255`) |
| `allowsAdditionalToolCalls` default | ✅ SDK-verified `= true` (`swiftinterface:252`); property is `allowsAdditionalCalls` · `false` ✅ probe-verified 2026-07-31: enforced, extra call fails `allPass` (§14.2) |
| `TrajectoryExpectation.ordered` / `.unordered` / `.disallowed` / `.allowsAdditionalCalls` — public vars | ✅ SDK-verified (`swiftinterface:248-251`) |
| `ToolExpectation(_ name:)` / `(_ name:, arguments:)` · `.name` · `.arguments` · `.isAnyOrderGroup` | ✅ docs + sample code |
| `ToolExpectation.anyOrder(_:)` | ✅ docs |
| `ToolExpectation: Generable` · `ArgumentMatcher: Generable, Codable, Sendable` | ✅ docs |
| `.exact` `.keyOnly` `.oneOf` `.range` `.contains` `.hasSuffix` `.naturalLanguage` | ✅ docs **and** sample code |
| `.pattern(argumentName:regex:)` · `.hasPrefix(argumentName:prefix:)` | ✅ docs + SDK-verified spellings (`swiftinterface:181,183`) — no sample exercises them |
| `.exact(… value:)` — wrapped `.string("x")` and bare `"x"` both compile (`ArgumentValue` is literal-expressible) | ✅ SDK-verified (`swiftinterface:15-81`) · **house style: wrapped** |
| `enum ArgumentValue` — `.string` `.int` `.double` `.bool` (the matcher's value type); `StructuredValue` adds `.null` `.array` `.dictionary` and is reached via `ArgumentValue.structuredValue` | ✅ SDK-verified (`swiftinterface:15-100`) · only `.string` observed in practice |
| `Metric(_:)` · `.passing(rationale:)` · `.failing(rationale:)` · `.scoring(_:rationale:)` · `.ignore(rationale:)` | ✅ docs + sample code |
| `Evaluator { input, subject in … }` — two arguments — collected in `var evaluators: Evaluators` | ✅ sample code |
| `aggregateMetrics(using aggregator: inout MetricsAggregator)` · `.group(_:)` · `computeMean/StandardDeviation/Variance(of:)` · `custom(of:label:_:)` | ✅ sample code |
| `.evaluates(_:)` / `.evaluates(_:info:)` · `EvaluationContext.current.result` · `result.aggregateValue(.mean(of:))` / `.custom(label:))` | ✅ sample code |
| Cohen's kappa or any agreement statistic | ❌ **not shipped** — hand-rolled in Apple's sample |
| `PrivateCloudComputeLanguageModel()` · `.quotaUsage.isLimitReached` · `.status` · `.resetDate` · `.limitIncreaseSuggestion?.show()` | ✅ docs + shipping code · **managed entitlement required** |
| whether an evaluation run consumes the developer's PCC quota | 🔴 GAP — unanswered by Apple |

### 20.2 The checklist

Before you trust a synthetic dataset:

- [ ] `targetCount` is written as `seeds.count + n`, never as a literal. (§3)
- [ ] Every rule the samples must obey lives in `sessionProvider`'s `instructions`, not in the prompt and
      not in conversational context. The factory can be called again mid-run. (§5)
- [ ] `sessionProvider` closes over nothing mutable and assumes nothing about invocation count. (§5)
- [ ] You logged how many times `sessionProvider` was invoked. (§5)
- [ ] `samplingStrategy` is omitted unless your dataset is genuinely ordered. (§7)
- [ ] Every validator rule is a predicate over **one** sample. No comparatives, no plurals. (§8)
- [ ] `invalidSamples.count` is **not zero** — a validator that rejects nothing is vacuous. (§8.1)
- [ ] If your dataset is prompt-only, the validator does **not** guard on `sample.expected`. (§8.2)
- [ ] The corpus audit ran: duplicates, length spread, tag concentration. (§8.3)
- [ ] The generated dataset is **committed** and generation is a CLI target, not a test. (§6.3)
- [ ] The evaluation over the generated dataset is otherwise **identical** to the curated one. (§9.3)
- [ ] An assertion pins the loaded sample count, because `JSONLoader` skips bad rows silently. (§9.3)
- [ ] You checked PCC availability *and* `quotaUsage.isLimitReached` before a long run. (§6.2)

Before you trust a tool evaluation:

- [ ] `subject(from:)` returns `ModelSubject(value:transcript: session.transcript.structuredTranscript)`.
      (§17.2)
- [ ] The harness treats a thrown `EvaluationError.missingTranscript(evaluatorType:)` as a setup
      failure to fix, not as a sample to skip. (§17.2)
- [ ] The session in `subject(from:)` is built the same way the feature builds it — same model, same
      guardrails, same instructions, same tools. (§17.3)
- [ ] Both `allPass` **and** `percentagePass` are aggregated, not just the strict one. (§17.1)
- [ ] `allowsAdditionalToolCalls` is written explicitly wherever `ordered:` is used — the default is
      `true` (SDK-verified), and an explicit value documents intent. (§14.2)
- [ ] Free-text arguments use `.naturalLanguage` or `.contains`, not `.exact`. (§15)
- [ ] Enumerable arguments use `.oneOf` rather than `.naturalLanguage` — deterministic and free. (§15.1)
- [ ] Argument values are written wrapped: `.string("gothic")`. (§15.2)
- [ ] At least one sample carries a `disallowed:` entry, so negative instruction following is measured.
      (§16)
- [ ] Generated tool samples were validated for: an expectation exists, ≥1 tool, and **only tool names you
      registered**. (§18.2)
- [ ] The generation instructions spell your tool names verbatim and state the ordering dependencies.
      (§18.1)

### 20.3 Symptom → cause

| Symptom | Likely cause | Section |
|---|---|---|
| The generator produced far fewer samples than you asked for | `targetCount` includes your seeds | §3 |
| The generator produced *nothing* and the stream ended immediately | `targetCount` ≤ `samples.count` | §3 |
| The generator produced nothing and `invalidSamples` is full | validator guards on `sample.expected` in a prompt-only dataset | §8.2 |
| The second half of the dataset repeats books from the first half | context exhausted; `sessionProvider` re-invoked with no memory | §5 |
| Review style drifts partway through the run | same | §5 |
| `invalidSamples` is empty | vacuous validator — probably a corpus rule written per-sample | §8.1 |
| Every generated review is the same length | "vary in length" is not validator-checkable and was ignored | §8.1, §8.3 |
| One tag appears on a fifth of the corpus | seed set was thematically narrow; generator amplified it | §8.3 |
| Scores dropped when the dataset grew | expected. Four hypotheses — read the bottom twenty rows first | §10.1 |
| Evaluation is green and the output is visibly bad | the dataset, the metric, or the judge is wrong; not the feature | §10 |
| Sample count silently fell after you changed the output type | `JSONLoader` skipped rows it could not decode | §9.3 |
| Evaluation run throws `EvaluationError.missingTranscript` | `ModelSubject` built without `transcript:` | §17.2 |
| Tool evaluation passes but the shipping feature misbehaves | the evaluation built the session differently (guardrails, instructions, options) | §17.3 |
| A correct trajectory fails on ordering | two independent calls were listed `ordered:`; use `unordered:` or `.anyOrder` | §13.4, §14.1 |
| Trajectory fails intermittently on a free-text argument | `.exact` on a value the model paraphrases | §15 |
| Trajectory results differ between two runs of the same transcript | `.naturalLanguage` is a model call, not a string compare | §15.1 |
| Generated tool samples never match any transcript | the generator invented tool names; validate against your registered set | §18.1 |
| Evaluation run failed midway with a quota error | PCC daily quota, which is orthogonal to availability | §6.2 |

---

## 21. Sources

**Apple sample-code project, read on disk — the highest-precedence evidence here, because it compiles
and ships.** **Book Tracker — *Using Evaluations to evaluate an intelligent feature*** (archive
`BookTrackerUsingEvaluationsToEvaluateAnIntelligentFeature/`, `MACOSX_DEPLOYMENT_TARGET = 27.0`, five
targets: one app, two unit-test bundles, two command-line tools). Files cited by name and line:
`BookSampleGenerator/main.swift` (the `SampleGenerator` CLI), `BookTrackerEvaluations/SearchBooks.swift`
(the `ToolCallEvaluator` evaluation and all sixteen `TrajectoryExpectation`s),
`BookTrackerEvaluations/BookTags.swift`, `BookTrackerEvaluations/SyntheticBookTags.swift`,
`BookTracker/Services/BookTaggingService.swift`, `BookTracker/Services/BookSearchTools.swift`,
`HillClimbingEvaluations/ModelJudgeAlignmentEvaluation.swift` and `Statistics.swift`,
`DatasetExtractor/main.swift`.
⚠️ **Two other Apple samples exist and are deliberately not cited anywhere in this guide:** the
coffee/generative-game sample and the SpeechAnalyzer sample are **iOS 26 / WWDC25 leftovers that were
never refreshed**, and nothing in them is evidence about 2026 behaviour.

**The framework's shipped Swift interface** —
`notes/sdk-interfaces/Evaluations-27.0-macos.swiftinterface` (885 lines), dumped from the Xcode 27
beta's macOS `Evaluations.framework` on **2026-07-29**. For names, signatures, defaults, availability
and case lists it outranks every source below, the sample included; for usage and runtime behaviour it
decides nothing. Cited as ✅ **SDK-verified** with line numbers. It closed this guide's GAPs on the
`SampleGenerator` overloads, `SamplingStrategy`'s cases, `TrajectoryExpectation`'s initialiser set
and public accessors, `allowsAdditionalToolCalls`'s default, and the bare-vs-wrapped argument value —
and corrected the `validator` signature to `async throws`.

**Apple documentation** (harvested 2026-07-27): `/documentation/evaluations` (framework index, 44 KB —
this is where the platform list and the Beta tags come from) · `/documentation/evaluations/samplegenerator` ·
`…/modelsample` · `…/modelsubject` · `…/arrayloader` · `…/jsonloader` · `…/metric` · `…/metricsaggregator` ·
`…/evaluationresult` · `…/evaluationtrait` · `…/toolcallevaluator` · `…/trajectoryexpectation` ·
`…/toolexpectation` · `…/argumentmatcher` · `…/scoredimension` · `…/scoringscale` · `…/modeljudgeevaluator` ·
`…/modeljudgeprompt`; the articles `generating-synthetic-evaluation-datasets`,
`evaluating-language-model-responses`, `evaluating-tool-calling-behavior`, `designing-effective-evaluations`,
`designing-effective-model-judges`, `designing-evaluation-criteria`, `designing-evaluation-datasets`
(**topic list only — see the GAP in §11.3**) · `/documentation/foundationmodels/transcript` and
`…/structuredtranscript` · Apple's *Using Private Cloud Compute* article.

**WWDC26 sessions** (spoken-word transcripts; no on-screen code was dictated, which is why narrated code
is 🟡 unless a sample or doc page corroborates it): **299** *Create robust evaluations for agentic apps*
— the source for `targetCount`, the `sessionProvider` lifecycle, the sampling strategies, the validator's
isolation, the 13→100 score drop and its four hypotheses, and the whole trajectory-expectation
walkthrough · **298** *Meet the Evaluations framework* — dataset variety, the 20–30 starting size, the
degenerate-distribution lesson, and "a model judge is just another `Evaluator`" · **335** *Improve your
prompts by hill climbing with Evaluations* — the green-test-proves-nothing framing, one-variable-at-a-time
discipline, and the tool-as-hill-climb move · **319** — the on-device/PCC comparison table, the daily
per-user quota, and the "< 2M downloads" eligibility statement.

**Corroborating shipping code, community-attributed:** entitlement plists and PCC availability/quota
handling in a third-party app (`frozen Noema 3.5 snapshot`), used only to confirm that the documented quota
API is what real code calls. Nothing from that source is presented as an Apple claim.

**Precedence used throughout, and where it changed an answer.** For *signatures*, the shipped
`.swiftinterface` first, then Apple sample projects; for *usage and behaviour*, Apple sample projects
first. Below both: Apple documentation > Apple-staff forum answers > WWDC transcripts > community
code. Three places where it mattered before the interface arrived:

1. The sessions describe a `ToolCallEvaluator` that *"combines a `LanguageModelSession` with the tools,
   gets a response, and captures the structured transcript"* (`299:179`), which reads as though the
   evaluator drives the session. **The sample shows the opposite**: you build the session in
   `subject(from:)` and hand the evaluator a `ModelSubject` you constructed. The sample wins, and §17 is
   written accordingly.
2. Session 299 gives five argument matchers ("`contains`, `oneOf`, `pattern`, `range`, and more"); the
   sample exercises seven; **the documentation lists nine**. The union is nine, and §15 says which two
   have never been seen in compiling code.
3. Session 299 describes `makeSamples` as taking "a prompt, a dataset, and a target count". **The
   documentation shows it is a method on `Array`**, so the dataset is the receiver. Both statements are
   true; only one of them tells you how to write the call.

**Open questions carried forward from this guide** (updated 2026-07-29), in rough order of how much
they would improve it: the PCC-quota question in §6.2 (unanswered by Apple, and it affects whether
large evaluations are viable at all); the exact semantics of `allowsAdditionalToolCalls: false` in
§14.2 (the default is now SDK-verified as `true`); what happens when a generation target is
unreachable (§3) and whether a mid-run session swap is observable (§5); whether a `disallowed`
entry's argument matchers narrow the prohibition (§16); and the body of
`designing-evaluation-datasets` in §11.3, which is a single public page nobody has read. **Closed by
the interface pass:** the `SamplingStrategy` case spellings (§7), the `SampleGenerator` overloads
(§4), `TrajectoryExpectation`'s initialiser set and public accessors (§13.1, §18.2),
`allowsAdditionalToolCalls`'s default (§14.2), and the bare-vs-wrapped argument value (§15.2).

[^missing-transcript]: Apple, [`ModelSubject.transcript`](https://developer.apple.com/documentation/evaluations/modelsubject/transcript): when a tool-call evaluator receives `nil`, it throws `EvaluationError.missingTranscript(evaluatorType:)` rather than scoring an empty trajectory.
