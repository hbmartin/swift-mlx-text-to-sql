# The complete failure taxonomy: availability, errors, guardrails and refusals

**Part 2 · Reference 06** · Series: [Apple on-device AI — a developer's guide series](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/README.md)

## What this covers

Everything that can go wrong between "I called `session.respond(to:)`" and "the user saw something
useful", organised as a taxonomy: **symptom → cause → fix**. Availability gating — proactive and
reactive, because Apple's 2026 samples quietly abandoned the first — the four error enums that
replaced one in 2026 plus the fifth error type that is in none of them, the *two distinct refusal
mechanisms* that almost everyone conflates, guardrail configuration and its documented blind spot
(which Apple's own sample code falls into), context-window overflow, the
undocumented error domains people are actually hitting in the betas, Private Cloud Compute quota
handling, and how to file a bug that Apple will act on. It ends with a complete, copyable
error-handling function.

This is the largest and longest-running pain cluster in the Apple Developer Forums — threads span
June 2025 to July 2026 with no resolution. It blocks more readers than any API gap, which is why it
sits early in Part 2 rather than at the end.

## What you need

- **Version floor.** `SystemLanguageModel`, `SystemLanguageModel.Availability`,
  `SystemLanguageModel.Guardrails`, `LanguageModelSession.GenerationError` and
  `LanguageModelSession.ToolCallError` are **iOS/iPadOS/macOS/visionOS 26.0+** (no watchOS).
  `tokenCount(for:)` is **26.4+**; `contextSize` is **26.4+** but carries
  `@backDeployed(before: iOS 26.4, macOS 26.4, visionOS 26.4)`. Everything in the 2026 error
  reshuffle — `LanguageModelError`, `LanguageModelSession.Error`, `SystemLanguageModel.Error`,
  `PrivateCloudComputeLanguageModel` and its `Error`/`QuotaUsage`, `TranscriptErrorHandlingPolicy` —
  is **27.0+** (and 27.0 is the first watchOS release for the framework).
  `LanguageModelSession.GenerationError` is **deprecated in 27.0**. `GeneratedContent.ParsingError`
  — which you also have to catch (§3.6) — is sample-confirmed but its availability line is not in
  this corpus.
- **Xcode 27** to catch the new error types at all. This is not a style preference; see §3.1.
- **A physical device on OS 27.0.** The Simulator punches out to the host macOS for inference, so an
  Xcode 27 SDK on a macOS 26 host produces meaningless errors (§7.3).

> ⚠️ **The defining property of this stack is that most defects do not throw.** A model-level
> refusal in string mode is *a normal-looking `String`*. A guardrail change ships outside the OS
> update cycle and silently starts blocking a prompt that worked yesterday. A catch ladder missing
> one arm compiles perfectly and swallows the most common failure there is. Read §3.4, §4.3 and
> §5.3 before you ship anything.

---

## Contents

1. [The five planes a request can fail on](#1-the-five-planes-a-request-can-fail-on)
2. [Availability — the gate before the gate](#2-availability--the-gate-before-the-gate)
3. [The 2026 error reshuffle: four enums where there was one](#3-the-2026-error-reshuffle-four-enums-where-there-was-one)
4. [The two refusal mechanisms](#4-the-two-refusal-mechanisms)
5. [Guardrail configuration and its blind spot](#5-guardrail-configuration-and-its-blind-spot)
6. [Context-window overflow](#6-context-window-overflow)
7. [Errors seen in the wild that are in no enum](#7-errors-seen-in-the-wild-that-are-in-no-enum)
8. [Private Cloud Compute: quota is not availability](#8-private-cloud-compute-quota-is-not-availability)
9. [How to report a bug to Apple so it gets acted on](#9-how-to-report-a-bug-to-apple-so-it-gets-acted-on)
10. [The complete graceful-degradation function](#10-the-complete-graceful-degradation-function)
11. [Quick-reference tables](#11-quick-reference-tables)

---

## 1. The five planes a request can fail on

Developers debug this stack badly because they treat "it didn't work" as one condition. It is five,
and they have different owners, different APIs, different fixes and different *timescales*.

| Plane | Question it answers | API surface | Changes on |
|---|---|---|---|
| **Availability** | Can this device/user run the model at all? | `model.availability`, `model.isAvailable`, `supportsLocale(_:)` — and, reactively, `SystemLanguageModel.Error` (§2.8) | User settings, region, OS install, asset download |
| **Session validity** | Did *I* use the session wrong? | `LanguageModelSession.Error` | Never — it's your bug |
| **Model capability** | Can this model do the thing I asked? | `LanguageModelError.unsupportedCapability`, `.unsupportedGenerationGuide`, `.unsupportedTranscriptContent`, `.unsupportedLanguageOrLocale` | Which model you passed to `init(model:)` |
| **Budget** | Did I exceed a limit? | `LanguageModelError.contextSizeExceeded`, `.rateLimited`, `.timeout`, `PrivateCloudComputeLanguageModel.Error.quotaLimitReached` | Transcript growth, user quota, thermals |
| **Safety** | Did the system, or the model, decline? | `LanguageModelError.guardrailViolation`, `LanguageModelError.refusal`, **and a plain `String`** | **Outside the OS update cycle** (§5.3) |

The last row is the one that ruins shipping apps, because it is the only plane that can change
under an app that you have not rebuilt, on a device the user has not updated.

> ✅ **VERIFIED** — the safety plane's out-of-band mutability is Apple's own statement, from
> `/documentation/foundationmodels/improving-the-safety-of-generative-model-output`:
> *"Apple may update the built-in guardrails at any time outside of the regular OS update cycle.
> This is done to rapidly respond, for example, to reported safety concerns that require a fast
> response. Include all of the prompts you use in your app in your test suite, and run tests
> regularly to identify when prompts start activating the guardrails."*

---

## 2. Availability — the gate before the gate

### 2.1 `SystemLanguageModel.Availability`, every case

> ✅ **VERIFIED** — declaration from `/documentation/foundationmodels/systemlanguagemodel`
> (harvested 2026-07-27). Availability line: `iOS 26.0+, iPadOS 26.0+, Mac Catalyst 26.0+,
> macOS 26.0+, visionOS 26.0+` — note **no watchOS**, even in 27.

```swift illustrative
@frozen enum Availability      // Equatable, Sendable, SendableMetatype
case available                 // "The system is ready for making requests."
case unavailable(_: UnavailableReason)
```

`UnavailableReason` has three documented cases: `.appleIntelligenceNotEnabled`,
`.deviceNotEligible`, `.modelNotReady`.

> ✅ **VERIFIED (SDK interface)** — now confirmed at the strongest evidence level by Apple's
> compiler-emitted `notes/sdk-interfaces/FoundationModels-26.5-macos.swiftinterface` (module 1.5.2),
> above the docs page it matches: `@frozen public enum Availability : Equatable, Sendable` with
> exactly `case available` and `case unavailable(UnavailableReason)`, wrapping a **non-frozen** nested
> `enum UnavailableReason { case deviceNotEligible; case appleIntelligenceNotEnabled; case modelNotReady }`.
> This is the **26.5** surface; the availability enum is structural and stable into 27 unless noted.
> Note the asymmetry the header makes precise: `Availability` is `@frozen` (its two cases are fixed
> forever) but `UnavailableReason` is **not** frozen — which is exactly why the `@unknown default`
> arm below is mandatory rather than stylistic (§2.1 tail, and the `0xFF` C-bridge proof).

Apple's canonical switch, verbatim from the class page:

```swift illustrative
struct GenerativeView: View {
    private var model = SystemLanguageModel.default

    var body: some View {
        switch model.availability {
        case .available:
            // Show your intelligence UI.
        case .unavailable(.deviceNotEligible):
            // Show an alternative UI.
        case .unavailable(.modelNotReady):
            // The model isn't ready because it's downloading or because of other system reasons.
        case .unavailable(let other):
            // The model is unavailable for an unknown reason.
        }
    }
}
```

Note what Apple's own snippet does: it handles two named reasons and funnels everything else,
including `.appleIntelligenceNotEnabled`, into `let other`. **Do not copy that shape.** The
`.appleIntelligenceNotEnabled` case is the one you can actually do something about, and it is the
case you will hit most on beta devices (§2.3).

The Meet-with-Apple code-along handles all three and states the intended UX for each:

> 🟡 **RECONSTRUCTED** — narration from the Foundation Models Framework Code-Along
> (Meet with Apple 205, the **iOS 26 / Xcode 26 baseline**). Identifier spellings match the docs
> above; the `@unknown default` arm is required by Swift for a non-frozen nested enum and was not
> spoken.

| Case | Apple's description | Apple's recommended handling |
|---|---|---|
| `.available` | "you have a green light… the model is loaded and you're ready to make generation requests" | proceed |
| `.unavailable(.deviceNotEligible)` | "the device doesn't support Apple Intelligence" | "gracefully hide the generative UI and show an alternate experience" |
| `.unavailable(.appleIntelligenceNotEnabled)` | "the device is capable, but Apple Intelligence is turned off in settings" | "**This is your chance to prompt the user to enable it.**" |
| `.unavailable(.modelNotReady)` | "a temporary state, likely because the model assets are still downloading" | "tell the user to try again" |

The three reason spellings and the catch-all arm are also attested in compiling Apple code:

> ✅ **VERIFIED (Apple sample code)** — `FoundationModelsCoffeeGame/MainMenu/MainMenuView.swift:47-70`
> from *Generate dynamic game content with guided generation and tools*, via
> `notes/web/apple-sample-code.md:1697-1719`. ⚠️ That sample is an **iOS 26 project**
> (`IPHONEOS_DEPLOYMENT_TARGET = 26.0`, no `LanguageModelError`, no profiles); cite it as the 26
> baseline only, never as 2026 guidance.
> ```swift
> switch SystemLanguageModel.default.availability {
> case .available:
>     gameStartButton
> case .unavailable(let reason):
>     switch reason {
>     case .appleIntelligenceNotEnabled:
>         Text("To play this game, turn on Apple Intelligence in Settings.")
>     case .modelNotReady:
>         Text("Cannot start the game until model is ready to use. Come back later!")
>     case .deviceNotEligible:
>         Text(":( Sorry, this game needs a device compatible with Apple Intelligence.")
>     default:
>         Text(":( Sorry, cannot start game. The model is unavailable for unknown reasons.")
>     }
> }
> ```

Two things to take from it. It uses a **nested** switch — outer on `Availability`, inner on
`UnavailableReason` — which is why the catch-all is spelled `default:` rather than
`@unknown default:` and why it costs nothing to write. And it handles all three reasons with
distinct copy, unlike the class-page snippet above. This is the shape to copy. It is also, as of
2026, the shape Apple's own current samples have **stopped writing entirely** — see §2.8.

There is a fourth state that no Swift-facing document names, but the C bridge does:

> ✅ **VERIFIED** — `apple/python-apple-fm-sdk`, `core.py`, mirroring the C enum
> `FMSystemLanguageModelUnavailableReason`:
> ```python
> class SystemLanguageModelUnavailableReason(IntEnum):
>     APPLE_INTELLIGENCE_NOT_ENABLED = 0
>     DEVICE_NOT_ELIGIBLE = 1
>     MODEL_NOT_READY = 2
>     UNKNOWN = 0xFF
> ```

`UNKNOWN = 0xFF` is proof that the framework itself can produce a reason outside the three
documented cases. Write the `@unknown default` arm.

### 2.2 Which availability API answers which question

Five things on `SystemLanguageModel` look like availability checks. They are not interchangeable.

> ✅ **VERIFIED** — all five from `/documentation/foundationmodels/systemlanguagemodel`.

```swift illustrative
var isAvailable: Bool                                    // 26.0+
var availability: SystemLanguageModel.Availability       // 26.0+
@backDeployed(before: iOS 26.4, macOS 26.4, visionOS 26.4)
final var contextSize: Int { get }                       // 26.4+
final var supportedLanguages: Set<Locale.Language> { get }
final func supportsLocale(_ locale: Locale = Locale.current) -> Bool
nonisolated(nonsending)
final func tokenCount(for instructions: Instructions) async throws -> Int   // 26.4+
```

| You want to know | Use | Do **not** use |
|---|---|---|
| "Should I show the AI button at all?" | `availability` (you need the reason to write copy) | `isAvailable` — it collapses three actionable states into `false` |
| "Is it worth prewarming?" | `isAvailable` | — |
| "Will this user's language work?" | `supportsLocale(_:)` | `supportedLanguages` |
| "How big is my budget?" | `contextSize` | a hardcoded `4096` |

> ✅ **VERIFIED** — `supportsLocale(_:)` discussion, verbatim: *"Use this method over
> `supportedLanguages` to check whether the given locale qualifies a user for using this model, as
> this method will take into consideration **language fallbacks**."*

The practical consequence, reported on the forums (thread 805378) and consistent with Apple's
language-gating answer in thread 797271: **Apple Intelligence keys off the Siri language setting,
not the system language** — *Settings → Apple Intelligence & Siri → Language*. A user whose phone
is in Catalan can still be served, because `supportsLocale(_:)` resolves the fallback to Spanish.
A user whose *Siri* language is unsupported cannot, no matter what their system language says.

> 🔴 **GAP — no per-app language override.** Thread 805378 requests
> `LanguageModelSession(preferredLanguage: "es-ES")`. No such initializer appears in the
> `LanguageModelSession` initializer list on Apple's docs page, and no Apple reply in the corpus
> confirms or denies a plan. If you need to serve a locale the user's Siri language doesn't cover,
> there is no supported mechanism today. Resolving this needs either a doc page for such an
> initializer or an Apple-staff answer.

⚠️ **SILENT FAILURE — do not hardcode `4096`.**

> ✅ **VERIFIED** — `/documentation/foundationmodels/managing-the-context-window`: *"Apple's
> on-device foundation model has a context window of 4096 tokens per session."*
>
> ⚠️ **Historical counterexample, now retired.** A frozen Noema 3.5 snapshot carried an
> uninstrumented comment claiming 8K on iOS 27. Its upstream is unavailable, and the claim did not
> reproduce on project-run simulator, stable macOS 27, beta-5 iPhone, or iPhone build `24A435`:
> the valid Mac/device observations were **4096**. Apple's Group Lab 8121 summary also documents
> 4096 as the iOS 27 platform value. Retain only the defensive lesson: the runtime property is
> dynamic, Simulator has also returned 0, and `4096` is a fallback for an invalid read—not policy.

If you hardcode 4096 and the device reports 8192, you will chop your own transcripts in half and
never see an error. If you hardcode 4096 and a future device reports less, you will get
`contextSizeExceeded` from a budget you believed was safe. Read `contextSize`, treat `<= 0` as
unknown, and fall back to 4096 only then. Session 241 says the same thing in Apple's own framing:

> ✅ **VERIFIED (transcript)** — WWDC26 session 241: *"In iOS 26.4, we released new APIs for
> inspecting the model's context size and counting the tokens in instructions, prompts, and
> transcripts. **You'll want to use these going forward to adapt your app to the hardware it's
> running on.**"* — "adapt to the hardware" only makes sense if the number varies.

### 2.3 The Siri coupling — the single most-reported availability bug of the 27 betas

**Symptom.** On iOS 27 Beta 1 and macOS 27 Beta 2, `SystemLanguageModel.default.availability`
returns `.unavailable(.appleIntelligenceNotEnabled)` on a device where Apple Intelligence *is*
enabled — unless the user has *also* turned on **"Siri" / "Hey Siri"** or **"Press Side Button for
Siri"**.

**Evidence.** Forum thread **835211** ("Why is `SystemLanguageModel.default.availability` tied to
user enabling talk / press side button for Siri?", NSCruiser, 2026-06-18) — **zero replies**, still
unanswered at capture. Thread **836760** ("Foundation models tied to Siri in Mac OS beta 2", Gil,
2026-07-02) reports the same behaviour on macOS and raises the EU question explicitly: in regions
where Siri AI has not shipped, does that gate the whole framework?

**Apple's position.** A Frameworks Engineer answered 836760:

> ✅ **VERIFIED (Apple staff, forum thread 836760)** — *"The Foundation Models framework **should be
> available in Europe even if Siri AI is not enabled**. Please file a bug report via Feedback
> Assistant and be sure to include a sysdiagnose to help us investigate."*

**Read the precedence carefully.** Per the series conventions, an Apple-staff forum answer outranks
a developer report — but only on the question it answers. Apple answered *"what is intended"*
("should be available"). The developers reported *"what is observed"*. Those are not in conflict;
together they say **this is a bug, it is real, and it was not fixed as of the captured betas.**
Apple's own instruction — file a Feedback with a sysdiagnose — is the reply you get when the team
cannot reproduce it from the description.

**What to do about it.**

1. Do not treat `.appleIntelligenceNotEnabled` as "the user opted out of AI". On 27 betas it may
   mean "the user turned off the side-button Siri shortcut". Your copy should point at *Settings →
   Apple Intelligence & Siri* generally, not at a specific toggle you have guessed.
2. If your app is EU-distributed and Apple Intelligence gating is load-bearing to your business
   model, **test on an EU-region device with an EU Apple Account before you commit**. The corpus
   contains an Apple statement of intent and two contradicting field reports, and nothing that
   settles it.
3. File your own Feedback with a sysdiagnose. Apple asked for exactly that.

> 🔴 **GAP — unresolved as of 2026-07-27.** Whether `.appleIntelligenceNotEnabled` is genuinely
> coupled to the Siri activation toggles, or whether 835211/836760 are two reports of one
> already-fixed beta regression, is not determined by any source in this corpus. What would resolve
> it: an Apple reply on 835211, a release-note entry, or a first-party reproduction on a shipping
> 27.0 build. Nobody in the corpus has run that test on a non-beta build, because at capture time
> there wasn't one.

### 2.4 Device support, and the capability fork nobody can query

Availability is a per-device answer, and starting with the 27 cycle the "available" answer is not
uniform.

> ✅ **VERIFIED (Apple staff, forum thread 832910, accepted answer)** — asked whether on-device
> model capability varies by hardware tier:
>
> > "Yes. There is **AFM 3 Core** and **AFM 3 Core Advanced**.
> >
> > Previously, the same on-device model was available across all devices, with different model
> > versions mentioned in the docs for `SystemLanguageModel`.
> >
> > Starting in the fall with Siri AI release:
> >
> > Devices with AFM 3 Core Advanced (most powerful):
> > - iPhone Air
> > - iPhone 17 Pro
> > - iPhone 17 Pro Max
> > - iPad (M4) or later with at least 12GB of unified memory
> > - Mac (M3) or later with at least 12GB of unified memory
> > - Apple Vision Pro (M5)
> >
> > All other devices: AFM 3 Core
> >
> > Plan to have different models. Model details and guidance will evolve over the summer's beta
> > period."

Note the **12 GB unified memory floor** on iPad and Mac — an M4 iPad with 8 GB gets the base model.

> 🔴 **GAP — you cannot ask which tier you got.** Thread 833642 has a Frameworks Engineer stating
> there is **no model-pinning API and no version-retrieval API**. By extension there appears to be
> no tier-retrieval API either, but nobody asked that question directly and nobody answered it.
> `contextSize` is the only capability-ish number you can read, and Apple has not said whether the
> two tiers differ in context size. What would resolve this: an SDK header, or an Apple answer to
> "does `SystemLanguageModel` expose which tier it is?".

Apple's recommended mitigation for the whole class of "the model changed under me" problems is the
**Evaluations framework** — regression-test your prompts across OS updates, because you cannot pin
a version. See [Part 6 — Evaluations](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md).

Also worth knowing: `SystemLanguageModel`'s own docs page enumerates the model generations.

> ✅ **VERIFIED** — verbatim from `/documentation/foundationmodels/systemlanguagemodel`:
> *"Apple periodically updates `SystemLanguageModel` in routine OS updates... Currently there are 3
> model versions that align with:*
> - *iOS, iPadOS, macOS, and visionOS 26.0 - 26.3*
> - *iOS, iPadOS, macOS, and visionOS 26.4*
> - *iOS, iPadOS, macOS, visionOS, **and watchOS** 27.0"*

Three model generations in about a year. Every one of them is a chance for a prompt that worked to
stop working, and 26.4 in particular is documented as having changed guardrail behaviour (§5.3).

### 2.5 There is no Required Device Capability for Apple Intelligence

This is the piece of the availability story with commercial consequences, and it is the answer to
forum thread **836810** ("Recommended App Store distribution strategy for apps that require
Foundation Models").

> ✅ **VERIFIED (Apple staff, Frameworks Engineer, thread 836810)** — *"The recommendation on the
> App Store side is to provide some baseline functionality to all users, regardless of whether Apple
> Intelligence is available. **The App Store doesn't support a required device capability for Apple
> Intelligence.** Even on compatible devices, there are a number of reasons why Apple Intelligence
> could be unavailable, such as if the user selected an unsupported Siri language, is located in an
> unsupported region, or opted out of Apple Intelligence."*

An Apple Designer in the same thread gave the architectural reason, and it is worth quoting in
full because it reframes what "Foundation Models" now means:

> ✅ **VERIFIED (Apple staff, thread 836810)** — *"As of WWDC 2026, Foundation Models framework
> covers both on-device foundation models and server-based models… and both Apple Foundation Models
> as well as any other LLMs. So 'foundation models' can mean a bunch of different things and a bunch
> of possible models, which is part of the reason why there isn't currently a clean device-capability
> flag."*
>
> *"So... what can you do?*
> 1. *Run an availability check as soon as you launch your app… Availability can tell you additional
>    information about compatibility... like if the model is downloading or not available for that
>    language. From a UX standpoint, **try to check availability before anyone agrees to pay for
>    your app's service**, to avoid someone paying for what they can't use.*
> 2. *Figure out if you can use a different model as backup, if Apple's on-device foundation model
>    isn't compatible with the device. Any server or local LLM might do."*

Three concrete obligations fall out of this:

1. **Your app will be installed on devices that can never run it.** You cannot filter in the App
   Store. Ship a non-AI baseline or your one-star reviews will write themselves.
2. **Gate the paywall on `availability`, not on install.** Apple says this explicitly. Check before
   purchase, not after.
3. **A fallback model is the supported answer.** `MLXLanguageModel`, `CoreAILanguageModel`, or a
   `ChatCompletionsLanguageModel` pointed at your own server all conform to the same `LanguageModel`
   protocol, so the fallback is a model swap and not a rewrite. See
   [Part 4 — Beyond the built-in model](../../part-04-beyond-the-built-in-model/README.md).

### 2.6 PCC availability is a *different enum* with a case you have never seen

`PrivateCloudComputeLanguageModel` (27.0+) has its own `Availability` type, and it carries a reason
that `SystemLanguageModel` does not.

> ✅ **VERIFIED** — from
> `/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute`:

```swift illustrative
let model = PrivateCloudComputeLanguageModel()

switch model.availability {
case .available:
    // Show your intelligence UI.
case .unavailable(.deviceNotEligible):
    // Show an alternative UI.
case .unavailable(.systemNotReady):
    // PCC isn't ready to serve requests.
case .unavailable(let other):
    // The model is unavailable for an unknown reason.
}
```

`.systemNotReady` does not exist on `SystemLanguageModel.Availability.UnavailableReason`. If you
have a shared availability helper that switches over one enum and gets handed the other, you will
either fail to compile (good) or funnel a recoverable transient state into your "device not
supported" branch (bad).

> ✅ **RESOLVED (2026-07-29) — the full PCC `UnavailableReason` case list is exactly two.**
> `case deviceNotEligible` and `case systemNotReady` — nothing else — ✅ **SDK-verified**
> (`FoundationModels-27.0-macos.swiftinterface:82-90`). Neither `.appleIntelligenceNotEnabled` nor
> `.modelNotReady` exists on the PCC enum; those belong to `SystemLanguageModel`'s three-case list
> (`:365-374`). One caveat: unlike `Availability` itself (`@frozen`, `:73`), `UnavailableReason` is
> **not** `@frozen`, so keep the `case .unavailable(let other)` catch-all — Apple's own example
> writes it, and the compiler will not warn you when a case is added.

Two more PCC availability facts you will not guess:

> ✅ **VERIFIED (Apple staff, thread 831998, accepted)** — *"There is a known issue that Private
> Cloud Compute does not currently work in simulators."* Filed as **177684296** in the iOS 27
> release notes, with the workaround *"Use a physical device running OS 27.0."*

> ✅ **VERIFIED (forum thread 831998)** — **removing the Private Cloud Compute entitlement triggers
> a `fatalError` at runtime**, and `model.isAvailable` returns `true` even when the call
> subsequently fails. An availability check does *not* protect you from a missing entitlement.

### 2.7 Testing availability without a drawer full of devices

Xcode can simulate the unavailable states. This is a high-value, low-discoverability feature.

> ✅ **VERIFIED (Apple docs)** — the exact steps, from the PCC article:
> 1. Choose **Product > Scheme > Edit Scheme**.
> 2. Select the **Run** page and choose the **Options** tab.
> 3. Select either **"Approaching Quota Usage Limit"** or **"Quota Usage Limit Reached"** from the
>    **"Simulated Apple Foundation Models Availability"** drop-down menu.
> 4. Click Close and run your project.

The same drop-down carries the `UnavailableReason`-mirroring options; the code-along demonstrates
selecting **"Apple Intelligence Not Enabled"** and shows the app rendering *"Trip Planner is
unavailable because Apple Intelligence has not been turned on."*

⚠️ **Three different names for this menu circulate.** Trust the docs.

| Source | Scheme page | Menu title | "approaching" option |
|---|---|---|---|
| **Apple docs (PCC article)** — authoritative | **Run** page → **Options** tab | **"Simulated Apple Foundation Models Availability"** | **"Approaching Quota Usage Limit"** |
| WWDC26 session 319 (spoken, beta build) | "Debug" then "Options" | "Simulate Apple Foundation Models Availability" | "Nearing Usage Limit" |
| Meet-with-Apple 205 (iOS 26 era) | Edit Scheme → scroll down | "Simulated Foundation Models availability" | n/a (quota didn't exist in 26) |

The menu exists and has at least those states; the transcript was narrated from a beta build whose
strings changed. If you are searching the Xcode UI and coming up empty, search for the word
"Simulated", not "Simulate".

### 2.8 Proactive gate or reactive catch — Apple changed its mind, quietly

Everything above assumes you check `availability` *before* you do anything. Apple's 2026 sample
code does not do that. At all.

> ✅ **VERIFIED (Apple sample code)** — across the two genuine iOS 27 Foundation Models samples —
> **Origami** (61 Swift files, deployment target 27.0) and **Searching indexed content with natural
> language** (the hiking-trails app, 6 Swift files, 27.0) — there is **no call to
> `SystemLanguageModel.availability`, no `isAvailable` check, and no `#available` gate on the model
> anywhere**. Both rely entirely on catching `SystemLanguageModel.Error` at the call site and
> rendering a message. `notes/web/apple-sample-code.md:777-781`.
>
> The only availability switch in any Apple sample is the one in §2.1 — and it is in the **iOS 26**
> game sample, which was never refreshed for 2026.

So Apple's shipped guidance is now split against itself: the docs page still shows the proactive
switch, the code-along still teaches it, and Apple's own current sample apps have deleted it.

**Teach and write both, because they answer different questions.**

| | Proactive gate | Reactive catch |
|---|---|---|
| **API** | `model.availability`, `supportsLocale(_:)` | `catch` / `if self is SystemLanguageModel.Error` |
| **Answers** | "Should this button exist?" | "This attempt just failed — what do I say?" |
| **Runs** | Before the user commits (before the paywall, per thread 836810 in §2.5) | After they tapped |
| **Catches the race** | ❌ assets can go away between check and call | ✅ that is exactly what it is for |
| **Gives a reason** | ✅ three distinct reasons, three distinct copy strings | ❌ **one** case, `.assetsUnavailable` (§3.4) |

The two are not redundant and neither subsumes the other. The gate is what stops you selling a
feature the device cannot run; the catch is what stops a `nil`-shaped hole in your UI when the
model goes away mid-session. Apple's own sample posture — reactive only — throws away the reason
string, and with it the ability to say *"turn on Apple Intelligence"* rather than *"something went
wrong"*. That is a real regression in user-facing quality, not a simplification worth copying.

The one place the samples are defensible: their deployment target is 27.0, so `#available` is moot,
and Origami is a tutorial app where a dead-end message is acceptable. In a shipping app with a
purchase flow it is not.

⚠️ **SILENT FAILURE — a reactive-only design that omits the `SystemLanguageModel.Error` arm handles
nothing.** If you drop the proactive gate *and* your catch ladder only tests `LanguageModelError`
— which is what Apple's own forum-posted ladder does (§3.7) — then every "Apple Intelligence is
turned off" failure falls through to your generic `catch` and renders whatever your fallback string
is. You have no gate and no handler, and the compiler is happy. See §3.4.

---

## 3. The 2026 error reshuffle: four enums where there was one

### 3.1 The migration fact that outranks everything else in this guide

In iOS 26 there was one error enum for generation: `LanguageModelSession.GenerationError`. In 27 it
is deprecated and its cases were redistributed across three new types.

> ✅ **VERIFIED** — the deprecation notice, verbatim from
> `/documentation/foundationmodels/languagemodelsession/generationerror` (page frontmatter carries
> `deprecated: true`):
>
> > **Deprecated**
> > Use `LanguageModelError`, `SystemLanguageModel.Error`, or `LanguageModelSession.Error` instead.
> > **Apps built with Xcode 26 will continue to catch this error until you rebuild with Xcode 27.
> > You must update to Xcode 27 to catch the new error types before submitting your app.**

> ✅ **VERIFIED (SDK interface)** — the *before* side of this rename is now confirmed at the strongest
> evidence level: Apple's compiler-emitted `notes/sdk-interfaces/FoundationModels-26.5-macos.swiftinterface`
> (module 1.5.2) still carries `LanguageModelSession.GenerationError` with its **nine** cases (listed
> in §3.6) and contains **no `LanguageModelError`** anywhere — grep-verified absent from the 26.5 SDK.
> So the split is real and directional: 26.x shipped one generation-error enum; 27 redistributes it.
> The full before/after taxonomy is the subject of
> [Part 17 — Error taxonomy migration](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md).
> ⚠️ The 26.5 `GenerationError` cases are the **before** side only — the error namespace is *not*
> stable across the rename, so never cite them as the 27 surface.

Read that twice. The behaviour is **toolchain-conditional, not OS-conditional**:

- Binary built with **Xcode 26**, running on **iOS 27**: still throws
  `LanguageModelSession.GenerationError`. Your existing `catch` arms keep working.
- Binary built with **Xcode 27**: throws the new types. Every `catch
  LanguageModelSession.GenerationError.…` arm you wrote silently stops matching.

⚠️ **SILENT FAILURE — the rebuild is the trigger.** Nothing about your source changes. You rebuild
with a new Xcode, your `catch GenerationError.exceededContextWindowSize` arm stops being reachable,
and the error falls through to your generic `catch` — where, if you wrote the common
`catch { showAlert("Something went wrong") }`, your carefully-built context-compaction recovery is
now dead code that the compiler will not warn you about. You find out from crash-free-but-useless
sessions in production.

The mitigation is mechanical: before shipping an Xcode 27 build, grep your codebase for
`GenerationError` and convert every arm using the table in §3.6.

### 3.2 `LanguageModelError` — the nine cases

> ✅ **VERIFIED** — `/documentation/foundationmodels/languagemodelerror`, iOS 27.0+ Beta.
> `enum LanguageModelError`, conforming to `Copyable`, `CustomDebugStringConvertible`, `Error`,
> `Escapable`, `LocalizedError`, `Sendable`, `SendableMetatype`. Descriptions are Apple's own
> one-liners from the case list.

| Case | Payload type | Apple's description |
|---|---|---|
| `.contextSizeExceeded(_:)` | `.ContextSizeExceeded` | "The session's transcript exceeded the model's context size." |
| `.rateLimited(_:)` | `.RateLimited` | "The session has been rate limited." |
| `.refusal(_:)` | `.Refusal` | "The model refused to answer." |
| `.timeout(_:)` | `.Timeout` | "The request timed out before the model could produce a response." |
| `.guardrailViolation(_:)` | `.GuardrailViolation` | "The model's safety guardrails were triggered by content in a prompt or the response generated by the model." |
| `.unsupportedCapability(_:)` | `.UnsupportedCapability` | "The model being used doesn't support a particular feature." |
| `.unsupportedTranscriptContent(_:)` | `.UnsupportedTranscriptContent` | "The prompt contains content that the model cannot process." |
| `.unsupportedGenerationGuide(_:)` | `.UnsupportedGenerationGuide` | "An unsupported generation guide was used" |
| `.unsupportedLanguageOrLocale(_:)` | `.UnsupportedLanguageOrLocale` | "The model was prompted to respond in a language that it does not support." |

Note `.refusal` and `.guardrailViolation` sitting side by side. **They are different mechanisms**,
not two spellings of one; §4 is entirely about that.

#### Five of the nine are confirmed by compiling Apple code — and the enum is non-frozen

The doc page is one source. Two Apple sample projects that ship a near-identical
`Error+DisplayMessage.swift` are a much stronger one, because those case names went through a
compiler.

> ✅ **VERIFIED (Apple sample code, two independent archives)** — `Origami/Models/Error+DisplayMessage.swift:12-36`,
> and the same file minus one clause at `LLMSearchUsingCoreSpotlightApp/Error+DisplayMessage.swift:11-32`.
> Via `notes/web/apple-sample-code.md:719-760, 1674-1680`:
>
> ```swift
> extension Error {
>     /// A short message describing the error, suitable for display in the UI.
>     var displayMessage: String {
>         if self is SystemLanguageModel.Error {
>             return "Apple Intelligence isn't available right now."
>         }
>         if let modelError = self as? LanguageModelError {
>             switch modelError {
>             case .timeout:
>                 return "This is taking longer than expected. Please try again."
>             case .guardrailViolation, .refusal:
>                 return "Origami can't work with that. Try a different photo or prompt."
>             case .contextSizeExceeded:
>                 return "There's too much in this conversation. Try regenerating to start fresh."
>             case .unsupportedLanguageOrLocale:
>                 return "Origami doesn't support this language."
>             default:
>                 break
>             }
>         }
>         if self is GeneratedContent.ParsingError {
>             return "Origami had trouble understanding the response. Please try again."
>         }
>         return "Something went wrong. Please try again."
>     }
> }
> ```

Four facts fall out of twenty-five lines, and every one of them changes how you write a catch block.

1. **`.timeout`, `.guardrailViolation`, `.refusal`, `.contextSizeExceeded` and
   `.unsupportedLanguageOrLocale` are real, compiling case names on `LanguageModelError`.** Two
   independent archives agreeing is as close to a header as this corpus gets. The other four —
   `.rateLimited`, `.unsupportedCapability`, `.unsupportedTranscriptContent`,
   `.unsupportedGenerationGuide` — are doc-page-only and appear in no sample, which is unsurprising:
   they are the cases you hit on a *different* model or a *malformed* schema, and both samples use
   the stock on-device one.
2. **`LanguageModelError` is non-frozen.** Both samples end the switch with `default: break`. In a
   library-evolution-enabled framework that is not stylistic — an exhaustive switch over a
   non-frozen enum does not compile without a catch-all, and Swift will make you write
   `@unknown default` in a switch that already covers every known case. Write the arm. Assume the
   nine cases in the table above are a floor, not a ceiling.
3. **You may match a payload case without binding its payload.** `case .timeout:` is legal even
   though the case carries a `Timeout` value. Bind only what you use — otherwise you get
   unused-value warnings across the whole ladder.
4. **`SystemLanguageModel.Error` is tested first, and `GeneratedContent.ParsingError` last** — see
   §3.4 and §3.6. Neither is a `LanguageModelError` case, and neither is reachable from a ladder
   that only tests `LanguageModelError`.

> ✅ **RESOLVED (2026-07-29) — the nine cases are the complete list in the 27.0 beta SDK.** The
> interface declares `public enum LanguageModelError : LocalizedError` with exactly the nine cases
> in the table above, in this order: `contextSizeExceeded`, `rateLimited`, `guardrailViolation`,
> `refusal`, `unsupportedCapability`, `unsupportedTranscriptContent`, `unsupportedGenerationGuide`,
> `unsupportedLanguageOrLocale`, `timeout` — ✅ **SDK-verified**
> (`FoundationModels-27.0-macos.swiftinterface:1527-1537`). The enum is still **non-frozen** (no
> `@frozen` attribute), so the ceiling can rise in a future SDK: keep the `default:` arm. The four
> doc-page-only cases are no longer doc-page-only — all nine are read from the interface.

#### The payload fields

The docs pages for the payload structs are thin. The complete field list comes from a *different*
Apple-authored source: the `foundation-models-language-model-protocol` skill shipped inside
`github.com/apple/foundation-models-utilities`, which exists to teach third parties how to throw
these correctly.

> ✅ **VERIFIED** — `skills/foundation-models-language-model-protocol/SKILL.md:549-557` in
> `apple/foundation-models-utilities`. This is Apple-authored *prose in a shipped source file*, not
> a header. It ranks below an SDK header and above a doc page in this series' precedence order
> because it is normative instruction to implementers, but if a header ever disagrees, the header
> wins.

| Case | Payload-specific fields |
|---|---|
| `.contextSizeExceeded(ContextSizeExceeded)` | `contextSize: Int`, `tokenCount: Int` |
| `.rateLimited(RateLimited)` | `resetDate: Date?` |
| `.guardrailViolation(GuardrailViolation)` | — (no case-specific field) |
| `.refusal(Refusal)` | `explanation: LanguageModelSession.Response<String>` (`get async throws`); read generated text from `.content`.[^refusal-api] |
| `.unsupportedCapability(UnsupportedCapability)` | `capability: LanguageModelCapabilities.Capability` |
| `.unsupportedTranscriptContent(UnsupportedTranscriptContent)` | `unsupportedContent: [Transcript.Entry]` |
| `.unsupportedGenerationGuide(UnsupportedGenerationGuide)` | `schemaName: String?` |
| `.unsupportedLanguageOrLocale(UnsupportedLanguageOrLocale)` | `languageCode: Locale.LanguageCode` |
| `.timeout(Timeout)` | — |

Plus, from the same file: *"Every payload struct exposes `debugDescription: String` … and
`metadata: [String: any Sendable]`."*

The header has now been read, and it agrees on every row: the payload structs and their
case-specific fields are ✅ **SDK-verified** verbatim
(`FoundationModels-27.0-macos.swiftinterface:1541-1661`), including the `debugDescription` +
`metadata` pair on all nine. One refinement the SKILL.md could not show: `Refusal`'s *stored*
members are just `debugDescription`/`metadata` — its `init` takes `explanation: String`
(`:1550`) and the `explanation: Response<String> { get async throws }` accessor plus
`explanationStream` live in a separate extension (`:1637-1646`).

`ContextSizeExceeded` is independently corroborated by the docs, which show
`init(contextSize:tokenCount:debugDescription:metadata:)` and a `.tokenCount` property. That is the
one payload you will actually branch on: it tells you both your budget and your overrun, which is
exactly what a compaction routine needs (§6).

Here is the exact construction pattern, taken from compiled Apple code rather than prose — this is
what a payload throw looks like in practice:

> ✅ **VERIFIED** — `Sources/FoundationModelsUtilities/LanguageModels/ChatCompletionsLanguageModel.swift:450-456`:

```swift illustrative
case .custom:
  throw LanguageModelError.unsupportedTranscriptContent(
    LanguageModelError.UnsupportedTranscriptContent(
      unsupportedContent: [entry],
      debugDescription: "Custom segments are not supported by \(Self.self)"
    )
  )
```

> ✅ **VERIFIED — the accessor is asynchronous and wrapped.** In the iOS 27 API,
> `LanguageModelError.Refusal.explanation` is `get async throws` and returns
> `LanguageModelSession.Response<String>`; retrieve the actual message from `response.content`.[^refusal-api]
> The plain `String` accepted by the payload initializer does not change the accessor's return type.

#### `unsupportedCapability` is thrown *for* you

This case behaves differently from the others: you do not usually cause it, and a model provider
does not usually throw it.

> ✅ **VERIFIED (Apple, SKILL.md:35)** — *"If a developer asks for a capability you didn't declare
> (e.g. tool calling on a model that doesn't support it), the framework throws
> `unsupportedCapability` for you — you don't write defensive code for that."*
> And at `:312`: *"Don't declare a capability you don't fully support — the framework throws
> `unsupportedCapability` for the developer when they request a capability you didn't list."*

So when you swap `SystemLanguageModel` for some third-party `LanguageModel` and suddenly get
`.unsupportedCapability(.guidedGeneration)`, that is the framework comparing your request against
the model's declared `LanguageModelCapabilities` — not the model failing. Fix it by picking a model
that declares the capability, or by dropping to string generation. This is the most common failure
when moving code between backends; see
[Part 4](../../part-04-beyond-the-built-in-model/README.md).

#### `rateLimited` is largely a background-and-server phenomenon

> ✅ **VERIFIED (Apple docs)** — from `streamResponse(to:generating:includeSchemaInPrompt:options:)`:
> *"**IMPORTANT** — If running in the background, use the non-streaming `respond(to:options:)`
> method to reduce the likelihood of encountering `LanguageModelError.rateLimited(_:)` errors."*

> ✅ **VERIFIED (Apple docs, Python SDK)** — `docs/source/api/errors.rst` in
> `apple/python-apple-fm-sdk`: *"**RateLimitedError** — Rate limits do not apply to the on-device
> `SystemLanguageModel` on macOS so you should not encounter this error."*

Taken together: on-device foreground work on macOS should never rate-limit; iOS background work can,
and streaming makes it likelier. Combine with the concurrency answer Apple gave in thread 833666:

> ✅ **VERIFIED (Apple staff, thread 833666)** — *"The OS manages the requests for the on-device LLM
> automatically, based on the system conditions (like thermals). **There's no entitlement or API to
> influence this.**"*

So the correct response to `.rateLimited` is backoff, not a retry loop. Use `resetDate` if present.

### 3.3 `LanguageModelSession.Error` — this one is your bug

> ✅ **VERIFIED** — `/documentation/foundationmodels/languagemodelsession/error`, iOS 27.0+ Beta.

```swift illustrative
enum Error
case concurrentRequests                    // "Multiple requests were made to the session concurrently."
case transcriptMutationWhileResponding     // "The session's transcript was mutated while a request was in progress."
```

These are **non-payload** cases, unlike the deprecated `GenerationError.concurrentRequests(_:)`.

Neither is a model failure; both mean you misused the session object. Apple's guidance for the first
is blunt:

> ✅ **VERIFIED (Apple docs, `isResponding`)** — *"**IMPORTANT** — You should not call any of the
> respond methods while this property is `true`. Disable buttons and other interactions to prevent
> users from submitting a second prompt while the model is responding to their first prompt."*

with the canonical SwiftUI shape:

```swift compile:27 imports:FoundationModels,SwiftUI
struct ShopView: View {
    @State var session = LanguageModelSession()
    @State var joke = ""

    var body: some View {
        Text(joke)
        Button("Generate joke") {
            Task {
                assert(!session.isResponding, "It should not be possible to tap this button while the model is responding")
                joke = try await session.respond(to: "Tell me a joke").content
            }
        }
        .disabled(session.isResponding) // Prevent concurrent calls to respond
    }
}
```

`.transcriptMutationWhileResponding` is new in 27 and is a *direct consequence* of the 27 feature
that made `session.transcript` settable. In 26 you could not hit it, because you could not mutate
the transcript at all — you rebuilt the session instead.

> ✅ **VERIFIED (Apple staff, thread 835927)** — *"In **iOS 27**, session's `transcript` property is
> now **mutable**, and transcript has a **`history` accessor** for updating everything except the
> instructions, so you can just use that instead of recreating the session."*

So: the ergonomic win comes with a new way to crash. If you are compacting the transcript from a
background task while a response streams on the main actor, you will get this error. Gate mutation
on `isResponding`, or do it inside a `DynamicProfile` `onPrompt` hook, which the framework schedules
for you at a safe point (see
[Part 3 — Context, profiles, agentic sessions](../../part-03-context-profiles-agentic/README.md)).

### 3.4 `SystemLanguageModel.Error` — one case, and it is not on watchOS

> ✅ **VERIFIED** — `/documentation/foundationmodels/systemlanguagemodel/error`, iOS 27.0+ Beta,
> **no watchOS**.

```swift illustrative
enum Error
case assetsUnavailable(_: SystemLanguageModel.Error.AssetsUnavailable)
```

`AssetsUnavailable` has `debugDescription` and `init(debugDescription:)`.

This is the runtime counterpart to `.unavailable(.modelNotReady)`: availability said the assets
weren't ready, or they went away between your check and your call. It is recoverable — the user
should try again later — and it is the one error where "tell them to retry" is genuinely the right
answer rather than a cop-out.

**Check this type first, before `LanguageModelError`.** Not because of type shadowing — the two are
disjoint, so an `as?` cast can only ever succeed for one — but because it is the arm people leave
out, and it is the one carrying the most common runtime failure there is.

> ✅ **VERIFIED (Apple sample code, two independent archives)** — both Origami and the Spotlight
> sample open their error handler with `if self is SystemLanguageModel.Error { … }` **before** any
> `LanguageModelError` test, and both map it to an "Apple Intelligence isn't available right now"
> string. `notes/web/apple-sample-code.md:728-731, 759-760, 1676-1679`. Note the `is` test: neither
> sample binds the error or switches over its single case, because there is nothing to branch on.

⚠️ **SILENT FAILURE — availability failures are not `LanguageModelError`s, and a ladder built from
Apple's forum snippet will miss them.** The recommended catch shape a Frameworks Engineer posted
(§3.7) has arms for `LanguageModelError`, `LanguageModelSession.Error` and the deprecated
`GenerationError` — and none for `SystemLanguageModel.Error`. Copy it verbatim, ship it, and every
user with Apple Intelligence turned off gets your generic "something went wrong" branch instead of
the one actionable message in the whole framework. Nothing warns you: the code compiles, the arms
you wrote all match the errors they were written for, and the one you didn't write is the one your
users hit. Apple's own sample code puts this test first for a reason.

The `no watchOS` detail matters if you share code: `SystemLanguageModel` itself has no watchOS
availability at all. On watchOS 27 the framework exists (`LanguageModelSession`, `Transcript`,
`Tool`, `Generable` and friends all gained watchOS 27.0), but the on-device system model does not —
watchOS is a `PrivateCloudComputeLanguageModel` platform. A `catch SystemLanguageModel.Error…` arm
in shared code will not compile for the watch target.

### 3.5 `PrivateCloudComputeLanguageModel.Error` — three cases, all network-shaped

> ✅ **VERIFIED** — `/documentation/foundationmodels/privatecloudcomputelanguagemodel/error`,
> iOS 27.0+ Beta.

| Case | Payload | Description |
|---|---|---|
| `.quotaLimitReached(_:)` | `.QuotaLimitReached` | "The allotted usage quota has been reached." |
| `.networkFailure(_:)` | `.NetworkFailure` | "An error that occurs when a network is available, but PCC is inaccessible." |
| `.serviceUnavailable(_:)` | `.ServiceUnavailable` | "Services are unavailable." |

Note the precision of `.networkFailure`'s description: *network available, PCC inaccessible*. That is
not "the user is offline" — that is "your request reached the internet and PCC did not answer".
Distinguishing them matters, because the fallback differs: offline → on-device model; PCC
unreachable → also on-device, but worth telling the user it's a temporary service issue rather than
their connection.

> ✅ **VERIFIED (Apple docs, PCC article)** — *"Using PCC requires a network connection, so **if the
> request fails because the network connection is unavailable, retry the request using the on-device
> model.**"*

`.quotaLimitReached` should almost never reach your catch block, because §8 shows how to see it
coming.

### 3.6 The old → new mapping

> ✅ **VERIFIED (case list — SDK interface)** / 🟡 **RECONSTRUCTED (the mapping itself)** — the
> deprecated case list is now confirmed by Apple's compiler-emitted
> `notes/sdk-interfaces/FoundationModels-26.5-macos.swiftinterface` (module 1.5.2), the strongest
> evidence class in this corpus, above the `GenerationError` doc page it also matches. The
> correspondences (the right-hand column) are still derived from names and descriptions — the 26.5
> interface has **no `LanguageModelError`** (grep-verified absent), so the 27 rename targets come from
> sample code and docs, not this SDK — and two of the renames are not obvious.

Deprecated `LanguageModelSession.GenerationError` cases (26.0+, no watchOS): `.assetsUnavailable(_:)`,
`.decodingFailure(_:)`, `.exceededContextWindowSize(_:)`, `.guardrailViolation(_:)`, `.rateLimited(_:)`,
`.refusal(_:_:)` (**two** associated values), `.concurrentRequests(_:)`, `.unsupportedGuide(_:)`,
`.unsupportedLanguageOrLocale(_:)`. Supporting types `GenerationError.Context` and
`GenerationError.Refusal`.

The 26.5 interface confirms this is **exactly nine cases and no more**. Every non-refusal case carries
a single `GenerationError.Context` (whose only stored field is `debugDescription`); `.refusal` alone
carries `(Refusal, Context)` — the extra associated value being the `GenerationError.Refusal` struct
where the `async throws` `explanation` and the `explanationStream` accessors live (§4.4). This *is* the
"on 26.x this was `GenerationError` with these nine cases" fact, now SDK-verified rather than
docs-only; the full before/after walk-through is
[Part 17 — Error taxonomy migration](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md).

| iOS 26 (`GenerationError`) | iOS 27 successor | Notes |
|---|---|---|
| `.exceededContextWindowSize(_:)` | `LanguageModelError.contextSizeExceeded(_:)` | **Renamed, not just moved.** Grep for both spellings. |
| `.unsupportedGuide(_:)` | `LanguageModelError.unsupportedGenerationGuide(_:)` | Renamed. |
| `.guardrailViolation(_:)` | `LanguageModelError.guardrailViolation(_:)` | Same name, new enum. |
| `.rateLimited(_:)` | `LanguageModelError.rateLimited(_:)` | Same name, new enum; payload gains `resetDate`. |
| `.unsupportedLanguageOrLocale(_:)` | `LanguageModelError.unsupportedLanguageOrLocale(_:)` | Same name, new enum. |
| `.refusal(_:_:)` — **two** values | `LanguageModelError.refusal(_:)` — **one** value | Arity changed; a two-binding `catch` will not compile. |
| `.assetsUnavailable(_:)` | `SystemLanguageModel.Error.assetsUnavailable(_:)` | **Moved to a different enum.** |
| `.concurrentRequests(_:)` | `LanguageModelSession.Error.concurrentRequests` | **Moved, and lost its payload.** |
| `.decodingFailure(_:)` | `GeneratedContent.ParsingError` — **a separate type, not an enum case** | Catch it as its own arm. See below. |

That last row is the one that breaks a mechanical migration, because the replacement is not in any
of the four enums. It is a distinct error type on `GeneratedContent`, and Apple's own sample code
catches it as its own arm at the *end* of the ladder:

> ✅ **VERIFIED (Apple sample code)** — `Origami/Models/Error+DisplayMessage.swift:12-36`, via
> `notes/web/apple-sample-code.md:745-747, 755`:
> ```swift
> if self is GeneratedContent.ParsingError {
>     return "Origami had trouble understanding the response. Please try again."
> }
> ```
> The type is independently attested with a public initializer in Apple's own package:
> `GeneratedContent.ParsingError(rawContent:debugDescription:)` in `foundation-models-utilities`.

Note where Apple puts it: **after** `LanguageModelError`, not before, and reached by an `is` test
rather than a `catch` pattern. And note the copy — *"had trouble understanding the response…
please try again"*. Apple treats a parse failure as **retryable**, which is right: the model
produced output that didn't fit the schema, and the next sample may well fit. That is the opposite
of the guidance for a refusal, which never becomes retryable.

The Spotlight sample ships the same file **without** this clause — it uses no `@Generable` output —
which is the practical rule: you need this arm exactly when you call `respond(to:generating:)`.

> ✅ **RESOLVED (2026-07-29) — it is the formal successor, stated by Apple in the SDK.** The
> deprecated `GenerationError.decodingFailure(_:)` case carries the per-case deprecation message
> *"Use ``GeneratedContent/ParsingError`` instead."* — ✅ **SDK-verified**
> (`FoundationModels-27.0-macos.swiftinterface:3555-3558`). The payload-porting caveat stands and
> is now precise: the old case's payload was a `GenerationError.Context` (`debugDescription` only),
> while `ParsingError` is a struct with `rawContent: String`, `underlyingError: (any Error)?`, and
> `debugDescription: String` (`:1399-1404`) — so a migrated arm gains the raw model output but
> must be rewritten, not renamed.

### 3.7 Catch order, and the pattern-matching bug

Apple's own recommended shape, posted by a Frameworks Engineer:

> ✅ **VERIFIED (Apple staff, thread 831404)** — verbatim from the reply:

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

Three things to take from this snippet.

**First, the shape is `catch let error as <Type>`, then switch inside** — not
`catch LanguageModelError.contextSizeExceeded(let c)`. That is not a stylistic accident. Thread
**831404** is titled *"Cannot pattern match `LanguageModelError` from a response stream"* and is
filed as **FB23061009**. The developer's case-pattern arms did not match errors coming out of a
`streamResponse` sequence; Apple's answer was the type-cast form.

Apple's own sample code uses exactly this shape and never uses a case pattern:

> ✅ **VERIFIED (Apple sample code, two independent archives)** — every error decision in Origami
> and the Spotlight sample is made by `if self is <Type>` or
> `if let modelError = self as? LanguageModelError { switch modelError { … } }`. There is not one
> `catch LanguageModelError.someCase(let x)` pattern in either project.
> `notes/web/apple-sample-code.md:724-750, 1676-1679`.

> 🟡 **RECONSTRUCTED interpretation.** The corpus contains the bug report, the FB number, and
> Apple's type-cast-shaped reply — it does **not** contain an Apple statement that case-pattern
> matching is broken, nor a fix. Our reading is that the type-cast form is the reliable one on the
> streaming path. What is now verified is the weaker but sufficient claim: **cast-then-switch is
> the form Apple writes**, in its docs snippets, in its forum answers and in its shipping sample
> code. Case patterns appear to work fine on the non-streaming `respond` path (§5.1, §6.1), but
> nothing is gained by using them.

**Second, `SystemLanguageModel.Error` and `PrivateCloudComputeLanguageModel.Error` are missing from
Apple's snippet, and so is `GeneratedContent.ParsingError`.** It predates or ignores them. The
omission of `SystemLanguageModel.Error` in particular is a live hazard — see the silent-failure
callout in §3.4. Apple's own sample code puts the arms in this order, and it is the order to copy:

> ✅ **VERIFIED (Apple sample code)** — `Origami/Models/Error+DisplayMessage.swift:12-36`:
> **1.** `SystemLanguageModel.Error` (availability, at use time) →
> **2.** `LanguageModelError` (switch, with `default: break`) →
> **3.** `GeneratedContent.ParsingError` (guided-generation decode) →
> **4.** a generic fallback string.
>
> Cancellation is handled *outside* this ladder entirely, as a non-error outcome:
> `} catch is CancellationError { … } catch { state = .error(error.displayMessage) }`
> (`Orchestrator.swift:353, 374, 396, 415, 439, 453, 624, 652`).

A complete ladder needs those four plus `LanguageModelSession.Error`,
`PrivateCloudComputeLanguageModel.Error` and `ToolCallError`; §10 has it.

Note what Apple's shape gets right that a `do/catch` ladder does not: `displayMessage` is an
extension on `Error` itself, so the classification lives in one file and every call site is
`catch { state = .error(error.displayMessage) }`. That is the same design goal as §10's single
outcome type, reached with less ceremony — and it is worth stealing wholesale if all you need from
an error is a string.

> 🔴 **GAP (narrowed 2026-07-29) — `LanguageModelSession.Error` is used by no Apple sample.** The
> type itself is no longer in any doubt: exactly two payload-free cases, `concurrentRequests` and
> `transcriptMutationWhileResponding`, `Equatable & Hashable`, `LocalizedError` — ✅ **SDK-verified**
> (`FoundationModels-27.0-macos.swiftinterface:2026-2034`). But neither 2026 sample catches it, so
> the corpus contains no compiling code that observes one. That is weak evidence about how often it
> fires in practice, not evidence the type is wrong. What would resolve it: any first-party or
> shipping code that catches it. `notes/web/apple-sample-code.md:105`.

**Third, keep the deprecated arm.** If you support both an Xcode 26 build train and an Xcode 27 one,
you need both. The deprecated arm produces a deprecation warning, not an error.

---

## 4. The two refusal mechanisms

This is the most valuable section in this guide, and the distinction it draws is the one almost
everyone gets wrong — including experienced developers filing otherwise-excellent bug reports.

**There are two independent safety systems, and a third failure surface that is not an error at
all.** They have different owners, different triggers, different error cases, and — critically —
**different configuration knobs, only one of which you can turn.**

### 4.1 The architecture, in Apple's words

> ✅ **VERIFIED** — `/documentation/foundationmodels/improving-the-safety-of-generative-model-output`,
> verbatim:
>
> Two built-in layers:
> > - Apple Foundation Models, running on-device and on Private Cloud Compute, **trained to handle
> >   sensitive topics with care**.
> > - *Guardrails* that aim to **block harmful or sensitive content, such as self-harm, violence,
> >   and adult materials, from both model input and output**.
>
> > Because safety risks are often contextual, **some harms might bypass both built-in framework
> > safety layers.**

Layer one — **guardrails** — is a *classifier* that sits outside the model. It inspects your prompt
before it reaches the model and the model's output before it reaches you. It is a filter, and it is
the layer `SystemLanguageModel(guardrails:)` configures.

Layer two — **the model's own training** — is inside the weights. There is no knob. The model
declines because it was trained to decline. Apple's phrasing is "trained to handle sensitive topics
with care", and the observable consequence is a refusal.

Here is the split as a table. Memorise it; almost every confused forum thread in this cluster is a
failure to keep these columns apart.

| | **Guardrail violation** | **Model-level refusal** |
|---|---|---|
| **What it is** | An external classifier blocked input or output | The model itself declined to answer |
| **Where it runs** | Around the model | Inside the model |
| **Error case (27)** | `LanguageModelError.guardrailViolation(_:)` | `LanguageModelError.refusal(_:)` |
| **Error case (26, deprecated)** | `GenerationError.guardrailViolation(_:)` | `GenerationError.refusal(_:_:)` |
| **Apple's one-liner** | "The model's safety guardrails were triggered by content in a prompt or the response generated by the model." | "The model refused to answer." |
| **Configurable?** | ✅ Yes — `.permissiveContentTransformations` | 🚫 **No. There is no API.** |
| **In string mode** | Throws (unless permissive) | ⚠️ **Does not throw** — returns a refusal *string* |
| **In `Generable` mode** | Throws, always, even under permissive guardrails | Throws |
| **Changes when?** | Any time, out of band with OS updates | On model updates (26.0/26.4/27.0) |

#### "One enum, two cases" is not "one mechanism"

Since iOS 27 both live on `LanguageModelError`, and Apple's own sample code matches them in the
**same arm**:

> ✅ **VERIFIED (Apple sample code, two independent archives)** —
> `Origami/Models/Error+DisplayMessage.swift:19-20` and
> `LLMSearchUsingCoreSpotlightApp/Error+DisplayMessage.swift`:
> ```swift
> case .guardrailViolation, .refusal:
>     return "Origami can't work with that. Try a different photo or prompt."
> ```

It is tempting to read that as Apple collapsing the distinction. It is not. What Apple collapsed is
the **user-facing copy**, and it collapsed it for the reason §4.2 gives: you cannot tell the user
*which* rule fired without telling an attacker the same thing, so both decline paths get one
generic apology. That is good UX advice and you should copy it.

The distinction survives everywhere it matters, and none of it is user-facing:

- **Which knob applies.** `.permissiveContentTransformations` moves `.guardrailViolation` traffic
  and has no authority over `.refusal` at all — Apple documents this explicitly (§5.2), and thread
  836673 is the field report (§4.5).
- **Which call shape is affected.** In permissive string mode `.guardrailViolation` becomes
  *unreachable* while `.refusal` keeps firing.
- **What changes it.** Guardrails move out of band with OS releases; the model's own refusal
  behaviour moves with the model version.
- **What you log.** Aggregate them in the UI, separate them in your telemetry, or you cannot tell a
  guardrail regression (§5.3, fixable by rewording) from a model regression (§4.5, not fixable at
  all) when your success rate drops.

So: **one message to the user, two counters in your metrics, two entirely different mitigation
plans.** A `case .guardrailViolation, .refusal:` arm in your view layer is correct. The same arm in
your classifier (§10.3) throws away the only information you have.

### 4.2 What a guardrail violation looks like

> ✅ **VERIFIED (Apple docs)** — the catch pattern, verbatim from the Safety article:

```swift illustrative
do {
    let session = LanguageModelSession()
    let topic = // A potentially harmful topic.
    let prompt = "Write a respectful and funny story about \(topic)."
    let response = try await session.respond(to: prompt)
} catch LanguageModelError.guardrailViolation(let violation) {
    // Handle the safety error.
}
```

The `GuardrailViolation` payload has **no case-specific fields** — just the universal
`debugDescription` and `metadata` that every payload struct carries. You cannot ask *which* rule
fired or *which* span triggered it. That is by design (telling an attacker precisely what tripped
the filter is itself a safety problem), and it is why the recovery UX has to be generic.

Real, documented false positives from the forums, for calibration on how sensitive this classifier
has been:

| Blocked prompt / word | Thread | Era |
|---|---|---|
| *"How can I **kill** deer ticks using a clothing treatment?"* | 788053 | 26.0 |
| *"I get safety violations just asking for a **taco recipe**"* | 788053 (community reply) | 26.0 |
| **"frunk"** (front trunk of an EV) | 820819 | 26.4 |
| **"Lock Pride"** — *Pride* is the user's car's name | 820819 | 26.4 |
| *"Tell me if the car is plugged in"* blocked; *"Is the car plugged in?"* fine | 820819 | 26.4 |
| Asking the model whether a user is in **deep distress**, to show crisis-support resources | 833614 (**FB20828230**) | 26.x |

That last row is worth sitting with. A digital-wellbeing app ("one sec") wanted to detect distress
in order to *surface crisis support*, and the guardrails blocked exactly the safety-critical path.
DTS acknowledged it: *"Thanks for filing the feedback report. It's under the investigation of
Foundation Models framework team."* Still open at capture.

Apple has been reducing this false-positive rate:

> ✅ **VERIFIED (Apple docs, updates page, "February 2026")** — *"Reduce the possibility of blocking
> benign content with improved guardrails for `SystemLanguageModel`."*
>
> ✅ **VERIFIED (transcript, WWDC26 session 241)** — *"You may have noticed adjustments in **iOS 26.4
> to reduce the number of false positives**, and we're continuing to make even more improvements in
> iOS 27."*

### 4.3 ⚠️ SILENT FAILURE: the refusal that is just a `String`

This is the single most under-appreciated behaviour in the framework.

> ✅ **VERIFIED (Apple docs, Safety article)** — verbatim:
> > When you generate a string response, and the model refuses a request, **it generates a message
> > that begins with a refusal like "Sorry, I can't help with"**.
> >
> > **You might not be able to programmatically determine whether a string response is a normal
> > response or a refusal**, so design the experience to anticipate both. If it's critical to
> > determine whether the response is a refusal message, initialize a new `LanguageModelSession` and
> > prompt the model to classify whether the string is a refusal.
> >
> > When you use guided generation to generate Swift structures or types, **there's no placeholder
> > for a refusal message. Instead, the model throws** a refusal error.

Restated as a rule:

> **In string mode, a model-level refusal is not an error. It is a successful `respond(to:)` call
> that returns a `String` saying no.** `try` succeeds. No `catch` arm runs. Your `response.usage`
> looks normal. Your analytics record a success. Your user sees "Sorry, I can't help with that"
> rendered in your beautiful custom result view.

The consequences are worse than they first look:

- **Your error handling never runs.** All the graceful-degradation work in §10 is bypassed.
- **Your retry logic never runs.** You will not try PCC, you will not rephrase, you will not fall
  back.
- **Your metrics lie.** Success rate looks fine; the feature is broken.
- **Cache and transcript pollution.** The refusal string is now a `.response` entry in the
  transcript, and the model has just seen itself refuse — which measurably increases the chance it
  refuses again on the next turn. A single silent refusal can poison a conversation.

Apple's own suggested detection — *"initialize a new `LanguageModelSession` and prompt the model to
classify whether the string is a refusal"* — costs you a second inference round-trip per response.
That is a real cost on-device. Three practical strategies, in increasing order of cost:

1. **Prefix check.** Cheap, imperfect, locale-fragile. Apple names the shape ("begins with a refusal
   like 'Sorry, I can't help with'") but does **not** publish an exhaustive list of refusal
   prefixes, and the strings are localized. Use it as a *signal*, never as a gate.
2. **Generate a `Generable` instead of a `String`.** This is the highest-leverage fix, and it is
   free: in guided-generation mode the refusal is thrown as an error rather than returned as text.
   If knowing about refusals matters to your feature, **stop generating strings**. Even a
   single-field `@Generable struct Answer { let text: String }` converts a silent failure into a
   catchable one.
3. **Classifier session.** Apple's suggestion. Correct, expensive, and worth it only when a missed
   refusal is a safety or correctness problem in its own right.

Strategy 2 is the one to reach for by default, and it is a genuinely surprising piece of advice:
*use guided generation as an error-handling mechanism*, not just as a parsing convenience. See
[Guided generation and `Generable`](02-guided-generation-and-streaming.md).

### 4.4 What a thrown refusal looks like

> ✅ **VERIFIED (Apple docs, Safety article)** — reproduced from the article, **but note it is
> written against the deprecated 26-era error type**, and the `explanation` handling is corrected
> against the SDK interface: the accessor returns a `Response<String>`, so the message is its
> `.content` (Apple's printed snippet binds `message` directly):

```swift compile:27 imports:FoundationModels
do {
    let session = LanguageModelSession()
    let topic = ""  // A sensitive topic.
    let response = try await session.respond(
        to: "List five key points about: \(topic)",
        generating: [String].self
    )
} catch LanguageModelSession.GenerationError.refusal(let refusal, _) {
    // Generate an explanation for the refusal.
    if let response = try? await refusal.explanation {
        let message = response.content
        // Display the refusal message.
    }
}
```

Two things about Apple's printed version of this snippet. It uses `LanguageModelSession.GenerationError.refusal(_:_:)`
— **two** associated values, the deprecated form — so on an Xcode 27 build it will not match. And
`GenerationError.Refusal.explanation` is `async` there ("takes time for the model to generate"),
which tells you something important regardless of the type: **the explanation is itself generated by
the model on demand.** It is not a constant. Asking for it costs an inference.

> ✅ **VERIFIED (SDK interface)** — the deprecated accessor's async shape is confirmed in
> `notes/sdk-interfaces/FoundationModels-26.5-macos.swiftinterface` (module 1.5.2):
> `GenerationError.Refusal` exposes `var explanation: Response<String> { get async throws }` plus a
> streaming `var explanationStream: ResponseStream<String> { get }`. The iOS 27
> `LanguageModelError.Refusal` accessor has the same asynchronous, response-wrapped shape.[^refusal-api]

The 27 equivalent is `LanguageModelError.refusal(_:)` with a single `Refusal` payload; await its
`explanation` and read `.content` from the returned response.

Note also that `generating: [String].self` in Apple's snippet is guided generation — which is
exactly why this one throws instead of returning a polite paragraph.

### 4.5 The iOS 27 regression: forum thread 836673, reproduced faithfully

This is the case study that makes the whole distinction concrete, and it is, in the judgement of
this series, **the most commercially dangerous unanswered thread in the corpus**.

**Thread 836673** — *"Foundation Models: Model-level refusal regression on iOS 27 beta for health
app prompts (not guardrailViolation)"*, posted by **rileygersh**, **2026-07-01**. One reply. No
Apple reply at capture (2026-07-27). Filed as **FB23513774**.

**The app.** A shipping App Store health app. Its feature summarises **the user's own glucose and
menstrual-cycle data** — data the user entered or synced themselves, being summarised back to them.
Not third-party content. Not generated content about anyone else. The most defensible possible
framing of "sensitive" data use.

**The history.** Working on iOS 26.x since early 2026. In production. Real users.

**The break.** On **iOS 27 beta 2**, *every prompt* was refused.

**The critical detail — the reason this thread is worth a page of a guide.** The error surfaced as
**`LanguageModelError`** with the messages *"The model refused to answer"* and *"May contain
sensitive content"* — and **not** as `GenerationError.guardrailViolation`. The developer's own
diagnosis, quoted in the thread: *"Classifier passes, but model itself refuses."* That is, the
guardrail layer let the prompt through; the model declined on its own.

**What did not help.** `SystemLanguageModel(guardrails: .permissiveContentTransformations)` made no
difference. Of course it didn't — see §5.2 and the table in §4.1: permissive guardrails configure
the classifier, and the classifier was never the thing blocking.

**Trigger vocabulary reported:** *"luteal phase"*, *"progesterone"*, *"glucose"*, *"time in range"*,
*"diabetes"*.

**Corroboration.** A second developer, building a journaling app, reported the same class of
regression on iOS 27 beta.

#### Unpacking the taxonomy the report itself slightly blurs

The reporter frames the finding as *"`LanguageModelError`, NOT `GenerationError.guardrailViolation`"*.
That phrasing conflates **two orthogonal axes**, and separating them is the whole point of this
section:

- **Axis 1 — which enum.** In iOS 27 `guardrailViolation` *also* lives on `LanguageModelError` —
  Apple's own sample code matches the two in a single arm (§4.1). So "it was `LanguageModelError`"
  does not by itself distinguish a guardrail violation from a refusal; both are `LanguageModelError`
  cases in 27. What it *does* rule out is the deprecated 26-era enum, which is consistent with an
  Xcode 27 build (§3.1).
- **Axis 2 — which mechanism.** The distinguishing evidence is the *message*: **"The model refused
  to answer"** is, character for character, Apple's documented one-liner for
  `LanguageModelError.refusal(_:)`. Apple's one-liner for `.guardrailViolation(_:)` is a different
  sentence entirely ("The model's safety guardrails were triggered by…"). Combined with the
  developer's "classifier passes, but model itself refuses" and with permissive guardrails having no
  effect, the mechanism is **`.refusal`**, not `.guardrailViolation`.

That is the reading this guide adopts, and it is an inference from three converging pieces of
evidence rather than an Apple statement — so:

> 🟡 **RECONSTRUCTED** — that thread 836673's error is specifically `LanguageModelError.refusal(_:)`
> is our reading, based on (a) the exact string match to Apple's documented case description,
> (b) the reporter's own classifier-vs-model diagnosis, and (c) permissive guardrails not helping.
> Apple has not answered the thread. If you can reproduce this, capture the enum case in a debugger
> and post it — that would settle it.

> 🔴 **GAP — "May contain sensitive content" is unmapped.** The second string the reporter quotes
> does not match any documented `LanguageModelError` case description in the corpus, and it does not
> match the `SensitiveContentAnalysisML` error text either (§7.1). It may be a `debugDescription`, an
> underlying error, or a message from a component below `FoundationModels`. Nothing in this corpus
> identifies it. What would resolve it: a full `NSError` dump including
> `NSMultipleUnderlyingErrorsKey` from a reproduction.

#### The interpretation that matters for planning

Apple reduced guardrail false positives in **26.4** and said it was "continuing to make even more
improvements in iOS 27" (§4.2). Simultaneously, a class of prompt that passed on 26.x began hitting
*model-level* refusals on 27 beta 2. Those two facts are consistent with **traffic moving between
the layers**: a looser classifier plus a differently-trained model can mean fewer
`guardrailViolation`s and more `refusal`s, for a net "safety behaviour" that feels similar in
aggregate and is *completely different* to handle in code.

> 🟡 **RECONSTRUCTED — this is our synthesis, not Apple's claim.** Apple has not said that refusal
> traffic increased in 27, has not answered 836673, and has published no before/after data. What is
> verified: 26.4 loosened guardrails (Apple docs + session 241); 27 "continues improvements"
> (session 241); a shipping app that passed on 26.x hit model-level refusals on 27 b2 (836673 +
> one corroborating report). The causal story linking them is an inference.

**If it is right, the planning consequence is severe:** every mitigation the ecosystem built for
this problem — `.permissiveContentTransformations`, prompt rewording around known guardrail
triggers, deny-list pre-screening — targets the *classifier*. None of them touch model-level
refusals. There is no API for the second layer at all. Your only levers are prompt design, the
`Generable` trick from §4.3 to at least *see* refusals, evaluation suites to detect the change
early, and `LanguageModelFeedback` to tell Apple (§9).

**And the version-floor consequence:** if you ship a health, wellness, journaling, medical, mental
health, or safety feature on `SystemLanguageModel`, **you must re-run your prompt suite against
every OS beta**, not just every OS release. This app's failure mode was total — *every* prompt — and
the developer only found out because they were testing betas. An app that ships and waits for the
public release finds out from App Store reviews.

### 4.6 The decision table

Given a failure, which mechanism was it?

| Observation | Mechanism | What to do |
|---|---|---|
| `catch LanguageModelError.guardrailViolation` fires | Classifier | Try `.permissiveContentTransformations` (string mode only). Reword. File Feedback. |
| `catch LanguageModelError.refusal` fires | Model | Guardrail config will **not** help. Reword, decompose the task, or route to a different model. File Feedback. |
| `respond(to:)` returns a `String` starting "Sorry, I can't…" | Model, in string mode | ⚠️ Silent. Switch to `Generable` so it throws (§4.3). |
| Same prompt worked last week, no rebuild, no OS update | Classifier | Guardrails update out of band (§5.3). Re-run your prompt suite. |
| Broke on an OS beta upgrade | Either — most likely the model | Model version changed (26.0-26.3 / 26.4 / 27.0). Evaluate. |
| Permissive guardrails made no difference | Model | Confirmed refusal, not guardrail. |
| Fails in `Generable` mode but not string mode | Classifier | `.permissiveContentTransformations` does not apply to guided generation (§5.2). |

---

## 5. Guardrail configuration and its blind spot

### 5.1 The API

> ✅ **VERIFIED** — `/documentation/foundationmodels/systemlanguagemodel/guardrails`, iOS 26.0+
> (no watchOS):

```swift illustrative
struct Guardrails              // Sendable, SendableMetatype — note: NOT Equatable
static let `default`: SystemLanguageModel.Guardrails
static let permissiveContentTransformations: SystemLanguageModel.Guardrails
```

and the initializer that takes them:

```swift illustrative
convenience init(useCase: SystemLanguageModel.UseCase = .general,
                 guardrails: SystemLanguageModel.Guardrails = Guardrails.default)
```

> ✅ **VERIFIED (SDK interface)** — both guardrail-taking initializers are confirmed in Apple's
> compiler-emitted `notes/sdk-interfaces/FoundationModels-26.5-macos.swiftinterface` (module 1.5.2),
> which supersedes the earlier forum-post-and-single-sample attestation of the `guardrails:` init:
> `convenience init(useCase: UseCase = .general, guardrails: Guardrails = Guardrails.default)` **and**
> `convenience init(adapter: Adapter, guardrails: Guardrails = .default)`. The `guardrails:` default is
> `Guardrails.default` in both, and `Guardrails` is a `struct` conforming to `Sendable` only —
> confirming it is **not** `Equatable` — exposing exactly the two `static let`s above and nothing else.
> Both the inits and `Adapter` are 26.0-era types (relevant to Part 17's adapter framing).
> **27.0 changes one of them (2026-07-29):** the `useCase:guardrails:` init is unchanged in the 27.0
> interface (`FoundationModels-27.0-macos.swiftinterface:389`), but `init(adapter:guardrails:)` and
> the whole `SystemLanguageModel.Adapter` type are marked
> `@available(iOS/macOS/visionOS, deprecated: 26.4, obsoleted: 27.0)` (`:386-392, :464-471`) —
> BEFORE: works, 26.0–26.x · AFTER: **does not compile against the 27.0 SDK**. Custom-adapter code
> must migrate off `SystemLanguageModel.Adapter` when it moves to Xcode 27.

Apple's own doc strings:

- `default` — *"Guardrails that default to ensuring that the system blocks unsafe content in prompts
  and responses."*
- `permissiveContentTransformations` — *"Guardrails that allow for permissively transforming text
  input, including potentially unsafe content, to text responses."*

Note that the initializer's `useCase:` parameter is defaulted, so `SystemLanguageModel(guardrails:)`
with a single argument compiles — and so does the bare `SystemLanguageModel()`.

> ✅ **VERIFIED (Apple sample code)** — the bare initializer is the 2026 house style: Origami and the
> Spotlight sample use `SystemLanguageModel()` **exclusively**, never `.default`; Book Tracker uses
> both. `notes/web/apple-sample-code.md:93`. The older `.default` static is not deprecated and every
> docs snippet still uses it; treat the two as interchangeable and pick one per codebase.

Usage, verbatim from the Safety article:

```swift compile:27 imports:FoundationModels
let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
```

and the full session construction, in shipping Apple sample code:

> ✅ **VERIFIED (Apple sample code)** — `BookTracker/Services/BookTaggingService.swift:1455` (via
> `notes/web/apple-sample-code.md:1452-1458`), with the same construction repeated in the sample's
> evaluation suite at `SearchBooks.swift` (`:1153-1160`):
> ```swift
> let session = LanguageModelSession(
>     model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
>     instructions: instructions
> )
> ```
> The same shape was reported by a developer a month earlier, before it was well documented —
> ✅ **VERIFIED (forum thread 835777, developer code, June 2026)**:
> ```swift
> LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations))
> ```

There is a second lesson in Book Tracker's use of it, and it is about evaluation rather than safety:
the sample constructs the model **the same way in the eval as in the feature**. If your feature runs
permissive and your evaluation runs default, you are measuring a system you do not ship. See
[Part 6 — Evaluations](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md).

There is a **history lesson** in that thread pair. In June 2025, thread 788053 asked about guardrail
configuration options and DTS answered:

> ✅ **VERIFIED (Apple staff, thread 788053)** — *"As of today, you only have the `.default` option,
> meaning that you use the system-provided guardrail. I'd suggest that you file a feedback report if
> the system guardrail doesn't work for your use case (over restrictive, for example)"*

One year later `.permissiveContentTransformations` exists. The Feedback-report advice worked. It is
slow, but it is the mechanism.

Note the Python SDK mirrors exactly these two options and nothing else, which is a useful
independent confirmation that the set is complete:

> ✅ **VERIFIED** — `apple/python-apple-fm-sdk`, `core.py`, mapped to Swift at
> `FoundationModelsCBindings.swift:107-137`:
> ```python
> class SystemLanguageModelGuardrails(IntEnum):
>     DEFAULT = 0
>     PERMISSIVE_CONTENT_TRANSFORMATIONS = 1
> ```

> ✅ **RESOLVED for the 27.0 beta (2026-07-29) — the set is exactly two.** The interface declares
> `struct Guardrails` with precisely `static let default` and
> `static let permissiveContentTransformations`, and no other member — ✅ **SDK-verified**
> (`FoundationModels-27.0-macos.swiftinterface:335-344`). The structural caveat stands: a
> struct-of-statics is the shape Apple uses when it intends to grow the set, so treat "two options"
> as *"two options as of the 27.0 betas"*, not a promise.

### 5.2 The blind spot: it does not apply to `Generable`

Developers discovered this before Apple documented it. Here is the developer's own comment, left in
the code they posted to the forums:

> ✅ **VERIFIED (forum thread 835777, developer, June 2026)** — verbatim, including the emphasis:
> ```swift
> LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations))
> // I'm aware that .permissiveContentTransformations does not apply to Generable, but I'd really
> // really really really love it, if it did!.
> ```

That folk knowledge is now confirmed and made precise by Apple's own documentation, and the precise
version is more interesting than the folk version:

> ✅ **VERIFIED (Apple docs, Safety article)** — verbatim, three sentences that between them define
> the entire semantics:
>
> > **This mode only works for generating a string value.** When you use guided generation, the
> > framework runs the default guardrails against model input and output as usual, and generates
> > `guardrailViolation` and `refusal` errors as usual.
> >
> > The session **skips the guardrail checks** in this mode, so it **never throws a
> > `guardrailViolation` error when generating string responses**.
> >
> > However, even with the `SystemLanguageModel` guardrails off, the on-device system language model
> > **still has a layer of safety. For some content, the model may still produce a refusal message.**

Three separate facts, each load-bearing:

1. **Permissive mode is per-*call-shape*, not per-model.** The same `SystemLanguageModel` instance,
   in the same session, gives you skipped guardrails on `respond(to:)` and full default guardrails
   on `respond(to:generating:)`. Nothing in the type system tells you this. A session configured
   permissively is only permissive for *some* of its own methods.
2. **In permissive string mode, `guardrailViolation` becomes unreachable.** Not "less likely" —
   Apple says "never throws". If you see one, you were in guided-generation mode.
3. **The model's own refusal layer is unaffected, always.** This is the sentence that explains
   thread 836673 completely (§4.5): the health app turned on permissive guardrails and nothing
   changed, because permissive guardrails have no authority over layer two.

⚠️ **SILENT FAILURE — the mode-flip is invisible.** Consider a codebase that starts with permissive
guardrails and string responses, working fine. Someone later adds structured output — a perfectly
ordinary refactor, `respond(to:)` → `respond(to:generating: Summary.self)` — to stop parsing
strings. The guardrails silently switch back to `.default` for that call. Prompts that shipped for
months start throwing `guardrailViolation`. Nothing in the diff mentions guardrails. Nothing in the
compiler output mentions guardrails. The `SystemLanguageModel(guardrails:)` line is untouched and
sitting right there in the file, looking like it is still in effect.

**This trap has already caught Apple.** Both places Book Tracker constructs a permissive model, the
very next line calls guided generation:

> ✅ **VERIFIED (Apple sample code)** — `BookTracker/Services/BookTaggingService.swift:1452-1459`
> and `SearchBooks.swift:1152-1162`, via `notes/web/apple-sample-code.md`:
> ```swift
> let session = LanguageModelSession(
>     model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
>     instructions: instructions
> )
> let response = try await session.respond(to: prompt, generating: BookTags.self)
> ```

Read that against Apple's own documented semantics three paragraphs up — *"This mode only works for
generating a string value. When you use guided generation, the framework runs the default guardrails
against model input and output as usual"* — and the conclusion is unavoidable: **in Apple's own
sample, the `guardrails:` argument does nothing.** Both call sites generate a `@Generable` type, so
both run default guardrails.

> 🟡 **RECONSTRUCTED (the conclusion, not either fact).** Both inputs are ✅ verified — the sample's
> code, and Apple's documentation sentence — but no source states "this line is a no-op in this
> sample". The deduction is direct, and the only way out of it is if the docs sentence is wrong. If
> you can demonstrate permissive guardrails affecting a `respond(to:generating:)` call, that is a
> documentation bug worth a Feedback, and it would change this section.

The reason to labour the point is not to score off Apple. It is that this is the exact refactor
described above, frozen in a shipping sample: someone wrote the permissive line because the feature
handles book reviews that may contain unpleasant content, and someone — possibly the same person —
wrote the guided-generation call because tags are structured. Both decisions are individually
right. Together they produce a line of code that reads as a safety configuration and is inert.
If you need permissive handling of user content *and* structured output, the only shape that works
is two calls: a permissive string call to transform the content, then a default-guardrail
`Generable` call over your own intermediate text.

The named use cases Apple gives for permissive mode tell you what it is *for* — text-in/text-out
transformations of content that is already in your app, not open-ended generation:

> ✅ **VERIFIED (Apple docs)** — verbatim:
> > - When you want the model to **tag the topic of conversations in a chat app** when some messages
> >   contain profanity.
> > - When you want to use the model to **explain notes in your study app** that discuss sensitive
> >   topics.

Both are "the user's own content, transformed". Neither is "generate something new". The name is
literal: *permissive content **transformations***.

### 5.3 Guardrails change under a running app

Thread **835777** is titled *"Has something in FoundationModels guardrails changed recently?"*. A
developer with a shipping app observed guardrail behaviour changing over a couple of weeks, with no
app update and no OS update on their side.

They were right, and Apple documents the mechanism:

> ✅ **VERIFIED (Apple docs, Safety article)** — verbatim:
> > **Apple may update the built-in guardrails at any time outside of the regular OS update cycle.**
> > This is done to rapidly respond, for example, to reported safety concerns that require a fast
> > response. Include all of the prompts you use in your app in your test suite, and run tests
> > regularly to identify when prompts start activating the guardrails.

This is the most operationally important sentence in the Foundation Models documentation, and it is
buried in an article most people never open. Sit with what it means:

- **Your safety behaviour is not pinned by anything you control.** Not your binary. Not your
  deployment target. Not the user's OS version.
- **There is no notification.** No API tells you the guardrails changed. No release note necessarily
  covers it, because it is explicitly out of band with releases.
- **"Run tests regularly" means in CI, on a schedule, against real devices** — not "before each
  release". A release-gated test suite cannot detect a change that happens between releases.

Apple's answer to the "what do I do about it" question is the Evaluations framework, and this is the
strongest argument for adopting it: it is not primarily a prompt-quality tool, it is a **regression
detector for a dependency you cannot version-pin**. Session 319 and thread 833642 both say the same
thing — there is no model pinning API, so evaluate. See
[Part 6 — Evaluations](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md).

Apple's response when you report a false positive:

> ✅ **VERIFIED (Apple staff, thread 835777)** — *"If you are seeing guardrails false positives, we
> recommend filing a Feedback from the Feedback Assistant. Make sure to include as much information
> as possible about the transcript: **tools exposed, instructions, prompt**…"*

Note the three things they want: **tools exposed, instructions, prompt**. Not just the prompt. That
is exactly what `logFeedbackAttachment` serialises for you (§9).

### 5.4 What actually reduces refusals, when no knob applies

Since layer two has no API, prompt and schema design *are* your mitigation. Apple's Safety article
gives four concrete techniques.

**Bound the input.** Convert free text into a closed set before it reaches the model:

```swift compile:27
enum TopicOptions {
    case family
    case nature
    case work
}
let topicChoice = TopicOptions.nature
let prompt = """
    Generate a wholesome and empathetic journal prompt that helps \
    this person reflect on \(topicChoice)
    """
```

**Bound the output.** A `@Generable enum` gives the model nowhere to put a refusal, which converts a
would-be refusal into either a valid case or a thrown error — both better than a paragraph:

```swift compile:27 imports:FoundationModels
@Generable
enum Breakfast {
    case waffles
    case pancakes
    case bagels
    case eggs
}
let session = LanguageModelSession()
let userInput = "I want something sweet."
let prompt = "Pick the ideal breakfast for request: \(userInput)"
let response = try await session.respond(to: prompt, generating: Breakfast.self)
```

**Deny-list, on both sides.** Apple's pattern checks input *and* output:

```swift illustrative
let session = LanguageModelSession()
let userInput = // The input a person enters in the app.
let prompt = "Generate a wholesome story about: \(userInput)"

// A function you create that evaluates whether the input
// contains anything in your deny list.
if verifyText(prompt) {
    let response = try await session.respond(to: prompt)

    // Compare the output to evaluate whether it contains anything in your deny list.
    if verifyText(response.content) {
        return response
    } else {
        // Handle the unsafe output.
    }
} else {
    // Handle the unsafe input.
}
```

> ✅ **VERIFIED (Apple docs)** — *"A deny list can be a simple list of strings in your code that you
> distribute with your app. Alternatively, **you can host a deny list on a server** so your app can
> download the latest deny list... **avoids requiring a full app update if a safety issue arise.**"*

The server-hosted variant is the same architectural move Apple made with the guardrails themselves,
for the same reason: safety fixes need a faster cycle than app review.

**Instructions, in capitals, and never with user input in them.** Two Apple rules that pull in
different directions and must both be obeyed:

> ✅ **VERIFIED (Apple docs)** — *"Use **uppercase words** to emphasize the importance of certain
> phrases for the model."*
> ```swift
> let instructions = """
>     Always respond in a respectful way. \
>     If someone asks you to generate content that might be sensitive, \
>     you must decline with 'Sorry, I can't do that.'
>     """
> ```
>
> *"**NOTE** — A session obeys instructions over a prompt, so **don't include input from people or
> any unverified input in the instructions**. Using unverified input in instructions makes your app
> **vulnerable to prompt injection attacks**, so write instructions with content you trust."*

Instructions are strong *because* the model privileges them over prompts — which is exactly why user
data must never be interpolated into them. Put your rules in instructions; put the user's words in
the prompt; never the reverse.

The uppercase trick is also Apple's recommended workaround for a *different* broken feature. When
`@Guide(.anyOf:)` failed to constrain generation (thread 812501, reproduced by Apple staff — the
model generated "Beijing" for a guide listing London/New York/Paris), Apple's suggested fix was to
drop the guide and put the constraint in capitals:

> ✅ **VERIFIED (Apple staff, thread 812501)** — recommended workaround, verbatim:
> ```
> You can ONLY call the tool getCityInfo for the these cities: "London",
> "Paris", "New York". For questions about all other cities you MUST tell
> the user "Sorry, I can't look up that city."
> ```

That is a schema bug rather than a safety one, and it belongs to
[tool calling](03-tools-and-tool-calling.md) — but it is the same technique, and it tells you how much of
this stack currently runs on capital letters.

**Finally: the risk-assessment discipline Apple asks for.**

> ✅ **VERIFIED (Apple docs)** — verbatim:
> > - List each AI feature in your app.
> > - For each feature, list possible safety risks that could occur, even if they seem unlikely.
> > - For each safety risk, score how serious the harm would be if that thing occurred, from **mild
> >   to critical**.
> > - For each safety risk, assign a strategy for how you'll mitigate the risk in your app.
>
> Test-input categories:
> > - Input that is nonsensical, snippets of code, or random characters.
> > - Input that includes sensitive content.
> > - Input that includes controversial topics.
> > - Vague or unclear input that could be misinterpreted.
>
> > For each prompt test, **log the timestamp, full input prompt, the model's response, and whether
> > it activates any built-in safety** or mitigations you've included in your app... **To scale your
> > tests, consider using a frontier LLM to auto-grade the safety of each prompt.**

That last clause is notable: Apple is explicitly recommending you use a frontier model to grade
your on-device model's safety behaviour at scale.

---

## 6. Context-window overflow

### 6.1 The error, and the budget it refers to

> ✅ **VERIFIED (Apple docs)** — `/documentation/foundationmodels/managing-the-context-window`,
> recovery pattern verbatim (note the 27-era case name):

```swift prelude:guide-context
do {
    // Perform a request that exceeds the context window.
    let response = try await session.respond(to: prompt)
} catch LanguageModelError.contextSizeExceeded(let context) {
    // Handle exceeding the context window size by creating a new session.
} catch {
    // Handle other errors that are thrown.
}
```

The payload carries both numbers you need: `contextSize: Int` and `tokenCount: Int`. So you know not
just *that* you overran but *by how much*, which lets a compaction routine target a ratio rather
than guess.

What consumes the budget:

> ✅ **VERIFIED (Apple docs)** — *"This includes all prompts, instructions, tool definitions and
> their input and output, generable type schemas, and all of the model's responses."*

Tool definitions and `@Generable` schemas are the two people forget. A tool's JSON Schema is in the
context on **every** turn, not just the turn it gets called.

Tokenization intuition, from the same page:

> ✅ **VERIFIED (Apple docs)** — *"In Latin alphabet languages such as English, a token typically
> represents three to four characters. For multibyte languages such as **Chinese, Japanese, Korean,
> and Vietnamese a token typically represents one character**."* And: *"the word `Sourdough` might be
> one token, but a phone number like `+1-(408)-555-0123` might use **over ten tokens**."*

The CJK/Vietnamese line has a direct product consequence: **the same feature has roughly a
three-to-four-times smaller effective context in Chinese, Japanese, Korean and Vietnamese** than in
English. If your app ships in those markets, your compaction thresholds cannot be one global
constant.

⚠️ **SILENT FAILURE — `maximumResponseTokens` truncates mid-sentence without error.**

> ✅ **VERIFIED (Apple docs)** — *"**IMPORTANT** — Only use `maximumResponseTokens` to prevent
> verbose responses. **Limiting tokens can cause the model to generate incomplete or grammatically
> incorrect responses, like "A cat is a small."**"*

You get a successful response containing "A cat is a small." No error. Combine this with the
`@Generable` path and it is worse: a truncated JSON body may fail to decode, and you will chase a
decoding bug that is actually a budget setting.

Apple's cheapest token saving, from the Instruments article:

> ✅ **VERIFIED (Apple docs)** — *"Excluding the schema removes redundant schema information and
> **can save hundreds of tokens per request**."*
> ```swift
> do {
>     for try await partial in session.streamResponse(to: myPrompt,
>                                                     generating: MyCustomItinerary.self,
>                                                     includeSchemaInPrompt: false) {
>         // Handle the partial result.
>     }
> } catch {
>     // Handle the error that the method throws.
> }
> ```
> But the caveat on the parameter itself: *"Consider using the default value of `true` for
> `includeSchemaInPrompt`. The exception to the rule is when the model has knowledge about the
> expected response format, either because it has been trained on it, or because it has seen
> exhaustive examples during this session."*

In iOS 27 this moved: `ContextOptions.includeSchemaInPrompt` is the new home, and the `respond`
overloads that take `metadata:` drop the standalone parameter.

### 6.2 The iOS 26 recovery pattern, and Apple's original advice

> ✅ **VERIFIED (Apple staff, DTS Engineer signed "-J", thread 790736)** — the original 26-era
> guidance:
> > "You are correct that currently the token limit for Foundation Models framework is around 4,000.
> > There is no guarantee that this will stay the same forever or across devices, however, so we
> > encourage developers to write their code in a way that is ready to handle the context window
> > limit when it arises.
> >
> > As mentioned in this session, your app can catch the `exceededContextWindowSize` error and handle
> > accordingly. One suggestion for this is to summarize a session's transcript thus far, and create
> > a new session with the condensed transcript, but the exact implementation will depend on your
> > use-case."

Apple's canonical implementation of "condensed transcript" — keep the first entry (instructions) and
the last (most recent context):

> ✅ **VERIFIED (Apple docs)**:

```swift compile:27 imports:FoundationModels
func newContextualSession(with originalSession: LanguageModelSession) -> LanguageModelSession {
    let allEntries = originalSession.transcript
    let condensedEntries = [allEntries.first, allEntries.last].compactMap { $0 }
    let condensedTranscript = Transcript(entries: condensedEntries)
    let newSession = LanguageModelSession(transcript: condensedTranscript)
    newSession.prewarm()
    return newSession
}
```

> *"The first transcript entry often contains important instructions and the last entry contains the
> most recent context. By preserving the first and last entry, you maintain continuity while
> dramatically reducing token usage."*

Note `prewarm()` on the new session — rebuilding a session throws away the KV cache, and prewarming
starts rebuilding it before the user's next prompt lands.

The developer complaint this pattern does not fully answer, from thread 817502:

> ✅ **VERIFIED (forum thread 817502, developer ilkomiliev)** — once `exceededContextWindowSize` is
> caught, **all context is lost**, and the context window size was not exposed by the API.

The second half of that complaint was fixed: `contextSize` (26.4, back-deployed) and
`tokenCount(for:)` (26.4) exist now.

> ✅ **VERIFIED (Apple staff, DTS Engineer Ziqiao Chen, thread 817502)** — *"A good news is that,
> since iOS 26.4 (and friends), we have the following API that returns the token count for the
> specified instructions: `tokenCount(for:)`"*

Also referenced there: **TN3193 — *Managing the on-device foundation model's context window***
(`https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window`).

### 6.3 What developers hand-rolled, and what replaced it

Thread **835927** ("Feedback on Foundation Models context management wrapper", rickystone, June
2026) is the best-documented example of the community solving this before Apple shipped a solution.
The developer built and published `github.com/ricky-stone/FoundationContext`, which:

1. checks the transcript's token count via **`tokenCount(for:)`**,
2. compacts at a threshold,
3. **retries once on `exceededContextWindowSize`**,
4. rebuilds a session from the compacted `Transcript`.

…and then asked Apple whether that was a sane use of the API. It was, and it is now partly obsolete:

> ✅ **VERIFIED (Apple staff, Frameworks Engineer, thread 835927)** — verbatim:
> > "The way you're doing compaction is generally correct, and recreating the session with the new
> > transcript is correct if you're targeting **iOS 26**.
> >
> > In **iOS 27**, session's `transcript` property is now **mutable**, and transcript has a
> > **`history` accessor** for updating everything except the instructions, so you can just use that
> > instead of recreating the session.
> >
> > We've also introduced the notion of **`DynamicProfiles`** as a way to clip into the session
> > lifecycle without having to wrap it, and open sourced some context management utilities similar
> > to your own! You can use them as-is, or use them as inspiration to create your own context
> > management modifiers to vend to others."

So the modern shape is: **stop catching the overflow and start preventing it**, with history
modifiers from `apple/foundation-models-utilities` composed onto a profile.

> ✅ **VERIFIED** — exact signatures from `apple/foundation-models-utilities` source:
> ```swift
> // DropCompletedToolCalls.swift:38
> extension LanguageModelSession.DynamicProfile {
>   public func droppingCompletedToolCalls() -> some DynamicProfile
> }
>
> // RollingWindow.swift:36 / :64
> extension LanguageModelSession.DynamicProfile {
>   public func rollingWindow(entries: Int) -> some DynamicProfile
>   public func rollingWindow(size: RollingWindowSize) -> some DynamicProfile
> }
>
> // SummarizeHistory.swift:53
> extension LanguageModelSession.DynamicProfile {
>   public func summarizeHistory<Model: LanguageModel>(
>     entryThreshold: Int,                  // no default
>     model: Model,                         // no default
>     instructions: Instructions? = nil,
>     summaryPostamble: String? = nil
>   ) -> some DynamicProfile
> }
> ```

Two warnings before you adopt them, both verified from the package's own source and tests, because
they turn "I added context management" into "I silently broke my transcript":

⚠️ **`rollingWindow(entries:)` is a naive `suffix(n)`.** It is not transcript-aware. It will cut
between a prompt and its response, and it can drop the `.instructions` entry entirely. The
package's own test carries this comment verbatim:

> ✅ **VERIFIED** — `RollingWindowTests.swift:71-73`: *"The naive suffix(2) trim repeatedly cuts
> between a prompt and its response, so the window starts with an orphaned response. **This
> documents the (buggy) naive outcome; in practice it crashes partway through.**"*

⚠️ **Composed in the obvious order, `summarizeHistory` never fires.** Modifiers apply outside-in:
last written is outermost and runs first. So in the package's own README example —
`.summarizeHistory(entryThreshold: 10, …).rollingWindow(entries: 10).droppingCompletedToolCalls()` —
the rolling window truncates to at most 10 entries *before* summarisation sees the history, and
summarisation's gate is `history.count > entryThreshold` (strictly greater). 10 is never > 10.
**Summarisation is dead code in that configuration**, and in every composed example currently
published. Set `entryThreshold` strictly below your rolling-window size.

Full treatment of profiles and history modifiers is in
[Part 3 — Context, profiles, agentic sessions](../../part-03-context-profiles-agentic/README.md).
For this guide the point is narrower: **`contextSizeExceeded` should be your backstop, not your
strategy.**

One more trap when you mix models:

> ✅ **VERIFIED (Apple staff, thread 833626, accepted)** — *"By default, the same transcript is
> shared between each Profile. So if you move from a Profile using `PrivateCloudComputeLanguageModel`
> to one using `SystemLanguageModel` and the transcript is over `SystemLanguageModel`'s context size
> limit, you'll hit a context limit exceeded error. The recommended approach here is to apply the
> **`historyTransform`** modifier to your `SystemLanguageModel` Profile."*

A 32K PCC transcript does not fit in a 4K on-device window. Falling back from PCC to on-device
without a `historyTransform` converts one failure (PCC unavailable) into two.

Finally, the platform where none of this is possible:

> ✅ **VERIFIED (Apple staff, DTS Engineer Ziqiao Chen, thread 813757)** — on the Shortcuts "Use
> Model" action: *"The answer then is that there is currently no way to detect an error from an
> action. I checked with the Shortcuts folks and they suggested that you file a feedback report with
> your use case to request the support of try-catch in Shortcuts"*

If your feature runs inside a Shortcut, you cannot catch context overflow at all — no retry, no
fallback to PCC, nothing. Keep Shortcut-exposed prompts small by construction.

---

## 7. Errors seen in the wild that are in no enum

These are the ones that make developers think they have lost their minds: real, reproducible errors
whose domains appear in no documentation.

### 7.1 `com.apple.SensitiveContentAnalysisML error 15`

**Symptom.** A completely innocuous prompt fails in `#Playground` on Xcode 27 beta 2.

> ✅ **VERIFIED (forum thread 836285, azamsharp, 2026-06-28)** — the reproducer, verbatim:
> ```swift
> #Playground {
>
>     let session = LanguageModelSession()
>
>     let response = try await session.respond(to: "List all states of USA.")
>
>     print(response.content)
>
>
> }
> ```
> → `The operation couldn't be completed. (com.apple.SensitiveContentAnalysisML error 15.)`

There is no user content here. There is no sensitive topic. "List all states of USA." is about as
benign as a prompt gets, and it fails inside a component whose name suggests it is scanning for
sensitive *media*.

**What was tried and did not work:** toggling Apple Intelligence off and on again. Apple's replies
in the thread amounted to "file a bug" and "was it fixed in the latest beta?".

**Interpretation.** `SensitiveContentAnalysisML` is the ML backing of the Sensitive Content Analysis
framework — an image/video-oriented system, not a text one. Seeing it in the failure path of a
text-only prompt suggests the safety pipeline in the 27 betas routes through a component that was
not provisioned, rather than that anything about the prompt was flagged. That reading is consistent
with the error being total and content-independent.

> 🔴 **GAP — `com.apple.SensitiveContentAnalysisML` error 15 is undocumented.** The domain does not
> appear in any Apple documentation, release note or forum answer in this corpus, and no Apple staff
> member has explained code 15. The interpretation above is inference from the domain name, not a
> verified claim. What would resolve it: an Apple reply on 836285, a release-note entry, or a
> reproduction with a full underlying-error chain.

**What to do.** Treat it as environmental, not as a prompt problem. Reproduce on a physical device
on the newest beta (§7.3), and if it persists, file it with a sysdiagnose. Do not rewrite your
prompts chasing it.

### 7.2 `com.apple.UnifiedAssetFramework Code=5000` — the Spotlight tool's model catalog

**Symptom.** Constructing a `SpotlightSearchTool()` and running a session fails, *even though the
language model itself reports available*.

> ✅ **VERIFIED (forum thread 838904, BlueFox123, 2026-07-22)** — repro and error, verbatim:
> ```swift
> import CoreSpotlight
> import FoundationModels
>
> let tool = SpotlightSearchTool()
>
> let session = LanguageModelSession(tools: [tool])
>
> let response = try await session.respond(to: "What hikes have I gone on?")
> ```
> ```
> Model Catalog error: Error Domain=com.apple.UnifiedAssetFramework Code=5000 "There are no underlying assets (neither atomic instance nor asset roots) for consistency token for asset set com.apple.modelcatalog" UserInfo={NSLocalizedFailureReason=There are no underlying assets (neither atomic instance ...
> ```

**Apple's answer**, which is worth quoting because it establishes that this is not your fault:

> ✅ **VERIFIED (Apple staff, Apple Designer, thread 838904)** — *"Whelp, that's totally a bug. 🐛
> You're doing everything correctly! That's not an error you should ever see normally. Thanks for
> reporting! I'm filing a bug report for this, although it would definitely help if you can tell me:
> Did you update your Mac right before this error or within the past few hours before the error?
> Rebooting your Mac _should_ resolve the issue…"*

**But the suggested fix did not work.** The reporter says rebooting did **not** resolve it, and the
error persisted from macOS 27 beta 3 through beta 4.

**The diagnostic lesson.** `com.apple.modelcatalog` is a *separate asset set* from the language
model's own assets. `SpotlightSearchTool` evidently pulls its own model asset. So **availability of
`SystemLanguageModel` tells you nothing about whether a built-in tool's assets are provisioned.**
There is no availability API for tool-side assets. If you ship a feature that depends on
`SpotlightSearchTool`, you need a runtime fallback for the case where the tool fails while the model
is fine.

### 7.3 `LanguageModelError error -1`, `ModelManagerError Code=1046`, and the Simulator trap

**Symptom.** A generic, information-free error:

```
Error Domain=FoundationModels.LanguageModelError Code=-1 "The operation couldn't be completed. (FoundationModels.LanguageModelError error -1.)" UserInfo={NSMultipleUnderlyingErrorsKey=(
         "Error Domain=FoundationModels.LanguageModelError Code=-1 \"(null)\" UserInfo={NSMultipleUnderlyingErrorsKey=(\n    \"Error Domain=ModelManagerServices.ModelManagerError Code=1046 \\\"(null)\\\" UserInfo={NSMultipleUnderlyingErrorsKey=(\\n)}\"\n)}"
     ), NSLocalizedDescription=The operation couldn't be completed. (FoundationModels.LanguageModelError error -1.)}
```

**Cause, most of the time.** This is the single most important debugging fact in the corpus:

> ✅ **VERIFIED (Apple staff, Apple Designer, thread 831404, accepted answer)** — verbatim:
> > "So currently we are _not_ able to replicate this issue on macOS 27.0 and Xcode 27.0, but given
> > similar historical issues we had at launch last year, I highly suspect the underlying cause is
> > that you're running macOS 26.
> >
> > **Why?** Xcode 27.0 contains the latest SDK, but the on-device `SystemLanguageModel` is actually
> > built into the OS. **Meaning** that when you run simulator from Xcode, the simulator is actually
> > **"punching out" to macOS** to run the model, using the 26.5 model inference code in the OS.
> > Whenever we see "weird" errors like this, it's usually an underlying incompatibility between the
> > Xcode SDK and OS for running the model. :(
> >
> > **Suggested Fix** Update a physical device to 27.0."

Read that carefully, because it changes how you should think about the Simulator entirely: **the
Simulator does not contain a model.** It forwards inference to the host macOS. So a Simulator
"iPhone running iOS 27" backed by a macOS 26 host is running *26* inference code behind a *27* SDK.
Any error you see in that configuration is meaningless.

**Consequences to internalise:**

- **`-1` is not a diagnosis.** It is "something below the framework failed and the error did not
  survive the boundary". Before investigating your code, check SDK-vs-host-OS skew.
- **`-1` is not Simulator-exclusive.** A second developer (isXander, same thread) reports the same
  `-1` on a **physical iPhone 17 Pro Max with New Siri enabled**. So "update to a physical device"
  eliminates the most common cause, not all causes.
- **PCC does not work in the Simulator at all** (known issue 177684296, §2.6).
- Filed as **FB23060822** (thread 831448, *"How to obtain more value out of a generic
  `FoundationModels.LanguageModelError error -1`"*).

> 🔴 **GAP — `ModelManagerServices.ModelManagerError Code=1046` is undocumented.** The reporter
> looked and so did we: *"Maybe error code `1046` means something, but I can't find a mention of it
> in the docs."* Never explained by Apple in this corpus. What would resolve it: an Apple reply, or
> a symbol dump of `ModelManagerServices`.

DTS corroborated the general principle in a different thread:

> ✅ **VERIFIED (Apple staff, DTS, thread 837226)** — *"Apple Intelligence and the `FoundationModels`
> framework rely heavily on on-device hardware"* — test on a physical device, specifically
> **iOS 27.0 beta 3 (build 24A5380h, released 2026-07-06)**.

### 7.4 `"Tool Choice requires tools"` — when tools do not reach the inference layer

> ✅ **VERIFIED (forum thread 837226, Hunter)** — console output, verbatim:
> ```
> InferenceError::hostFailed::InferenceError::inferenceFailed::TokenGenerationCore.GuidedGenerationError.invalidConfiguration(errorMessage: "Tool Choice requires tools") in response to ExecuteRequest
> Error during session.respond. description="The operation couldn't be completed. (FoundationModels.LanguageModelError error -1.)"
> Returning empty Spotlight result. elapsedMs=3254 toolReplies=0 totalSearchItems=0 uniqueSearchItems=0
> ```
> from:
> ```swift
> let session = LanguageModelSession(tools: [tool]) {
>     spotlightSearchInstructions
> }
> let response = try await session.respond(to: prompt, options: GenerationOptions(toolCallingMode: .required))
> ```
> Reproduced on **iPhone 17 Pro Max, iOS 27 beta 3**. Filed **FB23643759**. Still open at capture.

The error says tool choice requires tools — **and tools were passed.** So the tool array is not
reaching the inference layer. Note also that this surfaces to your `catch` as the generic
`LanguageModelError error -1` from §7.3; the informative text is only in the console. **When you
see `-1`, always check the console log**, because the real message frequently lives there and never
reaches your error object.

> ✅ **Empty-tool control, with bridge drift:** a genuinely empty `.required` request produced the
> generic code `-1` on Simulator, but typed `LanguageModelError.unsupportedGenerationGuide`, code 6,
> on iPhone 15 Pro / iOS build `24A5408d`. That control does not close FB23643759 — the report passed
> a non-empty toolset — but it proves code `-1` is not the only public-facing shape of this invalid
> configuration.

One genuine API ambiguity is visible in that snippet: `toolCallingMode` exists in two places —
`GenerationOptions(toolCallingMode:)` (used here) and the `DynamicProfile.toolCallingMode(_:)`
modifier that a Frameworks Engineer recommended in thread 833692 (*"You can use `.toolCallingMode`
with `DynamicProfiles` for this."*).

> ✅ **RESOLVED on the type question (2026-07-29): yes, one type.** The profile modifier is declared
> `func toolCallingMode(_ toolCallingMode: GenerationOptions.ToolCallingMode?) -> some
> DynamicProfile` — the *same* `GenerationOptions.ToolCallingMode` struct as the options field —
> ✅ **SDK-verified** (`FoundationModels-27.0-macos.swiftinterface:978`, with the struct and its
> `Kind` at `:3293-3313`: statics `.allowed`/`.required`/`.disallowed` over
> `case allowed/required/disallowed`). The dynamic-profiles article's general rule says call-site
> arguments override profile modifiers, and the runtime now confirms it.
>
> ✅ **DEVICE-CONFIRMED, one direction (2026-08-20).** On iPhone 15 Pro / iOS build `24A5408d`,
> profile `.required` + options `.disallowed` produced no tool call — the recorded probe line reads
> `toolCalled=false toolRan=false`. So call-site options override the profile modifier in the
> profile-allows → options-disallow direction. The earlier simulator run pointed the same way but
> lacked tool-calling assets.
>
> 🔴 **GAP — the reverse direction is an inference, not a recorded observation.**
> **Unknown:** whether options `.required` actually overrides a profile's `.disallowed`. That run
> threw `LanguageModelError.contextSizeExceeded(contextSize: 4096, tokenCount: 4099)`, and the
> probe's catch path did not record the `toolCalled`/`toolRan` discriminators — "the tool loop ran
> until overflow" is read off the error fingerprint alone.
> **What resolves it:** the probe has been updated to record the discriminators in its catch path;
> the next device run turns the fingerprint into an observation.
> **Safe default:** assume call-site `.required` *can* override a profile-level `.disallowed` —
> never rely on a profile's `.disallowed` as an enforcement boundary — while not treating the
> override as device-verified in that direction.

### 7.5 `ToolCallError` and "Failed to parse generated content"

> ✅ **VERIFIED (Apple docs)** — `LanguageModelSession.ToolCallError`, iOS 26.0+ (no watchOS):
> ```swift
> struct ToolCallError            // Error, LocalizedError, Sendable
> init(tool:underlyingError:)
> var tool: ...                   // "The tool that produced the error."
> var underlyingError: ...
> var errorDescription: ...
> ```

The `.tool` property is the useful bit: in a multi-tool session it tells you *which* tool blew up
without you having to instrument each one.

The most-reported instance is a first-party bug. `SpotlightSearchTool` presents the model with a
human-readable `description` and a `parameters` JSON Schema that **contradict each other**:

> ✅ **VERIFIED (forum thread 833651, developer bkusserow; confirmed a "known issue" by DTS,
> pointing at thread 832534)** — verbatim:
> > "The root cause is a mismatch between two things the framework sends to the model in the same
> > tool definition:
> > - the human-readable `description` ('Call format'), which presents the top-level arguments as
> >   `{ root, modelComposition, … }`, and
> > - the `parameters` JSON Schema (`FullArguments`), which requires
> >   `{ "query": { "type": "search", "value": { root, modelComposition, … } } }`.
> >
> > A model that follows the description is guaranteed to fail the schema."

Failure surface: `LanguageModelSession.ToolCallError` wrapping **"Failed to parse generated
content."** The tool is effectively uninvokable by any model that reads the description — which is
every model that is not specifically trained around the bug.

There is a matching error-handling policy you should know about when tools throw:

> ✅ **VERIFIED (Apple docs)** — `TranscriptErrorHandlingPolicy`, iOS 27.0+:
> ```swift
> struct TranscriptErrorHandlingPolicy   // Sendable, SendableMetatype
> static let preserveTranscript   // "Keep the current transcript as is."
> static let revertTranscript     // "Revert the transcript back to the state it was in just before the most recent request."
> ```
> and, from the tool-calling article: *"When errors are thrown from a tool, the framework rolls back
> the transcript to a previously known valid state. Use `transcriptErrorHandlingPolicy` to define
> whether the session preserves the transcript an error occurs or if it reverts back to before the
> last request. **When preserving the transcript, the last entry may be partially generated.**"*

⚠️ **SILENT FAILURE — `preserveTranscript` can leave a half-generated entry in your history.** That
partial entry then becomes context for the next turn. If you preserve, validate the tail before
continuing; if you cannot validate, prefer `revertTranscript`.

### 7.6 Toolchain and platform breakage that looks like an API problem

Two more, briefly, because both cost developers days:

> ✅ **VERIFIED (Apple staff, thread 835987)** — watchOS 27 Beta 2 build failure:
> ```
> /Applications/Xcode-beta.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS27.0.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-watchos.swiftinterface:6:15 Unable to resolve module dependency: 'CoreImage'
> ```
> Apple's reply, in full: *"This is a known bug."*

> ✅ **VERIFIED (forum thread 834652, developer self-answer, no Apple reply)** — *"No, not only does
> the Watch have to be running WatchOS 27, it also needs to be paired to an iPhone with Apple
> Intelligence enabled. This is despite the fact that PCC queries from WatchOS 27 go straight to the
> server and don't require the paired iPhone at all 🤷‍♂️"* — i.e. Apple Watch Series 11 + iPhone 15
> = no PCC. **Not Apple-confirmed**, but a high-signal deployment gotcha.

---

## 8. Private Cloud Compute: quota is not availability

### 8.1 The distinction, stated by Apple

> ✅ **VERIFIED (Apple docs, PCC article)** — *"A quota describes the model's **per-user request
> budget** and where the caller currently sits relative to it. **Quotas are orthogonal to a model's
> availability — a model can be available even after its usage limit has been reached.**"*

So `availability == .available` and `quotaUsage.isLimitReached == true` is a normal, expected state.
If your gating logic checks availability alone, you will happily enable a button that throws on
every press.

And quota is not rate limiting:

> ✅ **VERIFIED (Apple docs)** — *"Unlike rate limiting, where a person waits for a period of time
> before trying again, **exceeding the daily quota means a person either waits for their usage quota
> to refresh or they upgrade to a higher tier.**"*

Backoff-and-retry is the correct response to `.rateLimited`. It is the **wrong** response to
`.quotaLimitReached` — retrying in 30 seconds does nothing but burn battery. The two need different
code paths even though both feel like "too many requests".

Also worth stating plainly: the quota belongs to **the user's iCloud account, not to your app**.

> ✅ **VERIFIED (transcript, WWDC26 session 319)** — *"Requests are counted with your user's iCloud
> account."*

Which means your user may hit the limit because of *another app's* usage, and your "upgrade" call to
action leads to an **iCloud+** upgrade, not an in-app purchase.

### 8.2 The `QuotaUsage` API

> ✅ **VERIFIED (Apple docs)** —
> `/documentation/foundationmodels/privatecloudcomputelanguagemodel/quotausage-swift.struct`:
> ```swift
> struct QuotaUsage                        // Sendable
> var isLimitReached: Bool
> var status: QuotaUsage.Status
> var resetDate                            // "The date at which the quota will refresh."
> var limitIncreaseSuggestion: QuotaUsage.LimitIncreaseSuggestion?
> ```

Apple's own SwiftUI usage, verbatim from the PCC article:

```swift prelude:guide-context
let model = PrivateCloudComputeLanguageModel()

// Depending on the quota state, display a label to keep a person aware
// of the status of their daily limit.
if model.quotaUsage.isLimitReached {
    Text("Usage limit exceeded")
        .foregroundStyle(Color.red)
} else if case .belowLimit(let info) = model.quotaUsage.status {
    if info.isApproachingLimit {
        Text("Nearing usage limit")
            .foregroundStyle(Color.orange)
    }
}

// Display a button in your UI to present the available upgrade options.
if let suggestion = model.quotaUsage.limitIncreaseSuggestion {
    Button("Show options") {
        suggestion.show()
    }
}
```

Independent confirmation of the same shape from a shipping third-party app, including the
`@unknown default` arm Apple's snippet omits:

> ✅ **VERIFIED (shipping source)** — `frozen Noema 3.5 snapshot`,
> `AppleFoundationModelAvailability.swift:163-186`:
> ```swift
> let model = PrivateCloudComputeLanguageModel()
> switch model.availability {
> case .available:
>     let quota = model.quotaUsage
>     if quota.isLimitReached {
>         return .limitReached(resetDate: quota.resetDate)
>     }
>     if case .belowLimit(let information) = quota.status,
>        information.isApproachingLimit {
>         return .approachingLimit
>     }
>     return .available
> case .unavailable(.deviceNotEligible): …
> case .unavailable(.systemNotReady): …
> case .unavailable: …
> @unknown default: …
> }
> ```

Details worth knowing:

- `limitIncreaseSuggestion` is **optional**, and `.show()` presents **system UI** for the iCloud+
  upgrade. The shipping app checks `!= nil` before offering the affordance at all — do the same,
  because a dead "Upgrade" button is worse than none.
- `resetDate` may be absent: *"This value is **empty when the reset date isn't known or when the
  person is well below their limit**."* Do not render "resets at —".

> ✅ **RESOLVED (2026-07-29) — `QuotaUsage.Status` has exactly two cases.**
> `case belowLimit(Status.BelowLimit)` and `case limitReached(Status.LimitReached)` —
> ✅ **SDK-verified** (`FoundationModels-27.0-macos.swiftinterface:228-245`). `BelowLimit` carries
> `isApproachingLimit: Bool` (`:236-238`); `LimitReached` is an empty payload struct (`:243-244`).
> There is no `.atLimit`/`.overLimit`; "at limit" *is* `.limitReached`, and `isLimitReached: Bool`
> lives in its own extension on `QuotaUsage` (`:221-223`) — the interface does not show whether it
> is derived from `status`, but the two can only disagree by framework bug. The enum is not
> `@frozen`, so keep the default arm anyway. `QuotaUsage` itself is
> `status` + `limitIncreaseSuggestion: LimitIncreaseSuggestion?` + `resetDate: Date?`
> (`:212-216`), and `LimitIncreaseSuggestion`'s only member is `func show()` (`:249-256`).

> 🔴 **GAP — no numbers.** Thread 835974 ("More Detailed Quota Usage for PCC") asks for actual
> counts or percentages so developers can build a usage meter. The API exposes only the coarse
> states above. Filed **FB23378161**. Unresolved. You cannot build "37 of 50 requests used today".

### 8.3 Apple's UX guidance — do not use an alert

This is unusually prescriptive for Apple, and it is worth following exactly because the reasoning
generalises.

> ✅ **VERIFIED (transcript, WWDC26 session 319:77-90)** — verbatim across several beats:
> > "But when a user hits a limit, **the request throws an error. If that error is just shown in the
> > UI, that's not a great user experience, because it's not very actionable.** To handle this
> > better, you can check for **`isLimitReached` on the `quotaUsage` of the model**. And handle that
> > with custom UI in your app. Here I'm using a **label to go under my button**."
> >
> > "when the user's limit is exceeded, you can **show a button to let the user manage their limit**.
> > For example, a user could **upgrade their account** to get a higher limit."
> >
> > "You should **integrate this with your existing UI**. **Avoid showing an alert for the usage
> > limit. Because this UI should persist, and not be dismissed.** Instead, you can **update the
> > state of your UI, like disabling the button that makes a request.** And under that button I'm
> > showing a **subtle label**, with the button for letting the user get a higher limit, if they
> > want."
> >
> > "You can also **detect the case where a user is approaching their limit**. This can be good to
> > indicate to your users that they are close to their daily limit, so they can **make an informed
> > decision for which requests they want to make**."

And the docs say the same thing more tersely: *"Instead of presenting an alert that a person can
dismiss, add UI to clearly communicate the current status of a person's daily usage."*

The four rules, extracted:

1. **Never an alert.** An alert is dismissible; the condition is not. The user dismisses it, taps
   the button again, gets the alert again. That is a loop, not a UX.
2. **Persist the state in your UI.** The limit condition should be visible without the user
   triggering it.
3. **Disable the affordance.** Do not let the user fire a request you know will fail.
4. **Subtle label + actionable button.** A quiet inline label plus a "manage limit" button that
   calls `limitIncreaseSuggestion.show()`.

Rule 3 has a second-order benefit: it is the same pattern as `.disabled(session.isResponding)` for
concurrency (§3.3). One state machine, driving one button's enabled-ness, from all the reasons a
request could fail. That is the design this guide's §10 function is built to feed.

Apply the same shape to the approaching state: leave the button enabled, but tell the user their
budget is nearly spent so they can choose which request is worth it.

### 8.4 Simulating the quota states in Xcode

Same drop-down as §2.7:

> ✅ **VERIFIED (Apple docs)** — *"1. Choose **Product > Scheme > Edit Scheme**. 2. Select the
> **Run** page and choose the **Options** tab. 3. Select either **"Approaching Quota Usage Limit"**
> or **"Quota Usage Limit Reached"** from the **"Simulated Apple Foundation Models Availability"**
> drop-down menu. 4. Click Close and run your project."*

Both states are simulable, so there is no excuse for shipping the approaching-limit path untested.
Session 319 walks through coding exactly this: *"We already handled the `isLimitReached` case in the
code before. We can now also test the **`belowLimit`** case."*

Note that the option lives under **Simulated Apple Foundation Models Availability** even though
quota is explicitly *not* availability (§8.1). The menu name is a mild lie; the states are real.

### 8.5 Before any of this: eligibility

For a large fraction of readers, the PCC failure mode is not a runtime error — it is that you cannot
use it at all.

> ✅ **VERIFIED** — verbatim from `https://developer.apple.com/private-cloud-compute/` (fetched
> 2026-07-27):
> > Access to PCC is available to developers who meet the following criteria:
> > - Are enrolled in the **App Store Small Business Program**.
> > - Have fewer than **2 million first-time app downloads** from any of their apps on the App Store.
> > - Have the **Private Cloud Compute entitlement** assigned to their account.
>
> > Where Apple Intelligence is available, eligible developers can use PCC in their apps distributed
> > on the App Store, and test PCC features via TestFlight or ad hoc distribution. **Installs during
> > testing are not counted as first-time app downloads.**
>
> > If any app subsequently exceeds the 2 million first-time downloads threshold, or the developer is
> > no longer enrolled in the App Store Small Business Program, the developer will be notified and
> > must **migrate to an alternative solution within 6 months**.

Three things people get wrong:

- **The download cap is cumulative/lifetime, not annual.** Thread 835897 is a developer with ~180k
  units in the last year who is excluded because of pre-2015 success. That is the policy working as
  designed, not a misreading.
- **The Small Business Program condition appears in no WWDC session** in this corpus — sessions 241
  and 319 mention only the download threshold. A developer can meet the download bar and still be
  ineligible.
- **The URL matters.** `https://developer.apple.com/apple-intelligence/private-cloud-compute/`
  **404s**; the live path is `https://developer.apple.com/private-cloud-compute/`.

And the entitlement is not optional plumbing:

> ✅ **VERIFIED (Apple staff, thread 834749, accepted)** — *"The entitlement application is what you
> need to 'apply' for the program, and this entitlement in Xcode is what allows your app to access
> PCC."*

Entitlement key: `com.apple.developer.private-cloud-compute`. Missing it produces a **`fatalError`**
at runtime (§2.6) — not a catchable error. There is no defensive code for that; you fix the
entitlement.

On-device has none of these constraints:

> ✅ **VERIFIED (Apple staff, DTS Engineer Ziqiao Chen, thread 835897)** — on-device Foundation
> Models (`SystemLanguageModel`) have **no limits** for any developer.

Full treatment in
[Part 4 — Beyond the built-in model](../../part-04-beyond-the-built-in-model/README.md).

---

## 9. How to report a bug to Apple so it gets acted on

Every unresolved thread in this cluster ends the same way: *"file a Feedback and post the FB number
here."* That is not a brush-off — it is the only channel the framework team acts on. Doing it
properly takes ten minutes and materially changes your odds.

### 9.1 The official channel: `#Playground`, thumbs-up

Apple posted the instructions themselves, in a **pinned, locked** thread.

> ✅ **VERIFIED (Apple staff, DTS Engineer, thread 791250 — sticky, locked, zero replies)** —
> *"Provide actionable feedback for the Foundation Models framework and the on-device LLM"*.
>
> **Method 1 — Xcode `#Playground` (macOS/iOS 26 Beta 4 and later):**
> 1. In Xcode, create a playground using `#Playground`.
> 2. Reproduce the issue by setting up a session and generating a response with your prompt.
> 3. In the canvas on the right, click the **thumbs-up icon** to the right of the response.
> 4. Follow the pop-up instructions and submit by clicking **"Share with Apple"**.
>
> **Method 2 — Feedback report** (`https://developer.apple.com/bug-reporting/`), including:
> - **Language model feedback** — "essential component containing session transcript (instructions,
>   prompts, responses, etc.)"
> - Retrieve it via **`logFeedbackAttachment(sentiment:issues:desiredOutput:)`**, write the data to
>   a file, attach it.
> - If system-configuration related, also capture and attach a **sysdiagnose**.

The thumbs-up route is the highest-signal one for *model quality* problems — refusals, bad output,
guardrail false positives — because it packages the full transcript automatically. Use Method 2 when
the bug is in your app's code path and you need to control what gets attached, or when the issue is
environmental (then the sysdiagnose is the payload that matters).

Note the version floor on the thumbs-up affordance: **macOS/iOS 26 Beta 4**. It has been there for
about a year, and almost nobody uses it.

### 9.2 `LanguageModelFeedback` and `logFeedbackAttachment`

> ✅ **VERIFIED (Apple docs)** — types (iOS 26.0+ … watchOS 27.0+):
> ```swift
> struct LanguageModelFeedback
> struct LanguageModelFeedback.Issue       // init(category:explanation:)  + Issue.Category
> enum LanguageModelFeedback.Sentiment     // .negative, .neutral, .positive  (CaseIterable)
> ```
> and the session method:
> ```swift
> @discardableResult final func logFeedbackAttachment(
>     sentiment: LanguageModelFeedback.Sentiment?,
>     issues: [LanguageModelFeedback.Issue] = [],
>     desiredOutput: Transcript.Entry? = nil) -> Data
> ```
> iOS 27 adds two more overloads: `logFeedbackAttachment(sentiment:issues:desiredResponseContent:)`
> and `logFeedbackAttachment(sentiment:issues:desiredResponseText:)`.

Usage, verbatim from Apple's docs:

```swift prelude:guide-context
let feedbackData = session.logFeedbackAttachment(sentiment: .positive)

let feedbackData = session.logFeedbackAttachment(
    sentiment: .negative,
    issues: [
        LanguageModelFeedback.Issue(
            category: .incorrect,
            explanation: "The model provided outdated information"
        )
    ],
    desiredOutput: Transcript.Entry.response(...)
)
```

Constructing a `desiredOutput` — this is what turns "it's wrong" into "here is what right looks
like", which is the difference between a bug report that gets triaged and one that gets closed:

```swift compile:27 imports:FoundationModels
let text = Transcript.TextSegment(content: "The capital of France is Paris.")
let segment = Transcript.Segment.text(text)
let response = Transcript.Response(segments: [segment])
let entry = Transcript.Entry.response(response)
```

For a `Generable` type:

```swift prelude:guide-context
let customType = MyCustomType(...) // A generable type.
let structure = Transcript.StructuredSegment(schemaName: String(describing: Foo.self), content: customType.generatedContent)
let segment = Transcript.Segment.structure(structure)
let response = Transcript.Response(segments: [segment])
let entry = Transcript.Entry.response(response)
```

The returned `Data` is JSON and concatenates:

```swift prelude:guide-context
let allFeedback = feedbackData + feedbackData2 + feedbackData3
let url = URL(fileURLWithPath: "path/to/save/feedback.json")
try allFeedback.write(to: url)
```

> ✅ **VERIFIED (Apple docs)** — *"Use `LanguageModelFeedback` to retrieve language model session
> transcripts from people using your app. After collecting feedback, you can **serialize it into a
> JSON file and include it in the report you send with Feedback Assistant**."*

> ✅ **RESOLVED (2026-07-29) — the full `Issue.Category` case list, from the 27.0 interface.**
> Eight cases, `CaseIterable`: `.unhelpful`, `.tooVerbose`, `.didNotFollowInstructions`,
> `.incorrect`, `.stereotypeOrBias`, `.suggestiveOrSexual`, `.vulgarOrOffensive`,
> `.triggeredGuardrailUnexpectedly` — ✅ **SDK-verified**
> (`FoundationModels-27.0-macos.swiftinterface:3448-3469`). So for a guardrail false positive the
> apt category is **`.triggeredGuardrailUnexpectedly`**, not `.incorrect`. (`Sentiment` is
> `.positive`/`.negative`/`.neutral`, `:3417-3421`; `Issue.init(category:explanation:)` at
> `:3440`.)

Note the signature drift worth guarding against: the pinned forum post names
`logFeedbackAttachment(sentiment:issues:desiredOutput:)`, and the docs list that plus the two
`desiredResponse*` variants. Autocomplete rather than copy from prose.

Apple explicitly asked for `LanguageModelFeedback` submissions for the 26.4 guardrail regressions:

> ✅ **VERIFIED (Apple staff, thread 820819)** — *"Thank you for your feedback! Can you submit a
> **`LanguageModelFeedback`** through Feedback Assistant for this specific issue?"*

### 9.3 What to include, by failure type

Assembled from what Apple staff asked for across threads:

| Failure | Attach |
|---|---|
| Guardrail false positive | `logFeedbackAttachment` JSON. Apple asked specifically for **"tools exposed, instructions, prompt"** (thread 835777) |
| Model refusal | Same, plus `desiredOutput` showing the answer you expected. Note whether `.permissiveContentTransformations` changed anything — that single fact identifies the layer |
| Availability / `.appleIntelligenceNotEnabled` | **sysdiagnose** (Apple asked for this explicitly, thread 836760), plus region, Siri language, and which Siri toggles are on |
| `-1` / undocumented domain | Full `NSError` dump including `NSMultipleUnderlyingErrorsKey`, **console log** (§7.4), device model, exact OS build, Xcode build, and **host macOS version if the Simulator was involved** |
| Tool not invoked | Tool `name`, `description`, `parameters` schema, and the full instructions |

And post the FB number in the forum thread. It is how the threads in this corpus got connected to
radars at all — the eleven FB numbers this guide cites all came from developers doing exactly that.

---

## 10. The complete graceful-degradation function

Everything above, assembled into something you can paste into a project. The design goals:

- **One outcome type** that a view can switch on, so failure handling lives in one place rather than
  smeared across `catch` arms in twelve view models.
- **Catch every one of the six error types**, in the arm order Apple's own sample code uses —
  `SystemLanguageModel.Error` first, `GeneratedContent.ParsingError` after `LanguageModelError`.
- **Distinguish the two refusal mechanisms**, including the string-mode silent one.
- **Recover from context overflow once**, then give up rather than loop.
- **Fall back from PCC to on-device** on network/service failure, with the transcript problem
  acknowledged.
- **Never retry a quota error.**

> ⚠️ **Read the evidence markers inside the code.** Every symbol used here appears in §2–§9 with a
> citation. The one place where the corpus is thin — refusal-string detection (§4.3) — is written
> defensively and commented as such. (`Refusal`'s accessor, formerly a gap, is settled in §3.2:
> `async throws`, returning a `Response<String>`.) If a line has no citation upstream, it is not
> in this function.

### 10.1 The outcome type

```swift compile:27
import Foundation
import FoundationModels

/// Everything a generation attempt can produce, flattened into one switchable value.
/// A view binds to this; nothing else in the app needs to know the framework's error types exist.
/// Note: not `Sendable` — the `.unclassified` payload is an arbitrary `any Error`, which
/// carries no Sendable guarantee. Everything here is produced and consumed on the main actor.
enum GenerationOutcome<Content> {

    /// The model answered, and we have no reason to think it was a refusal.
    case success(Content)

    /// The feature cannot run at all right now. `guidance` is user-facing copy.
    case unavailable(reason: UnavailableKind, guidance: String)

    /// The system or the model declined. `mechanism` tells you which knob, if any, applies.
    case declined(mechanism: DeclineMechanism, detail: String)

    /// A budget was exhausted. `retryAfter` is nil when retrying is pointless (quota).
    case budgetExhausted(kind: BudgetKind, retryAfter: Date?)

    /// The chosen model cannot do what was asked. Change models or change the request.
    case unsupported(detail: String)

    /// The model produced output that would not decode into the requested `Generable`.
    /// Retryable — unlike a refusal. See §3.6.
    case malformedOutput(detail: String)

    /// A transient system condition. Retrying later is reasonable.
    case transient(detail: String)

    /// We misused the session. This is our bug; it should never ship.
    case programmerError(detail: String)

    /// Anything we could not classify. Log the whole thing; see §7.3.
    case unclassified(any Error)

    enum UnavailableKind: Sendable {
        case deviceNotEligible          // no hardware support — hide the feature permanently
        case appleIntelligenceOff       // user setting — offer a deep link / instructions
        case modelNotReady              // assets downloading — offer retry
        case localeUnsupported          // Siri language not covered — see §2.2
        case unknownReason              // the 0xFF path — treat as temporary
    }

    /// The distinction from §4. Only `.guardrail` is configurable.
    enum DeclineMechanism: Sendable {
        case guardrail                  // classifier — `.permissiveContentTransformations` may help
        case modelRefusal               // model's own training — no API affects this
        case suspectedStringRefusal     // heuristic only — see §4.3
    }

    enum BudgetKind: Sendable {
        case contextWindow(used: Int, limit: Int)
        case rateLimit
        case dailyQuota                 // PCC only — never retry, offer upgrade
        case timeout
    }
}
```

### 10.2 The availability gate

Run this before you show the button, not after the user taps it — that is Apple's explicit advice in
thread 836810 ("check availability before anyone agrees to pay").

Apple's 2026 sample apps do not have this function; they gate nothing and rely entirely on catching
`SystemLanguageModel.Error` (§2.8). Keep both. The gate gives you the *reason*, which the error type
does not, and it is the only thing standing between a user and a purchase they cannot use.

```swift prelude:guide-context
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
enum AvailabilityGate {

    /// Returns `nil` when the model is usable, or an outcome describing why it is not.
    /// Deliberately checks locale too: `.available` does not imply "available in this language".
    static func check<C: Sendable>(
        _ model: SystemLanguageModel,
        locale: Locale = .current
    ) -> GenerationOutcome<C>? {

        switch model.availability {
        case .available:
            break

        case .unavailable(.deviceNotEligible):
            return .unavailable(
                reason: .deviceNotEligible,
                guidance: "This device doesn't support Apple Intelligence."
            )

        case .unavailable(.appleIntelligenceNotEnabled):
            // §2.3: on 27 betas this can also mean a Siri activation toggle is off.
            // Do NOT name a specific switch; point at the settings pane.
            return .unavailable(
                reason: .appleIntelligenceOff,
                guidance: "Turn on Apple Intelligence in Settings to use this feature."
            )

        case .unavailable(.modelNotReady):
            return .unavailable(
                reason: .modelNotReady,
                guidance: "The on-device model is still downloading. Try again shortly."
            )

        case .unavailable:
            // The C bridge exposes UNKNOWN = 0xFF (§2.1), so this arm is reachable.
            return .unavailable(
                reason: .unknownReason,
                guidance: "This feature is temporarily unavailable."
            )

        @unknown default:
            return .unavailable(
                reason: .unknownReason,
                guidance: "This feature is temporarily unavailable."
            )
        }

        // §2.2: gating is on the *Siri* language, and `supportsLocale` accounts for fallbacks.
        guard model.supportsLocale(locale) else {
            return .unavailable(
                reason: .localeUnsupported,
                guidance: "This feature isn't available in your Siri language yet."
            )
        }

        return nil
    }

    /// §2.2: never hardcode 4096. Treat a non-positive report as "unknown" and fall back.
    static func contextBudget(_ model: SystemLanguageModel) -> Int {
        let reported = model.contextSize
        return reported > 0 ? reported : 4096
    }
}
```

### 10.3 The classifier: one error, one outcome

This is the piece worth reading twice — it is the full catch ladder from §3, in the arm order
Apple's own sample code uses (§3.7), with the mechanism distinction from §4 encoded in the
`.guardrailViolation` / `.refusal` split.

```swift prelude:guide-context
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
enum FailureClassifier {

    static func classify<C: Sendable>(_ error: any Error) -> GenerationOutcome<C> {

        // Cancellation is not a failure. Check it first or it becomes `.unclassified`.
        // Apple's samples handle it as a separate `catch is CancellationError` arm
        // outside the classifier entirely (§3.7); folding it in here is equivalent.
        if error is CancellationError {
            return .transient(detail: "Cancelled.")
        }

        // ---- 1. On-device asset / availability problems (no watchOS — see §3.4) -------
        // FIRST, exactly as Apple's own sample code orders it. This is the arm developers
        // omit, and it carries the most common runtime failure there is (§2.8, §3.4).
        #if !os(watchOS)
        if let systemError = error as? SystemLanguageModel.Error {
            switch systemError {
            case .assetsUnavailable:
                // The payload's `debugDescription` is for your logs, never for the UI —
                // bind it only if you are actually logging it, or you get an unused-value warning.
                return .unavailable(
                    reason: .modelNotReady,
                    guidance: "The on-device model isn't ready yet. Try again shortly."
                )
            @unknown default:
                return .transient(detail: String(describing: systemError))
            }
        }
        #endif

        // ---- 2. Our own misuse. Fix the code; do not show this to a user. -------------
        // No Apple sample catches this type (§3.7 gap); the two cases are doc-verified.
        if let sessionError = error as? LanguageModelSession.Error {
            switch sessionError {
            case .concurrentRequests:
                // §3.3 — gate the UI on `session.isResponding`.
                return .programmerError(detail: "Concurrent requests on one session.")
            case .transcriptMutationWhileResponding:
                // §3.3 — new in 27, because `transcript` became settable.
                return .programmerError(detail: "Transcript mutated during a response.")
            @unknown default:
                return .programmerError(detail: String(describing: sessionError))
            }
        }

        // ---- 3. PCC-specific failures (§3.5, §8) -------------------------------------
        if let pccError = error as? PrivateCloudComputeLanguageModel.Error {
            switch pccError {
            case .quotaLimitReached:
                // §8.1 — NOT a rate limit. Retrying is useless. retryAfter stays nil;
                // the caller reads `quotaUsage.resetDate` for the real answer.
                return .budgetExhausted(kind: .dailyQuota, retryAfter: nil)
            case .networkFailure:
                // "network available, PCC inaccessible" — fall back on-device.
                return .transient(detail: "Private Cloud Compute is unreachable.")
            case .serviceUnavailable:
                return .transient(detail: "Private Cloud Compute is temporarily unavailable.")
            @unknown default:
                return .transient(detail: String(describing: pccError))
            }
        }

        // ---- 4. Model errors — the nine documented cases (§3.2) ----------------------
        // Use the type-cast-then-switch form, NOT `catch LanguageModelError.foo(let x)`:
        // it is what Apple's own sample code writes, and §3.7 / FB23061009 reports case
        // patterns failing on the streaming path.
        // `LanguageModelError` is NON-FROZEN (§3.2): the `@unknown default` arm at the
        // bottom is required, and the nine cases are a floor, not a ceiling.
        if let modelError = error as? LanguageModelError {
            switch modelError {

            case .contextSizeExceeded(let payload):
                return .budgetExhausted(
                    kind: .contextWindow(used: payload.tokenCount, limit: payload.contextSize),
                    retryAfter: nil          // recoverable by compaction, not by waiting
                )

            case .rateLimited(let payload):
                // §3.2 — payload carries `resetDate: Date?`.
                return .budgetExhausted(kind: .rateLimit, retryAfter: payload.resetDate)

            case .timeout:
                return .budgetExhausted(kind: .timeout, retryAfter: nil)

            case .guardrailViolation(let payload):
                // §4.2 — the CLASSIFIER blocked this. `.permissiveContentTransformations`
                // may help, but only for string generation (§5.2).
                // Apple's samples fold this into one arm with `.refusal` because the USER
                // sees the same apology either way. Keep them apart HERE: this is the only
                // place the distinction is recoverable, and §4.1 explains why it matters.
                return .declined(mechanism: .guardrail, detail: payload.debugDescription)

            case .refusal(let payload):
                // §4.4 — the MODEL declined. No guardrail setting affects this.
                // `payload.explanation` is `async throws` and costs an inference (§3.2);
                // `debugDescription` is guaranteed on every payload struct and is free.
                return .declined(mechanism: .modelRefusal, detail: payload.debugDescription)

            case .unsupportedCapability(let payload):
                // §3.2 — the framework threw this by comparing your request against the
                // model's declared LanguageModelCapabilities. Swap models, or drop the feature.
                return .unsupported(detail: "Capability unsupported: \(payload.capability)")

            case .unsupportedTranscriptContent(let payload):
                return .unsupported(
                    detail: "Unsupported transcript content (\(payload.unsupportedContent.count) entries)."
                )

            case .unsupportedGenerationGuide(let payload):
                return .unsupported(
                    detail: "Unsupported generation guide in schema: \(payload.schemaName ?? "unknown")"
                )

            case .unsupportedLanguageOrLocale(let payload):
                return .unavailable(
                    reason: .localeUnsupported,
                    guidance: "This feature isn't available in \(payload.languageCode.identifier) yet."
                )

            @unknown default:
                return .unclassified(modelError)
            }
        }

        // ---- 5. Guided-generation decode failure (§3.6) ------------------------------
        // NOT a LanguageModelError case. It is the successor role to the deprecated
        // `GenerationError.decodingFailure`, and Apple's own sample tests it here, after
        // LanguageModelError. Only reachable from `respond(to:generating:)`.
        if error is GeneratedContent.ParsingError {
            // Apple's own copy for this is "had trouble understanding the response.
            // Please try again." — i.e. treat it as RETRYABLE, unlike a refusal.
            return .malformedOutput(detail: String(describing: error))
        }

        // ---- 6. A tool blew up (§7.5) ------------------------------------------------
        if let toolError = error as? LanguageModelSession.ToolCallError {
            // `.tool` identifies WHICH tool, which is the whole value of this type.
            return .unclassified(toolError)
        }

        // ---- 7. Deprecated 26-era errors, for mixed build trains (§3.1) ---------------
        // Only reachable in a binary built with Xcode 26. Kept so one source tree can
        // serve both toolchains. Delete once you are Xcode-27-only.
        if let legacy = error as? LanguageModelSession.GenerationError {
            return .unclassified(legacy)
        }

        // ---- 8. Everything else — including the `-1` family (§7.3) --------------------
        // Log the full NSError chain including NSMultipleUnderlyingErrorsKey, plus the
        // console output: the informative message frequently never reaches this object.
        return .unclassified(error)
    }
}
```

### 10.4 The generator: gate, attempt, recover, degrade

```swift prelude:guide-context
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@MainActor
final class ResilientGenerator {

    private let model: SystemLanguageModel
    private var session: LanguageModelSession
    private let instructions: String

    init(instructions: String,
         guardrails: SystemLanguageModel.Guardrails = .default) {
        // §5.2: `.permissiveContentTransformations` applies ONLY to string generation.
        // Passing it does not make guided generation permissive.
        self.model = SystemLanguageModel(guardrails: guardrails)
        self.instructions = instructions
        self.session = LanguageModelSession(model: model, instructions: instructions)
    }

    /// String generation. Convenient, and silently swallows refusals (§4.3) —
    /// which is why this returns `.declined(.suspectedStringRefusal, …)` on a heuristic hit.
    /// Prefer `generate(_:producing:)` whenever you need to know about refusals.
    func generate(_ prompt: String) async -> GenerationOutcome<String> {
        if let blocked: GenerationOutcome<String> = AvailabilityGate.check(model) {
            return blocked
        }
        // §3.3: never fire a second request into a busy session.
        guard !session.isResponding else {
            return .programmerError(detail: "Called generate while a response was in flight.")
        }

        do {
            let response = try await session.respond(to: prompt)
            let text = response.content

            if Self.looksLikeRefusal(text) {
                return .declined(mechanism: .suspectedStringRefusal, detail: text)
            }
            return .success(text)

        } catch {
            let outcome: GenerationOutcome<String> = FailureClassifier.classify(error)
            return await recoverIfPossible(outcome, retrying: prompt)
        }
    }

    /// Guided generation. §4.3: use this whenever a missed refusal would matter —
    /// in this mode a refusal THROWS instead of arriving as prose.
    func generate<T: Generable & Sendable>(
        _ prompt: String,
        producing type: T.Type
    ) async -> GenerationOutcome<T> {
        if let blocked: GenerationOutcome<T> = AvailabilityGate.check(model) {
            return blocked
        }
        guard !session.isResponding else {
            return .programmerError(detail: "Called generate while a response was in flight.")
        }

        do {
            let response = try await session.respond(to: prompt, generating: type)
            return .success(response.content)
        } catch {
            return FailureClassifier.classify(error)
        }
    }

    // MARK: - Recovery

    /// Exactly one compaction-and-retry on context overflow. One, not a loop:
    /// if a compacted transcript still overflows, the prompt itself is too big.
    private func recoverIfPossible(
        _ outcome: GenerationOutcome<String>,
        retrying prompt: String
    ) async -> GenerationOutcome<String> {

        guard case .budgetExhausted(.contextWindow(let used, let limit), _) = outcome else {
            return outcome
        }

        // Log the ratio — it tells you whether compaction can plausibly help at all.
        // used/limit near 1.0 means trim; used/limit >> 1.0 means the prompt is the problem.
        _ = (used, limit)

        compactTranscript()

        do {
            let response = try await session.respond(to: prompt)
            let text = response.content
            return Self.looksLikeRefusal(text)
                ? .declined(mechanism: .suspectedStringRefusal, detail: text)
                : .success(text)
        } catch {
            return FailureClassifier.classify(error)
        }
    }

    /// Apple's documented compaction: keep the first entry (instructions) and the last
    /// (most recent context), rebuild, and prewarm to start refilling the KV cache.
    /// On iOS 27 you can instead assign `session.transcript.history` in place — but do it
    /// only when `!session.isResponding`, or you get `.transcriptMutationWhileResponding` (§3.3).
    /// For anything beyond a backstop, use the history modifiers from §6.3.
    private func compactTranscript() {
        let allEntries = session.transcript
        let condensed = [allEntries.first, allEntries.last].compactMap { $0 }
        let newSession = LanguageModelSession(transcript: Transcript(entries: condensed))
        newSession.prewarm()
        session = newSession
    }

    // MARK: - Heuristics

    /// ⚠️ HEURISTIC, NOT AN API. Apple documents only the *shape* of a refusal — that it
    /// "begins with a refusal like 'Sorry, I can't help with'" — and explicitly warns that
    /// you "might not be able to programmatically determine whether a string response is a
    /// normal response or a refusal" (§4.3). These strings are English-only and incomplete.
    /// Treat a hit as a signal to fall back, never as proof; treat a miss as meaningless.
    /// The robust answer is to generate a `Generable` so the framework throws instead.
    private static func looksLikeRefusal(_ text: String) -> Bool {
        let opening = text.prefix(64).lowercased()
        return opening.hasPrefix("sorry, i can't")
            || opening.hasPrefix("sorry, i cannot")
            || opening.hasPrefix("i can't help with")
            || opening.hasPrefix("i cannot help with")
    }
}
```

### 10.5 Adding the PCC tier

Layering PCC on top is a model swap plus a quota check. The two things that make it non-trivial are
that quota is not availability (§8.1), and that a 32K transcript does not fit in a 4K window (§6.3).

```swift compile:27 imports:Foundation,FoundationModels
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@MainActor
struct CloudTier {

    let model = PrivateCloudComputeLanguageModel()

    enum Readiness: Sendable {
        case ready
        case approachingLimit
        case limitReached(resetDate: Date?)
        case unavailable(String)
    }

    /// §8.1: check BOTH availability and quota. `.available` with `isLimitReached == true`
    /// is a normal state, and calling anyway throws on every request.
    func readiness() -> Readiness {
        switch model.availability {
        case .available:
            let quota = model.quotaUsage
            if quota.isLimitReached {
                return .limitReached(resetDate: quota.resetDate)   // may be nil (§8.2)
            }
            if case .belowLimit(let info) = quota.status, info.isApproachingLimit {
                return .approachingLimit
            }
            return .ready

        case .unavailable(.deviceNotEligible):
            return .unavailable("This device can't use Private Cloud Compute.")
        case .unavailable(.systemNotReady):
            return .unavailable("Private Cloud Compute isn't ready right now.")
        case .unavailable:
            return .unavailable("Private Cloud Compute is unavailable.")
        @unknown default:
            return .unavailable("Private Cloud Compute is unavailable.")
        }
    }

    /// §8.3: present this as a persistent, non-dismissible affordance — NOT an alert.
    /// Only offer the button when a suggestion actually exists.
    func upgradeAction() -> (() -> Void)? {
        guard let suggestion = model.quotaUsage.limitIncreaseSuggestion else { return nil }
        return { suggestion.show() }
    }
}
```

And the routing rule, which is short but earns its place:

```swift illustrative
// Pseudocode for the tier decision. Two rules do all the work:
//
//   1. On `.limitReached`, do NOT retry and do NOT wait. Disable the PCC affordance,
//      show the persistent label, expose `upgradeAction()`, and fall back on-device.
//      (§8.1: quota is not a rate limit.)
//
//   2. When falling back from PCC to on-device MID-CONVERSATION, the shared transcript
//      is sized for 32K and the on-device window is ~4K. Apply a `historyTransform`
//      to the on-device profile, or you turn one failure into two (§6.3, thread 833626).
//
// Also: PCC does not work in the Simulator at all (177684296). If your fallback path
// "always fires" in the Simulator, that is why — it is not your routing logic.
```

### 10.6 What this function deliberately does not do

- **It does not retry `guardrailViolation` or `refusal`.** Neither is transient. Re-sending the same
  prompt gets the same answer and, in a session, makes the next refusal more likely (§4.3).
- **It does not retry `.dailyQuota`.** Quota refreshes on a schedule, not on backoff (§8.1).
- **It does not loop on context overflow.** One compaction, one retry. A second overflow means the
  prompt itself does not fit, and looping just burns battery.
- **It does not retry `.malformedOutput`, though you reasonably could.** Apple's own copy for a
  `GeneratedContent.ParsingError` invites a retry ("please try again", §3.6) and a re-sample may
  well decode. One retry, then give up — the same budget as context overflow.
- **It does not surface `debugDescription` to users.** Those strings are diagnostics and are not
  localized.
- **It does not treat `.unclassified` as fatal.** Given §7, a meaningful share of real-world failures
  will land there through no fault of yours. Log the full chain, degrade, move on.

---

## 11. Quick-reference tables

### 11.1 Symptom → cause → fix

| Symptom | Most likely cause | Fix |
|---|---|---|
| `.unavailable(.appleIntelligenceNotEnabled)` on a device with AI on | Siri activation toggle coupling on 27 betas (835211, 836760) | Point users at *Settings → Apple Intelligence & Siri*. File Feedback + sysdiagnose. |
| `.unavailable(.deviceNotEligible)` on a "supported" device | Region, or the device is on the AFM 3 Core tier list boundary | Check `support.apple.com/en-us/121115`. Ship a non-AI baseline (§2.5). |
| `.unavailable(.modelNotReady)` persists | Assets still downloading, or asset provisioning failed | Retry UI; if permanent, sysdiagnose. |
| Feature works for you, not for a user in another country | Siri **language**, not system language (§2.2) | `supportsLocale(_:)`; no per-app override exists. |
| Every `catch` arm stopped matching after an Xcode upgrade | You rebuilt with Xcode 27; `GenerationError` is deprecated (§3.1) | Migrate every arm using the table in §3.6. |
| `catch GenerationError.refusal(let r, _)` no longer compiles | Arity changed: 27's `.refusal(_:)` has one value (§3.6) | Single binding, new enum. |
| `catch GenerationError.decodingFailure` has no successor to port to | It moved off the error enums entirely (§3.6) | Catch `GeneratedContent.ParsingError` as its own arm, after `LanguageModelError`. |
| Users with Apple Intelligence off get your generic error copy | Your ladder has no `SystemLanguageModel.Error` arm (§3.4) | Add it, first. Apple's forum snippet omits it; Apple's sample code puts it at the top. |
| Switch over `LanguageModelError` won't compile as exhaustive | The enum is non-frozen (§3.2) | Write `@unknown default`. The nine cases are a floor. |
| `.permissiveContentTransformations` has no effect at all | The call generates a `Generable` — permissive is string-mode only (§5.2). Apple's own Book Tracker sample makes this mistake. | Split into a permissive string call, then a default-guardrail `Generable` call over your own text. |
| `guardrailViolation` on a benign prompt | Classifier false positive | `.permissiveContentTransformations` **for string mode only**; reword; file Feedback with tools + instructions + prompt. |
| Permissive guardrails changed nothing | It is a model refusal, not a guardrail (§4.5) | No API. Reword, decompose, or change models. |
| Guardrails fire only in `Generable` mode | Permissive mode does not apply to guided generation (§5.2) | Split into a string call, or accept default guardrails. |
| Response is a polite "Sorry, I can't help with…" and no error thrown | ⚠️ Model refusal in string mode (§4.3) | Switch to guided generation so it throws. |
| Same prompt broke with no rebuild and no OS update | Guardrails updated out of band (§5.3) | Re-run your prompt suite. Evaluations in CI. |
| Everything broke after an OS beta | Model version changed (26.0-26.3 / 26.4 / 27.0) | Evaluations; no pinning API exists. |
| `contextSizeExceeded` under 4096 tokens | You are counting only the prompt — tools, schemas, instructions and history all count (§6.1) | `tokenCount(for:)`; read `contextSize`. |
| `contextSizeExceeded` right after switching from PCC | 32K transcript, 4K window (§6.3) | `historyTransform` on the on-device profile. |
| Truncated output like "A cat is a small." | `maximumResponseTokens` too low (§6.1) | Raise or remove it. |
| `LanguageModelError error -1`, no detail | SDK/host-OS skew via the Simulator punch-out (§7.3) | Physical device on 27.0. Then read the console. |
| `ModelManagerError Code=1046` | Undocumented; usually accompanies the above | Same. 🔴 GAP. |
| `com.apple.SensitiveContentAnalysisML error 15` on a trivial prompt | Undocumented; environmental (§7.1) | Physical device, newest beta, sysdiagnose. Do not rewrite prompts. |
| `UnifiedAssetFramework Code=5000` with `SpotlightSearchTool` | Tool's own model-catalog assets missing; Apple-confirmed bug (§7.2) | Reboot *may* help; needs a runtime fallback. |
| `"Tool Choice requires tools"` with tools passed | Tool array not reaching inference (§7.4) | FB23643759, open. Remove `.required` as a probe. |
| `ToolCallError` / "Failed to parse generated content" | `SpotlightSearchTool` description-vs-schema mismatch (§7.5) | Known issue; wrap args manually. |
| PCC throws on every request although `isAvailable == true` | Quota reached — orthogonal to availability (§8.1) | Check `quotaUsage.isLimitReached` first. |
| PCC `fatalError` at launch | Missing `com.apple.developer.private-cloud-compute` entitlement (§8.5) | Add the entitlement; not catchable. |
| PCC never works in the Simulator | Known issue 177684296 (§2.6) | Physical device on 27.0. |
| Error inside a Shortcut cannot be handled | Shortcuts "Use Model" has no try/catch (§6.3) | Keep those prompts small by construction. |

### 11.2 Which error type lives where

Listed in the arm order Apple's own sample code uses (§3.7).

| Type | Version | Cases | Meaning |
|---|---|---|---|
| `SystemLanguageModel.Error` | 27.0+, no watchOS | 1 | On-device asset state. **Test this first** (§3.4) |
| `LanguageModelError` | 27.0+ | 9 documented, **non-frozen** (§3.2) | The model or the request |
| `GeneratedContent.ParsingError` | 27.0+ — ✅ SDK-verified (`FoundationModels-27.0-macos.swiftinterface:1397-1404`) | struct | Output wouldn't decode into your `Generable` (§3.6) |
| `LanguageModelSession.Error` | 27.0+ | 2 | **Your** misuse of the session |
| `PrivateCloudComputeLanguageModel.Error` | 27.0+ | 3 | Quota / network / service |
| `LanguageModelSession.ToolCallError` | 26.0+, no watchOS | struct | A tool threw; `.tool` names it |
| `LanguageModelSession.GenerationError` | 26.0+, **deprecated 27.0** | 9 | Everything, pre-reshuffle |

Five of `LanguageModelError`'s nine cases — `.timeout`, `.guardrailViolation`, `.refusal`,
`.contextSizeExceeded`, `.unsupportedLanguageOrLocale` — are confirmed by two independent Apple
sample archives (§3.2). As of 2026-07-29 all nine are ✅ SDK-verified as the complete list in the
27.0 beta interface (`:1527-1537`), and the case counts in the table above are read from the same
capture (`SystemLanguageModel.Error`: 1, `:616-622` · `LanguageModelSession.Error`: 2, `:2026-2034`
· `PrivateCloudComputeLanguageModel.Error`: 3, `:151-158`).

### 11.3 Feedback numbers cited in this guide

Useful when you file — checking whether your issue is already tracked saves everyone time.

| FB | Subject | Thread |
|---|---|---|
| FB20828230 | Guardrails block crisis-support detection | 833614 |
| FB23060822 | `LanguageModelError -1` in Simulator | 831448 |
| FB23061009 | Cannot pattern-match `LanguageModelError` from a stream | 831404 |
| FB23092325 | `onToolCall` error kills the whole turn loop | 833610 |
| FB23378161 | Request for detailed PCC quota numbers | 835974 |
| FB23513774 | iOS 27 model-level refusal regression (health prompts) | 836673 |
| FB23643759 | `SpotlightSearchTool` "Tool Choice requires tools" | 837226 |

### 11.4 Every gap and open uncertainty this guide declares

Collected so you can see the shape of what is unknown, rather than discovering it mid-implementation.
Entries marked 🔴 **GAP** remain unanswered by the corpus; three rows are
🟡 **RECONSTRUCTED** — we have a reading, not a confirmation. Rows struck through were closed on
**2026-07-29** against `notes/sdk-interfaces/FoundationModels-27.0-macos.swiftinterface`.

| § | Unknown | What would resolve it |
|---|---|---|
| 2.2 | No per-app language override (`preferredLanguage:`) | Doc page or Apple answer on 805378 |
| 2.3 | Is `.appleIntelligenceNotEnabled` genuinely Siri-toggle-coupled? | Apple reply on 835211, or a non-beta reproduction |
| 2.4 | No API exposes AFM 3 Core vs Core Advanced | SDK header, or an Apple answer |
| 2.6 | ~~Full PCC `UnavailableReason` case list~~ — **✅ RESOLVED 2026-07-29**: exactly `.deviceNotEligible` + `.systemNotReady` | Resolved — 27.0 `.swiftinterface:82-90` |
| 3.2 | ~~`LanguageModelError`'s full case list~~ — **✅ RESOLVED 2026-07-29**: exactly the nine documented cases (still non-frozen — keep `default:`) | Resolved — 27.0 `.swiftinterface:1527-1537` |
| 3.6 | ~~Is `GeneratedContent.ParsingError` the *formal* successor to `decodingFailure`?~~ — **✅ RESOLVED 2026-07-29**: yes, per the SDK's own deprecation message; payloads do *not* correspond field-for-field | Resolved — 27.0 `.swiftinterface:3555-3558` |
| 3.7 | `LanguageModelSession.Error` is caught by no Apple sample | Any compiling code that observes one |
| 4.5 | Exact enum case behind thread 836673 | Debugger capture from a reproduction |
| 4.5 | What "May contain sensitive content" maps to | Full `NSError` chain from a reproduction |
| 4.5 | Whether refusal traffic actually rose in 27 | Apple statement or before/after data |
| 5.1 | ~~Is the `Guardrails` set really just two?~~ — **✅ RESOLVED for the 27.0 beta**: yes, `default` + `permissiveContentTransformations` | Resolved — 27.0 `.swiftinterface:335-344` |
| 5.2 | 🟡 That `.permissiveContentTransformations` is inert in Apple's own Book Tracker sample is our deduction from two verified facts, not a stated one | A demonstration either way, or an Apple clarification of the docs sentence |
| 7.1 | `com.apple.SensitiveContentAnalysisML` error 15 | Apple reply on 836285 |
| 7.3 | `ModelManagerServices.ModelManagerError` 1046 | Apple reply, or symbol dump |
| 7.4 | ~~Are the two `toolCallingMode` surfaces one type?~~ **✅ RESOLVED:** same type (SDK, 2026-07-29). Which wins: options override profile, device-confirmed **only** in the allows→disallow direction (2026-08-20, `toolCalled=false toolRan=false`); 🔴 the disallow→require direction threw `contextSizeExceeded(4096, 4099)` with the discriminators unrecorded — "options won" there is an error-fingerprint inference | Next device run — the probe now records `toolCalled`/`toolRan` in its catch path |
| 8.2 | ~~Full `QuotaUsage.Status` case list~~ — **✅ RESOLVED 2026-07-29**: `.belowLimit(_)` / `.limitReached(_)` only | Resolved — 27.0 `.swiftinterface:228-245` |
| 8.2 | Numeric quota values | None — Apple does not expose them (FB23378161) |
| 9.2 | ~~Full `LanguageModelFeedback.Issue.Category` list~~ — **✅ RESOLVED 2026-07-29**: eight cases incl. `.triggeredGuardrailUnexpectedly` | Resolved — 27.0 `.swiftinterface:3448-3469` |

[^refusal-api]: Apple, [`LanguageModelError.Refusal.explanation`](https://developer.apple.com/documentation/foundationmodels/languagemodelerror/refusal/explanation) (`get async throws`) and [`LanguageModelSession.Response.content`](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/response/content), which contains the generated `String`.

---

## Where to go next

- [Sessions, prompts and instructions](01-sessions-and-prompting.md) — the happy path
  this guide is the shadow of.
- [Guided generation and `Generable`](02-guided-generation-and-streaming.md) — and §4.3's argument
  for using it as an error-handling mechanism.
- [Tool calling](03-tools-and-tool-calling.md) — `ToolCallError`, the `.anyOf` bug, `SpotlightSearchTool`.
- [Part 3 — Context, profiles, agentic sessions](../../part-03-context-profiles-agentic/README.md) —
  `DynamicProfile`, `historyTransform`, and the history modifiers that make §6 mostly unnecessary.
- [Part 4 — Beyond the built-in model](../../part-04-beyond-the-built-in-model/README.md) — PCC
  eligibility in full, and the fallback models that answer §2.5.
- [Part 6 — Evaluations](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md) — the only defence against §5.3.
- [Part 17 — Migration from pre-iOS 27](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md) — the
  full `GenerationError` migration, of which §3.6 is the error-handling slice.
