# Guided generation and snapshot streaming: `@Generable`, `@Guide`, dynamic schemas, `PartiallyGenerated`

**What this covers.** The Foundation Models framework's structured-output system, end to end: what
the `@Generable` macro actually synthesises, every `@Guide` form we have evidence for, building
schemas at runtime with `DynamicGenerationSchema`, reading results out of `GeneratedContent`, and
how `streamResponse` differs from `respond`. It also covers three things Apple has documented
nowhere: **how guided generation is enforced under the hood** (grammar-constrained decoding via
`xgrammar`); the architectural consequence — a bring-your-own-model app can *lose* guided
generation precisely when it selects the fastest backend; and **guided generation over images**, the
`Attachment(_:).label(_:)` → `ImageReference` → `.attachmentLabel` round trip that lets a structured
result name which of your input photos it is talking about.

**Version floor.** The guided-generation core — `Generable`, `GenerationSchema`,
`DynamicGenerationSchema`, `GeneratedContent`, `GenerationGuide`, `GenerationID`,
`LanguageModelSession.Response`, `LanguageModelSession.ResponseStream` — is **iOS 26.0 / iPadOS 26.0 /
Mac Catalyst 26.0 / macOS 26.0 / visionOS 26.0**, and **watchOS 27.0** (it gained watchOS in the 2026
release). ✅ **VERIFIED** from the availability strings on the Apple documentation pages
(`/documentation/foundationmodels/*`, harvested 2026-07-27). Things you will meet in this guide that
are **iOS 27.0 / macOS 27.0 only**: `LanguageModelError` (including
`.unsupportedGenerationGuide(_:)`), `ContextOptions`, the `metadata:` overload family of
`respond`/`streamResponse`, `Response.usage` / `Snapshot.usage`, `GenerationSchema.name`,
`ImageReference` (and with it the whole of §2.7), and
`LanguageModelCapabilities.guidedGeneration`. `SystemLanguageModel.tokenCount(for:)` and
`contextSize` are **iOS 26.4**. There is **no** guided-generation API that requires iOS 27 to do the
basic job — a `@Generable` struct written against the iOS 26 SDK still compiles and runs.

**What you need.** Xcode 26 minimum for `@Generable`; **Xcode 27** if you want the new error types to
be catchable (see the migration note in §11). A physical device or a macOS 27 host — the Simulator
punches out to the host OS for inference, which is the single largest source of phantom bug reports
in this stack. Read
[`01-sessions-and-prompting.md`](01-sessions-and-prompting.md) first if you have never created a
`LanguageModelSession`.

---

## Contents

1. [The claim, precisely stated](#1-the-claim-precisely-stated)
2. [`@Generable`: what the macro synthesises](#2-generable-what-the-macro-synthesises)
3. [`@Guide`: the complete catalogue](#3-guide-the-complete-catalogue)
4. [⚠️ `.anyOf` does not constrain generation](#4-️-anyof-does-not-constrain-generation)
5. [How guided generation is actually enforced: constrained decoding](#5-how-guided-generation-is-actually-enforced-constrained-decoding)
6. [⚠️ The logits problem: when your fastest backend loses guided generation](#6-️-the-logits-problem-when-your-fastest-backend-loses-guided-generation)
7. [`GenerationSchema` and `DynamicGenerationSchema`](#7-generationschema-and-dynamicgenerationschema)
8. [`GeneratedContent`: the untyped door](#8-generatedcontent-the-untyped-door)
9. [Snapshot streaming](#9-snapshot-streaming)
10. [Token economics: `includeSchemaInPrompt`](#10-token-economics-includeschemainprompt)
11. [Failure taxonomy for structured output](#11-failure-taxonomy-for-structured-output)
12. [The Python SDK's parallel surface](#12-the-python-sdks-parallel-surface)
13. [Checklists and decision tables](#13-checklists-and-decision-tables)
14. [Open gaps](#14-open-gaps)

---

## 1. The claim, precisely stated

Apple's own framing of guided generation, from the 2025 code-along, is worth quoting exactly because
the wording is load-bearing:

> "the key benefit of guided generation is that it **fundamentally guarantees structural
> correctness**. It uses a technique called **constraint[ed] decoding** to do that. What it does is
> **give you control over what the model should generate, whether that be strings or numbers or
> arrays or even a custom data structure that you define**."
>
> — ✅ **VERIFIED** (WWDC-adjacent transcript): *Foundation Models Framework Code-Along*
> (Meet with Apple 205), lines 489–493.

And the composability claim:

> "**The key thing to note here is that when you apply `@Generable`, it is completely composable. The
> framework understands how to build this entire complex object from the top down, all while
> guaranteeing structural correctness.**" — same source, lines 441–442.

Read those two quotes carefully. The guarantee is **structural**, not **semantic**. The framework
promises you will get *a well-formed `Itinerary`* — five properties, correct types, `days` an array
of `DayPlan`, `ActivityKind` one of the four declared cases. It does **not** promise the values are
correct, sensible, or inside every constraint you asked for. Section 4 documents a case where Apple
staff reproduced the model ignoring a constraint entirely.

The practical corollaries you should internalise before writing any code:

| Guaranteed | Not guaranteed |
|---|---|
| The result parses into your Swift type | The values are true, or drawn from the set you named |
| Nested `@Generable` types are built top-down | Ordering, distribution, or coverage of array elements |
| Enum-typed properties hold a declared case | That every `GenerationGuide` you attach is enforced (see §4) |
| Every partial snapshot is a valid *partial* object | That a partial snapshot is a valid *complete* object |

The second thing to internalise: **guided generation and snapshot streaming are one mechanism, not
two.** Because the decoder is constrained to emit a structurally valid document top-down, the
framework can hand you a coherent partially-filled object at every step. That is exactly why Apple
calls it "snapshot streaming" and why `T.PartiallyGenerated` exists. If you turn structured output
off, streaming degrades to plain text deltas. Section 9 develops this.

Finally, the payoff Apple emphasises and most developers under-use: **guided generation lets you
delete prompt text.**

> "the final change we'll need to make is to **remove additional structural guidance that we are
> providing in our instructions**. Notice how we say 'each day needs an activity, hotel and
> restaurant, always include a title, short description, day by day'. **But all of this information
> is already in our itinerary `@Generable` struct. We don't need to provide it again in our
> instructions.**" — ✅ **VERIFIED**, code-along lines 459–463.

That is not a style preference. Instructions and prompts consume context-window tokens on a model
whose on-device context is 4,096 tokens (see
[`../../part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md`](../../part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md)).
Every sentence of format prose you delete is budget you get back.

---

## 2. `@Generable`: what the macro synthesises

### 2.1 The protocol the macro conforms you to

```swift illustrative
protocol Generable : ConvertibleFromGeneratedContent, ConvertibleToGeneratedContent
```

✅ **VERIFIED** from `/documentation/foundationmodels/generable`. The full inherited set is
`ConvertibleFromGeneratedContent`, `ConvertibleToGeneratedContent`, `InstructionsRepresentable`,
`PromptRepresentable`, `SendableMetatype`.

The three protocol members:

```swift illustrative
static var generationSchema: GenerationSchema { get }
func asPartiallyGenerated() -> Self.PartiallyGenerated
associatedtype PartiallyGenerated          // "A representation of partially generated content"
```

✅ **VERIFIED**, same page.

Two framework types conform to `Generable` out of the box: **`GeneratedContent`** (which is
therefore both the erased representation *and* a legal generation target — see §7.4) and
**`ImageReference`** (iOS 27.0+ — the reason it exists, and the round trip it completes, is §2.7).
✅ **VERIFIED** from the same page's conforming-types list.

The `InstructionsRepresentable` / `PromptRepresentable` inheritance is the quietly important part.
It is what makes this legal:

```swift prelude:guide-context
let prompt = Prompt {
    "Generate a 3-day itinerary to Grand Canyon."
    "Here is an example of the desired format, but don't copy its content."
    Itinerary.exampleTripToJapan        // ← an *instance* of a @Generable type, in a prompt builder
}
```

✅ **VERIFIED** (code-along, lines 542–556). The presenter is explicit that
`exampleTripToJapan` is "**actually an instance of the `Itinerary` `@Generable` with all its
properties populated**" (line 550), and that embedding it means "**not only does it include all the
guidance, but also the schema that's part of this prompt now**" (lines 570–572). Hold onto that
sentence; §10 depends on it.

### 2.2 The three macro spellings

```swift illustrative
@Generable(description:)
@Generable(description:representNilExplicitlyInGeneratedContent:)
@Generable(name:description:representNilExplicitlyInGeneratedContent:)
```

✅ **VERIFIED** — these three macro signatures are listed on the FoundationModels framework index
page. Apple's own note on the third: it exists for "using a custom name for the schema instead of
the Swift type name."

Practical reading of each parameter:

- **`description:`** — a type-level natural-language description. It is *not* free. It is emitted
  into the JSON schema that goes into the prompt.
- **`name:`** — decouples the schema's identity from the Swift type name. This matters when the
  schema name is user-visible: `ChatCompletionsLanguageModel` in the `foundation-models-utilities`
  package sends `schema.name` as the OpenAI `response_format.json_schema.name`
  (✅ **VERIFIED**, `ChatCompletionsLanguageModel.swift:266`), so on that path the Swift type name
  leaks to a third-party server unless you override it.
- **`representNilExplicitlyInGeneratedContent:`** — 🔴 **GAP (narrowed 2026-07-29)** on semantics;
  the declarations are now pinned. The three macro overloads and their availability are
  ✅ **SDK-verified** (`FoundationModels-27.0-macos.swiftinterface:1131-1139`):
  `@Generable(description: String? = nil)` is 26.0; `@Generable(description:
  representNilExplicitlyInGeneratedContent: Bool)` is **26.4** with *no default* — passing it is
  opting in explicitly; and the 27.0 `@Generable(name: String, description: String? = nil,
  representNilExplicitlyInGeneratedContent: Bool = false)` overload **defaults it to `false`**. The
  same flag appears as `representNilExplicitlyInGeneratedContent explicitNil: Bool` on
  `DynamicGenerationSchema.init` (`:3162-3164`) and `GenerationSchema.init` (`:3365-3367`), both
  26.4+. So the *default behaviour* is the implicit form, and the flag's internal name is
  `explicitNil` — consistent with the reading that `true` emits `"field": null` rather than
  omitting the key. What the emitted schema actually does with it is still unverified: no doc page
  in the corpus explains the semantics, and interfaces do not show macro expansions. **What would
  resolve it:** the doc page for the macro overload, or the expanded macro output (right-click the
  attribute in Xcode 27 → *Expand Macro*). The difference is observable in
  `GeneratedContent.Kind.null` handling and in whether an optional property appears in `required`.

### 2.3 The canonical shape

Apple's own example, verbatim from
`/documentation/foundationmodels/generable`:

```swift xfail:27 imports:FoundationModels
import FoundationModels

@Generable
struct SearchSuggestions {
    @Guide(description: "A list of suggested search terms.", .count(4))
    var searchTerms: [SearchTerm]

    @Generable
    struct SearchTerm {
        // Use a generation identifier for data structures the framework generates.
        var id: GenerationID

        @Guide(description: "A two- or three- word search term, like 'Beautiful sunsets'.")
        var searchTerm: String
    }
}
```

✅ **VERIFIED** verbatim as Apple's published example. Note three things: `@Guide` sits on the
property, not the type; `.count(4)` is a `GenerationGuide` passed as the *second* argument; and
`GenerationID` is a property type, not an attribute.

> ⚠️ **BETA COMPILER CONTRADICTION — nested `@Generable` is documented but does not type-check in
> Xcode 27 beta `27A5228h`.** The verifier proves the published fence fails: the generated macro
> source says `SearchTerm.PartiallyGenerated` is not a member type. Until a later beta fixes the
> expansion, move `SearchTerm` to file scope. The `xfail:27` marker makes that change visible: if a
> later compiler accepts Apple's sample, verification fails and forces this warning to be removed.

`@Generable` also works on enums, and this is the cheapest constraint in the framework:

```swift compile:27 imports:FoundationModels
@Generable
enum ActivityKind {
    case sightseeing
    case foodAndDining
    case shopping
    case hotelAndLodging
}
```

🟡 **RECONSTRUCTED** — the code-along narrates this type ("the type can only be **sightseeing, food
and dining, shopping, hotel and lodging**", lines 421–422) and states "**The enum is a great way to
have the model generate specific cases that are predefined**", but the source is read aloud rather
than shown as text. The *concept* — `@Generable` on an enum of cases — is firmly attested. Case
spellings above are inferred from spoken words.

The *forms* an `@Generable` enum may take are no longer inferred. Apple's Origami sample (iOS 27)
ships three of them:

```swift illustrative
@Generable enum OrigamiTemplate: String, CaseIterable { … }   // raw values include hyphens:
                                                              //   case catOrDogFace = "cat-or-dog-face"
@Generable enum CraftDomain: String, Codable { … }
@Generable enum ImageCategory: String, Codable {
    case craftInspiration = "inspiration for the craft"       // sentence-length raw value
    …
}
```

✅ **VERIFIED** from `Origami/Tutorial/Intelligence/OrigamiTemplate.swift:10-19`,
`Origami/Brainstorm/CraftDomain.swift:10-15` and `Origami/Brainstorm/ImageAnalysis.swift:23-27`.
A raw type is optional — an enum with no raw type and no associated values also compiles under
`@Generable` (`FoundationModelsCoffeeGame/GenerateDialog/Characters.swift:79-92`, iOS 26 sample,
so treat that one as the 26 baseline rather than 2026 evidence).

Two things fall out of `ImageCategory`, and they are the reason to read Apple's enums closely:

- **The raw value is the prompt-facing surface.** `case craftInspiration = "inspiration for the
  craft"` puts a human-readable phrase into the schema's `enum` keyword while keeping a Swift-idiomatic
  case name. That is a free `description:` you do not pay for twice.
- **Hyphens and spaces in raw values are fine.** `"cat-or-dog-face"` is a legal generated value; the
  grammar constrains the *string*, not a Swift identifier.

A `@Generable` enum is also a legal **tool argument** type — `var templateMatch: OrigamiTemplate`
inside a `Tool.Arguments` struct (✅ **VERIFIED**,
`Origami/Tutorial/Intelligence/CraftTools.swift:12-32`), which is the cleanest way to give a tool a
closed vocabulary. See §4.8.

### 2.4 Primitives are generable targets too

You do not need a struct:

```swift compile:27 imports:FoundationModels
let prompt = "How many tablespoons are in a cup?"
let session = LanguageModelSession(model: .default)

// Generate a response with the type `Float`, instead of `String`.
let response = try await session.respond(to: prompt, generating: Float.self)
```

✅ **VERIFIED** verbatim from
`/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation`.

Apple's own streaming sample also generates an **array** directly —
`generating: [Person].self` — so collection types are legal roots as well
(✅ **VERIFIED**; the snippet is quoted in full in §9.3, including the syntax error Apple shipped in
it).

### 2.5 `GenerationID` and why you cannot use `name` as an identity

```swift illustrative
struct GenerationID          // iOS 26.0+ … watchOS 27.0+
```

> "A unique identifier that is stable for the duration of a response, but not across responses."
>
> — ✅ **VERIFIED**, `/documentation/foundationmodels/generationid`.

Apple's own comment in the sample says why you need it:

> "A person's name changes as the response is generated, and two people can have the same name, so
> it is not suitable for use as an id. `GenerationID` receives special treatment and is guaranteed
> to be both present and stable."

✅ **VERIFIED** verbatim from the same page. This is a *streaming* concern: in a SwiftUI `ForEach`
over `[Person.PartiallyGenerated]`, using `name` as the identity makes rows churn as characters
arrive. Add `var id: GenerationID` to any `@Generable` type you intend to render in a list.

⚠️ **The "not across responses" half is the trap.** A `GenerationID` is *not* a stable domain key.
Do not persist it, do not use it to diff two responses, do not key a cache on it.

### 2.6 The composability contract, and its cost

The framework builds nested types "from the top down" (code-along, line 441). That is the
constrained decoder walking your type graph. The cost is stated by Apple in plain language:

> "For every `Generable` type in a request, the framework converts its type and format information to
> a JSON schema and provides it to the model. This contributes to the available context window
> size... To reduce the size of your generable type:
> - Reduce the complexity of your `Generable` type by evaluating whether properties are necessary to
>   complete the task.
> - Give your properties short and clear names.
> - Use `Guide(description:)` on properties only when it improves response quality.
> - Add a `Guide(description:_:)` with `maximumCount(_:)` to reduce token usage."
>
> — ✅ **VERIFIED** verbatim, `/documentation/foundationmodels/generable`.

Note the third bullet. Apple is telling you that a `description:` on every property is an
anti-pattern, not a best practice. Each one is tokens in the prompt on a 4K budget.

The measured cost, from Apple's own Instruments walkthrough of a five-property nested itinerary type
plus one tool plus instructions: **max token count 1044**, dropping to **700** when the schema is
excluded from the prompt (✅ **VERIFIED**, Apple-published, code-along lines 897 and 979–987; no
device or OS build is stated in the transcript, so treat the absolute numbers as indicative and the
~33% delta as the reusable figure). See §10.

### 2.7 Guided generation over images: `Attachment` → `ImageReference` → `.attachmentLabel`

`SystemLanguageModel` accepts images in 27, and the interesting part for *this* guide is that the
model can point back at one. `ImageReference` is the second framework type conforming to `Generable`
(§2.1), and it exists so a structured result can say *which input image* each element is about.

The round trip has three steps, and Apple's Origami sample works all three.

**1. Attach the image with a label you control.** ✅ **VERIFIED** verbatim,
`Origami/Models/DataModels/Photo.swift:77-91`:

```swift prelude:guide-context
func toPrompt() async throws -> Prompt {
    #if canImport(UIKit)
    guard let image = UIImage(data: data) else { return Prompt {} }
    #elseif canImport(AppKit)
    guard let image = NSImage(data: data) else { return Prompt {} }
    #endif
    let idImage = Attachment(image).label(idString)
    return Prompt { idImage }
}
```

`Attachment(_:)` takes a `UIImage` / `NSImage` **directly** — there is no
`ImageAttachmentContent` construction at the call site, despite the type existing in the framework's
symbol list. `.label(_:)` is a modifier returning something a `Prompt` builder accepts. The label in
the sample is app-generated and stable — `"Photo_\(id.uuidString.prefix(6))"`
(`Photo.swift:65-67`) — which is the whole point: it is *your* key, not the model's.
`Prompt {}` (empty) is a legal graceful-degradation value.

Prompt builders also splice **`[Prompt]` arrays inline**, which is how you attach N images
(✅ **VERIFIED**, `Origami/Models/Orchestrator.swift:596-616`):

```swift prelude:guide-context
var imagePrompts: [Prompt] = []
for photo in photos { imagePrompts.append(try await photo.toPrompt()) }

let prompt = Prompt {
    if let note { note }
    "I'm on section \(sectionIndex) step number \(stepNumber). How does this look?"
    imagePrompts                                   // ← an array of Prompts, spliced
    "For reference the step reads: \(stepContent ?? "")"
}
let stream = session.streamResponse(to: prompt)
```

**2. Declare an `ImageReference` property in the `@Generable` type.** ✅ **VERIFIED** verbatim,
`Origami/Brainstorm/ImageAnalysis.swift:11-21`:

```swift prelude:guide-context
@Generable
struct ImageAnalysis {
    var image: ImageReference
    var analysis: String

    @Guide(description: "What do you think the *purpose* of this photo is for the project?")
    var typeOfImage: ImageCategory
}
```

**3. Resolve it back to your object through `.attachmentLabel`.** ✅ **VERIFIED** verbatim,
`Origami/Brainstorm/BrainstormModel.swift:142-144`:

```swift prelude:guide-context
let photo = project.photos.first { photo in
    photo.idString == image.attachmentLabel
}
```

`ImageReference.attachmentLabel` is a `String` — the label you attached in step 1, handed back by the
model. Nothing about the image's *pixels* comes back; the reference is an identity, not a payload.

And it streams. `Origami/Brainstorm/BrainstormModel.swift:168-171` reads the label out of a
*partial* snapshot to start rendering before the analysis text arrives (✅ **VERIFIED** verbatim):

```swift illustrative
for item in partialResponse.content.images ?? [] {
    // Need at least an ID to start streaming.
    if let id = item.image?.attachmentLabel {
```

Note the double optionality — `.images` is `[…]?` on the partially-generated projection and
`.image` is `ImageReference?` inside it. §9.2 explains why.

**Why this is the pattern to steal.** Any multi-image task — "which of these photos shows the
finished fold?", "tag each receipt with its category", "pick the best three" — needs the output keyed
to specific inputs. Without `ImageReference` the model has to describe the image in prose and you
have to match on that prose, which is exactly the kind of string-matching that §4 exists to warn you
off. With it, the join key is an identifier you minted.

⚠️ Two limits worth stating. The label is a *model-generated string* like any other guided value: it
is grammar-constrained to be a string, not to be one of the labels you attached. Treat a lookup miss
as expected — Origami's code is a `first(where:)` returning an `Optional` and the call site handles
`nil`. And `ImageReference` is **iOS 27.0+** while the rest of the guided-generation core is 26.0, so
this whole section is behind an availability check on a mixed-target app.

## 3. `@Guide`: the complete catalogue

The forms below are grounded in Apple's macro documentation and compiling first-party samples;
unsupported combinations are kept out of the catalogue.[^guide-macro-source]

### 3.1 The macro forms

Two `@Guide` signatures are listed on the framework index page:

```swift illustrative
@Guide(description:)
@Guide(description:_:)      // second parameter is one or more GenerationGuide values
```

✅ **VERIFIED** from `/documentation/foundationmodels` (macro list).

But Apple's own prose in *Managing the context window* shows a third form that matches neither
signature:

```swift compile:27 imports:FoundationModels
@Generable
struct GameSettings {
    @Guide(.minimumCount(1), .maximumCount(20))
    @Guide(description: "Keyboard shortcuts for desktop")
    var keyboardShortcuts: [String]
}
```

✅ **VERIFIED** verbatim from
`/documentation/foundationmodels/managing-the-context-window`. Two facts fall out:

1. **`@Guide` stacks.** Two attributes on one property is legal and Apple ships it in documentation.
2. **A description-less, variadic-guides-only overload exists.** ✅ **VERIFIED** as *usage* in
   compiling first-party code: `@Guide(.minimumCount(3))` at
   `Origami/Brainstorm/BrainstormIdea.swift:20`, and `@Guide(.count(2))` in the iOS 26 coffee-game
   sample. 🟡 The *spelling of the declaration* remains **RECONSTRUCTED** — something like
   `@Guide(_ guides: GenerationGuide<Value>...)` must exist, but it is not on the index page.

So **three arities are attested in shipping Apple code**, and you can use any of them:

```swift illustrative
@Guide(description: "…")                       // Origami, Book Tracker
@Guide(.minimumCount(3))                       // Origami — guides only, no description
@Guide(description: "…", .count(3...8))        // Book Tracker — both
```

✅ **VERIFIED** from `BrainstormIdea.swift:11,20`, `BookTracker/Services/BookTaggingService.swift:13-45`.

### 3.2 Every guide, with Apple's own one-liners

```swift illustrative
struct GenerationGuide<Value>          // iOS 26.0+ … watchOS 27.0+
```

The complete static member list, ✅ **VERIFIED** from
`/documentation/foundationmodels/generationguide`, with Apple's own descriptions quoted:

| Guide | Apple's description | Applies to |
|---|---|---|
| `pattern(_:)` | "Enforces that the string follows the pattern." | `String` |
| `element(_:)` | "Enforces a guide on the elements within the array." | arrays |
| `count(_:)` | "Enforces that the array has exactly a certain number elements." | arrays |
| `constant(_:)` | "Enforces that the string be precisely the given value." | `String` |
| `anyOf(_:)` | "Enforces that the string be one of the provided values." | `String` — **see §4** |
| `range(_:)` | "Enforces values fall within a range." | numeric |
| `minimum(_:)` | "Enforces a minimum value." | numeric |
| `maximum(_:)` | "Enforces a maximum value." | numeric |
| `minimumCount(_:)` | "Enforces a minimum number of elements in the array." | arrays |
| `maximumCount(_:)` | "Enforces a maximum number of elements in the array." | arrays |

Usages actually observed across the Apple corpus: `.count(4)`, `.count(3...8)`, `.range(0...20)`,
`.range(1...10)`, `.minimum(1)`, `.maximum(10)`, `.maximumCount(2)`, `.maximumCount(3)`,
`.maximumCount(5)`, `.minimumCount(1)`.

⚠️ **`count` takes both an `Int` and a range.** ✅ **VERIFIED** — both overloads are exercised in
compiling Apple sample code: `@Guide(description: "Descriptive tags capturing themes, genres, moods,
and topics from the review", .count(3...8))` at
`BookTracker/Services/BookTaggingService.swift:13-45` (macOS 27), and the `Int` form `@Guide(.count(2))`
in the coffee-game sample plus `.count(4)` in the `Generable` reference page. A `ClosedRange<Int>`
overload therefore exists in fact, whatever its declared spelling.

### 3.3 The guide-to-type compatibility matrix

Attaching a guide to a property whose type does not support it does **not** fail at compile time.
It fails at request time, when the framework materialises the schema.

The most complete evidence in the corpus for which combinations are legal is not Apple's
documentation — it is the **negative test suite of the Foundation Models SDK for Python**
(`tests/test_guides.py`, lines 560–811), which asserts that each of the following raises
`UnsupportedGuideError`. Because the Python SDK's guides are resolved on the Swift side into real
`FoundationModels.GenerationGuide` cases (`resolveStringGuides`, `resolveArrayStringGuides`,
`resolveDoubleGuides`, `resolveIntGuides`, `resolveIntArrayGuides`, `resolveDoubleArrayGuides` in
`FoundationModelsCBindings.swift`), the matrix is the *framework's*, not Python's.

| Property type | Guides that are rejected |
|---|---|
| `String` | `minimum`, `maximum`, `range`, `count`, `minimumCount`, `maximumCount` |
| `Int` | `anyOf`, `pattern`, `count`, `minimumCount`, `maximumCount` |
| `Double` / `Float` | `anyOf`, `pattern`, `count`, `minimumCount`, `maximumCount` |
| `[Int]`, `[Double]` | `anyOf`, `pattern`, `minimum`, `maximum`, `range` |
| `[String]` | `pattern`, `minimum`, `maximum`, `range` — **but `anyOf` is accepted** |
| `Bool` | *(no guides at all — the bridge builds `Bool` schemas with no guide list)* |
| `[SomeGenerable]` | everything except `count` / `minimumCount` / `maximumCount` |

✅ **VERIFIED** as the Python SDK's asserted behaviour (read from
`tests/test_guides.py` and `FoundationModelsCBindings.swift:1586-1734`).
🟡 **RECONSTRUCTED** as a statement about pure-Swift `@Guide`: the guide *names* are translated
(Python `max_items` → Swift `.maximumCount`, `regex` → `.pattern`, `min_items` → `.minimumCount`),
and the Python layer adds its own client-side validation on top. The *shape* of the matrix is
strong; treat an individual cell as a hypothesis you should confirm with a `#Playground` run before
you depend on it.

Two rows deserve comment:

- **`[String]` + `anyOf` works.** The Python test file carries an explicit source comment: *"anyOf
  does work on array<string>, so it's not included here"*, and the Swift bridge implements it as
  `GenerationGuide.element(.anyOf(...))` — i.e. it constrains each element, not the array. That is
  the right mental model for `element(_:)` generally.
- **`Bool` ignores guides silently.** The Swift bridge builds `Bool` properties as
  `.init(type: Bool.self)` with **no** guides parameter. A guide attached to a `Bool` therefore does
  not throw `unsupportedGuide` — it evaporates. ✅ **VERIFIED** from the bridge's type table.

### 3.4 What happens when a guide is not supported

```swift illustrative
// iOS 27.0+
catch let error as LanguageModelError {
    if case .unsupportedGenerationGuide(let context) = error { … }
}
```

✅ **VERIFIED**: `LanguageModelError.unsupportedGenerationGuide(_:)`, payload type
`LanguageModelError.UnsupportedGenerationGuide`, description *"An unsupported generation guide was
used"*, from `/documentation/foundationmodels/languagemodelerror`.

On iOS 26 the same condition surfaced as `LanguageModelSession.GenerationError.unsupportedGuide(_:)`,
which is **deprecated in 27.0**. The rename is `unsupportedGuide` → `unsupportedGenerationGuide`.

⚠️ **SILENT FAILURE — the deprecation is behavioural, not cosmetic.** Apple's deprecation notice,
verbatim:

> "Use `LanguageModelError`, `SystemLanguageModel.Error`, or `LanguageModelSession.Error` instead.
> **Apps built with Xcode 26 will continue to catch this error until you rebuild with Xcode 27. You
> must update to Xcode 27 to catch the new error types before submitting your app.**"
>
> — ✅ **VERIFIED** verbatim from
> `/documentation/foundationmodels/languagemodelsession/generationerror`.

Read that again. **Which `catch` block fires depends on which Xcode built the binary.** A
`catch let e as LanguageModelSession.GenerationError` that has been quietly swallowing schema
problems for a year stops firing the day you rebuild with Xcode 27, and your `catch { }` fallback —
or worse, an unhandled `try?` — takes over. If your structured-output code has any error handling at
all, it needs a re-read before an Xcode 27 submission. See
[`06-availability-errors-and-guardrails.md`](06-availability-errors-and-guardrails.md) and
[`../../part-17-migration-from-pre-ios-27/README.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md).

### 3.5 A note on `pattern(_:)`

The Python SDK's documentation carries a constraint that has no equivalent statement in the Swift
docs:

> "Note that the `SystemLanguageModel` only supports **simple regex patterns** like `\d+` for digits
> or `\w+` for word characters."
>
> — ✅ **VERIFIED**, `docs/source/guided_generation.rst:111-112` in `apple/python-apple-fm-sdk`.

The SDK's live tests use only `\w` and `\d+`. Since the constraint is described as a property of
`SystemLanguageModel` rather than of the Python binding, it is reasonable to read it as applying to
Swift `.pattern(_:)` on the same model — but that is an inference, not a quote. If you need
anchored, alternated, or backreferencing patterns, validate the output yourself rather than trusting
the guide.

⚠️ One inconsistency worth knowing so you do not copy it: the Python `generation_guide.py`
docstrings show `regex=r"#/[a-zA-Z]+/#"` — Swift *regex-literal* delimiters leaking into a Python
docstring. The working tests use bare patterns. Do not include `#/…/#` delimiters in a pattern
string.

---

## 4. ⚠️ `.anyOf` does not constrain generation

> ## ⚠️ SILENT FAILURE
>
> **`@Guide(.anyOf([...]))` does not reliably restrict the model's output to the listed values.**
> The model can and does emit a value that is not in the set. Nothing throws. The response parses
> cleanly into your Swift type, because `String` is still a `String`. Your `switch` falls through to
> `default`, or your dictionary lookup returns `nil`, in production, on a user's device.
>
> **Apple reproduced this on Apple's own hardware.** An Apple Designer on the Developer Forums
> confirmed the bug after reproducing it, and an Apple Frameworks Engineer noted that it reproduces
> on **iOS 26.2**.
>
> **Do not ship a correctness-critical constraint expressed only as `.anyOf`.**

### 4.1 The evidence, precisely

Source: Apple Developer Forums **thread 812501**, captured 2026-07-27. Precedence level 3 in this
series' hierarchy (Apple-staff answer) — above WWDC transcripts, below headers and doc pages.

The reproduction, verbatim from the thread:

```swift prelude:guide-context
@Generable
struct Arguments {
    @Guide(description: "The city to get information about.", .anyOf(["London", "New York", "Paris"]))
    let city: String
}

func call(arguments: Arguments) throws -> String {
    print("Arguments are", arguments.generatedContent)
    let cityName = arguments.city
    let cityInfo = getCityInfo(for: cityName)
    return cityInfo
}
```

**The model generated `"Beijing"`.**

Asked what `.anyOf` is *supposed* to do, Apple's answer was **both** of the following:

1. list all the options in the schema presented to the model, **and**
2. constrain generation at prediction time.

It simply does not do (2) reliably. That is the whole finding, and it is the single most important
sentence in this guide.

### 4.2 It is not specific to the macro

The same failure was reported through the runtime-schema path (thread 811620), with this code:

```swift prelude:guide-context
let citiesDefinedAtRuntime = ["London", "New York", "Paris"]

let citySchema = DynamicGenerationSchema(
    name: "CityList",
    properties: [
        DynamicGenerationSchema.Property(
            name: "city",
            schema: DynamicGenerationSchema(
                name: "city",
                anyOf: citiesDefinedAtRuntime
            )
        )
    ]
)

let generationSchema = try GenerationSchema(root: citySchema, dependencies: [])
let tools = [CityInfo(parameters: generationSchema)]
```

✅ **VERIFIED** verbatim from the thread. And through the `GenerationSchema.Property(guides:)` path:

```swift prelude:guide-context
struct SectionReader: Tool {
    let article: Article
    let sections: [String]

    let name: String = "readSection"
    let description: String = "Read a specific section from the article."

    var parameters: GenerationSchema {
        GenerationSchema(
            type: GeneratedContent.self,
            properties: [
                GenerationSchema.Property(
                    name: "section",
                    description: "The article section to access.",
                    type: String.self,
                    guides: [.anyOf(sections)]
                )
            ]
        )
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let requestedSectionName = try arguments.value(String.self, forProperty: "section")
        // …
    }
}
```

✅ **VERIFIED** verbatim from thread 812501. So: **macro guide, dynamic schema, and static schema
property all exhibit it.** Whatever is broken is downstream of all three spellings.

### 4.3 The second, separate bug in the same thread

Apple's *initial* hypothesis for thread 812501 turned out not to explain that case — but it is
independently true and worth carrying:

> "Once a `LanguageModelSession` is initialized with a tool, the `parameters` property is
> **computed once and never updated**. If the schema initially has an empty array, the `.anyOf`
> constraint won't be enforced even if sections are later added."
>
> — ✅ **VERIFIED** verbatim, Apple Designer, thread 812501.

This is a real, distinct footgun. `Tool.parameters` is a computed property in every example Apple
ships, which makes it *look* dynamic. It is read once, at session initialisation. If your allowed
set is populated asynchronously — from a network fetch, a Core Data query, a file load — and the
session is created before it lands, the model sees an empty enum forever. **Recreate the session
after the set is known**, or build the schema eagerly and pass it in.

### 4.4 What Apple recommends instead

Two workarounds, both from Apple staff in thread 812501:

**1. Validate inside the tool and return a corrective string.**

```swift prelude:guide-context
func call(arguments: Arguments) async throws -> String {
    switch arguments.city {
    case "London", "New York", "Paris":
        return getCityInfo(for: arguments.city)
    default:
        return "Not a valid city. City must be one of: \(validCities)"
    }
}
```

⚠️ **With a documented failure mode.** The original poster reported that the model then *gets stuck
in loops re-calling the tool with invalid arguments.* If you use this pattern, count attempts and
break out yourself; do not assume the corrective string converges.

**2. Drop `.anyOf` and put the constraint in the instructions, in capitals.** Apple's own suggested
text, verbatim:

```
You can ONLY call the tool getCityInfo for the these cities: "London",
"Paris", "New York". For questions about all other cities you MUST tell
the user "Sorry, I can't look up that city."
```

Recall that the model is *trained to obey instructions over prompts* ("The model is trained to obey
instructions over prompts", ✅ **VERIFIED**, code-along lines 193–199), so this is not as flimsy as
it looks — but it is a probabilistic constraint, not a structural one.

### 4.5 What this guide recommends

Ordered by strength:

1. **Use a `@Generable enum` when the set is known at compile time.** Do not reach for `.anyOf` for
   a fixed vocabulary. See the caveat in §4.6 before treating this as absolute.
2. **Validate at the boundary, always.** Every `.anyOf`-constrained value crossing from the model
   into your app is untrusted input. Write the `default:` case. Return a typed error from it.
3. **Shrink the set instead of describing it.** If the allowed set is small, model each option as a
   case rather than a string.
4. **Restate the constraint in instructions**, in addition to the guide, when correctness matters.
5. **Exclude impossible values from the set at build time.** This is what Apple's own code does —
   see §4.7.

A defensive helper worth keeping around:

```swift compile:27 imports:Foundation
import FoundationModels

enum ConstrainedValueError: Error, LocalizedError {
    case outOfSet(field: String, got: String, allowed: [String])

    var errorDescription: String? {
        switch self {
        case let .outOfSet(field, got, allowed):
            return "Model produced \(got) for \(field); allowed: \(allowed.joined(separator: ", "))"
        }
    }
}

/// Re-checks an `.anyOf` constraint that the framework may not have enforced.
func validated(
    _ value: String,
    field: String,
    allowed: [String]
) throws -> String {
    guard allowed.contains(value) else {
        throw ConstrainedValueError.outOfSet(field: field, got: value, allowed: allowed)
    }
    return value
}
```

Wrap every `.anyOf`-guided string read in that, or an equivalent, before it reaches your domain
logic. It costs one line per field and turns a silent wrong answer into a catchable error.

### 4.6 Does the same bug affect `@Generable enum`?

🔴 **GAP.** This is the question you actually want answered and the corpus does not answer it.

Here is what is known. The Foundation Models JSON-Schema dialect serialises `.anyOf` (and
`.constant`) to the standard JSON-Schema **`enum`** keyword — ✅ **VERIFIED** from two independent
places: the Python SDK's `GuideType` enum carries the source comment
`anyOf = "enum"  # Serializes to "enum" in JSON schema`, and the Swift-exported schema fixtures in
`tests/tester_schemas/` show guides serialising as *"standard JSON Schema keywords: `enum` (anyOf &
constant), `minimum`/`maximum`, `minItems`/`maxItems`, `pattern` (regex)"*. Separately,
`GenerationSchema` has an initializer `init(type:description:anyOf:)` documented as *"Creates a
schema for a string enumeration"* — ✅ **VERIFIED** from
`/documentation/foundationmodels/generationschema`.

That strongly suggests a `@Generable enum` and a `.anyOf` guide **land on the same JSON-Schema
construct**, which would mean anything that breaks one can break the other. But:

- No report in the corpus describes a `@Generable enum` producing an undeclared case.
- Apple's code-along teaches enums and `.anyOf` as two mechanisms for the same job and shows the
  enum working.
- Every closed vocabulary in Apple's three 2026 sample apps is a `@Generable enum`; none is an
  `.anyOf` (§4.8). Suggestive of where Apple's own confidence sits — but sample apps have
  compile-time vocabularies anyway, so it is not evidence about enforcement.
- Nobody in the corpus has traced where the `enum` constraint is lost between schema and sampler.

**What would resolve it:** a five-line `#Playground` on a device running the target OS —
a `@Generable enum` with four unusual cases, greedy sampling, and a prompt that begs for a fifth
value. Run it a hundred times and count. Until someone does that, treat *both* mechanisms as
advisory and validate.

> 🟠 **Suggestive on Simulator and device; larger N still needed.** The probe suite ran 10 greedy
> adversarial samples on the iOS 27 Simulator (2026-07-31) and another 10 on iPhone 15 Pro / iOS
> build `24A5408d` (2026-08-20): **20/20 aggregate runs, 0 violations, 0 errors**. That is consistent
> with constrained decoding, but N=10 per destination is too small to close an intermittent defect
> first reported on iOS 26.2. Re-run with `PROBE_ENUM_RUNS=100`; keep validating in `call` meanwhile.

### 4.7 Apple's own code validates `.anyOf` results

This is circumstantial but instructive. The `apple/foundation-models-utilities` package's `Skills`
API builds a tool whose single argument is constrained by `.anyOf`:

```swift prelude:guide-context
let parameters = try! GenerationSchema(                           // Skills.swift:269
  root: DynamicGenerationSchema(
    name: "Arguments",
    properties: [
      DynamicGenerationSchema.Property(
        name: "skill",
        schema: DynamicGenerationSchema(
          type: String.self,
          guides: [.anyOf(allowed)]                               // :277
        ),
      )
    ]
  ),
  dependencies: []
)
```

✅ **VERIFIED** verbatim from the package source. And then, in the tool's `call`:

```swift prelude:guide-context
func call(arguments: GeneratedContent) async throws -> Prompt {
  let name = try arguments.value(String.self, forProperty: "skill")   // :294

  guard let skill = skills.first(where: { $0.name == name }) else {
    throw GeneratedContent.ParsingError(                             // :298
      rawContent: arguments.jsonString,
      debugDescription: """
        Model attempted to toggle a skill named '\(name)', \
        but no matching skill was found.

        Available skills:
        \(skills.map(\.name).joined(separator: "\n"))
        """
    )
  }
  // …
}
```

✅ **VERIFIED** verbatim, `Skills.swift:293-319`.

Apple's own shipping code, in the package it wrote to demonstrate emerging practice, **handles the
case where the model names a skill that was not in the `.anyOf` set.** It also carries a
`strictSchema` flag that *removes already-active skill names from the enum* so that "the model
literally cannot emit an invalid toggle" — a phrasing that only makes sense if the enum is doing
real work in the common case, while the `ParsingError` path exists because it sometimes is not.

**This is an inference, not an Apple statement.** But the pattern — narrow the set as much as
possible, then validate anyway — is exactly what §4.5 recommends, and it is what Apple's engineers
actually wrote.

### 4.8 What Apple's own 2026 sample apps do instead

A negative finding, and a strong one. Across the three refreshed-for-2026 sample projects — Origami
(iOS 27, 61 Swift files), Book Tracker (macOS 27, 20 Swift files) and *Searching indexed content with
natural language* (iOS 27, 6 Swift files) — **`.anyOf` does not appear once.** Not on a `@Guide`, not
on a `DynamicGenerationSchema`, not on a `GenerationSchema.Property`. ✅ **VERIFIED** by grep across
all three archives.

Every closed vocabulary in those apps is a **`@Generable` enum** instead: `OrigamiTemplate`,
`CraftDomain`, `ImageCategory` (§2.3), including as a tool-argument type. That is not proof that
Apple's engineers know `.anyOf` is unreliable — sample apps have compile-time vocabularies, which is
exactly the case §4.5's recommendation 1 covers — but it does mean **there is no first-party 2026
code demonstrating `.anyOf` working.** Weigh that against the forum reproduction in §4.1 before you
build a correctness-critical feature on it.

What the samples *do* demonstrate is belt-and-braces. Book Tracker's tagging feature states the same
3–8 constraint **three times**: in the guide (`.count(3...8)`), again in the instructions prose
(*"Return between 3 and 8 tags"*), and a third time as a heuristic `Evaluator` that measures whether
the shipped model actually complies. ✅ **VERIFIED**, `BookTracker/Services/BookTaggingService.swift:13-45`.

```swift compile:27 imports:FoundationModels
@Generable
struct BookTags: Codable, Equatable {
    @Guide(description: "Descriptive tags capturing themes, genres, moods, and topics from the review",
           .count(3...8))
    var tags: [String]
}
```

Read the redundancy as the lesson: Apple's own sample treats a `GenerationGuide` as **a hint worth
measuring**, not a contract worth trusting. The measurement half lives in
[`../../part-06-evaluations/references/01-foundations-and-hill-climbing.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/references/01-foundations-and-hill-climbing.md).

---

## 5. How guided generation is actually enforced: constrained decoding

Apple says the words "constrained decoding" once, in a code-along, and never explains them. No
documentation page in the corpus describes the mechanism. This section reconstructs it from two
open-source repositories that had to implement it — and which, independently, reached for the same
third-party library.

### 5.1 What constrained decoding means, concretely

A language model produces, at every step, a vector of **logits** — one real number per vocabulary
token, the model's unnormalised preference for each possible next token. A sampler turns that vector
into one chosen token (greedy = argmax; temperature/top-p = a weighted draw).

Constrained decoding inserts a step between those two:

```
    model forward pass
            │
            ▼
      logits[vocabSize]                   ← per-token scores
            │
            ├──────────────► grammar matcher: "given what has been emitted so far,
            │                                  which tokens keep the document valid?"
            │                                        │
            │                                        ▼
            │                                bitmask[vocabSize/32]
            ▼                                        │
     apply mask: logits[i] = -inf  ◄─────────────────┘
       for every disallowed i
            │
            ▼
         sampler
            │
            ▼
      chosen token ──────────► grammar matcher.acceptToken(token)
            │
            ▼
       decode to text
```

Your schema is compiled once into a **grammar**. At each step the grammar's *matcher* — which knows
the parse state, i.e. "we are inside the value of the key `title`, which must be a string, and we
have already emitted an opening quote" — produces a bitmask of permissible tokens. Everything else
has its logit set to negative infinity. The sampler then physically **cannot** choose an invalid
token, whatever the temperature.

That is why the structural guarantee is a guarantee and not a hope. It is enforced in the sampler,
not in the prompt.

It also explains three otherwise-puzzling behaviours:

- **`includeSchemaInPrompt: false` still produces valid structure.** The prompt copy of the schema
  is a *hint to improve quality*; the grammar mask is what enforces shape. Removing the hint costs
  accuracy, not validity.
- **Schema constraints beat the prompt.** The Python SDK's test suite asserts that with a schema
  carrying `maxItems: 3`, a prompt asking for five children yields `len(children) == 3`
  (✅ **VERIFIED**, `tests/test_json_guided_generation.py`, `person.json` fixture). The prompt is
  advisory; the grammar is not.
- **Guided generation "allows for optimizations that speed up inference"** (code-along, line 493) —
  a masked vocabulary is a smaller search.

### 5.2 The evidence: both Apple and MLX ship `xgrammar`

**Apple's `coreai-models`** — the package behind `CoreAILanguageModel` — declares:

```swift illustrative
.package(url: "https://github.com/mlc-ai/xgrammar", branch: "main"),
```

✅ **VERIFIED** from `Package.swift:43-47` of `apple/coreai-models`. The package contains a
`CXGrammar` C/C++ bridge target at `swift/Sources/lib/CXGrammar` (files `xgrammar_c_bridge.h/.cpp`,
`dlpack/dlpack.h`, `module.modulemap`), a `GuidedGeneration/` source directory inside
`CoreAILanguageModels`, and a `GuidedGenerationTests` test target. The `CoreAILanguageModels` target
compiles with `.define("CXGRAMMAR_IMPORT")` and links `libc++`.

**`ml-explore/mlx-swift-lm`** ships two of its nine library products for exactly this:

| Product | Description (verbatim from the repo) |
|---|---|
| `MLXGuidedGeneration` | **"Grammar-constrained generation (JSON Schema or EBNF) for any MLX model."** |
| `MLXCXGrammar` | the vendored xgrammar C++17 interop layer |

✅ **VERIFIED** from `Package.swift` and the repo's target descriptions.

And the single best piece of evidence in the whole corpus — a comment in `mlx-swift-lm`'s
`Package.swift`, explaining why it renames the vendored C++ namespaces at compile time:

> "Rename the vendored C++ namespaces at compile time so this target's symbols cannot collide with
> another xgrammar in the same binary (**e.g. CoreAI's prebuilt copy**)."
>
> ✅ **VERIFIED** verbatim, `Package.swift:203-228`, alongside `.define("xgrammar", to:
> "mlx_xgrammar")` and `.define("picojson", to: "mlx_picojson")`.

The MLX team wrote a symbol-renaming hack **because they expected Apple's Core AI framework to have
its own xgrammar in the same process.** That is convergent evidence from two independent teams that
`xgrammar` is how grammar-constrained decoding is done on this platform.

🟡 **RECONSTRUCTED — the important caveat.** All of the above is verified for the **Core AI** and
**MLX** backends. It is a strong *inference*, not a verified fact, that `SystemLanguageModel` — the
built-in Apple Intelligence model — uses the same library. What is verified for the system model is
only that Apple calls the technique "constrained decoding" (code-along, line 490) and that an
Apple-forums error string names an internal
`TokenGenerationCore.GuidedGenerationError.invalidConfiguration` type (thread 837226) — so *some*
guided-generation subsystem exists inside the OS with its own configuration errors. **What would
resolve it:** symbol inspection of the shipped `FoundationModels.framework` / `TokenGenerationCore`
binary on macOS 27.

### 5.3 The actual API, if you want to look at it

Apple's `coreai-models` exposes the mechanism as ordinary Swift. This is the clearest description of
what "guided generation" does that exists anywhere:

```swift illustrative
// swift/Sources/CoreAILanguageModels/GuidedGeneration/XGrammarWrapper.swift
public final class CompiledGrammar { public var memorySizeBytes: Int }

public final class GrammarCompiler {
    public init(tokenizerInfo: TokenizerInfo, maxThreads: Int = 8, cacheEnabled: Bool = true)
    public func compileJSONSchema(_ schema: String,
                                  anyWhitespace: Bool = true,
                                  strictMode: Bool = true) throws -> CompiledGrammar
}

public final class GrammarMatcher {
    public init(compiledGrammar: CompiledGrammar, maxRollbackTokens: Int = 0)
    public func fillNextTokenBitmask(_ bitmask: UnsafeMutablePointer<Int32>) -> Bool
    public func acceptToken(_ tokenId: Int32) -> Bool
    public var isTerminated: Bool
    public func reset()
}

public enum XGrammarError: Error { case schemaCompilationFailed(String) }
```

✅ **VERIFIED** verbatim from the repo. Note `compileJSONSchema` — **the input is a JSON Schema
string**, which is exactly what `GenerationSchema` encodes to (§7.5).

The per-step session type:

```swift prelude:guide-context
public struct ConstrainedGenerationSession: ~Copyable {
    public let schema: String
    public let vocabularySize: Int
    public var isTerminated: Bool
    public init(jsonSchema: String, tokenizerInfo: TokenizerInfo) throws
    public mutating func nextTokenBitmask() -> [Int32]?
    @discardableResult public mutating func applyMask(to logits: inout [Float]) -> Bool
    @discardableResult public mutating func applyMask(to logits: inout [Float16]) -> Bool
    @discardableResult public mutating func acceptToken(_ tokenId: Int32) -> Bool
    public mutating func reset()
}
```

✅ **VERIFIED** verbatim (initializer list abridged; four initializers exist). Masking sets
disallowed logits to `-.infinity` for `Float` and `-Float16.greatestFiniteMagnitude` for `Float16`.

And the loop that ties Foundation Models to it:

> `CoreAIExecutor.respondConstrained` JSON-encodes the FM `GenerationSchema`
> (`try JSONEncoder().encode(schema)`) and feeds the string to
> `ConstrainedDecodingStrategy(jsonSchema:vocabSize:)`.
>
> Per step: run 1 inference step → `session.applyMask(&maskedLogits)` →
> `CompositeSampler.sample(from: &maskedLogits, config:)` → `session.acceptToken(token)`; a rejected
> token ends the stream.
>
> — ✅ **VERIFIED** from the source reading of `apple/coreai-models`.

**`GenerationSchema` → `JSONEncoder` → JSON Schema string → compiled grammar → per-token bitmask →
masked logits → sampler.** That is the entire pipeline, and it is the answer to "what does
`@Generable` actually do."

### 5.4 Two channels, one API — and why `.anyOf` can fail

Now put §4 and §5 together, because this is the model that makes the `.anyOf` bug intelligible.

A `@Guide` value can travel down **two different channels**:

| Channel | Carries | Enforcement | Cost |
|---|---|---|---|
| **Prompt channel** — the JSON schema serialised into the prompt | descriptions, and the shape of every keyword | *advisory* — the model may ignore it | tokens in the context window |
| **Grammar channel** — the JSON schema compiled into a token-level grammar | whichever keywords the grammar compiler implements | *absolute* — impossible to violate | grammar compile time + a bitmask per step |

Apple told the forum that `.anyOf` is supposed to do **both**. The observed behaviour is that the
prompt channel works (the options appear in the schema; the model usually complies) and the grammar
channel does not bite (Beijing gets through).

⚠️ Where exactly it is lost — schema serialisation, grammar compilation, or the matcher — is
🔴 **GAP**, and I will not guess. What matters for you is the shape of the failure: **a guide whose
grammar channel is inert degrades silently into a prompt hint.** That is precisely why it produces a
parseable, plausible, wrong answer rather than an error.

Keep this two-channel model. It is also the correct way to think about `includeSchemaInPrompt`
(§10): that flag turns the *prompt* channel off and leaves the *grammar* channel alone.

### 5.5 Constrained-decoding gotchas worth knowing

These come from reading `apple/coreai-models`. They apply directly if you ship a Core AI backend and
are informative background otherwise.

- **Multi-token stop sequences are dropped.** The engine logs *"Warning: Multi-token stop sequences
  not supported by xgrammar, using single-token stops only"* and continues. ✅ **VERIFIED**.
- **`stopTokenIds:` is a dead parameter.** Three `ConstrainedGenerationSession` initializers accept
  it, document it, and never forward it to `TokenizerInfo` — which has no such parameter, and the C
  bridge has no stop-token entry point among its fourteen declarations. ✅ **VERIFIED** by source
  reading. The repo compensates with "defense in depth": stopping on `isTerminated` in the decoder
  loop *and* adding `endoftext` to the tokenizer-config stop patterns.
- **A default-value mismatch silently changes vocabulary semantics.** `TokenizerInfo.init` defaults
  `vocabType` to `.raw`; `ConstrainedGenerationSession` and `TokenizerInfoCache` default to
  `.byteLevel`. Building a `TokenizerInfo` yourself and passing it in uses RAW semantics unless you
  say otherwise. ✅ **VERIFIED**. This is a textbook silent failure: no error, subtly wrong masks.
- **`xgrammar` is pinned to `branch: "main"`** in `apple/coreai-models`' `Package.swift`, not to a
  semver range. ✅ **VERIFIED** — a reproducibility hazard if you vendor that package.

---

## 6. ⚠️ The logits problem: when your fastest backend loses guided generation

> ## ⚠️ SILENT FAILURE (architectural)
>
> Constrained decoding requires access to the **per-step logits vector**. Some high-performance
> inference engines never expose it, because they sample **on the GPU** and only hand back the
> chosen token. On those engines, guided generation is **impossible** — not slow, not degraded,
> impossible.
>
> If your app lets a user (or a heuristic) pick a backend, **`@Generable` can stop working when the
> user picks the fast one.**
>
> Stated as an architectural rule: **a bring-your-own-model app loses Apple's flagship
> structured-generation feature exactly when it selects its fastest backend.** This is not a tuning
> detail to be discovered late — it is a **model-and-engine selection constraint** that belongs in
> your backend decision table alongside context length and tokens/second. Full treatment on the
> provider side:
> [Part 4 · BYO model behind `LanguageModelSession`](../../part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md).

### 6.1 The concrete case

Apple's own `coreai-models` ships four inference engines. Two facts, both ✅ **VERIFIED** by source
reading:

```
"coreai-sequential"  -> CoreAISequentialEngine   (dynamic model, CPU-side sampling)   supportsLogits == true
"coreai-pipelined"   -> CoreAIPipelinedEngine    (GPU, GPU-side sampling)             supportsLogits == false
"static-shape"       -> StaticShapeEngine        (Neural Engine, chunked static)      supportsLogits == true
```

The pipelined engine's own header explains why:

> GPU-pipelined inference engine using Core AI's encode API.
> - Non-blocking GPU encoding via `InferenceFunction.encode`
> - **GPU-direct token sampling (argmax/topK) via MPSGraph compute shaders**
> - Pipeline-depth-matched buffer rotation for CPU/GPU overlap

✅ **VERIFIED** verbatim, `CoreAIPipelinedEngine.swift:36-43`. The whole point of that engine is that
the token never comes back to the CPU. Logits therefore cannot either — the design that makes it
fast is the design that makes constrained decoding impossible.

Ask it for logits and it throws, with an unusually honest message:

> `"CoreAI pipelined engine does not support logits (GPU-side sampling). Use a sequential engine for
> constrained generation or evaluation."`

✅ **VERIFIED** verbatim. And at the Foundation Models boundary:

> If the engine lacks logits, `CoreAIExecutor.respondConstrained` throws
> `unsupportedCapability(.guidedGeneration)` with debugDescription *"This model's inference engine
> does not support guided generation (constrained decoding requires per-step logits)."*

✅ **VERIFIED**. That maps to `LanguageModelError.unsupportedCapability(_:)` — "The model being used
doesn't support a particular feature" (✅ **VERIFIED**,
`/documentation/foundationmodels/languagemodelerror`).

### 6.2 Why "silent" — the capability declaration can be optimistic

Here is the part that turns a clean thrown error into a trap. `CoreAILanguageModel` computes its
declared capabilities like this:

> `isGuidedGenerationSupported` = the loaded engine's `supportsLogits` **if known**, else
> `variant != "coreai-pipelined"`.
>
> — ✅ **VERIFIED** from the source reading of `CoreAILanguageModel.swift`.

Now combine that with three other verified facts from the same repo:

1. The default `LoadMode` is **`.lazy`** — at `init` time, the engine is *not* loaded, so
   `supportsLogits` is **not known**.
2. `variant` defaults to **`nil`**, and `nil` / `"auto"` / `"default"` all mean *auto-detect*.
3. Auto-detect selects **`CoreAIPipelinedEngine`** for a dynamic model.

🟡 **RECONSTRUCTED (inference chain, each link verified).** For the most ordinary call in the
package —

```swift prelude:guide-context
let model = try await CoreAILanguageModel(resourcesAt: modelURL)   // .lazy, variant: nil
let session = LanguageModelSession(model: model)
```

— on a dynamic model, `capabilities` is evaluated before the engine exists, falls back to
`variant != "coreai-pipelined"`, and `nil != "coreai-pipelined"` is **true**. The model therefore
**advertises `.guidedGeneration`**, the framework lets a `generating:` request through on the
strength of that advertisement, the auto-detector then loads the pipelined engine, and the request
fails at generation time.

The framework's own contract makes this consequential. From Apple's provider skill documentation:

> "If a developer asks for a capability you didn't declare (e.g. tool calling on a model that
> doesn't support it), the framework throws `unsupportedCapability` for you — you don't write
> defensive code for that."
>
> and: "**Don't declare a capability you don't fully support** — the framework throws
> `unsupportedCapability` for the developer when they request a capability you didn't list."
>
> — ✅ **VERIFIED** verbatim,
> `skills/foundation-models-language-model-protocol/SKILL.md:35` and `:312` in
> `apple/foundation-models-utilities`.

So the framework's guard is only as good as the provider's honesty, and a heuristic that runs before
the engine loads is not honest — it is a guess. **If you ship a Core AI backend and need guided
generation, pass `variant: "coreai-sequential"` (or `"static-shape"`) explicitly, or construct with
`mode: .eager` so the capability is computed from a real engine.** 🟡 The remedy is reconstructed
from the same source facts; verify against your own build.

### 6.3 The same shape on other backends

**MLX (`ml-explore/mlx-swift-lm`).** Guided generation is **opt-in at model construction**:

```swift prelude:guide-context
if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
    let model = #huggingFaceLanguageModel(
        configuration: LLMRegistry.gemma3_1B_qat_4bit,
        capabilities: [.guidedGeneration])
    let session = LanguageModelSession(model: model)

    let recommendation = try await session.respond(
        to: "Recommend one thing to do in Chicago.",
        generating: Recommendation.self)
    print(recommendation.content)
}
```

✅ **VERIFIED** verbatim from the `mlx-swift-lm` README (lines 104–141). Omit
`capabilities: [.guidedGeneration]` and the *same code* throws `unsupportedCapability` at the
`generating:` call. Note also the two different availability floors in that snippet: `@Generable`
needs 26.0, the `LanguageModelSession(model:)` path needs 27.0.

Note further that `MLXGuidedGeneration` is a **separate library product** and `MLXFoundationModels`
depends on it *trait-conditionally*. Turning off the `FoundationModelsIntegration` trait — which
consumers targeting pre-27 OSes are explicitly told to do — compiles the whole bridge away.
✅ **VERIFIED** from `Package.swift`.

**OpenAI-compatible servers (`ChatCompletionsLanguageModel`).** The flag is right in the
initializer:

```swift illustrative
public init(
  name: String,
  url: URL,
  additionalHeaders: [String: String] = [:],
  supportsGuidedGeneration: Bool = true,
  urlSessionConfiguration: URLSessionConfiguration? = nil
)
```

✅ **VERIFIED** verbatim, `ChatCompletionsLanguageModel.swift:73`. It gates one capability and only
one:

```swift prelude:guide-context
public var capabilities: LanguageModelCapabilities {
  if supportsGuidedGeneration {
    LanguageModelCapabilities([.vision, .toolCalling, .reasoning, .guidedGeneration])
  } else {
    LanguageModelCapabilities([.vision, .toolCalling, .reasoning])
  }
}
```

✅ **VERIFIED** verbatim, `:88-92`. When enabled, `request.schema` maps to the OpenAI
`response_format` with `name: schema.name`. When the flag is `false`, the schema is simply not sent
— and since `.guidedGeneration` is then undeclared, the framework throws for you. **But if the flag
is `true` and the remote server ignores `response_format`** (a very common situation with small
local servers), nothing throws: you get free-form text back and a decoding failure downstream, which
looks like a model-quality problem and is not.

**The same conclusion, reached independently in the field.** A community Core AI model-zoo project
that patched the pipelined engine until non-standard architectures (hybrid Qwen3.5, SSM
Granite / LFM) ran behind `LanguageModelSession` records the outcome as a flat constraint:

> "with the pipelined-engine patch stack, the non-standard bundles … **DO** run behind
> `LanguageModelSession` too; note **guided generation requires engine logits, which GPU-pipelined
> bundles don't expose**."
>
> — ✅ **VERIFIED** as a quotation, `notes/repos/john-rocky-models.md`, entry dated 2026-06-11.
> **Community-measured, not an Apple statement.** It cross-checks with
> `InferenceEngine.supportsLogits` in that fork — default `false`, overridden `true` only by the
> sequential and static-shape engines — which is the same table as §6.1.

So the constraint survives the obvious workaround. Patching a GPU-pipelined engine to *load* an exotic
model does not give it logits; the sampling still happens on the GPU. If you need `@Generable`, the
engine choice is made for you, and it is the slower one.

**Third-party field report on the consequences.** From the same corner of the ecosystem:

> "242's baton-pass flips the route from inside a **tool** the model calls. On the kit's upstream
> engine that path is unreliable: small/thinking models emit tool-call JSON the framework rejects
> with `GenerationError.decodingFailure`… **The reliable 'the model decides' channel is guided
> generation.**"
>
> — ✅ **VERIFIED** as a quotation (community source, `knowledge/dynamic-profiles-local-models.md`).
> The author notes it applies to third-party `LanguageModel` providers, **not** to Apple's own
> models. Community-measured, unverified by Apple.

The irony is worth stating plainly: on weak third-party models, guided generation is the *most*
reliable control channel you have — and it is the first capability those same backends drop when
tuned for speed.

### 6.4 The rule

| If you are… | Then… |
|---|---|
| Using `SystemLanguageModel` or PCC only | You always have guided generation. Skip this section. |
| Shipping a Core AI backend | Pin `variant:` to a logits-capable engine, or load `.eager`, if you use `@Generable`. |
| Shipping an MLX backend | Declare `capabilities: [.guidedGeneration]` explicitly. |
| Shipping a Chat-Completions backend | Set `supportsGuidedGeneration:` honestly per endpoint, and *test* that `response_format` is honoured. |
| Letting users choose a backend at runtime | Check `model.capabilities.contains(.guidedGeneration)` **before** you offer a feature that requires it, and degrade the UI, not the request. |

Full treatment of the provider side lives in
[`../../part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md`](../../part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md)
and
[`../../part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md`](../../part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md).

---

## 7. `GenerationSchema` and `DynamicGenerationSchema`

When the shape of your output is known at compile time, `@Generable` is all you need. When it is not
— a form whose fields come from a server, a picker whose options come from the user's own data, a
tool whose argument set depends on app state — you build the schema at runtime.

The code-along explicitly lists "**dynamic runtime schemas**" as a topic it did not have time to
cover (line 1003). This section is that topic.

### 7.1 `GenerationSchema` — the finished, immutable article

```swift illustrative
struct GenerationSchema
// Copyable, CustomDebugStringConvertible, Decodable, Encodable, Escapable, Sendable
```

✅ **VERIFIED** from `/documentation/foundationmodels/generationschema`.

Initializers, ✅ **VERIFIED** from the same page:

```swift illustrative
init(root:dependencies:)                                            // from DynamicGenerationSchema
init(type:description:anyOf:)                                       // "Creates a schema for a string enumeration."
init(type:description:properties:)
init(type:description:representNilExplicitlyInGeneratedContent:properties:)
```

Members: `var name: String` (**iOS 27.0+**; see §7.6), and a nested
`GenerationSchema.Property` with `init(name:description:type:guides:)`.

`GenerationSchema.SchemaError` cases, ✅ **VERIFIED**:

| Case | When |
|---|---|
| `.duplicatePropertySchema(_:property:context:)` | two properties with the same name |
| `.duplicateTypeSchema(_:type:context:)` | two dynamic schemas claiming the same name |
| `.emptyTypeChoicesSchema(_:context:)` | an `anyOf` with an empty array |
| `.undefinedReferencesSchema(_:references:context:)` | a `referenceTo:` that nothing defines |

Plus `SchemaError.Context` (with `debugDescription` / `init(debugDescription:)`), `errorDescription`
and `recoverySuggestion`.

⚠️ **`.emptyTypeChoicesSchema` is your friend, and you should not swallow it.** It is the error that
catches the "my allowed array hadn't loaded yet" bug from §4.3 — but only if you propagate the throw.
Note that Apple's own `Skills` code writes `try!` at that construction site (`Skills.swift:269`),
which traps rather than throws. Do not copy that.

### 7.2 `DynamicGenerationSchema` — the builder

```swift illustrative
struct DynamicGenerationSchema        // Sendable, SendableMetatype
```

> "An individual schema may reference other schemas by name, and references are resolved when
> converting a set of dynamic schemas into a `GenerationSchema`."
>
> ✅ **VERIFIED** verbatim from `/documentation/foundationmodels/dynamicgenerationschema`.

The full initializer set, ✅ **VERIFIED** from the same page:

```swift illustrative
init(arrayOf:minimumElements:maximumElements:)
init(name:description:anyOf:)
init(name:description:properties:)
init(name:description:representNilExplicitlyInGeneratedContent:properties:)
init(referenceTo:)                 // "Creates an refrence schema."  [sic — Apple's typo]
init(type:guides:)                 // "Creates a schema from a generable type and guides."
static var null                    // "Creates a null schema."

struct DynamicGenerationSchema.Property   // init(name:description:schema:isOptional:)
```

Four of these do all the work:

- **`init(name:properties:)`** — an object. `description:` has a default; Apple's own examples and
  the forum code both omit it.
- **`init(name:anyOf:)`** — a string enumeration whose cases are known only at runtime.
- **`init(type:guides:)`** — the bridge back to the static world. `DynamicGenerationSchema(type:
  String.self, guides: [.anyOf(allowed)])` is how you attach a `GenerationGuide` to a runtime
  property.
- **`init(referenceTo:)`** — a by-name reference to another schema, resolved at
  `GenerationSchema(root:dependencies:)` time. This is what lets runtime schemas be recursive.

### 7.3 The worked example

Apple's own, ✅ **VERIFIED** verbatim from
`/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation`:

```swift compile:27 imports:FoundationModels
// Create the dynamic schema at runtime.
let menuSchema = DynamicGenerationSchema(
    name: "Menu",
    properties: [
        DynamicGenerationSchema.Property(
            name: "dailySoup",
            schema: DynamicGenerationSchema(
                name: "dailySoup",
                anyOf: ["Tomato", "Chicken Noodle", "Clam Chowder"]
            )
        )

        // Add additional properties.
    ]
)
```

```swift prelude:guide-context
// Create the schema.
let schema = try GenerationSchema(root: menuSchema, dependencies: [])

// Pass the schema to the model to guide the output.
let response = try await session.respond(
    to: "The prompt you want to make.",
    schema: schema
)
```

Note the `schema:` label — a **different overload family** from `generating:`. From the class page's
overload list: `respond(to:schema:includeSchemaInPrompt:options:)`,
`respond(schema:includeSchemaInPrompt:options:prompt:)`,
`respond(to:schema:options:contextOptions:metadata:)`, plus the `streamResponse` mirrors. The full
declarations are now ✅ **SDK-verified** (26.x forms:
`FoundationModels-27.0-macos.swiftinterface:2103-2111` for `respond`, `:2056-2058` for
`streamResponse`, each returning `Response<GeneratedContent>` /
`ResponseStream<GeneratedContent>` with `includeSchemaInPrompt: Bool = true`; the 27.0
`contextOptions:`/`metadata:` forms at `:2147-2159`, `:2073-2079`, where the flag moves into
`ContextOptions(includeSchemaInPrompt: true)` and the overloads are `@_disfavoredOverload`).

**The return type is different.** `respond(to:generating: T.self)` gives you
`Response<T>` whose `.content` is a `T`. `respond(to:schema:)` gives you a response whose `.content`
is a **`GeneratedContent`** — because there is no Swift type to decode into. You read it with
`value(_:forProperty:)`. ✅ **SDK-verified** (2026-07-29): every `schema:` overload is declared
`-> Response<GeneratedContent>` (`FoundationModels-27.0-macos.swiftinterface:2103-2111`),
matching the Python SDK's documented split (`generating=Cls` → an instance of `Cls`; `schema=` →
a `GeneratedContent`).

### 7.4 A runtime schema, end to end

Putting it together for a real case — a survey whose questions arrive from a server:

```swift illustrative
import FoundationModels

struct SurveyQuestion {
    let key: String            // e.g. "primaryUseCase"
    let prompt: String         // e.g. "The person's main use case"
    let options: [String]      // e.g. ["work", "school", "hobby"]
}

func makeSchema(for questions: [SurveyQuestion]) throws -> GenerationSchema {
    let properties = questions.map { q in
        DynamicGenerationSchema.Property(
            name: q.key,
            description: q.prompt,
            schema: DynamicGenerationSchema(name: q.key, anyOf: q.options),
            isOptional: false
        )
    }

    let root = DynamicGenerationSchema(name: "SurveyAnswers", properties: properties)
    return try GenerationSchema(root: root, dependencies: [])
}

func answer(
    _ questions: [SurveyQuestion],
    about transcript: String,
    in session: LanguageModelSession
) async throws -> [String: String] {

    let schema = try makeSchema(for: questions)

    let response = try await session.respond(
        to: "Fill in the survey based on this conversation:\n\(transcript)",
        schema: schema
    )

    var result: [String: String] = [:]
    for q in questions {
        let raw = try response.content.value(String.self, forProperty: q.key)
        // §4: never trust `.anyOf`. Validate.
        guard q.options.contains(raw) else {
            throw ConstrainedValueError.outOfSet(field: q.key, got: raw, allowed: q.options)
        }
        result[q.key] = raw
    }
    return result
}
```

🟡 **RECONSTRUCTED as a composite.** Every individual call — `DynamicGenerationSchema.Property(name:
description:schema:isOptional:)`, `DynamicGenerationSchema(name:anyOf:)`,
`GenerationSchema(root:dependencies:)`, `respond(to:schema:)`,
`GeneratedContent.value(_:forProperty:)` — is ✅ **VERIFIED** individually from the sources cited
above. The assembly, and the assumption that `response.content` on the `schema:` path is a
`GeneratedContent`, are mine.

Three things this example is doing on purpose:

1. `dependencies: []` because nothing is referenced by name. If a property's schema were
   `DynamicGenerationSchema(referenceTo: "Address")`, the `Address` schema must appear in
   `dependencies`, or you get `.undefinedReferencesSchema`.
2. `isOptional: false` explicitly, because optionality in this dialect means *absence from
   `required`* (§7.5), not a nullable type.
3. Validating every `.anyOf` result. Always.

### 7.5 The Foundation Models JSON-Schema dialect

`GenerationSchema` "conforms to `Codable` and encodes to standard JSON Schema" — and you can see the
exact output, because the Python SDK ships Swift-exported fixtures. This is `person.json`,
✅ **VERIFIED** verbatim from `tests/tester_schemas/person.json` in `apple/python-apple-fm-sdk`:

```json
{
  "additionalProperties": false,
  "properties": {
    "age":      { "description": "The person's age", "maximum": 100, "minimum": 18, "type": "integer" },
    "children": { "description": "The person's children", "items": { "$ref": "#" },
                  "maxItems": 3, "type": "array" },
    "name":     { "description": "The person's name", "type": "string" }
  },
  "required": ["children", "name"],
  "title": "Person",
  "type": "object",
  "x-order": ["age", "children", "name"]
}
```

The dialect's rules, ✅ **VERIFIED** by inspection of the seven shipped fixtures:

| Feature | Encoding |
|---|---|
| type name | `"title"` |
| declaration order | **`"x-order"`** — a custom extension, not standard JSON Schema |
| unknown keys | `"additionalProperties": false`, always |
| optional property | simply **absent from `"required"`** |
| nested types | under `"$defs"`, referenced `"$ref": "#/$defs/Age"` |
| root self-reference | `"$ref": "#"` |
| `.anyOf` / `.constant` | `"enum"` |
| `.minimum` / `.maximum` / `.range` | `"minimum"` / `"maximum"` |
| `.minimumCount` / `.maximumCount` / `.count` | `"minItems"` / `"maxItems"` |
| `.pattern` | `"pattern"` |

That `"x-order"` key is worth pausing on. JSON objects are unordered; the framework needs a
deterministic property order because the *grammar* emits properties in a fixed sequence. `x-order`
is how declaration order survives serialisation — and it is why the order of properties in your
`@Generable` struct is a real design decision, not cosmetic: it is the order the model fills them
in, and therefore the order they appear in your streaming snapshots (§9).

Exporting a schema from Swift, ✅ **VERIFIED** from
`docs/source/guided_generation.rst:246-248` of the Python SDK:

```swift prelude:guide-context
let schema = ProductReview.generationSchema
let jsonData = try JSONEncoder().encode(schema)
try jsonData.write(to: URL(fileURLWithPath: "schema.json"))
```

This is a genuinely useful debugging move regardless of Python: dump the JSON your `@Generable` type
produces and read it. It tells you exactly what the model is being shown and what the grammar will
be compiled from. It is the only direct window onto the prompt channel.

### 7.6 `GenerationSchema.name` (iOS 27.0+)

A small API with a visible history. In beta 1, `foundation-models-utilities` carried a private
extension that round-tripped the schema through `JSONEncoder`/`JSONSerialization` just to read the
`"title"` key, falling back to `"type"`, then to `"Response"`. In beta 3 that extension was **deleted
entirely** in favour of a first-class `GenerationSchema.name` property.

✅ **VERIFIED** by `git show 376ca60` on `apple/foundation-models-utilities`, and the current call
site at `ChatCompletionsLanguageModel.swift:266`.

The declaration is now ✅ **SDK-verified**: `public var name: String { get }`, 27.0+,
**non-optional** (`FoundationModels-27.0-macos.swiftinterface:3319-3327`) — so every schema has
*some* name. 🔴 **GAP:** what that `String` *is* for an anonymous or inline schema (e.g. one built
from `DynamicGenerationSchema(name:)` versus one built from a Swift type) is still not documented
anywhere in the corpus, and a getter body is not visible in the interface. **What would resolve
it:** the doc page for `generationschema/name`, or a one-line print in a `#Playground`.

---

## 8. `GeneratedContent`: the untyped door

```swift illustrative
struct GeneratedContent        // conforms to Generable itself
```

> "Generated content may contain a single value, an array, or key-value pairs with unique keys."
>
> ✅ **VERIFIED** verbatim, `/documentation/foundationmodels/generatedcontent`.

You meet `GeneratedContent` in four places: as `Response.rawContent`, as the argument type of a tool
whose `parameters` is a `GenerationSchema`, as the result of the `schema:` overload family, and as
the payload of a `ParsingError`.

### 8.1 The surface

✅ **VERIFIED** from the doc page.

```swift illustrative
// Initializers
init(_:)
init(_:id:)
init(elements:id:)
init(properties:id:)
init(properties:id:uniquingKeysWith:)
init(json:)                       // "Creates equivalent content from a JSON string"
init(kind:id:)

// Accessors
var kind: GeneratedContent.Kind
func value(_:)
func value(_:forProperty:)
var isComplete: Bool              // "A Boolean that indicates whether the generated content is completed"
var generatedContent: GeneratedContent
var jsonString: String
var debugDescription: String
var id: GenerationID
```

```swift illustrative
enum GeneratedContent.Kind {
    case array(_:)
    case bool(_:)
    case null
    case number(_:)
    case string(_:)
    case structure(properties:orderedKeys:)
}
```

Two members deserve attention:

- **`.structure(properties:orderedKeys:)` carries `orderedKeys`.** That is `x-order` (§7.5) surviving
  all the way into the runtime representation. If you are walking a `GeneratedContent` generically,
  iterate `orderedKeys`, not the dictionary.
- **`isComplete`** is the streaming-aware flag. During a stream, a `GeneratedContent` may be a
  well-formed prefix; `isComplete` is how you tell "this string is finished" from "this string is
  still arriving."

`init(json:)` and `jsonString` give you a lossless round-trip through text. That is how you persist a
partial result, log a failure, or hand a model's output to a non-Swift consumer.

### 8.2 Reading values

```swift prelude:guide-context
let name = try arguments.value(String.self, forProperty: "section")
```

✅ **VERIFIED** verbatim from the forum tool code in §4.2. It `throws` — a missing or wrongly-typed
property is an error, not a `nil`.

⚠️ **The Python binding of the same call does not throw.** `contents.value(int, "invalid_key")`
returns `None` for a missing key, asserted in `tests/test_error_handling.py:67-68`
(✅ **VERIFIED**). If you are porting between the two SDKs, that asymmetry will bite you: Swift
surfaces the model's omission, Python silently gives you a null.

### 8.3 `GeneratedContent.ParsingError` as a first-class signal

```swift illustrative
struct GeneratedContent.ParsingError
init(rawContent:underlyingError:debugDescription:)
var rawContent
var underlyingError
var debugDescription
```

✅ **VERIFIED** from the doc page.

**`GeneratedContent.ParsingError` is a separate error type — it is not a case of
`LanguageModelError`, and a `catch let e as LanguageModelError` will not see it.** ✅ **VERIFIED**
from Apple's Origami sample, whose error-to-UI mapping tests for it as its own type, after
`SystemLanguageModel.Error` and after `LanguageModelError`
(`Origami/Models/Error+DisplayMessage.swift:12-36`):

```swift prelude:guide-context
if self is GeneratedContent.ParsingError {
    return "Origami had trouble understanding the response. Please try again."
}
```

That single line settles a question the documentation leaves open: a structured-output decode
failure reaches you as a **thrown `GeneratedContent.ParsingError`**, and code that only handles
`LanguageModelError` falls through to its generic `catch`. If your UI distinguishes "the model
refused" from "the model produced something I couldn't read" — and it should, because the remedies
differ — you need this branch. §11.1 places it in the full ladder.

It travels in the other direction too: **you are also expected to throw it yourself.** Apple's
`Skills` implementation constructs one with the two-argument form
`GeneratedContent.ParsingError(rawContent:debugDescription:)` when the model names a skill that does
not exist (§4.7). That is the framework's idiom for *"the model produced syntactically valid content
that is semantically impossible"* — and, since Origami catches the same type, throwing it from your
own tool lands your semantic failures in the same UI branch as the framework's parse failures.

Adopt it. When your `.anyOf` validation fails, throwing a `ParsingError` with `rawContent:
arguments.jsonString` and a `debugDescription` that lists the legal values gives the framework —
and your logs, and Instruments — a structured record of what the model actually said.

✅ **RESOLVED (2026-07-29):** it *is* the named successor. The deprecated
`GenerationError.decodingFailure(_:)` case carries the SDK's own per-case deprecation message
*"Use ``GeneratedContent/ParsingError`` instead."* — ✅ **SDK-verified**
(`FoundationModels-27.0-macos.swiftinterface:3555-3558`). The struct's members are also read
verbatim there: `rawContent: String`, `underlyingError: (any Error)?`, `debugDescription: String`,
conforming to `LocalizedError` (`:1399-1404`). While migrating, still catch
`GeneratedContent.ParsingError` **and** keep a generic `catch` — apps built with Xcode 26 keep
throwing the old case until rebuilt.

---

## 9. Snapshot streaming

### 9.1 `respond` vs `streamResponse`, exactly

The two declarations, ✅ **VERIFIED** verbatim from
`/documentation/foundationmodels/languagemodelsession`:

```swift illustrative
@discardableResult nonisolated(nonsending)
final func respond<Content>(to prompt: Prompt,
                            generating type: Content.Type = Content.self,
                            includeSchemaInPrompt: Bool = true,
                            options: GenerationOptions = GenerationOptions())
  async throws -> LanguageModelSession.Response<Content> where Content : Generable

final func streamResponse<Content>(to prompt: Prompt,
                                   generating type: Content.Type = Content.self,
                                   includeSchemaInPrompt: Bool = true,
                                   options: GenerationOptions = GenerationOptions())
  -> sending LanguageModelSession.ResponseStream<Content> where Content : Generable
```

Read the effects, not the names:

| | `respond` | `streamResponse` |
|---|---|---|
| `async` | **yes** | **no** |
| `throws` | **yes** | **no** |
| returns | `Response<Content>` | `ResponseStream<Content>` (`sending`) |
| `@discardableResult` | yes | no |
| errors surface | at the `await` | inside the `for try await` loop |

⚠️ **`streamResponse` is not `async` and does not `throws`.** You do not `try await` the call. You
`try await` the *iteration*. This is stated explicitly in the code-along:

> "we replaced `session.respond` with **`session.streamResponse`** and kept the rest of the argument
> same… **But we don't have an `await` here. What we get instead is an async sequence called
> `stream`, which means we can then loop over it**"
>
> ✅ **VERIFIED**, code-along lines 623–630.

Getting this wrong produces a confusing compiler error rather than a runtime bug, so it is a cheap
mistake — but it also means **a schema error does not surface where you started the stream.** If you
build a `DynamicGenerationSchema` badly, you will find out inside the loop, possibly after the view
has already rendered a spinner.

The full overload matrix is large: six non-metadata plus six metadata variants each for `respond`
and `streamResponse` — **24 methods**. The `@PromptBuilder` trailing-closure forms
(`streamResponse(generating:includeSchemaInPrompt:options:prompt:)`) and the `schema:` forms exist
for both. ✅ **VERIFIED** as names from the class page.

⚠️ **The `metadata:` family (iOS 27.0+) drops `includeSchemaInPrompt`** — that knob moved into
`ContextOptions.includeSchemaInPrompt`. ✅ **VERIFIED** from the class page's overload list and the
note that `ContextOptions` carries it. So on the modern overloads you write
`contextOptions: ContextOptions(includeSchemaInPrompt: false)` rather than a bare argument.
🟡 The exact `ContextOptions` initializer label set is **RECONSTRUCTED** — the corpus confirms
`ContextOptions` has `includeSchemaInPrompt` and `reasoningLevel` members
(`SKILL.md:271`, `:283` in `foundation-models-utilities`) but does not show the initializer.

### 9.2 `T.PartiallyGenerated`

> "**So what is `PartiallyGenerated`? Think of this as a mirror version of our struct where every
> single property is an optional. `@Generable` defines this automatically for us. It's a perfect way
> to represent data that arrives over time.**"
>
> ✅ **VERIFIED** verbatim, code-along lines 611–613.

It applies **through the whole type graph**: `Itinerary.PartiallyGenerated` has
`days: [DayPlan.PartiallyGenerated]?`, whose elements have
`activities: [Activity.PartiallyGenerated]?`, and so on (code-along 643–644).

```swift prelude:guide-context
// ViewModels/ItineraryGenerator.swift
var itinerary: Itinerary.PartiallyGenerated?
```

```swift illustrative
func generateItinerary(dayCount: Int = 3) async throws {
    let prompt = Prompt { /* … */ }

    let stream = session.streamResponse(
        to: prompt,
        generating: Itinerary.self
    )

    for try await partialResponse in stream {
        itinerary = partialResponse.content
    }
}
```

✅ **VERIFIED** (code-along lines 620–630, identifiers read aloud).

**Each element is a complete snapshot, not a delta.** The presenter: "you'll get a snapshot every
time of whatever has been generated at that point in time" (line 630). You *assign*, you never
append. This is the single most important behavioural difference from every other streaming LLM API
you have used, and it is why Apple's marketing name for the feature is "snapshot streaming"
(✅ **VERIFIED**, WWDC26 session 241, line 1).

The consequence for `x-order` (§7.5): properties fill in **declaration order**. Put the fields your
UI shows first — a title, a summary — at the top of the struct, and the user sees something within a
few tokens instead of after the whole object.

### 9.3 `ResponseStream`, `Snapshot`, and `Response`

```swift illustrative
struct Response<Content> where Content : Generable        // iOS 26
struct ResponseStream<Content> where Content : Generable  // iOS 26, conforms to AsyncSequence
struct LanguageModelSession.ResponseStream.Snapshot
struct LanguageModelSession.Usage                          // iOS 27
```

✅ **VERIFIED** from the doc pages. Members:

- **`Response`** — `.content`, `.rawContent`, `.usage` (iOS 27), `.transcriptEntries`
- **`ResponseStream`** — `.collect()`, documented as *"The result from a streaming response, after it
  completes"*; the element type is `ResponseStream.Snapshot`
- **`Snapshot`** — `.content`, `.rawContent`, `.transcriptEntries`, `.usage`
- **`Usage`** — `init(input:output:metadata:)`, `.input`, `.output`, `.metadata`, `.totalTokenCount`;
  `Usage.Input` has `.totalTokenCount` / `.cachedTokenCount`; `Usage.Output` has `.totalTokenCount` /
  `.reasoningTokenCount`

Two useful moves fall out:

**`.collect()` gives you streaming's UX and non-streaming's ergonomics.** Drive the UI from the loop,
then take the final settled value:

```swift prelude:guide-context
let stream = session.streamResponse(to: prompt, generating: Itinerary.self)
for try await snapshot in stream {
    self.partial = snapshot.content        // drive the UI
}
let final = try await stream.collect()      // the completed result
```

`.collect()` is verified to exist with that documented meaning, and its
declaration is ✅ **SDK-verified**: `nonisolated(nonsending) func collect() async throws ->
sending Response<Content>` (`FoundationModels-27.0-macos.swiftinterface:2208`). Whether it may
be called after manual iteration was a 🔴 GAP; it is now measured. ✅ **Probe-verified,
2026-07-31** (`probes/` `fm.collect-after-iteration`, run on the 27.0 sim runtime) — **calling
`collect()` after fully iterating the stream succeeds and returns the complete response** (13
manual iterations, then `collect()` returned the full 51-character content). You can do both, as
the snippet above does. The docs still do not say so; if you want belt-and-braces, keeping the
last snapshot's `.content` remains harmless.

**`Snapshot.usage` lets you meter mid-stream.** On a per-token-billed third-party backend, that is
how you implement a spend cap without waiting for the response to finish.

Apple's own SwiftUI streaming sample, ✅ **VERIFIED verbatim** — *including the syntax errors Apple
shipped in it*, reproduced here unaltered so you recognise it if you find it:

```swift illustrative
@Generable struct Person: Equatable {
    var id: GenerationID
    var name: String
}

struct PeopleView: View {
    @State private var session = LanguageModelSession()
    @State private var people = [Person.PartiallyGenerated]()

    var body: some View {
        // A person's name changes as the response is generated,
        // and two people can have the same name, so it is not suitable
        // for use as an id.
        //
        // `GenerationID` receives special treatment and is guaranteed
        // to be both present and stable.
        List {
            ForEach(people) { person in
                Text("Name: \(person.name)")
            }
        }
        .task {
            do {
                for try! await people in stream.streamResponse(
                    to: "Who were the first 3 presidents of the US?",
                    generating: [Person].self
                ) {
                    withAnimation {
                        self.people = people
                }
            } catch {
                // Handle the thrown error.
            }
        }
    }
}
```

⚠️ That snippet has unbalanced braces, a stray `try!` inside `for try! await`, an undefined
`stream`, and iterates the stream *as if* the element were the content rather than a `Snapshot`. It
is on Apple's documentation site in that state. **Do not copy it.** Use the corrected form below.

### 9.4 A streaming view that compiles

```swift prelude:guide-context
import SwiftUI
import FoundationModels

@Generable
struct Person: Equatable {
    var id: GenerationID
    var name: String
    @Guide(description: "One sentence on why they are notable.")
    var note: String
}

@MainActor
@Observable
final class PeopleModel {
    private(set) var people: [Person.PartiallyGenerated] = []
    private(set) var failure: String?
    private let session = LanguageModelSession()

    var isResponding: Bool { session.isResponding }

    func load() async {
        failure = nil
        let stream = session.streamResponse(
            to: "Who were the first 3 presidents of the US?",
            generating: [Person].self
        )
        do {
            for try await snapshot in stream {
                people = snapshot.content
            }
        } catch let error as LanguageModelError {
            failure = "Model error: \(error)"
        } catch let error as LanguageModelSession.Error {
            failure = "Session misuse: \(error)"
        } catch {
            failure = "\(error)"
        }
    }
}

struct PeopleView: View {
    @State private var model = PeopleModel()

    var body: some View {
        List {
            ForEach(model.people) { person in
                VStack(alignment: .leading) {
                    if let name = person.name { Text(name).font(.headline) }
                    if let note = person.note { Text(note).font(.subheadline) }
                }
            }
        }
        .animation(.default, value: model.people)
        .overlay { if let failure = model.failure { Text(failure) } }
        .task { await model.load() }
        .disabled(model.isResponding)
    }
}
```

🟡 **RECONSTRUCTED as a composite**, from verified parts: `streamResponse(to:generating:)` and
snapshot assignment (code-along); `GenerationID` for `ForEach` identity and the `[Person].self` root
(Apple docs); the three-way `catch` ladder (verbatim from an Apple Frameworks Engineer, forum thread
831404 — see §11); `session.isResponding` and the `.disabled` idiom (Apple docs, verbatim example).
The loop shape itself — `for try await partial in stream { … partial.content … }`, where
`partial.content` is the partially-generated projection with every field `Optional` — is
✅ **VERIFIED** in compiling Apple code at `Origami/Brainstorm/BrainstormModel.swift:103-124` and
`Origami/Coach/CoachModel.swift:58-73`.

Points of technique:

- **`if let` on every property, at every level.** "you have to do the same for every single
  property" — the code-along presenter gives up doing it by hand on camera and pastes the finished
  file (lines 636–668). It is genuinely tedious. Keep the `@Generable` type shallow enough that it
  is not.
- **`.animation(_:value:)` on the container**, not `withAnimation` inside the loop. Snapshots can
  arrive several times per second; animating each assignment individually fights itself. This
  requires `Person: Equatable`, which is why Apple's sample declares it.
- **`.disabled(session.isResponding)`.** Apple is unusually blunt about this:
  > "**IMPORTANT** — You should not call any of the respond methods while this property is `true`.
  > Disable buttons and other interactions to prevent users from submitting a second prompt while
  > the model is responding to their first prompt." ✅ **VERIFIED** verbatim.
  >
  > A second concurrent call throws `LanguageModelSession.Error.concurrentRequests` ("Multiple
  > requests were made to the session concurrently") — ✅ **VERIFIED**, iOS 27.
- **Reveal *n* − 1 items while streaming, all *n* at the end.** Apple's Origami sample keeps the
  in-progress element hidden so its text does not visibly grow, and only reveals an item once the
  model has moved on to the next one (✅ **VERIFIED** verbatim,
  `Origami/Brainstorm/BrainstormModel.swift:120-123`):
  ```swift prelude:guide-context
  // When the model starts a new idea, all earlier ones are
  // finalized — reveal those, but keep the in-progress one hidden
  // so its text doesn't grow visibly midstream.
  completedNewIdeasCount = max(completedNewIdeasCount, newIdeas.count - 1)
  ```
  This is the polish move for arrays of structured items. Streaming a *paragraph* character by
  character reads as generative; streaming a *card in a list* whose title reflows three times reads
  as broken. Note that Apple wrote `max(_:_:)` rather than a plain assignment, which makes the
  revealed count monotonic; why that is necessary is not explained in the sample, but copying it
  costs nothing and guarantees rows never disappear mid-stream.

### 9.5 ⚠️ Do not stream in the background

> **IMPORTANT** — If running in the background, use the non-streaming `respond(to:options:)` method
> to reduce the likelihood of encountering `LanguageModelError.rateLimited(_:)` errors.
>
> — ✅ **VERIFIED** verbatim, from the doc page for
> `streamResponse(to:generating:includeSchemaInPrompt:options:)`.

This is easy to violate accidentally: a `.task` on a view that stays alive when the app is
backgrounded keeps iterating, and you get rate-limited rather than paused. Branch on scene phase and
use `respond` for anything that can run without a visible UI.

### 9.6 ⚠️ A stream can finish having yielded zero snapshots

> ## ⚠️ SILENT FAILURE
>
> **`for try await … in stream { }` can complete without the body ever executing.** The most common
> cause: the model's whole turn was a **tool call**, so there was no assistant text and no partial
> object to snapshot. Nothing throws. The stream simply ends.
>
> Any UI that shows a spinner and hides it *on the first snapshot* hangs forever. Any code that
> reads a `var latest: T?` after the loop and force-unwraps it crashes. Any state machine that
> transitions out of `.loading` only from inside the loop body never leaves `.loading`.
>
> **Drive the terminal state from the loop's completion, not from its first iteration.**

This is not a hypothesis. Apple handles it explicitly, with a comment naming the cause —
✅ **VERIFIED** verbatim, `Origami/Coach/CoachModel.swift:58-73`:

```swift prelude:guide-context
func processStream(_ stream: LanguageModelSession.ResponseStream<String>) async throws {
    state = .loading
    var accumulated = ""
    var didReceivePartial = false
    for try await partial in stream {
        didReceivePartial = true
        accumulated = partial.content
        state = .responded(accumulated)
    }
    // If the stream finished without ever yielding text (for example, the model
    // only returned a tool call), land on `.responded("")` so the UI
    // exits the loading state and the follow-up field returns.
    if !didReceivePartial {
        state = .responded("")
    }
}
```

The `didReceivePartial` flag is the whole pattern, and it generalises past the free-text case:

```swift prelude:guide-context
func load() async {
    state = .loading
    var latest: Itinerary.PartiallyGenerated?

    let stream = session.streamResponse(to: prompt, generating: Itinerary.self)
    do {
        for try await snapshot in stream {
            latest = snapshot.content
            state = .streaming(snapshot.content)
        }
    } catch is CancellationError {
        state = .idle                       // cancellation is an outcome, not a failure
        return
    } catch {
        state = .failed(error)              // §11.1 for the type ladder
        return
    }

    // Reached on *every* successful completion, including the zero-snapshot one.
    state = latest.map(State.finished) ?? .finished(nil)
}
```

Three rules fall out, and they are cheap:

1. **Set the terminal state after the loop, unconditionally.** Not in the last iteration — there may
   not be one.
2. **Never make the spinner's dismissal conditional on a snapshot.** Bind it to `session.isResponding`
   or to your own post-loop assignment.
3. **Treat `CancellationError` as a separate, non-error outcome.** Origami does this at eight
   distinct call sites, always as `catch is CancellationError` *before* the general `catch`
   (✅ **VERIFIED**, `Origami/Models/Orchestrator.swift:353, 374, 396, 415, 439, 453, 624, 652`) — a
   user tapping "stop" is not a failure to display.

⚠️ Note the interaction with tools. A tool-only turn is *normal* in an agentic session: the model
calls your tool, your tool returns a string, and the framework may resolve the turn without producing
prose. Guides that stream a chat transcript hit this the moment a tool enters the picture. See
[`03-tools-and-tool-calling.md`](03-tools-and-tool-calling.md).

🔴 **GAP:** whether a tool-only turn is the *only* way to get a zero-snapshot stream is unverified —
Apple's comment says "for example", which implies others. **What would resolve it:** an empty-response
or immediately-guardrailed request on device, instrumented with the same `didReceivePartial` counter.
Write the defensive code regardless; it is four lines.

### 9.7 Transcript timing and cancellation

- **Breaking out of the loop early** cancels the request; that is standard `AsyncSequence` behaviour
  and the framework's Swift-concurrency contract. What it leaves behind was a 🔴 GAP and is now
  measured. ✅ **Probe-verified, 2026-07-31** (`probes/` `fm.stream-early-break`, run on the 27.0
  sim runtime) — after an early `break` (2 partials in), **a partial `.response` entry IS present in
  `session.transcript`** (`entries=[prompt,response]`) **and `session.isResponding` remains `true`**
  at least 500 ms later. Treat a broken-out session as still busy: do not issue a follow-up `respond`
  on it without checking `isResponding`, and do not assume the transcript ends cleanly at the prompt.
- The Python SDK's equivalent states *"The session transcript is updated only after streaming
  completes"* (✅ **VERIFIED** from its docstring). The Swift measurement above shows that after an
  early break the partial entry has already landed — so do not carry the Python docstring's mental
  model over to Swift's cancellation path.
- Related and verified for Swift: `TranscriptErrorHandlingPolicy` (iOS 27) with
  `.preserveTranscript` and `.revertTranscript`, and Apple's note that **"When preserving the
  transcript, the last entry may be partially generated."** ✅ **VERIFIED**. That is the framework
  telling you a half-finished structured object can end up in your history.

---

## 10. Token economics: `includeSchemaInPrompt`

Every `@Generable` type you name in a request is serialised to JSON Schema and put in the prompt.
That is the "prompt channel" of §5.4. `includeSchemaInPrompt: false` turns it off.

### 10.1 The measured effect

From Apple's own Instruments walkthrough of the code-along app — a five-property nested `Itinerary`
type, one tool, and a one-shot example in the prompt:

| Metric | Before | After |
|---|---|---|
| Max token count | **1044** | **700** |
| Asset loading | ~700 ms *inside* the session, blocking first token | *before* the session (via `prewarm()`) |

✅ **VERIFIED** as Apple-published, code-along lines 897 and 979–987. ⚠️ **Attribution caveat:** the
transcript states no device model, OS build, Xcode version, or date beyond "macOS Tahoe and Xcode
26" as the code-along's stated baseline. Treat 1044→700 as *Apple's demo on unspecified hardware*,
not as a benchmark. The reusable claim is the shape: **roughly a third of the token budget of a
modest structured request was the schema.**

Apple's documentation puts the same claim in generic terms:

> Excluding the schema removes redundant schema information and **can save hundreds of tokens per
> request.**
>
> ✅ **VERIFIED** verbatim from *Analyzing the runtime performance of your Foundation Models app*;
> the direct Apple Markdown response and its SHA-256 are preserved in the
> [2026-09-22 evidence note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/web/apple-foundation-models-runtime-performance-2026-09-22.md).

And the token budget counts everything:

> "**this token count includes everything we've added into the session. This includes your
> instructions, your prompts, your tools. It includes the generables with the itinerary, all of
> it.**" — ✅ **VERIFIED**, code-along lines 895–901.

### 10.2 The precondition — and the silent failure if you break it

> ## ⚠️ SILENT FAILURE
>
> `includeSchemaInPrompt: false` **without a fully-populated `@Generable` instance in the prompt**
> removes the model's only description of what you want, while leaving the grammar in place. You
> still get a structurally valid object. You get a *worse* one — wrong emphasis, empty-ish strings,
> arrays padded to satisfy the grammar. Nothing throws, no warning appears, and the regression is
> invisible unless you are measuring quality.

Apple's rule, verbatim:

> Consider using the default value of `true` for `includeSchemaInPrompt`. **The exception to the rule
> is when the model has knowledge about the expected response format, either because it has been
> trained on it, or because it has seen exhaustive examples during this session.**
>
> ✅ **VERIFIED** verbatim from the doc page.

And the code-along's version of the same rule, with the mechanism:

> "because **our one-shot example is quite detailed, the full schema definition in the prompt is
> redundant. We can remove it by setting `includeSchemaInPrompt` to `false`.**"
>
> ✅ **VERIFIED**, lines 918–921.

Chain it back to §2.1: embedding an *instance* of a `@Generable` type in a `Prompt { }` "**not only
does it include all the guidance, but also the schema that's part of this prompt now**" (lines
570–572). The instance *is* the schema, expressed by example. That is what makes the exclusion safe.

The safe pattern, ✅ **VERIFIED** as to shape from code-along lines 542–556 and 2020–2028:

```swift prelude:guide-context
let prompt = Prompt {
    "Generate a 3-day itinerary to Grand Canyon."
    if kidFriendly {
        "The itinerary must be kid-friendly."
    }
    "Here is an example of the desired format, but don't copy its content."
    Itinerary.exampleTripToJapan          // the golden example — carries the schema implicitly
}

let stream = session.streamResponse(
    to: prompt,
    generating: Itinerary.self,
    includeSchemaInPrompt: false,          // safe *because* of the line above
    options: GenerationOptions(sampling: .greedy)
)
```

🟡 The **parameter order** here is reconstructed: the presenter describes adding
`includeSchemaInPrompt` after the other arguments, while the verified declaration in §9.1 places it
third. The declaration wins; the code above follows it.

Apple's own framing of what the one-shot example adds, on top of structure:

> "**While `@Generable` enforces the structure, the one-shot example teaches the model about
> relationship and the style within the structure… While the difference in output may not always be
> dramatic, it's an important way to significantly improve the quality of your generated content.**"
>
> ✅ **VERIFIED**, code-along lines 584–586. Note Apple's own hedge in that quote.

### 10.3 Reducing schema cost without turning it off

Apple's four levers, ✅ **VERIFIED** verbatim from the `Generable` page and repeated in §2.6:
fewer properties; shorter property names; `description:` only where it demonstrably helps;
`maximumCount(_:)` on arrays.

That last one is non-obvious: a `maximumCount` reduces tokens **in the response**, because it caps
how much the grammar will let the model emit. It is the only guide that pays for itself twice.

A concrete illustration of the naming lever, from Apple's tokenisation note:

> the word `Sourdough` might be one token, but a phone number like `+1-(408)-555-0123` might use
> **over ten tokens** because of the characters and symbols.
>
> ✅ **VERIFIED** verbatim.

Property names like `primaryDestinationDisplayName` are not free; `destination` is. And since
`x-order` preserves declaration order, renaming is safe — it is the *name*, not the position, that
the grammar keys on.

---

## 11. Failure taxonomy for structured output

The errors you will actually see, and which are which.

### 11.1 The three-error ladder

Verbatim code from an Apple Frameworks Engineer, forum thread 831404 (✅ **VERIFIED** as a quotation
of Apple's own reply):

```swift compile:27 imports:FoundationModels
let session = LanguageModelSession()
let stream = session.streamResponse(to: "Tell me about origami.")

do {
    for try await partialResponse in stream {

    }
} catch let error as LanguageModelError {

} catch let error as LanguageModelSession.Error {

} catch let error as LanguageModelSession.GenerationError {
   // Deprecated in 27.0
} catch {

}
```

Three distinct error types, plus a catch-all. The split is by *whose fault it is*:

| Type | Availability | Means |
|---|---|---|
| `SystemLanguageModel.Error` | iOS 27.0 | the **on-device assets** are the problem — check **first** |
| `LanguageModelError` | iOS 27.0 | the **model** failed or refused |
| `GeneratedContent.ParsingError` | iOS 26.0 | the model's output **could not be read** into your type (§8.3) |
| `LanguageModelSession.Error` | iOS 27.0 | **you** misused the session |
| `LanguageModelSession.GenerationError` | iOS 26.0, **deprecated 27.0** | the old undifferentiated enum |
| `LanguageModelSession.ToolCallError` | iOS 26.0 | your **tool** threw |

**Ordering matters, and Apple's own code puts `SystemLanguageModel.Error` first.** Availability
failures are a *different type* from generation failures — they are not a `LanguageModelError` case —
so a ladder that tests `LanguageModelError` first will let them fall through to your generic `catch`
and report "something went wrong" for a device that simply has Apple Intelligence turned off.
✅ **VERIFIED** from `Origami/Models/Error+DisplayMessage.swift:12-36`, which is the most complete
first-party statement of this taxonomy in existence:

```swift compile:27 imports:FoundationModels
extension Error {
    /// A short message describing the error, suitable for display in the UI.
    var displayMessage: String {
        if self is SystemLanguageModel.Error {
            return "Apple Intelligence isn't available right now."
        }
        if let modelError = self as? LanguageModelError {
            switch modelError {
            case .timeout:
                return "This is taking longer than expected. Please try again."
            case .guardrailViolation, .refusal:
                return "Origami can't work with that. Try a different photo or prompt."
            case .contextSizeExceeded:
                return "There's too much in this conversation. Try regenerating to start fresh."
            case .unsupportedLanguageOrLocale:
                return "Origami doesn't support this language."
            default:
                break
            }
        }
        if self is GeneratedContent.ParsingError {
            return "Origami had trouble understanding the response. Please try again."
        }
        return "Something went wrong. Please try again."
    }
}
```

Three things to take from it beyond the ordering. **`LanguageModelError` is non-frozen** — the
`default: break` is mandatory, and a `switch` without one stops compiling when Apple adds a case.
The cases are matched **without binding their associated values**, which is legal and keeps the
switch readable. And note what is *absent*: Origami never calls `SystemLanguageModel.availability`
and never gates its UI on model readiness — Apple's 2026 samples handle the
Apple-Intelligence-disabled path **reactively**, by catching `SystemLanguageModel.Error` at use time.
Guide 6 argues you should still do both; see
[`06-availability-errors-and-guardrails.md`](06-availability-errors-and-guardrails.md).

⚠️ `LanguageModelSession.Error` appears in the doc harvest and in Apple's forum snippet above but is
**used by no shipping sample**. Keep it in the ladder — it costs one line — but do not treat its
case list as settled.

### 11.2 The cases that hit structured output specifically

From `LanguageModelError` (✅ **VERIFIED**, all nine cases and Apple's descriptions are on the doc
page):

| Case | Structured-output relevance | Seen in a sample? |
|---|---|---|
| `.unsupportedGenerationGuide(_:)` | a guide illegal for that property type (§3.3) | no |
| `.unsupportedCapability(_:)` | the backend cannot do guided generation at all (§6) | no |
| `.contextSizeExceeded(_:)` | your schema plus instructions plus transcript blew the window (§10) | ✅ |
| `.guardrailViolation(_:)` | safety tripped on prompt or response | ✅ |
| `.refusal(_:)` | the **model** declined — distinct from a guardrail | ✅ |
| `.timeout` | the request took too long — a *retryable* outcome, unlike the two above | ✅ |
| `.unsupportedLanguageOrLocale` | the user's language is not supported | ✅ |
| `.rateLimited(_:)` | streaming in the background (§9.5) | no |

The "seen in a sample" column is the difference between a name harvested from a documentation index
and a name that compiles. The five ticked cases are ✅ **VERIFIED** from Origami's
`Error+DisplayMessage.swift` and independently from the Spotlight sample, which ships a near-identical
file. The three unticked ones come from the doc page only. The enum is **non-frozen**, so this table
is a floor, not a census.

From `LanguageModelSession.Error`: `.concurrentRequests`, `.transcriptMutationWhileResponding` —
both non-payload cases, unlike their iOS 26 predecessors. ✅ **VERIFIED** from the doc page; no
sample exercises them.

From `GenerationSchema.SchemaError`: the four cases in §7.1, thrown at schema-construction time
rather than generation time.

### 11.3 `permissiveContentTransformations` and `@Generable`: a contested claim

`SystemLanguageModel.Guardrails` has exactly two documented members — `static let default` and
`static let permissiveContentTransformations` (✅ **VERIFIED** from
`/documentation/foundationmodels/systemlanguagemodel/guardrails`), and the permissive one is
described as *"Guardrails that allow for permissively transforming text input, including potentially
unsafe content, **to text responses**."* That phrase is why developers read it as text-only.

One of them said so in a forum thread answered by an Apple Frameworks Engineer:

```swift compile:27 imports:FoundationModels
LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations))
// I'm aware that .permissiveContentTransformations does not apply to Generable, but I'd really
// really really really love it, if it did!
```

✅ **VERIFIED** verbatim as a quotation (developer code plus their own comment, forum thread 835777).
Note what is verified: that a developer *believes* this. Apple did not confirm it in the thread.

**Apple's own macOS 27 sample pairs the two anyway.** Book Tracker's tagging feature — the feature
its entire evaluation suite is built around — constructs a permissive-guardrail model and immediately
makes a guided-generation request against it:

```swift prelude:guide-context
let session = LanguageModelSession(
    model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
    instructions: instructions
)
let response = try await session.respond(to: prompt, generating: BookTags.self)
```

✅ **VERIFIED** verbatim, `BookTracker/Services/BookTaggingService.swift:13-45`. Book reviews contain
violence, sexual content and profanity in summary form, which is exactly the false-positive class the
permissive guardrails exist for — so this is a deliberate pairing, not an oversight.

🔴 **GAP.** These two pieces of evidence cannot both be fully right, and the corpus does not settle
it. Either the permissive guardrails *do* affect `@Generable` requests and the forum developer was
mistaken, or Apple's own sample carries a no-op. Shipping first-party sample code outranks a
developer's aside in this series' precedence order, so **do not treat "permissive guardrails are
useless with `@Generable`" as settled fact** — the earlier editions of this guide did, and that was
too strong. **What would resolve it:** a device test that trips a guardrail false positive on a
`@Generable` request under both guardrail settings and compares. The 2026-08-20 device run below
completed but its stimulus did not reproduce the false positive, so the missing piece is now a
prompt that reliably trips one on device. Meanwhile, try it — it
is one initializer argument — but budget for it not helping, and do not build a schedule around it.
Full guardrail treatment in
[`06-availability-errors-and-guardrails.md`](06-availability-errors-and-guardrails.md).

> 🟠 **Device run completed, stimulus did not reproduce.** The Simulator comparison threw
> guardrail code 2 under both settings. On iPhone 15 Pro / iOS build `24A5408d`, the same two
> requests both succeeded. That removes the destination blocker but does not isolate the setting;
> resolving the gap now needs a prompt that reliably trips the same false positive on device.

### 11.4 Determinism when you are testing structured output

> "**Greedy sampling tells the model to stop being creative and to always pick the most obvious next
> token. This makes the model's output deterministic.**" — ✅ **VERIFIED**, code-along lines 696–702.

```swift illustrative
options: GenerationOptions(sampling: .greedy)
```

"**By default, it does random sampling**" (line 836). For any test that asserts on a specific
generated value — a classification enum, an `.anyOf` field, a tool being called — set `.greedy` or
your test is a coin flip.

Note this interacts with §5.1: greedy sampling picks the argmax **of the masked logits**. Constrained
decoding and greedy sampling compose cleanly; the mask is applied first.

---

## 12. The Python SDK's parallel surface

`apple/python-apple-fm-sdk` ships the same concepts with Python spellings. Useful if you are
building evaluation pipelines in a notebook (see
[`../../part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md`](../../part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md)),
and useful even if you are not — the SDK is a thin binding over the same runtime, so its test suite
is evidence about framework behaviour (that is where §3.3's matrix came from).

**Requirements**, ✅ **VERIFIED** from the repo README: **macOS 26.0+** (note: *not* 27),
Xcode 26.0+ **and you must open Xcode once and accept the SDKs agreement**, Python 3.10+, Apple
Silicon, Apple Intelligence enabled.

### 12.1 `@fm.generable` and `fm.guide`

✅ **VERIFIED** verbatim from the repo README (lines 78–101):

```python
import apple_fm_sdk as fm

@fm.generable # This decorator signals this type be generated by a model
class Cat:
    name: str
    age:int = fm.guide("Age in years", range=(0, 20))

async def generate_cat():
    model = fm.SystemLanguageModel()

    is_available, reason = model.is_available()
    if is_available:
        session = fm.LanguageModelSession()
        cat = await session.respond("Generate an adorable rescue cat", generating=Cat)
        print(f"Model response: {cat}")
    else:
        print(f"Foundation Models not available: {reason}")
```

The mapping:

| Swift | Python |
|---|---|
| `@Generable struct Cat { … }` | `@fm.generable` on a class with annotated fields |
| `@Guide(description: "…", .range(0...20)) var age: Int` | `age: int = fm.guide("Age in years", range=(0, 20))` |
| `try await session.respond(to:generating:)` | `await session.respond(prompt, generating=Cat)` |
| `SystemLanguageModel.default` | `fm.SystemLanguageModel()` |
| `model.availability` → enum | `model.is_available()` → `(bool, reason)` |

Note the structural difference in `fm.guide`: it is **a default value**, not an attribute. It returns
`dataclasses.field(metadata={"description": …, "guides": [...]})`. ✅ **VERIFIED** from
`generation_guide.py`. Three consequences:

- `@fm.generable` wraps the class in `@dataclass` if it is not one already, and normal dataclass
  field-ordering rules apply — a guided field with no default cannot follow a defaulted field.
- The decorator accepts three call forms: `@fm.generable`, `@fm.generable()`,
  `@fm.generable("description")`. ✅ **VERIFIED**.
- ⚠️ **`@fm.generable("description")`'s description is silently dropped.** The decorator stores it as
  `cls._generable_description` and `generation_schema()` never reads it, so the emitted schema's
  root description is always `None`. ✅ **VERIFIED** by source reading plus a repo-wide grep showing
  the attribute has exactly two references: its declaration and its assignment. Field-level
  descriptions from `fm.guide("…")` **do** flow through. Swift's `@Generable(description:)` does
  carry through (the exported `cat.json` fixture has a root `"description"`), so this is a
  Python-only regression.

`fm.guide`'s full signature, ✅ **VERIFIED** from `generation_guide.py`:

```python
def guide(
    description: Optional[str] = None, *,
    anyOf: Optional[List[str]] = None,
    constant: Optional[str] = None,
    count: Optional[int] = None,
    element: Optional["GenerationGuide"] = None,
    max_items: Optional[int] = None,
    maximum: Optional[Union[int, float]] = None,
    min_items: Optional[int] = None,
    minimum: Optional[Union[int, float]] = None,
    range: Optional[tuple] = None,
    regex: Optional[str] = None,
) -> Any
```

Name mapping to Swift: `max_items` → `.maximumCount`, `min_items` → `.minimumCount`, `regex` →
`.pattern`, `anyOf` → `.anyOf`. `range` takes a **tuple**, e.g. `range=(0, 20)`, not a Swift range.

### 12.2 The separate JSON-Schema path

Distinct from `generating=`, and this is the part with no direct Swift equivalent in the corpus:

```python
import json, apple_fm_sdk as fm

with open("tests/tester_schemas/hedgehog.json") as f:
    schema = json.load(f)

session = fm.LanguageModelSession(model=model)
generated_content = await session.respond(
    "Generate a very old hedgehog who likes to dance",
    json_schema=schema)                      # -> fm.GeneratedContent

name = generated_content.value(str, for_property="name")
```

✅ **VERIFIED** from the SDK docs. Under the hood, Swift does
`JSONDecoder().decode(GenerationSchema.self, from: Data(jsonSchemaString.utf8))` — i.e. it
reconstructs a real `GenerationSchema` from the JSON. That is the same `Codable` conformance from
§7.5, used in reverse.

`tests/test_json_guided_generation.py` exercises seven fixtures, and the list doubles as a coverage
map of the dialect (✅ **VERIFIED**): `age.json` (basic integers, strict), `cat.json` (`$defs`/`$ref`),
`hedgehog.json` (min/max, enum, size-limited arrays), `person.json` (recursive `$ref: "#"`, optional
properties, `maxItems`), `shelter.json` (arrays of complex objects, multi-level `$defs`),
`petClub.json` (multiple entity types), `newsletter.json` (optional complex objects and arrays).

The **schema-beats-prompt** assertion cited in §5.1 lives here: `person.json` has `maxItems: 3`, the
prompt asks for five children, `len(children) == 3`.

The `respond` dispatch, ✅ **VERIFIED** from `session.py`:

```python
generating=Cls        -> an instance of Cls
schema=GenerationSchema -> GeneratedContent
json_schema=dict      -> GeneratedContent
```

and `generating` + `schema` together raises
`ValueError("Cannot specify both 'generating' and 'schema' arguments")`.

### 12.3 ⚠️ Three Python-side silent failures

> ## ⚠️ SILENT FAILURE
>
> **1. `options=` is ignored when you pass `generating=`.** The typed guided path drops the argument
> on the floor: temperature, sampling mode and max-tokens have **no effect** on a
> `session.respond(..., generating=Cls, options=...)` call. ✅ **VERIFIED** by source reading at
> `session.py:473`. Your "deterministic" Python eval run is not deterministic.
>
> **2. `x: str | None` is not detected as optional.** Optionality is decided by
> `is_optional = "Optional" in str(self.type_class)` — literal string sniffing. On Python ≤3.13,
> `str(int | None)` is `'int | None'`, which fails the test; the type name also falls through to the
> literal string `'int | None'`, which Swift then treats as a *reference to a schema type named
> `int | None`* → schema build failure. ✅ **VERIFIED** by source reading plus measured
> `str()` output on CPython 3.11–3.14. **Always write `typing.Optional[X]`.**
>
> **3. On Python 3.14, even `Optional[X]` stops being optional.** `str(Optional[int])` became
> `'int | None'` in 3.14, so the same sniff fails and every property becomes required. 3.14 is not
> in the package classifiers but *is* allowed by `requires-python = ">=3.10"`. ✅ **VERIFIED** for
> the string comparison; 🟡 the end-to-end consequence is inferred, not run.

### 12.4 Streaming is text-only in Python

```python
async def stream_response(self, prompt, options=None) -> AsyncIterator
```

Its own docstring, ✅ **VERIFIED**:

> - Yields complete text **snapshots (not deltas)** as generation progresses
> - **Does not support guided generation (text responses only)**
> - Can be cancelled mid-stream using asyncio cancellation
> - "The session transcript is updated only after streaming completes"

So the snapshot semantics carry over, but `PartiallyGenerated` does not. The SDK *does* synthesise a
`{Cls}PartiallyGenerated` companion dataclass with every field `Optional[...]` and a
`GenerationID`-defaulted `id` — and **nothing ever constructs one**. ✅ **VERIFIED** by source
reading. It is unwired plumbing, presumably awaiting a typed-streaming implementation. Do not build
on it.

⚠️ Also verified by source reading: `stream_response` does **not** acquire the SDK's
`self._request_lock`, so a stream and a `respond()` can overlap on one session — the Python
equivalent of the `concurrentRequests` hazard, without the error.

---

## 13. Checklists and decision tables

### 13.1 Which constraint mechanism?

| Situation | Use | Why |
|---|---|---|
| Fixed set, known at compile time | `@Generable enum` | Cheapest; no runtime array to keep in sync. Still validate — §4.6. |
| Set known at runtime, shape fixed | `@Guide(.anyOf(...))` on `String` | Only option at the macro level. **Validate the result.** |
| Both shape *and* set known only at runtime | `DynamicGenerationSchema` → `GenerationSchema` | The `schema:` overloads; you get `GeneratedContent` back. |
| Schema comes from outside Swift | `JSONDecoder().decode(GenerationSchema.self, …)` | `GenerationSchema` is `Codable` over the dialect in §7.5. |
| Numeric bound | `.range(_:)` / `.minimum(_:)` / `.maximum(_:)` | Real JSON-Schema keywords; no reported defects. |
| Array size | `.count` / `.minimumCount` / `.maximumCount` | Also reduces response tokens. |
| Per-element constraint | `.element(_:)` | Wraps another guide; how `[String]` + `anyOf` works. |
| String shape | `.pattern(_:)` | Simple patterns only on `SystemLanguageModel` (§3.5). |
| Output must name one of *my input images* | `ImageReference` property + `Attachment(_:).label(_:)` | The join key is yours, not prose (§2.7). iOS 27.0+. |

### 13.2 Pre-ship checklist for any `@Generable` feature

- [ ] Every `.anyOf`-guided value is validated at the boundary; the `default:` case throws.
- [ ] Every `@Generable enum` read has a `default:` / `@unknown default:` that is not `fatalError`.
- [ ] `Tool.parameters` is not computed from data that loads after session init (§4.3).
- [ ] The schema is dumped once with `JSONEncoder().encode(T.generationSchema)` and read by a human.
- [ ] `description:` appears only on properties where removing it measurably hurt.
- [ ] Arrays carry a `maximumCount`.
- [ ] `includeSchemaInPrompt: false` appears **only** alongside a populated instance in the prompt.
- [ ] Tests that assert on generated values set `GenerationOptions(sampling: .greedy)`.
- [ ] Streaming code is disabled or switched to `respond` when the app is backgrounded.
- [ ] **The terminal UI state is set after the stream loop, not inside it** — a stream can yield zero
      snapshots (§9.6).
- [ ] `catch is CancellationError` precedes the general `catch` on every streaming call site (§9.6).
- [ ] `.disabled(session.isResponding)` guards every button that starts a request.
- [ ] The error handling checks `SystemLanguageModel.Error` **first**, then `LanguageModelError`
      (with a `default:`, it is non-frozen), then `GeneratedContent.ParsingError`, then a generic
      `catch` — and has been re-read since the switch to Xcode 27 (§3.4, §11.1).
- [ ] Every `ImageReference` lookup handles the miss case — `.attachmentLabel` is a model-generated
      string like any other (§2.7).
- [ ] If a non-system backend is reachable, `capabilities.contains(.guidedGeneration)` is checked
      before the feature is offered (§6).
- [ ] Nothing persists or diffs a `GenerationID` across responses.
- [ ] The constraint that actually matters is **also measured**, not just guided — Apple's own sample
      states its 3–8 range in the guide, in the instructions, and in an evaluator (§4.8).

### 13.3 Debugging a structured-output problem

1. **Dump the schema.** `print(try String(data: JSONEncoder().encode(T.generationSchema), encoding: .utf8)!)`.
   Confirm the keywords you expect are actually there — `enum`, `minItems`, `pattern`.
2. **Check `x-order`.** If your UI shows nothing for a second, the interesting fields may be at the
   bottom of the struct.
3. **Set `.greedy`** and re-run. If the failure becomes deterministic, it is a prompt/schema problem;
   if it stays intermittent, it is a sampling-boundary problem.
4. **Turn `includeSchemaInPrompt` back on.** If quality returns, you removed the prompt channel
   without a one-shot example (§10.2).
5. **Print `response.rawContent.jsonString`.** The `GeneratedContent` shows exactly what the model
   emitted before decoding.
6. **Profile with the Foundation Models instrument.** Long-press Run → Profile → Blank template →
   `+` → "Foundation Models". The detail pane shows max token count. ✅ **VERIFIED**, code-along
   869–901. ⚠️ Apple's warning, verbatim: a recording **"captures and stores all Foundation Models
   prompts and responses in an unencrypted form"** — handle trace files accordingly.
7. **Test on device, not the Simulator.** The Simulator punches out to the host macOS for inference,
   so an Xcode-27-SDK build on a macOS 26 host produces meaningless errors. This is documented by
   Apple staff as the single most common source of phantom reports in this framework.

---

## 14. Open gaps

Collected, so a future reader knows exactly what is unresolved and what would resolve it.

Rows struck through were closed on **2026-07-29** against the captured 27.0 beta interface
(`notes/sdk-interfaces/FoundationModels-27.0-macos.swiftinterface`); the inline sections carry the
line-numbered citations.

| # | Unknown | What would resolve it |
|---|---|---|
| 1 | `representNilExplicitlyInGeneratedContent:` **semantics** on `@Generable` — the three overloads, their floors (26.0 / 26.4 / 27.0), and the 27.0 default `= false` are now SDK-verified (§2.2) | The macro's doc page, or *Expand Macro* in Xcode 27 |
| 2 | Whether `@Generable enum` suffers the same non-enforcement as `.anyOf` (§4.6) — 🟠 20/20 aggregate clean runs across iOS 27 sim + iPhone 15 Pro, but only N=10 per destination | A 100-iteration device run with a four-case enum and adversarial prompt |
| 3 | Whether the `.anyOf` defect is fixed in iOS 27.0 — narrowed by the clean beta-5 runs above; original reproduction is iOS 26.2 | Re-run the exact thread-812501 repro at large N on device |
| 4 | Where in the pipeline the `.anyOf` constraint is lost (§5.4) | Symbol-level tracing of `TokenGenerationCore` on macOS 27 |
| 5 | Whether `SystemLanguageModel` uses `xgrammar` (§5.2) — verified only for Core AI and MLX | Symbol inspection of the shipped `FoundationModels.framework` / `TokenGenerationCore` binary |
| 6 | ~~Full declarations of the `respond(to:schema:…)` / `streamResponse(to:schema:…)` overload family~~ — **✅ RESOLVED** (§7.3): all return `Response<GeneratedContent>` / `ResponseStream<GeneratedContent>` | Resolved — 27.0 `.swiftinterface:2056-2058, :2073-2079, :2103-2111, :2147-2159` |
| 7 | ~~Whether `ResponseStream.collect()` may be called after manual iteration (§9.3)~~ — **✅ RESOLVED on sim + iPhone 15 Pro:** yes; it returns the complete response (`fm.collect-after-iteration`) | Resolved by runtime probe |
| 8 | ~~Swift cancellation semantics of a stream broken out of early, and whether a partial entry lands~~ — **✅ RESOLVED on sim + iPhone 15 Pro:** partial `.response` lands and `isResponding` remains `true` (§9.7; `fm.stream-early-break`) | Resolved by runtime probe |
| 9 | ~~`ContextOptions`' exact initializer labels (iOS 27)~~ — **✅ RESOLVED**: `init(includeSchemaInPrompt: Bool? = nil, reasoningLevel: ContextOptions.ReasoningLevel? = nil)`, both properties optional-typed | Resolved — 27.0 `.swiftinterface:3132-3135` |
| 10 | What `GenerationSchema.name` returns for an anonymous/inline schema — the declaration (`var name: String`, non-optional, 27.0) is now SDK-verified (§7.6) | The `generationschema/name` doc page, or a `print` |
| 11 | ~~Whether `GeneratedContent.ParsingError` is *specifically* the successor to `GenerationError.decodingFailure`~~ — **✅ RESOLVED**: the SDK's own deprecation message names it (§8.3) | Resolved — 27.0 `.swiftinterface:3555-3558` |
| 12 | The declared signature of the description-less `@Guide(_ guides:)` overload — the three `@Guide` macro declarations in the interface all carry `description:` first (`@Guide(description: String? = nil, _ guides: GenerationGuide<T>...)`, `:1142, :1145, :1148`), so the "description-less" call form works because `description:` has a default | The macro's doc page |
| 13 | Whether `.permissiveContentTransformations` affects a `@Generable` request. Simulator blocked both settings; iPhone 15 Pro succeeded under both, so neither run isolated the knob (§11.3) | A device prompt that reliably trips a guardrail false positive, under both settings |
| 14 | Whether a tool-only turn is the *only* cause of a zero-snapshot stream — Apple's comment says "for example" (§9.6) | An instrumented empty-response or guardrailed request on device |
| 15 | Whether `LanguageModelSession.Error` is real in practice — its two cases are SDK-verified (`:2026-2034`), but it is used by no shipping sample (§11.1) | A device repro of `.concurrentRequests` printing the concrete type |

Closed since the first edition, and recorded here so nobody re-opens them: whether `count(_:)` has
both `Int` and `ClosedRange<Int>` overloads (yes — §3.2), whether a description-less `@Guide` is
usable (yes — §3.1), and what the `Attachment` → `ImageReference` round trip actually spells (§2.7).
All three were settled by reading Apple's shipping sample projects.

None of these blocks shipping. Every one of them is a place where a plausible-looking sentence could
have been written and was not.

---

## See also

- [`01-sessions-and-prompting.md`](01-sessions-and-prompting.md) — sessions, instructions vs.
  prompts, prompt builders, prewarming
- [`03-tools-and-tool-calling.md`](03-tools-and-tool-calling.md) — the `Tool` protocol, whose
  `Arguments` are `@Generable` and whose `parameters` is a `GenerationSchema`
- [`06-availability-errors-and-guardrails.md`](06-availability-errors-and-guardrails.md) — the full
  error and guardrail taxonomy
- [`../../part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md`](../../part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md)
  — the 4K budget your schema is spending
- [`../../part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md`](../../part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md)
  — **read this if §6 applies to you**
- [`../../part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md`](../../part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md)
  — declaring capabilities honestly, from the provider side
- [`../../part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md`](../../part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md)
  — the Python SDK in depth
- [`../../part-06-evaluations/references/01-foundations-and-hill-climbing.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/references/01-foundations-and-hill-climbing.md)
  — how to detect the quality regression that `includeSchemaInPrompt: false` can cause
- [`../../part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md)
  — the Core AI engines and the xgrammar layer from §5, in full
- [`../../part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md)
  — `MLXFoundationModels` and `MLXGuidedGeneration`
- [`../../part-17-migration-from-pre-ios-27/README.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md)
  — the Xcode 26 → 27 error-catching change

---

*Sources for this guide: **Apple's shipping sample projects** — Origami: Crafting a dynamic tutorial
for Apple Intelligence (iOS 27, 61 Swift files) and Book Tracker: Using Evaluations to evaluate an
intelligent feature (macOS 27, 20 Swift files), with the iOS 26 `FoundationModelsCoffeeGame` used
only where it is labelled as the 26 baseline; Apple documentation pages under
`/documentation/foundationmodels` (harvested 2026-07-27); WWDC26 session 241; Meet with Apple 205
(*Foundation Models Framework Code-Along*); Apple Developer Forums threads 811620, 812501, 831404,
835777, 837226; `apple/coreai-models`; `apple/foundation-models-utilities`;
`apple/python-apple-fm-sdk`; `ml-explore/mlx-swift-lm`; community field notes on GPU-pipelined Core
AI bundles (§6.3). Precedence when these conflicted: **compiling first-party sample code** >
SDK/source > docs > Apple-staff forum answers > transcripts > community. Every conflict encountered
is called out inline — see §11.3 for the one place a sample overturned what this guide previously
asserted.*

[^guide-macro-source]: Apple, [`Guide(description:_:)`](https://developer.apple.com/documentation/foundationmodels/guide%28description%3A_%3A%29),
    documents the macro that constrains guided-generation properties; the concrete forms below are
    cross-checked against the first-party examples cited inline.
