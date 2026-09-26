# Private Cloud Compute: eligibility, reasoning, and quota UX

**Part 4 · Beyond the built-in model · Reference 01**

**Version floor:** `PrivateCloudComputeLanguageModel` is **iOS 27.0 / iPadOS 27.0 / macOS 27.0 /
watchOS 27.0 / visionOS 27.0** — there is no back-deployment and no 26.x equivalent. `ContextOptions`,
`ContextOptions.ReasoningLevel`, `Transcript.Reasoning`, `LanguageModelError` and
`LanguageModelSession.Usage` are all **27.0** too. The one exception in this guide is `contextSize`,
which exists on `SystemLanguageModel` from the **Xcode 26.4 SDK** and is therefore *not* behind the
27 gate — but on `PrivateCloudComputeLanguageModel` it is 27.0, because the class is. You need
**Xcode 27** for the quota-simulation scheme option and to catch the new error types at all: an app
built with Xcode 26 keeps catching the deprecated `LanguageModelSession.GenerationError` until you
rebuild.

Before any of that, though: **PCC is gated on your business, not your code.** Three conditions, all
of which you must satisfy before a single line of this guide is useful to you. That is §1, and it is
first for a reason.

---

## What this covers

Apple's server-side Foundation Model — the same model behind many Apple Intelligence features —
reached third-party developers in the 27 cycle behind a `LanguageModel` conformance you swap in with
one line. This guide covers:

- **Eligibility, in full.** Three conditions, not one. One of them appears in **no WWDC session**,
  one of them is measured over your entire App Store history rather than the last twelve months, and
  one of them is a managed entitlement you apply for at a URL that most people mistype. If you fail
  any of the three, §1.7 tells you what to build instead.
- The **entitlement**: where to request it, what it looks like in the project, and the failure mode
  when it is absent (which is not a thrown error).
- **What you actually get** — 32K context against the on-device model's 4K, three reasoning levels,
  no API keys, no authentication, no account setup, no token cost to you, and Foundation Models on
  watchOS for the first time, precisely *because* the inference is remote.
- **The one-line swap**, and the much more interesting claim underneath it: `@Generable`, `Tool`,
  streaming, dynamic profiles and `Transcript` behave identically. One documentation contradiction
  about the initializer, resolved by Apple's own compiling sample code.
- **Availability**, which is three separate checks answering three separate questions, plus the fact
  that **quota is orthogonal to availability** — a model can report `.available` and still fail every
  request.
- **Reasoning**: what it is, the four `ReasoningLevel` cases (Apple's prose says three), where the
  reasoning text lands, how to observe it to drive a progress UI, and the fact that it silently
  spends your 32K.
- **Quota UX**, which is the largest single body of explicit Apple design guidance in the entire
  Foundation Models corpus: `quotaUsage`, `isLimitReached`, the nearing-limit state,
  `limitIncreaseSuggestion.show()`, a complete SwiftUI implementation, the Xcode scheme option that
  simulates both states — and the reason a usage *meter* is impossible to build today.
- **Errors**: `PrivateCloudComputeLanguageModel.Error` has three cases nobody has written about, and
  its relationship to `LanguageModelError` is unresolved.
- The **fallback architecture** for the majority of readers who are ineligible.

## What you need

- **Xcode 27** and a **physical device on 27.0 or later**. ⚠️ **PCC does not work in the Simulator**
  — this is a known issue with an Apple radar number, and the error it produces looks like a bug in
  your code. §5.5.
- The **managed** `com.apple.developer.private-cloud-compute` entitlement, granted to your account.
- A device that supports Apple Intelligence, signed in to iCloud, with a network connection.
- Familiarity with `LanguageModelSession`, `@Generable` and the `Tool` protocol — see
  Part 2. This guide changes the *model behind* the session; everything in front of it is unchanged.
- For §11, the Evaluations framework (Part 6). Apple's recommendation is not to adopt PCC until you
  have measured that the on-device model is insufficient.

---

## Contents

1. [Eligibility: three conditions, not one](#1-eligibility-three-conditions-not-one)
2. [The entitlement](#2-the-entitlement)
3. [What you get, and what it costs](#3-what-you-get-and-what-it-costs)
4. [The one-line swap](#4-the-one-line-swap)
5. [Availability is three questions, not one](#5-availability-is-three-questions-not-one)
6. [Reasoning](#6-reasoning)
7. [Quota UX — Apple's most prescriptive design guidance](#7-quota-ux--apples-most-prescriptive-design-guidance)
8. [Simulating quota states in Xcode](#8-simulating-quota-states-in-xcode)
9. [Errors](#9-errors)
10. [Context: 32K, and the cost of coming back down](#10-context-32k-and-the-cost-of-coming-back-down)
11. [Generable, tools, and evaluating before you commit](#11-generable-tools-and-evaluating-before-you-commit)
12. [If you are not eligible](#12-if-you-are-not-eligible)
13. [Declared gaps](#13-declared-gaps)
14. [Quick reference](#14-quick-reference)
15. [Sources](#15-sources)

---

## 1. Eligibility: three conditions, not one

Every WWDC26 mention of Private Cloud Compute eligibility is a single sentence about downloads.
Session 241:

> ✅ **VERIFIED** — WWDC26 session 241 ("What's new in Foundation Models"), `241:42`: *"PCC is
> available with no cloud API costs to developers who have **less than 2 million first time
> downloads**. Your users will have access to PCC every day and if they are subscribed to iCloud+,
> their limit will be even higher!"*

Session 319 says the same thing more tersely:

> ✅ **VERIFIED** — WWDC26 session 319 ("Build with the new Apple Foundation Model on Private Cloud
> Compute"), `319:26-27`: *"This model is available for apps with **less than 2M downloads**. And
> you can apply on the developer website today."*

And the documentation article says nothing concrete at all:

> ✅ **VERIFIED** — `/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute`:
> *"**IMPORTANT** — To develop with PCC you must meet certain **eligibility requirements**. To learn
> more and request access to the **managed entitlement**, see Accessing Private Cloud Compute."*

If you stop reading there — as a large number of developers did, and as at least one earlier draft of
this series did — you will conclude that eligibility is one number and that you are under it. That
conclusion is wrong for two independent reasons.

The actual criteria are published on Apple's PCC developer page, and there are three of them:

> ✅ **VERIFIED** — verbatim from `https://developer.apple.com/private-cloud-compute/`, fetched
> 2026-07-27 and recorded in `notes/forums/forum-pain-points.md:509-512`:
>
> > Access to PCC is available to developers who meet the following criteria:
> > - Are enrolled in the **App Store Small Business Program**.
> > - Have fewer than **2 million first-time app downloads** from any of their apps on the App Store.
> > - Have the **Private Cloud Compute entitlement** assigned to their account.

Three conditions. Two of them have nothing to do with your app's code, and one of them is stated in
no WWDC session we hold.

### 1.1 Condition 1 — enrolment in the App Store Small Business Program

This is the omission that matters. **No transcript in the WWDC26 corpus mentions the App Store Small
Business Program in connection with PCC.** Sessions 241 and 319 both give the download threshold and
stop. A developer who watches both sessions, checks their App Store Connect numbers, finds they are
comfortably under two million, and starts designing a PCC feature can still be ineligible — and will
not find out until the entitlement request comes back.

> 🟡 **RECONSTRUCTED / source-precedence note.** The Small Business Program condition is quoted above
> from Apple's own developer page, which is evidence class 3 (Apple documentation) in this series'
> precedence order. It is **not** attested in any WWDC transcript, and it was originally surfaced in
> our corpus through secondary coverage plus the developer-site guide before the page itself was
> fetched (`notes/02-lead-agent-corpus-gaps-filled.md:228-249`, which recommends "one more direct
> confirmation from the Apple entitlement/application page before this goes into a published
> guide"). The page fetch in `notes/forums/forum-pain-points.md:507-512` is that confirmation. Treat
> the condition as real; treat the *exact wording* as subject to the page changing under you, since
> policy pages are not versioned and our capture is a single point in time (2026-07-27).

Practically: the App Store Small Business Program is an annual, opt-in enrolment with its own revenue
threshold and its own re-qualification rules, administered in App Store Connect and entirely separate
from the Developer Program membership that gets you Xcode and provisioning. If you are not in it, PCC
is not available to you regardless of your download count. Check enrolment status **before** you
design anything, not after.

There is a live forum thread about the adjacent question of whether a hobbyist developer even
qualifies for the Small Business Program (thread 833625, "Hobbyist Eligibility for App Store Small
Business Program", listed in `notes/forums/forum-pain-points.md:113-114`) — which tells you the
coupling between the two programmes surprised people immediately.

### 1.2 Condition 2 — fewer than 2 million *lifetime* first-time downloads

The download bar is not "two million downloads last year". It is not per-app either. Read the wording
again: *"fewer than 2 million first-time app downloads **from any of their apps** on the App Store."*

Three consequences, in increasing order of how badly they surprise people:

**It is cumulative across your whole account, not per app.** A developer with twelve apps is measured
on the sum.

**It is measured over your entire App Store history, not a rolling window.** This is the one that
generated an angry forum thread with a title that says everything: *"I did well on iOS a decade ago.
So - no foundation models for me?"*

> ✅ **VERIFIED** — Apple Developer Forums thread **835897** (24 June 2026), original poster: *"I had
> 180k downloaded units in the last year - but I'm excluded from foundation models because I did well
> before 2015… **Lifetime downloads**."* Recorded in `notes/transcripts/fm-core.md:239-242`.
>
> Apple's answer in the same thread, from **DTS Engineer (Ziqiao Chen)**, confirms the reading:
> on-device Foundation Models have **no limits** for any developer, while apps with **more than 2
> million first-time app downloads across a long time span are ineligible for PCC**
> (`notes/forums/forum-pain-points.md:501-505`).

Note the phrase "across a long time span" in Apple's own reply. Our corpus originally flagged the
lifetime reading as needing verification (`notes/02-lead-agent-corpus-gaps-filled.md:181-184`); the
DTS reply plus the page wording resolve it. **The forum poster was reading the policy correctly.** A
developer whose current business is small can be permanently excluded by a hit they shipped in 2013.

**Testing installs do not count.**

> ✅ **VERIFIED** — same page, quoted at `notes/forums/forum-pain-points.md:514-516`: *"Where Apple
> Intelligence is available, eligible developers can use PCC in their apps distributed on the App
> Store, and test PCC features via **TestFlight or ad hoc distribution**. **Installs during testing
> are not counted as first-time app downloads.**"*

So you can build and beta-test a PCC feature without eating into your own threshold. That is the one
piece of good news in this section.

### 1.3 What happens if you cross the line later

You do not get cut off mid-flight, but you do get a clock.

> ✅ **VERIFIED** — `https://developer.apple.com/private-cloud-compute/`, quoted at
> `notes/forums/forum-pain-points.md:518-520`: *"If any app subsequently exceeds the 2 million
> first-time downloads threshold, **or the developer is no longer enrolled in the App Store Small
> Business Program**, the developer will be notified and must **migrate to an alternative solution
> within 6 months**."*
>
> Restated independently by a **Frameworks Engineer (Apple)** in thread **833641** ("Guidance Around
> PCC"), marked Recommended: *"If your app exceeds the 2 million first-time downloads threshold, you
> will be notified and must migrate to an alternative solution within 6 months."*
> (`notes/forums/forum-pain-points.md:524-525`.)

Read that first clause carefully: **success is a termination condition.** If your app takes off, the
intelligence feature you built on PCC has a six-month fuse. And the second clause means the fuse can
also be lit by a change in your Small Business Program status — which has its own annual
re-qualification, entirely outside the Foundation Models world.

This has a concrete architectural implication that is worth stating before we write any code:

> **Design the PCC path as a swappable tier from day one.** Not because the API is unstable, but
> because the *business* qualification is time-limited by construction. §12 covers the fallback
> architecture; the point here is that you should build it at the same time you build the PCC path,
> not six months after a congratulatory email.

### 1.4 The URL

There are two URLs and one of them does not exist.

| URL | Status |
|---|---|
| `https://developer.apple.com/private-cloud-compute/` | ✅ The live page. Criteria + entitlement request. |
| `https://developer.apple.com/contact/request/private-cloud-compute/` | ✅ The direct request form. |
| `https://developer.apple.com/apple-intelligence/private-cloud-compute/` | 🚫 **404s.** |

> ✅ **VERIFIED** — the 404 is recorded at `notes/02-lead-agent-corpus-gaps-filled.md:241-243`: *"`https://developer.apple.com/apple-intelligence/private-cloud-compute/` **404s**. The live path is
> `https://developer.apple.com/private-cloud-compute/` (this is also the URL the forum poster in
> thread 834749 cites)."*
>
> The `/contact/request/` form URL is the strongest-evidence item in this section: it appears **in a
> code comment inside two separate Apple sample projects**, not in prose
> (`notes/web/apple-sample-code.md:236-237`, Origami's `OrchestratorProfile.swift`).

The `/apple-intelligence/` path is a natural guess and it circulates in write-ups. Do not link it.

### 1.5 The three conditions as a preflight checklist

Run this before you write anything:

```text
[ ] 1. Are you enrolled in the App Store Small Business Program?
       App Store Connect → Agreements, Tax, and Banking.
       ← Stated in NO WWDC session. Check this one first, precisely because
         nobody told you about it.

[ ] 2. Sum of first-time App Store downloads across ALL your apps, for ALL time,
       under 2,000,000?
       ← Lifetime, not annual. Not per-app. TestFlight/ad-hoc installs excluded.

[ ] 3. Is com.apple.developer.private-cloud-compute assigned to your account?
       Request at https://developer.apple.com/private-cloud-compute/
       ← A MANAGED entitlement. You cannot self-serve it in Xcode.

If any box is unchecked → §12. The fallback is a different architecture,
not a different flag.
```

### 1.6 What eligibility does *not* gate

Two clarifications that save wasted worry:

- **The on-device model has no eligibility bar at all.** ✅ DTS Engineer, thread 835897: on-device
  Foundation Models (`SystemLanguageModel`) have **no limits** for any developer
  (`notes/forums/forum-pain-points.md:503`). Nothing in this section applies to Part 2's material.
- **Non-App-Store distribution is fine for the on-device model.** ✅ Frameworks Engineer, thread
  832033: *"Yes, non-App Store apps can use the Foundation Models framework to access the on-device
  system model."*

> 🔴 **GAP — whether PCC works for non-App-Store / notarized-only macOS distribution.** The PCC page's
> wording is *"in their apps distributed on the App Store, and test PCC features via TestFlight or ad
> hoc distribution"*, which reads like App Store distribution is required for shipping, but no Apple
> statement addresses a notarized-outside-the-App-Store Mac app directly. Thread 832033 answers only
> the on-device question. **What would resolve it:** an Apple-staff answer on a thread that asks
> specifically about Developer ID distribution, or explicit wording on the entitlement page.
> **Safe default meanwhile:** if you ship outside the App Store on macOS, plan the on-device model as
> your baseline and treat PCC as an App-Store-build-only enhancement, gated at runtime by
> `model.availability` (§5) rather than by a compile-time flag — so the same binary degrades cleanly.

### 1.7 If you fail any condition, stop here

For a substantial share of readers the honest answer is "you cannot use this API". That is not a
dead end, but it is a **different architecture**, not a different constant: you take on
authentication, key storage, billing, rate limiting and a privacy disclosure that PCC would have
handled for you. §12 sketches it, and the rest of Part 4 covers each backend in depth.

---

## 2. The entitlement

### 2.1 The key, and the fact that it is *managed*

> ✅ **VERIFIED** — the entitlement key is **`com.apple.developer.private-cloud-compute`**, and it is
> a **managed** entitlement: you request it and Apple assigns it; you cannot simply tick a box in
> Xcode's Signing & Capabilities pane and have it work.
>
> Four independent confirmations in our corpus:
> 1. The doc article links `/documentation/BundleResources/Entitlements/com.apple.developer.private-cloud-compute`
>    (`notes/web/apple-docs-fm-evals-speech.md:1692`).
> 2. **Apple's own sample code names it in a comment, in two separate sample projects**, together with
>    the request URL (`notes/web/apple-sample-code.md:235-239`) — this is the strongest evidence class
>    in this corpus.
> 3. The Origami documentation article says *"Add the **managed** `com.apple.developer.private-cloud-compute`
>    entitlement"*.
> 4. It appears as a real key in four shipping `.entitlements` files in a third-party app
>    (`Noema.entitlements`, `NoemaDirect.entitlements`, `NoemaVisionOS.entitlements`,
>    `RelayServer.entitlements`) — community evidence that the key spelling is right in practice.

Note that **the entitlement name is never spoken in any WWDC session.** Session 319 tells you to
"apply on the developer website"; session 241 says "including the entitlement you'll need to use it,
make sure to tune in to our video" — and then the video does not name it either. The name only exists
in writing.

### 2.2 How to request it

> ✅ **VERIFIED** — **Sla1708 / Sayan Lakhoua (Apple)** in thread **829539** ("Private Cloud Compute
> entitlement"), accepted answer (`notes/forums/forum-pain-points.md:532-541`):
>
> > "You can now request access to the Private Cloud Compute (PCC) Entitlement directly: Request
> > Private Cloud Compute (PCC) Entitlement — https://developer.apple.com/private-cloud-compute/
> >
> > Please note that you must meet certain eligibility requirements to develop with Private Cloud
> > Compute."

And the question everyone asks — *is the entitlement application the same thing as "applying for the
programme"?* — has an explicit Apple answer:

> ✅ **VERIFIED** — **Apple Designer (Apple)** in thread **834749** ("Accessing Private Cloud
> Compute"), accepted (`notes/forums/forum-pain-points.md:527-530`):
>
> > "**The entitlement application is what you need to 'apply' for the program**, and this entitlement
> > in Xcode is what allows your app to access PCC."

So there is one application, not two. The forum poster in 834749 also asked whether a standard
Developer Program account can apply and whether there is an additional fee; the fee half is answered
by the page itself — **no cloud API cost for eligible developers**
(`notes/forums/forum-pain-points.md:522`) — and the eligibility half is §1.

> **Operational note, community-reported:** the request page **returned HTTP 500 during WWDC26 week**
> (rickystone, thread 829539, `notes/forums/forum-pain-points.md:543-544`). The same thread notes the
> entitlement can also be requested from a link at the bottom of the "Adding server-side intelligence
> with Private Cloud Compute" documentation page. If the form is down, that is the second door.

### 2.3 ⚠️ SILENT FAILURE — the missing entitlement does not throw

This is the one that will cost you an afternoon.

> ⚠️ **SILENT FAILURE — removing the PCC entitlement produces a `fatalError`, not a catchable error.**
> Your carefully written `do/catch` around `session.respond(to:)` never runs. The process dies.
>
> 🟡 **RECONSTRUCTED / community-reported** — this comes from Apple Developer Forums thread **831998**
> ("`PrivateCloudComputeLanguageModel` fails to respond"), recorded at
> `notes/forums/forum-pain-points.md:498-499`: *"Also from this thread: **removing the Private Cloud
> Compute entitlement triggers a `fatalError`** at runtime, and `model.isAvailable` returns `true`
> even when the call fails."* The thread has an accepted Apple answer about a **different** issue (the
> Simulator, §5.5); the `fatalError` observation is from the thread's participants, not from Apple
> staff, so treat the *mechanism* as reported rather than documented. What is not in doubt is the
> shape of the failure: it is a crash, not a thrown `Error`.
>
> **Defensive consequence:** do not ship a build configuration that can reach
> `PrivateCloudComputeLanguageModel` without the entitlement. In particular, if you strip entitlements
> for an internal/enterprise variant, gate the *construction* of the model behind a compile-time flag,
> not just its use:
>
> ```swift
> #if PCC_ENABLED
> let model = PrivateCloudComputeLanguageModel()
> #endif
> ```

Note the second half of that report — **`model.isAvailable` returns `true` even when the call
fails.** That is a preview of §5.4: availability is not a health check.

### 2.4 What Apple's own sample ships

Worth knowing before you copy anything from Origami: **Apple's PCC-capable sample does not ship the
entitlement.**

> ✅ **VERIFIED** — `notes/web/apple-sample-code.md:63-65, 321-324`: Origami's
> `Origami/Origami.entitlements` contains **only** `com.apple.security.app-sandbox`. PCC is
> opt-in-by-comment: the sample defaults to the on-device model and tells you, in a comment, to
> request the managed entitlement and swap one line.
>
> The comment itself, from `Origami/Models/OrchestratorProfile.swift:11-75`
> (`notes/web/apple-sample-code.md:233-240`):
>
> ```swift
> // Brainstorm and tutorial work best on a server model. The sample
> // defaults to the on-device system model so it runs out of the box.
> // To use Private Cloud Compute, request access to the managed
> // `com.apple.developer.private-cloud-compute` entitlement at
> // https://developer.apple.com/contact/request/private-cloud-compute/,
> // then replace the `serverModel` initialization with the line below.
> // var serverModel = PrivateCloudComputeLanguageModel()
> var serverModel = SystemLanguageModel()
> ```

That single stored property is worth studying for a second, because it is the cleanest expression of
the architecture this whole guide is arguing for. The model is a **property of the profile struct**,
referenced from several branches, not constructed inline at each call site. That is what makes the
switch a one-line change — and it is what will make the switch *back* a one-line change when your
2013 hit pushes you over two million.

---

## 3. What you get, and what it costs

### 3.1 The model

> ✅ **VERIFIED** — WWDC26 session 241, `241:29-32`: the PCC model is *"the very same one that powers
> many of the Apple Intelligence features you know and love"*, *"a much bigger model than the
> on-device models"*, with a **32,000 token context window**, and *"comes with a powerful new
> capability, **reasoning**. Reasoning models are trained to spend time carefully thinking through
> their answers before providing a response, which results in significantly better outcomes."*

Session 319 gives the intended use cases:

> ✅ **VERIFIED** — `319:8-9`: *"you can build complex AI features in your apps. Like **assistants
> that reason over large user input** or **features that rely on making lots of tool calls, with
> large outputs**. And you can even **call Private Cloud Compute from watchOS**."*

Those two phrases are a good filter. "Reason over large user input" and "lots of tool calls with
large outputs" both describe **context pressure**, not capability gaps. If your feature is a
three-sentence summary of a paragraph, PCC will not make it better; it will make it slower and
consume a user's daily quota. §11 is about proving which of the two you have.

### 3.2 The comparison table

> ✅ **VERIFIED** — verbatim from the PCC documentation article
> (`notes/web/apple-docs-fm-evals-speech.md:1677-1683`). Session 319 narrates the same five rows with
> the same values at `319:38-45`, so transcript and docs agree exactly here:

| Capability | `SystemLanguageModel` | `PrivateCloudComputeLanguageModel` |
|---|---|---|
| Preserves privacy | ✅ | ✅ |
| Works offline | ✅ | 🚫 |
| Usage limits | Unlimited | Limit per day |
| Reasoning | Not supported | Multiple levels |
| Context size | 4K | 32K |

Two rows deserve annotation.

**"Reasoning: Not supported" on the on-device model** means `ContextOptions.reasoningLevel` is, in
practice, a PCC-only (or custom-provider-only) knob. Setting it on a `SystemLanguageModel` session is
not a compile error; §6.5 covers what actually happens.

**"Context size: 4K"** is the number Apple prints, and it is now settled:

> ✅ **SETTLED — the on-device figure is 4,096.** Apple's slide (`319:44`), the docs table, and
> **TN3193** ("Managing the on-device foundation model's context window", read 2026-07-27) all state
> it plainly, and the 2026-07-31 runtime probe measured `contextSize == 4096` on the iOS 27.0
> simulator runtime (`probes/`, `fm.contextSize`). The contrary claim — a comment in shipping
> third-party app code (`Noema/AFMLLMClient.swift:133-135`, community-measured) that the iOS 27
> model reports 8K — is uncorroborated by Apple and now rests entirely on iOS 27 *hardware*; treat
> it as a footnote, not a live conflict. Apple's DTS Engineer in thread 790736 (iOS 26 era) still
> applies: *"There is no guarantee that this will stay the same forever or across devices."*
>
> **Ruling: still do not hardcode 4096.** Read `contextSize`. The PCC side of the table is better
> corroborated — a shipping app hardcodes `static let privateCloudContextLimit = 32_768`
> (`Noema/AppleFoundationModelRegistry.swift:7`) and the docs article states 32K in prose — but even
> there, prefer the property. Note that forum thread 833642's 32K figure came from a **community**
> reply, not Apple staff (`notes/forums/forum-pain-points.md:328-329`); the *documentation article* is
> what makes 32K an Apple number.

### 3.3 `contextSize`, and the version trap inside it

> ✅ **VERIFIED** — session 319, `319:59-60`: *"we also added a convenient API to let you
> **programmatically get the context size for a model**. Just access the **`contextSize`** property on
> **either `SystemLanguageModel` or `PrivateCloudComputeLanguageModel`**."*
>
> Declaration, from `/documentation/foundationmodels/systemlanguagemodel/contextsize`
> (`notes/web/apple-docs-fm-evals-speech.md:71-76`) — note the explicit back-deployment attribute:
>
> ```swift
> final var contextSize: Int { get }
> ```
>
> On PCC the property is asynchronous and throwing:
> `var contextSize: Int { get async throws }`.[^pcc-context-size] Now also ✅ **SDK-verified**:
> `nonisolated(nonsending) final public var contextSize: Swift.Int { get async throws }`
> (`FoundationModels-27.0-macos.swiftinterface:129-139`) — a computed property, not a constant;
> there is no 32K literal anywhere in the interface, so the published figure is documentation, and
> the property is the only programmatic source.

The trap: `contextSize` was **announced** in a 27-era session but **shipped** in the 26.4 SDK for
`SystemLanguageModel`. So `SystemLanguageModel.default.contextSize` must **not** be wrapped in an
`if #available(iOS 27.0, *)` block — do that and you needlessly lose it on 26.4–26.x devices. On
`PrivateCloudComputeLanguageModel` the property is 27.0-only for the trivial reason that the whole
class is.

Defensive read, following the pattern in shipping code (`AFMLLMClient.swift:140`, community):

```swift compile:27
import FoundationModels

/// Returns the model's context size in tokens, or a conservative fallback.
/// `contextSize` is documented to return an `Int`; shipping code treats
/// non-positive values as "unknown" rather than trusting them.
func contextBudget(for model: SystemLanguageModel) -> Int {
    let reported = model.contextSize
    return reported > 0 ? reported : 4096      // fallback ONLY, never the primary path
}
```

> 🟡 **RECONSTRUCTED** — the `<= 0` guard is a *practice* borrowed from shipping third-party code, not
> a documented contract. Apple documents `contextSize` as a non-optional `Int` and says nothing about
> a sentinel. Keep the guard anyway; it costs one comparison and it is the difference between a
> mis-sized prompt and a crash-free fallback.

### 3.4 The economics: nothing to set up, nothing to pay

This is the actual product pitch, and it is unusually strong. Session 319, sequentially:

> ✅ **VERIFIED** — `319:19-25`:
> - *"Private Cloud Compute is integrated in the OS, together with **iCloud**. So you **don't have to
>   worry about authentication or API keys**, like you typically do with server models."*
> - *"With **no account setup, no authentication and no API keys**, this is really the easiest server
>   LLM you'll ever use."*
> - *"**there are no token costs to you, the developer.**"*
> - *"**Each user gets a daily limit.** And users can **upgrade to iCloud+** to get higher limits."*

The docs restate it (`notes/web/apple-docs-fm-evals-speech.md:1689`): *"Typically, you need to handle
authentication and manage API keys with server models. **You don't need to handle either when you use
PCC.** People just need a device that supports Apple Intelligence and gets a **daily request limit**.
People can upgrade their **iCloud+** subscription to get more access when they want it."*

Read the cost model carefully, because it inverts the usual one:

| | Third-party server LLM | PCC |
|---|---|---|
| Who pays per token | **You**, the developer | Nobody — no token cost to you |
| Who is rate-limited | Your account, aggregate | **Each user**, individually, daily |
| Auth to build | OAuth / token provider / Keychain / App Attest | **None** |
| What runs out | Your budget | **Your user's daily allowance** |
| Who can fix it | You (top up) | **The user** (wait, or upgrade iCloud+) |

The consequence for your UI is the whole of §7. When your budget runs out you show an error to
yourself; when your *user's* budget runs out you have to explain a limit they did not know they had,
in a product they did not know was using it, with an action only they can take. That is why Apple
spends a fifth of session 319 on the design of one label and one button.

### 3.5 Privacy — and your obligation to say so

> ✅ **VERIFIED** — `319:14-17`: *"you can access a powerful server LLM, **without compromising on
> privacy**. Private Cloud Compute is designed with **end-to-end privacy** in mind, ensuring that
> **user data is never stored**. The data is only used for requests. And all of this has been
> **independently verified by researchers**."*
>
> Session 241 (`241:38-43`) adds: *"**No prompts are ever stored**, and we make it possible for
> **independent researchers to verify these claims**."*

That is a genuinely different guarantee from "we have a good privacy policy". But note that WWDC26
session 339 closes with an instruction addressed to *everyone* in the model-provider ecosystem, and
it applies to you as a PCC adopter too:

> ✅ **VERIFIED** — `339:204-205`: *"whether you're choosing a package or shipping one, make sure
> everyone in the chain understands the privacy implications of the model behind it. **On-device and
> cloud-based models have very different privacy characteristics, and your users deserve to know which
> they're getting.**"*

If you use a dynamic profile that routes some turns on-device and some to PCC (§10), your users are
crossing that boundary mid-conversation without being told. Tell them.

### 3.6 watchOS, and why it is a PCC story

> ✅ **VERIFIED** — `241:40-41`: *"**Private Cloud Compute makes it possible for us to bring the
> Foundation Models framework to watchOS**. Starting in **watchOS 27**, you can wear your most
> powerful intelligence features right on your wrist."* Session 319 (`319:9`) repeats it: *"you can
> even **call Private Cloud Compute from watchOS**."*
>
> Corroborated by the availability snippet in the docs, which lists watchOS
> (`notes/web/apple-docs-fm-evals-speech.md:1703`):
>
> ```swift
> if #available(iOS 27.0, macOS 27.0, watchOS 27.0, visionOS 27.0, *) {
>     // Create a session using the server-based model.
> } else {
>     // Use the on-device model on older versions.
> }
> ```

The causality is worth spelling out because it explains an asymmetry you will hit elsewhere: the
Foundation Models framework reached watchOS **because the inference is remote**. The on-device model
is not described as running on the watch anywhere in our corpus. Contrast `SpotlightSearchTool`, which
session 246 explicitly lists for *"iOS, iPadOS, macOS, and visionOS"* — **no watchOS**. So on the
watch you have the server model and, at minimum, a narrower tool ecosystem around it.

Two live watchOS caveats:

> ⚠️ **Community-reported pairing requirement, UNVERIFIED by Apple.** Forum thread **834652** ("Can any
> Apple Watch running WatchOS 27 access PCC via Foundation Models?") ends in an OP self-answer with no
> Apple reply (`notes/forums/forum-pain-points.md:646-652`):
>
> > "No, not only does the Watch have to be running WatchOS 27, it also needs to be **paired to an
> > iPhone with Apple Intelligence enabled**. This is despite the fact that PCC queries from WatchOS 27
> > go straight to the server and don't require the paired iPhone at all 🤷‍♂️"
>
> If true: **Apple Watch Series 11 + iPhone 15 = no PCC**, even though the watch itself never runs the
> model. **What would resolve it:** an Apple-staff answer on 834652, or explicit wording in the
> watchOS 27 release notes. **Safe default meanwhile:** on watchOS, treat `model.availability` as the
> only truth and design a complete non-AI path — you cannot infer eligibility from the watch's own
> hardware.

> ✅ **VERIFIED — a watchOS 27 beta 2 build break, acknowledged by Apple.** Thread **835987**: importing
> `FoundationModels` on watchOS 27 beta 2 fails with
> `…/WatchOS27.0.sdk/…/FoundationModels.swiftmodule/arm64e-apple-watchos.swiftinterface:6:15 Unable to
> resolve module dependency: 'CoreImage'`. Frameworks Engineer (Apple), accepted: *"This is a known
> bug."* Almost certainly fallout from the new image-attachment API pulling CoreImage into the module
> interface on a platform that lacks it. Status as of 2026-07-27: acknowledged, no fix version given.

---

## 4. The one-line swap

### 4.1 The claim

> ✅ **VERIFIED** — `319:29-31`: *"If you already have an app using Foundation Models, you know that it
> takes just **3 lines of code** to prompt the on-device LLM. You create a session and then ask it to
> respond to your prompt. And now by changing just **1 line of code**, you can switch to the new
> server model on PCC."*

The line, verbatim from the documentation article
(`notes/web/apple-docs-fm-evals-speech.md:1697-1701`):

```swift xfail:26 compile:27
import FoundationModels

// Create a session with the server-side model.
let session = LanguageModelSession(model: PrivateCloudComputeLanguageModel())
let response = try await session.respond(to: "Analyze this document...")
```

Three independent corroborations that this exact spelling compiles:

| Source | Evidence class |
|---|---|
| Apple's Book Tracker sample, `BookSampleGenerator/main.swift` — `LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: "…")` (`notes/web/apple-sample-code.md:1362-1364`) | **Sample code** (strongest) |
| Apple Engineer reply in thread 832053, verbatim code block (`notes/forums/forum-pain-points.md:683-686`) | Apple-staff forum answer |
| Forum thread 834749, developer's working snippet | Community |

And the type name itself is settled: `PrivateCloudComputeLanguageModel`, not the "PCCLanguageModel"
that circulated from caption shorthand.

> ✅ **VERIFIED** — `notes/web/apple-sample-code.md:84`: *"`PrivateCloudComputeLanguageModel()` in two
> archives … **CONFIRMED**. 'PCCLanguageModel' was caption shorthand."* The initializer is a bare
> `init()` with no configuration (`notes/web/apple-docs-fm-evals-speech.md:1666`, and the sample
> comment states the motive plainly: *"Uses Private Cloud Compute for larger, more diverse
> generations."*).

### 4.2 The documentation contradiction, and how it resolves

There is a real inconsistency in Apple's own docs about whether the classic session initializer even
accepts a non-`SystemLanguageModel` model, and it is worth knowing about because it is exactly the
call site you are about to write.

> ⚠️ **CONFLICT.** From our index of the `LanguageModelSession` page
> (`notes/web/apple-docs-fm-evals-speech.md:196`):
>
> > "the *legacy* inits are typed `model: SystemLanguageModel`, **NOT** `some LanguageModel`. Only the
> > two dynamic-profile inits accept an arbitrary `LanguageModel`. But the PCC article says *'Because
> > both `PrivateCloudComputeLanguageModel` and `SystemLanguageModel` conform to the `LanguageModel`
> > protocol, you can pass either to `init(model:tools:instructions:)`.'* — this is a **documentation
> > contradiction**… **UNVERIFIED which is correct.**"
>
> **Ruling: the PCC article is right, and the symbol-page typing is stale or incomplete.** Apple's
> Book Tracker sample compiles `LanguageModelSession(model: PrivateCloudComputeLanguageModel(),
> instructions: …)`. Under this series' evidence precedence, a compiling first-party sample project
> outranks a documentation page. There is presumably an unlisted iOS 27 overload generic over
> `LanguageModel`.
>
> **Practical consequence:** if you hit a type error on this line, the cause is your SDK, not your
> spelling. Confirm you are building against the Xcode 27 SDK before changing anything.

### 4.3 What stays exactly the same

This is the part that makes the swap worth doing rather than merely possible.

> ✅ **VERIFIED** — `319:32-35`: *"With just that line, you're now talking to a much larger model, with
> larger context and more complex reasoning capabilities. The Foundation Models framework offers a
> **unified Swift API**, regardless of which model you're talking to. **Getting structured output with
> Generable, or calling Tools, works just the same with the PCC model, as it does with the on-device
> model.** This easily lets you switch between models, without having to rewrite your code."*

The mechanism, which the transcript leaves implicit and the docs state:
`PrivateCloudComputeLanguageModel` and `SystemLanguageModel` both conform to the **`LanguageModel`**
protocol, and Apple lists exactly those two as the framework's own conformers
(`notes/web/apple-docs-fm-evals-speech.md:1780`).

So the following all behave identically across the swap, and none of them appear in this guide again
because Part 2 already covers them:

- `@Generable` + `@Guide` structured output and `respond(to:generating:)`
- `streamResponse(to:)` and `PartiallyGenerated` snapshot streaming
- The `Tool` protocol, parallel and back-to-back tool calls, `toolCallingMode`
- `Instructions`, `Prompt`, the transcript, `LanguageModelSession.Usage`
- Dynamic profiles and every profile modifier

Two things *do* change and both get their own section: reasoning becomes available (§6) and quota
becomes something you must render (§7).

### 4.4 Where the model belongs in your code

The temptation is to write `LanguageModelSession(model: PrivateCloudComputeLanguageModel())` inline.
Apple's sample does not, and the reason is architectural rather than stylistic.

> ✅ **VERIFIED** — Origami stores the model as a property of the profile struct and references it from
> multiple branches (`notes/web/apple-sample-code.md:327-328`): *"**Model choice is a *property* of the
> profile struct, not of each branch.** `serverModel` is stored once and referenced from multiple
> branches — this is what makes flipping to PCC a one-line change."*

Here is the shape, adapted from Apple's compiling code. Note `Profile { … }.model(_:)` — a **modifier**,
not an initializer label:

```swift prelude:guide-context
import FoundationModels

struct OrchestratorProfile: LanguageModelSession.DynamicProfile {
    var orchestrator: Orchestrator

    // One switch point for the whole app.
    var serverModel = SystemLanguageModel()          // ← swap to PrivateCloudComputeLanguageModel()

    var body: some DynamicProfile {
        switch orchestrator.mode {
        case .brainstorm:
            Profile {
                BrainstormInstructions(orchestrator: orchestrator)
            }
            .model(serverModel)
            .temperature(1.0)

        case .tutorial:
            Profile {
                TutorialInstructions(orchestrator: orchestrator)
            }
            .model(serverModel)
            .reasoningLevel(.deep)
        }
    }

    private var isOnDevice: Bool {
        type(of: serverModel) == SystemLanguageModel.self
    }
}
```

> ✅ **VERIFIED** — every element of that skeleton is from `Origami/Models/OrchestratorProfile.swift:11-75`
> as recorded in `notes/web/apple-sample-code.md:229-294`: the nested conformance
> `LanguageModelSession.DynamicProfile`, the **short** body type `some DynamicProfile`,
> `Profile { … }.model(…)` rather than `Profile(model:) { … }`, `.temperature(1.0)` as a `Double`,
> `.reasoningLevel(.deep)`, and the `type(of:) == SystemLanguageModel.self` runtime model-kind test —
> which is slightly hacky, and is Apple's own idiom here.

Two corrections that earlier reconstructions of this API got wrong, so you do not reintroduce them:
`Profile(model:) { … }` is **not** the spelling (it is a content closure plus a `.model(_:)`
modifier), and the body type is the **short** `some DynamicProfile`, not
`some LanguageModelSession.DynamicProfile`. Both are recorded as corrections in
`notes/web/apple-sample-code.md:80` and `:2`.

Dynamic profiles proper are Part 3's subject. What matters here is the discipline: **one stored
property is your model-selection surface.** §12's fallback plugs into the same property.

---

## 5. Availability is three questions, not one

There are three checks and they answer three genuinely different questions. Developers conflate them
and then file bugs against the wrong one.

| Check | Question it answers | Version |
|---|---|---|
| `#available(iOS 27.0, …)` | Does this OS have the API at all? | compile/runtime OS gate |
| `model.availability` | Can this device/user reach PCC right now? | 27.0 |
| `model.supportsLocale(_:)` | Will it answer in the language I need? | 27.0 on PCC |
| `model.quotaUsage` | Has this user already spent their day? | **orthogonal — see §5.4** |

### 5.1 The OS gate

> ✅ **VERIFIED** — the docs article's own snippet
> (`notes/web/apple-docs-fm-evals-speech.md:1703-1707`):
>
> ```swift
> if #available(iOS 27.0, macOS 27.0, watchOS 27.0, visionOS 27.0, *) {
>     // Create a session using the server-based model.
> } else {
>     // Use the on-device model on older versions.
> }
> ```

Note what is and is not in that list. iOS, macOS, watchOS, visionOS. **iPadOS follows iOS.** tvOS and
Mac Catalyst are absent from every PCC availability statement in our corpus.

> ✅ **RESOLVED (2026-07-29) — the availability annotations, read from the 27.0 interface.** Every
> `PrivateCloudComputeLanguageModel` declaration is
> `@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)` with an explicit
> `@available(tvOS, unavailable)` — ✅ **SDK-verified**
> (`FoundationModels-27.0-macos.swiftinterface:43-48` and repeated on every extension). So:
> **tvOS: unavailable, stated in the SDK.** watchOS 27.0 is *included* — notable, because
> `SystemLanguageModel` is `watchOS, unavailable` (`:257-260`), making PCC the only Apple-hosted
> `LanguageModel` on watch. **Mac Catalyst:** there is no `macCatalyst` attribute anywhere in the
> interface, and the module is built with `-target-variant arm64e-apple-ios27.0-macabi` (`:3`), so
> Catalyst inherits the iOS 27.0 floor at the *declaration* level — whether the PCC service answers
> a Catalyst process at runtime is still unobserved. Apple's four-platform `#available` snippet is
> exactly right; copy it.

A community-shipping variant of the same check omits watchOS and includes visionOS
(`AFMLLMClient.swift:91`: `if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *)`) — a reminder that
these lists are hand-maintained and drift. Copy Apple's.

### 5.2 `availability` — and a PCC-only unavailability reason

> ✅ **VERIFIED** — verbatim from the docs article
> (`notes/web/apple-docs-fm-evals-speech.md:1710-1724`):
>
> ```swift
> let model = PrivateCloudComputeLanguageModel()
>
> switch model.availability {
> case .available:
>     // Show your intelligence UI.
> case .unavailable(.deviceNotEligible):
>     // Show an alternative UI.
> case .unavailable(.systemNotReady):
>     // PCC isn't ready to serve requests.
> case .unavailable(let other):
>     // The model is unavailable for an unknown reason.
> }
> ```
>
> Note the annotation in our source notes: **`.systemNotReady` is a PCC-only reason, not present on
> `SystemLanguageModel.Availability.UnavailableReason`.** The type is
> `PrivateCloudComputeLanguageModel.Availability` — a nested type, distinct from the on-device model's
> availability enum. Do not assume the reason lists match.

The `case .unavailable(let other)` arm is doing real work: the reason enum is not frozen, and there is
at least one reason Apple's own sample does not name. Shipping third-party code adds an
`@unknown default:` arm on top (`AppleFoundationModelAvailability.swift:163-186`, community) — belt
and braces, and correct.

Session 319 states the gating rule in one sentence:

> ✅ **VERIFIED** — `319:36-37`: *"Keep in mind, **just like with the on-device model, PCC is only
> available on Apple Intelligence devices.** It's important to check the availability API, and
> gracefully handle when Apple Intelligence is not available on a user's device."*

### 5.3 Proactive gating vs reactive catching

The 2026 samples changed Apple's own advice here, and the change is easy to miss.

> ✅ **VERIFIED** — `notes/web/apple-sample-code.md` correction (p): *"The **2026 samples dropped
> proactive `availability` gating** in favour of reactive `SystemLanguageModel.Error` catching; the
> stale iOS 26 game still gates."*

But the PCC **documentation article** teaches proactive gating, with the switch above. So which is it?

**Both, for different purposes, and PCC tilts toward proactive.** The reason is not technical, it is
commercial, and Apple stated it directly on a different thread:

> ✅ **VERIFIED** — **Apple Designer (Apple)**, thread 836810
> (`notes/forums/forum-pain-points.md:571-575`): *"Run an availability check as soon as you launch your
> app… Availability can tell you additional information about compatibility… From a UX standpoint,
> **try to check availability before anyone agrees to pay for your app's service**, to avoid someone
> paying for what they can't use."*
>
> Same thread, **Frameworks Engineer (Apple)**: *"The App Store doesn't support a required device
> capability for Apple Intelligence."* There is **no** `UIRequiredDeviceCapabilities` entry that keeps
> your app off an ineligible device. *"The recommendation on the App Store side is to provide some
> baseline functionality to all users, regardless of whether Apple Intelligence is available."*

So for PCC: **gate proactively for anything that shapes navigation, onboarding or purchase**, and
**catch reactively for everything else** — because availability can change between your check and your
call, and because §5.4 means `.available` was never a promise anyway.

### 5.4 ⚠️ SILENT FAILURE — availability is not a health check

> ⚠️ **SILENT FAILURE — `availability == .available` and `isAvailable == true` do not mean your next
> request will succeed.** There is no error, no warning, and no state anywhere in the availability API
> that reflects the single most common real-world failure: the user has already used up today's quota.
>
> ✅ **VERIFIED** — Apple says this outright in the docs
> (`notes/web/apple-docs-fm-evals-speech.md:1734`): *"A quota describes the model's **per-user request
> budget** and where the caller currently sits relative to it. **Quotas are orthogonal to a model's
> availability — a model can be available even after its usage limit has been reached.**"*
>
> Reinforced from the field: in thread 831998 a developer reports **`model.isAvailable` returns `true`
> even when the call fails** (`notes/forums/forum-pain-points.md:499`, community-reported).
>
> **The correct preflight is two properties, not one**, and in this order:
>
> ```swift
> let model = PrivateCloudComputeLanguageModel()
>
> switch model.availability {
> case .available:
>     // Necessary, but NOT sufficient.
>     if model.quotaUsage.isLimitReached {
>         // Available, and yet every request will fail. Render §7's UI.
>     }
> case .unavailable(let reason):
>     // Fall back to SystemLanguageModel or your non-AI path.
> }
> ```
>
> Shipping third-party code models exactly this two-step and collapses it into one app-level enum
> (`AppleFoundationModelAvailability.swift:163-186`, community): `.available`,
> `.approachingLimit`, `.limitReached(resetDate:)`, plus the unavailable reasons. That collapse is a
> good idea — it puts the "available but useless" state on the same axis as the others, where your UI
> can see it.

### 5.5 ⚠️ The Simulator does not run PCC

> ⚠️ **SILENT-ish FAILURE — PCC in the Simulator produces a meaningless error that looks like your
> bug.** It is not silent (it throws), but the error is content-free, which is functionally worse: it
> sends you debugging your own code.
>
> ✅ **VERIFIED** — **Frameworks Engineer (Apple)**, thread **831998**, accepted answer
> (`notes/forums/forum-pain-points.md:476-484`):
>
> > "Hi! There is a known issue that **Private Cloud Compute does not currently work in simulators**."
> > … iOS 27 release notes: *"Private Cloud Compute might not work when you use simulators.
> > (**177684296**) **Workaround: Use a physical device running OS 27.0.**"*
>
> The error, verbatim from the reporter:
>
> ```text
> Error Domain=FoundationModels.LanguageModelError Code=-1 "The operation couldn't be completed.
> (FoundationModels.LanguageModelError error -1.)" UserInfo={NSMultipleUnderlyingErrorsKey=(
>   "…ModelManagerServices.ModelManagerError Code=1046 …" )}
> ```
>
> **`ModelManagerServices.ModelManagerError Code=1046` is undocumented** and was never explained by
> Apple. And note the sting in the tail: a second developer reported the same `-1` on a **physical
> iPhone 17 Pro Max with New Siri enabled**, so `-1` is *not* Simulator-exclusive
> (`notes/forums/forum-pain-points.md:494-496`).

This compounds with the more general Simulator trap for the whole framework, which is the single most
useful debugging fact in the corpus:

> ✅ **VERIFIED** — **Apple Designer (Apple)**, thread 831404, accepted
> (`notes/forums/forum-pain-points.md:459-471`): *"Xcode 27.0 contains the latest SDK, but the
> on-device `SystemLanguageModel` is actually built into the OS. Meaning that when you run simulator
> from Xcode, the simulator is actually **'punching out' to macOS** to run the model, using the 26.5
> model inference code in the OS. Whenever we see 'weird' errors like this, it's usually an underlying
> incompatibility between the Xcode SDK and OS for running the model. :( **Suggested Fix:** Update a
> physical device to 27.0."*

**Rule for this guide: every measurement, every screenshot, every bug report — physical device on
27.0 or later.** The Simulator is for layout.

### 5.6 The network, and the documented fallback

> ✅ **VERIFIED** — docs-only guidance, absent from the transcript
> (`UsingPrivateCloudCompute.md:56`, quoted at `notes/transcripts/fm-ecosystem.md:243-245`): *"Using
> PCC requires a network connection, so **if the request fails because the network connection is
> unavailable, retry the request using the on-device model.**"*

That is a stronger recommendation than it looks: Apple is telling you the on-device model is a
*runtime* fallback for PCC, not merely a lesser alternative you offer on old OSes. §10 covers the
context-size problem that creates.

### 5.7 Locale

> ✅ **VERIFIED** — `PrivateCloudComputeLanguageModel` exposes `supportedLanguages` and
> `supportsLocale(_:)` (`notes/web/apple-docs-fm-evals-speech.md:1671-1672`). Shipping code uses it as
> a hard precondition (`AFMLLMClient.swift:92-95`, community):
>
> ```swift
> let model = PrivateCloudComputeLanguageModel()
> guard model.supportsLocale(LocalizationManager.preferredLocale()) else {
>     throw AFMLLMClientError.unsupportedLocale
> }
> ```

Two things to know about locale support generally, both from Apple staff:

- ✅ **Frameworks Engineer**, thread 797271: *"Foundation Models support the same set of languages as
  Apple Intelligence."*
- Apple Intelligence language is driven by the **Siri language setting, not the system language**
  (Settings → Apple Intelligence & Siri → Language). Reported by a semi-authoritative community source
  in thread 805378 — treat as **community-sourced**, not Apple. The same source describes
  `supportsLocale(_:)` as returning `true` for a *close* language, e.g. Catalan resolving via Spanish.
  Useful mental model; unverified contract.

If the locale is unsupported, the failure is a typed error (`LanguageModelError.unsupportedLanguageOrLocale(_:)`),
which is §9.

### 5.8 A note on the Siri-enablement symptom

You may hit `.appleIntelligenceNotEnabled`-shaped failures on 27 betas when the user has Siri
switched off. Do **not** design permanent UX around requiring Siri.

> ✅ **VERIFIED — this is a bug with an Apple acknowledgement, not a designed gate.** Forum threads
> 835211 and 836760 report that `SystemLanguageModel.default.availability` returns
> `.appleIntelligenceNotEnabled` unless "Siri"/"Hey Siri" or "Press Side Button for Siri" is enabled.
> An **Apple Frameworks Engineer confirmed on thread 836760** that the framework *"should be available
> in Europe even if Siri AI is not enabled"* and asked for a bug report with a sysdiagnose — i.e. the
> coupling is a defect. Status as of **2026-07-27: unresolved.**
>
> 🔴 **GAP — whether the same coupling affects `PrivateCloudComputeLanguageModel.availability`.** Both
> reporting threads concern the on-device model, whose `Availability` is a *different* type with a
> *different* reason list; PCC's documented reasons are `.deviceNotEligible` and `.systemNotReady`.
> Nothing in our corpus tests PCC against a Siri-disabled device. **What would resolve it:** a device
> report of `PrivateCloudComputeLanguageModel().availability` with Siri disabled on 27.0+.
> **Safe default meanwhile:** handle `.unavailable(let other)` with a generic, non-accusatory message
> and a working non-AI path — never instruct the user to "turn on Siri", which may be advice for a bug
> that gets fixed under you.

---

## 6. Reasoning

### 6.1 What it is, in Apple's own words

The clearest plain-English definition Apple gives of reasoning anywhere is in session 319, and it is
worth quoting in full because it also tells you exactly where the text goes:

> ✅ **VERIFIED** — `319:46-52`: *"But what is reasoning? When an LLM responds to your prompt, it
> typically just reads the prompt and generates a response. With reasoning, **the model thinks before
> it generates the response. This literally happens by letting the model generate extra text, in a
> separate segment of the transcript.**
>
> The PCC model offers **3 levels of reasoning**. **Light** lets the model gather some extra context.
> **Moderate** lets the model reason a little deeper. And with **Deep**, the text for the reasoning
> segment may be **even longer than the actual response**."*

Session 241 adds the *why*:

> ✅ **VERIFIED** — `241:32`: *"Reasoning models are trained to spend time carefully thinking through
> their answers before providing a response, which results in significantly better outcomes."*

Two facts are already load-bearing from those quotes: the reasoning text is **generated**, and it
lands in a **separate segment of the transcript**. §6.4 and §6.5 are the consequences of each.

### 6.2 The type — four cases, not three

Apple's prose says three levels. The enum has four.

> ✅ **VERIFIED** — from `/documentation/foundationmodels/contextoptions`
> (`notes/web/apple-docs-fm-evals-speech.md:603-618`):
>
> ```swift
> struct ContextOptions          // Equatable, Sendable, SendableMetatype
> init(includeSchemaInPrompt:reasoningLevel:)
> var includeSchemaInPrompt      // "Inject the schema into the prompt to bias the model."
> var reasoningLevel: ContextOptions.ReasoningLevel
>
> enum ReasoningLevel            // Equatable, Sendable, SendableMetatype
> case light      // "A level that indicates light thinking that's good for quick responses."
> case moderate   // "A level that indicates a moderate amount thinking."
> case deep       // "A level that indicates deep thinking that's good for more analysis over a request."
> case custom(_:) // "A custom level that indicates a level not supported by the other cases."
> ```

The fourth case, **`.custom(_:)`**, is in no session and no article prose. It exists for
`LanguageModel` conformances that expose reasoning granularity Apple's three names cannot describe —
which is a Part 4 provider-authoring concern, not a PCC concern. Two practical consequences for you:

1. **`ReasoningLevel` is not exhaustively switchable in a future-proof way.** If you switch over it,
   handle `.custom` (and consider `@unknown default`, since nothing in our sources marks the enum
   frozen).
2. ✅ **RESOLVED (2026-07-29) — `.custom(_:)`'s associated value is a `String`.** The full enum is
   read verbatim from the 27.0 interface: `case light`, `case moderate`, `case deep`,
   `case custom(Swift.String)` — ✅ **SDK-verified**
   (`FoundationModels-27.0-macos.swiftinterface:3141-3147`; not `@frozen`, so keep the
   `@unknown default`). Note also that both fields of `ContextOptions` are **Optional** —
   `includeSchemaInPrompt: Bool?`, `reasoningLevel: ReasoningLevel?`, `init` defaults both to `nil`
   (`:3132-3136`). **Safe default unchanged:** do not construct `.custom` against PCC. Nothing
   suggests the PCC model accepts an arbitrary string, and §6.6 shows what happens when a model is
   handed a level it does not support.

Note also `includeSchemaInPrompt` on the same struct — `ContextOptions` is a general "how does my
prompt reach the model" bag, not a reasoning-only type. That is the distinction session 339 draws:

> ✅ **VERIFIED** — `339:108-110`: *"**`ContextOptions` control what goes into the prompt**, like the
> reasoning level you want the model to use, or a response schema. **`GenerationOptions` control the
> decoder loop**: sampling strategy, temperature, and maximum response length."*

So: **`contextOptions:` is not `options:`.** They are different parameters carrying different types
and confusing them is a compile error, not a subtle bug — but it is a compile error people spend ten
minutes on.

### 6.3 Setting the level: two places

**On a single call.**

> ✅ **VERIFIED** — verbatim from the PCC article
> (`notes/web/apple-docs-fm-evals-speech.md:620-626`):
>
> ```swift
> let response = try await session.respond(
>     to: "What are the tradeoffs in this architecture?",
>     contextOptions: ContextOptions(reasoningLevel: .deep)
> )
> ```
>
> Session 319 confirms the placement in narration (`319:53`): *"You can set the reasoning level **when
> calling `respond` on your session**."*

**On a profile**, where it applies to every turn that profile handles.

> ✅ **VERIFIED** — `.reasoningLevel(.deep)` as a `DynamicProfile` modifier, from Apple's compiling
> Origami sample (`Origami/Models/OrchestratorProfile.swift`, recorded at
> `notes/web/apple-sample-code.md:266` and confirmed at `:82`):
>
> ```swift
> Profile {
>     TutorialInstructions(orchestrator: orchestrator)
> }
> .model(serverModel)
> .reasoningLevel(.deep)
> ```
>
> Apple's dynamic-profiles documentation also shows it computed
> (`notes/web/apple-docs-fm-evals-speech.md:1040`): `.reasoningLevel(likesAstronomy ? .deep : .light)`
> — so the modifier takes an expression, not just a literal.

Which to use: put it on the **profile** when reasoning depth is a property of the *mode* your app is
in (Origami reasons deeply for tutorial generation and not at all for term lookups); put it on the
**call** when it is a property of the individual request.

> ⚠️ **A documentation oddity worth not copying.** One Apple documentation page shows a profile
> carrying **both** modifiers at once (`Origami.md:151-163`, recorded at
> `notes/transcripts/fm-ecosystem.md:353-368`):
>
> ```swift
> Profile(model: pccModel) { TutorialInstructions() }
>     .reasoningLevel(.deep)
>     .contextOptions(ContextOptions(reasoningLevel: .deep))   // ← redundant
> ```
>
> That snippet is doubly suspect: it uses the `Profile(model:)` initializer form that the **compiling
> sample contradicts** (§4.4), and it sets the same value twice through two different modifiers. The
> shipping sample writes only `.reasoningLevel(.deep)`. **Follow the sample.** Whether a
> `.contextOptions(_:)` profile modifier exists at all is unverified — we have it from one doc snippet
> and nothing else.

### 6.4 ⚠️ SILENT FAILURE — reasoning spends your context, invisibly

> ⚠️ **SILENT FAILURE — reasoning tokens are real tokens, they count against the 32K, and they never
> appear in anything you render.** You can watch `response.content` and your own prompt sizes stay
> modest while the transcript quietly fills with text you never wrote, until a
> `LanguageModelError.contextSizeExceeded` arrives from a conversation that "obviously" fits.
>
> ✅ **VERIFIED** — `319:56-58`, the footgun stated by Apple: *"But keep in mind, **reasoning is extra
> text that the model generates. So it uses tokens. This counts towards your context size limit.**"*
>
> ✅ **VERIFIED** — and the reason it is invisible, from the docs
> (`notes/web/apple-docs-fm-evals-speech.md:628`): *"The more reasoning you apply causes the model to
> use more of the context window… **Reasoning segments reflect the model's intermediate reasoning and
> don't appear in the final response content.**"*
>
> Recall `319:52`: at `.deep`, *"the text for the reasoning segment may be **even longer than the
> actual response**."* On a long multi-turn session at `.deep`, reasoning can plausibly be the largest
> single consumer of your 32K — and it is the one line item absent from every mental model built on
> the on-device API.

**How to see it.** The framework does expose the number; you just have to ask.

> ✅ **VERIFIED** — `241:54-56`: *"Sessions and responses now have a **`usage`** property that tells
> you precisely how many tokens were used. You can also check **how many of the input tokens were read
> from cache**, and **how many of the response tokens were used for reasoning**."*
>
> The type, from the docs index (`notes/web/apple-docs-fm-evals-speech.md:287-295`):
>
> ```swift
> struct Usage                                              // iOS 27
> init(input:output:metadata:)
> var input: Usage.Input, output: Usage.Output, metadata, totalTokenCount
>
> // Usage.Input:  init(totalTokenCount:cachedTokenCount:)  → .totalTokenCount, .cachedTokenCount
> // Usage.Output: init(totalTokenCount:reasoningTokenCount:) → .totalTokenCount, .reasoningTokenCount
> ```
>
> `usage` is available on `LanguageModelSession` (cumulative), on `Response` and on
> `ResponseStream.Snapshot` (`:289-291`).

So this is a two-line instrument, and if you are shipping `.deep` you should have it in your logs
from day one:

```swift compile:27
import FoundationModels
import os

private let log = Logger(subsystem: "com.example.app", category: "pcc")

func summarize(
    _ document: String,
    using session: LanguageModelSession,
    model: PrivateCloudComputeLanguageModel
) async throws -> String {
    let response = try await session.respond(
        to: "Summarize this document:\n\n\(document)",
        contextOptions: ContextOptions(reasoningLevel: .deep)
    )

    let usage = response.usage
    let budget = try await model.contextSize
    log.info("""
        pcc turn: in=\(usage.input.totalTokenCount) \
        (cached \(usage.input.cachedTokenCount)) \
        out=\(usage.output.totalTokenCount) \
        (reasoning \(usage.output.reasoningTokenCount)) \
        session total=\(session.usage.totalTokenCount) / budget \(budget)
        """)

    return response.content
}
```

> 🟡 **RECONSTRUCTED** — the *property names* above are verified from the docs index; the *composition*
> (reading `session.usage.totalTokenCount` alongside the awaited PCC `contextSize` in one log line) is
> our pattern, not Apple's.[^pcc-context-size] `Usage.metadata` exists and is documented as *"Language models that provide
> other kinds of usage statistics may encode them in metadata"* — its key set for PCC specifically is
> unknown.

The cache-hit line is a bonus and it is Apple's own formula: *"determine your cache hit rate by
dividing the cached input tokens by the total input tokens"* (KV-caching article,
`notes/web/apple-docs-fm-evals-speech.md:297`).

### 6.5 The reasoning segment, and using it for progress UI

This is the payoff for reasoning living in its own transcript entry rather than being prepended to the
response.

> ✅ **VERIFIED** — `319:54-55`: *"The **transcript of your session includes the reasoning segment.**
> You can **observe the transcript to show progress**, which is especially useful with the **Deep**
> reasoning level, which may take some time."*
>
> And the debugging value, docs-only (`UsingPrivateCloudCompute.md:135`, quoted at
> `notes/transcripts/fm-ecosystem.md:341-344`): *"Reasoning segments reflect the model's intermediate
> reasoning and don't appear in the final response content. **Reviewing them helps you understand why
> the model produced a particular answer**, which is useful when debugging complex prompts."*

The transcript shape is verified:

> ✅ **VERIFIED** — `Transcript.Entry` gains a case in iOS 27
> (`notes/web/apple-docs-fm-evals-speech.md:1922-1930`):
>
> | Case | Payload | Description |
> |---|---|---|
> | `.reasoning(_:)` | `Transcript.Reasoning` | "Reasoning from the model." **(NEW iOS 27)** |
>
> And the payload (`:1953-1958`):
>
> ```swift
> // Transcript.Reasoning  (iOS 27 only)
> init(id:metadata:segments:signature:)
> var description, metadata, segments, signature
> //   metadata:  "Metadata produced by the model while generating this reasoning entry."
> //   segments:  "Ordered reasoning segments."
> //   signature: "Opaque producer-supplied signature for this reasoning entry."
> ```
>
> Session 339 independently names `reasoning` as one of the six transcript entry kinds
> (`instructions | prompt | toolCalls | toolOutput | response | reasoning`, `339:98-102`), and the
> provider-side channel API has a matching `.reasoning(action: .appendText(_:tokenCount:))` event
> (verified across three `LanguageModelExecutor` conformances). So the entry is real, it streams, and
> it is separate from `.response`.

`LanguageModelSession` conforms to `Observable`, and `session.transcript` is a property on it — so a
SwiftUI view that reads `session.transcript` re-renders as entries arrive. Here is a progress
affordance built on that:

```swift illustrative
import SwiftUI
import FoundationModels

struct ThinkingIndicator: View {
    let session: LanguageModelSession

    /// The text of the most recent reasoning entry, if the model is currently
    /// thinking. Reasoning lands in its own transcript entry, so it is visible
    /// here before any response text exists.
    private var latestReasoning: String? {
        for entry in session.transcript.reversed() {
            switch entry {
            case .reasoning(let reasoning):
                return reasoning.segments.compactMap(\.plainText).joined()
            case .response:
                return nil          // the answer has started; stop showing "thinking"
            default:
                continue
            }
        }
        return nil
    }

    var body: some View {
        if session.isResponding, let thought = latestReasoning {
            VStack(alignment: .leading, spacing: 4) {
                Label("Thinking…", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(thought)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                    .animation(.default, value: thought)
            }
            .transition(.opacity)
        }
    }
}
```

> 🟡 **RECONSTRUCTED — read the fine print on this one.** Verified: `Transcript.Entry.reasoning(_:)`
> exists, `Transcript.Reasoning` has `.segments` described as "Ordered reasoning segments",
> `LanguageModelSession` is `Observable`, `session.transcript` exists and is mutable in 27, and
> `session.isResponding` exists with Apple's own instruction to drive UI from it (*"Disable buttons and
> other interactions to prevent users from submitting a second prompt"*,
> `notes/web/apple-docs-fm-evals-speech.md:259-261`).
>
> **Not verified: `\.plainText`.** No source in our corpus shows how to extract a `String` from a
> `Transcript.Segment`. The `Segment` enum's cases are known — `.text(_:)`, `.attachment(_:)`,
> `.structure(_:)`, `.custom(_:)` (`:1934-1940`) — so the safe rewrite is to pattern-match:
>
> ```swift
> reasoning.segments.compactMap { segment in
>     if case .text(let text) = segment { return text.content }   // 🟡 `.content` also unverified
>     return nil
> }.joined()
> ```
>
> `Transcript.TextSegment(content:)` is attested — Apple's Origami sample constructs
> `.text(Transcript.TextSegment(content:))` (`notes/web/apple-sample-code.md:14`) — so `content` is
> at least the *initializer* label. Whether it is also a readable property is an inference.
> **What would resolve it:** `/documentation/foundationmodels/transcript/textsegment`.
> **Safe default meanwhile:** if you cannot read segment text, `Transcript.Reasoning` also has a
> `description` property (it appears in our member list), and every `Transcript.Entry` conforms to
> `CustomStringConvertible` — enough to show *that* the model is thinking even if not *what*.

The design point survives the uncertainty: **drive the "thinking" state off the presence of a
reasoning entry, and drive the "answering" state off the response entry or the stream.** Do not drive
either off a timer.

> ⚠️ **SILENT FAILURE — the first-token spinner that never ends.** Related and verified: a
> `streamResponse(to:)` can complete having yielded **zero** partials when the model's entire
> contribution is a tool call. Apple's Origami sample handles it explicitly with a `didReceivePartial`
> flag (`Origami/Coach/CoachModel.swift:58-73`). At `.deep` on PCC the same UI bug has a second cause:
> the model may spend a long time producing reasoning before any response text exists. **Drive your
> loading state off stream *completion*, never off first-token arrival.** Covered in full in Part 2's
> streaming guide.

### 6.6 Picking a level

Apple's recommendation is explicit and it is not "start at deep":

> ✅ **VERIFIED** — docs-only, no transcript equivalent
> (`notes/web/apple-docs-fm-evals-speech.md:627`): *"To determine what reasoning level to use, evaluate
> your feature by **starting with `.moderate`**. Use `.deep` when you determine the task needs
> additional reasoning, like when you're making architectural decisions with many competing
> constraints. **Deep reasoning is slower**, but it spends more time catching things that the other
> levels miss."*

A working heuristic that respects the token cost:

| Level | Use when | Cost |
|---|---|---|
| `.light` | Extraction, classification, rewriting — the answer is *in* the input | Smallest reasoning segment |
| `.moderate` | **Start here.** Synthesis, multi-document summary, ordinary tool-using turns | Apple's recommended default |
| `.deep` | Many competing constraints; a wrong answer is expensive; latency is acceptable | Reasoning segment may exceed the response; **budget context for it** |

> 🔴 **GAP — no published latency or token numbers for any reasoning level.** Apple says `.deep` "may
> take some time" and "is slower"; nobody has published a second, a token count, or a ratio, and our
> corpus contains no community measurement either — unsurprising, since PCC is entitlement-gated so
> the community that can benchmark it is small. **What would resolve it:** an `Instruments` trace or a
> `Usage.output.reasoningTokenCount` distribution from a real entitled app, on named hardware/OS.
> **Safe default meanwhile:** instrument `reasoningTokenCount` per level in your own app (§6.4) before
> you commit to `.deep` in a latency-sensitive path, and treat any number you read elsewhere without
> hardware+OS+date attribution as fiction.

### 6.7 What happens if you set a reasoning level on a model that has no reasoning

The docs table says `SystemLanguageModel` reasoning is "Not supported". So what does
`ContextOptions(reasoningLevel: .deep)` do on an on-device session?

The framework routes on declared capabilities, and refuses rather than silently ignoring:

> ✅ **VERIFIED** — from the `LanguageModelCapabilities` docs
> (`notes/web/apple-docs-fm-evals-speech.md:1827`): *"When a model doesn't support a capability, **the
> framework can refuse to dispatch incompatible requests to the executor** and throw a
> `LanguageModelError.unsupportedCapability(_:)` error instead."*
>
> The MLX adapter's doc comment states the same rule from the provider side, and is the sharpest
> phrasing anywhere (`MLXLanguageModel.swift:515-519`, Apple/MLX source): *"Declaring `.reasoning`
> matters for **request routing**: the framework **only forwards a `reasoningLevel` to executors that
> declare `.reasoning`, and auto-rejects one otherwise (on the developer's behalf) before `respond`
> runs.**"*
>
> The capability member itself is documented: `.reasoning` — *"The capability to reason, structurally
> separately from producing a response."* (`:1805`)

So the behaviour is a **throw**, not a silent no-op — good. But note the practical shape of the bug it
creates: in a dynamic profile that switches models by mode (§4.4), a `.reasoningLevel(.deep)` modifier
attached to the wrong branch fails at *request* time, in the branch you tested least. Attach
reasoning modifiers to the same branch that attaches `.model(serverModel)`, never above the switch.

> ✅ **RESOLVED (2026-07-29) — yes, `capabilities` is public on the concrete class.** The PCC
> `LanguageModel` conformance declares `final public var capabilities: LanguageModelCapabilities
> { get }` (and `executorConfiguration`) directly on `PrivateCloudComputeLanguageModel` —
> ✅ **SDK-verified** (`FoundationModels-27.0-macos.swiftinterface:96-105`). So
> `pccModel.capabilities.contains(.reasoning)` compiles as a concrete property read; the declared
> `Capability` statics are `.vision`, `.guidedGeneration`, `.reasoning`, `.toolCalling`
> (`:1509-1524`). What the property *returns* on a real PCC-entitled device is still unobserved —
> use it as the runtime probe, with the documented capability table (§3.2) and the typed error in
> §9 as the cross-check.

---

## 7. Quota UX — Apple's most prescriptive design guidance

Session 319 devotes roughly a fifth of its running time to the design of one label and one button.
That is not padding. It is the part of PCC adoption that has no analogue anywhere else in the
Foundation Models framework, and getting it wrong produces the specific failure Apple names:

> ✅ **VERIFIED** — `319:77-78`: *"when a user hits a limit, **the request throws an error. If that
> error is just shown in the UI, that's not a great user experience, because it's not very
> actionable.**"*

### 7.1 The quota model

> ✅ **VERIFIED** — `319:70-73`: *"When using the PCC model in your app, it's important to handle usage
> limits well. **Requests are counted with your user's iCloud account.** And you can optimize your app
> for the case where a user hits a limit."*

Four properties of that sentence, each with a design consequence:

**It is per *user*, not per app.** Your app shares a budget with every other PCC-using app on that
device, and with the user's other devices signed in to the same iCloud account. You cannot know how
much of it your app consumed. A user can hit their limit in your app having never used your AI
feature before.

**It is daily.** Not a rolling window, not a rate limit. Apple draws this distinction explicitly:

> ✅ **VERIFIED** — docs (`notes/web/apple-docs-fm-evals-speech.md:1761`): *"**Unlike rate limiting,
> where a person waits for a period of time before trying again, exceeding the daily quota means a
> person either waits for their usage quota to refresh or they upgrade to a higher tier.**"*

That kills the reflex you have from every other server API: **do not retry, and do not back off.**
Exponential backoff on a quota error is a loop that burns battery and never succeeds.

**It is raised by iCloud+.** `319:25`: *"users can **upgrade to iCloud+** to get higher limits."* This
is why there is a button in the API at all — the remedy is a real, purchasable thing, and it is not
your IAP.

**You have no visibility into the number.** §7.6.

### 7.2 The API surface

> ✅ **VERIFIED** — from `/documentation/foundationmodels/privatecloudcomputelanguagemodel/quotausage-swift.struct`
> and the PCC article (`notes/web/apple-docs-fm-evals-speech.md:1726-1734`):
>
> ```swift
> struct QuotaUsage                        // Sendable
> var isLimitReached: Bool
> var status: QuotaUsage.Status
> var resetDate                            // "The date at which the quota will refresh."
> var limitIncreaseSuggestion: QuotaUsage.LimitIncreaseSuggestion?
> ```
>
> Reached via `model.quotaUsage` (`:1669`). Apple's framing: *"A quota describes the model's **per-user
> request budget** and where the caller currently sits relative to it."*

And the canonical usage, verbatim from Apple's article — this is the snippet to copy:

> ✅ **VERIFIED** — `notes/web/apple-docs-fm-evals-speech.md:1736-1757`:
>
> ```swift
> let model = PrivateCloudComputeLanguageModel()
>
> // Depending on the quota state, display a label to keep a person aware
> // of the status of their daily limit.
> if model.quotaUsage.isLimitReached {
>     Text("Usage limit exceeded")
>         .foregroundStyle(Color.red)
> } else if case .belowLimit(let info) = model.quotaUsage.status {
>     if info.isApproachingLimit {
>         Text("Nearing usage limit")
>             .foregroundStyle(Color.orange)
>     }
> }
>
> // Display a button in your UI to present the available upgrade options.
> if let suggestion = model.quotaUsage.limitIncreaseSuggestion {
>     Button("Show options") {
>         suggestion.show()
>     }
> }
> ```

Session 319 narrates the same code (`319:79-83`) and adds the two placement decisions:

> ✅ **VERIFIED** — `319:79-83`: *"you can check for **`isLimitReached` on the `quotaUsage` of the
> model**. And handle that with custom UI in your app. Here I'm using a **label to go under my
> button**… when the user's limit is exceeded, you can **show a button to let the user manage their
> limit**. For example, a user could **upgrade their account** to get a higher limit."*

Type notes, precisely:

- **`isLimitReached: Bool`** is a top-level convenience on `QuotaUsage`, *not* a case of `Status`. Both
  Apple's snippet and shipping third-party code read it directly.
- **`Status`** has at least `.belowLimit(_:)`, whose associated value exposes `isApproachingLimit: Bool`.
  ✅ **RESOLVED (2026-07-29) — the full `Status` case list is exactly two:**
  `case belowLimit(Status.BelowLimit)` and `case limitReached(Status.LimitReached)` —
  ✅ **SDK-verified** (`FoundationModels-27.0-macos.swiftinterface:228-245`). `BelowLimit` carries
  `isApproachingLimit: Bool`; `LimitReached` is an empty payload struct; there is no
  unknown/indeterminate case, and the enum is **not** `@frozen`. **Keep following Apple's snippet
  shape anyway** — test `isLimitReached` first, then `if case .belowLimit(let info) = status` —
  because a non-frozen enum can grow and the convenience `Bool` insulates you.
- **`resetDate`** is `Date?` — ✅ **SDK-verified**
  (`FoundationModels-27.0-macos.swiftinterface:215`), matching the docs' *"this value is empty when
  the reset date isn't known or when the person is well below their limit."* Never render a bare
  unwrapped date.
- **`limitIncreaseSuggestion: LimitIncreaseSuggestion?`** is optional, and its optionality is the
  signal. `show()` presents **system** UI for the upgrade — you do not build the upgrade flow, and you
  do not know what it contains. Shipping code checks `!= nil` to decide whether to offer the
  affordance at all (`AppleFoundationModelAvailability.swift:199, 210`, community). **Do that.** A
  button that presents nothing is worse than no button.

### 7.3 The four design rules, quoted

These are the most explicit UI instructions Apple gives about any Foundation Models API, and they are
worth reading as rules rather than suggestions:

> ✅ **VERIFIED** — `319:84-88`, verbatim: *"You should **integrate this with your existing UI**.
> **Avoid showing an alert for the usage limit. Because this UI should persist, and not be dismissed.**
> Instead, you can **update the state of your UI, like disabling the button that makes a request.** And
> under that button I'm showing a **subtle label**, with the button for letting the user get a higher
> limit, if they want."*
>
> Restated in the docs (`notes/web/apple-docs-fm-evals-speech.md:1762`): *"**Instead of presenting an
> alert that a person can dismiss**, add UI to clearly communicate the current status of a person's
> daily usage."*

| # | Rule | Why |
|---|---|---|
| 1 | **Integrate with your existing UI** | The limit is a state of your feature, not an event |
| 2 | **No alert** | An alert is dismissible; the state is not. Dismiss it and the button is still dead |
| 3 | **Disable the button that makes the request** | Make the unavailability legible *before* the tap |
| 4 | **Subtle label under the button + a "get a higher limit" button** | Non-alarming, and *actionable* |

Rule 2 is the one people break, because "request failed" reflexively maps to `.alert(...)` in SwiftUI.
Notice why it is wrong here and not merely unfashionable: **an alert is a modal report of a past
event, and this is a persistent property of the present.** The user dismisses it, taps the button
again, and gets the same alert. That is the "not very actionable" failure from `319:78`, rendered as a
loop.

And the approaching state has its own rationale:

> ✅ **VERIFIED** — `319:89-90`: *"You can also **detect the case where a user is approaching their
> limit**. This can be good to indicate to your users that they are close to their daily limit, so they
> can **make an informed decision for which requests they want to make**."*

That is a real design goal: the nearing-limit label is not a warning, it is **information that changes
which request the user chooses to spend the day's remainder on**. Which means the label should appear
next to the *choice*, not in a settings screen.

### 7.4 A complete implementation

Here is the whole pattern in one file: a state model, the button, the label, the upgrade affordance,
and the error path. It is the four rules made concrete.

```swift compile:27
import SwiftUI
import FoundationModels

// MARK: - State

/// One app-level enum that collapses availability AND quota onto a single axis.
/// This is the key move: "available but out of quota" is not an error condition,
/// it is a state your UI renders — just like "unavailable".
@available(iOS 27.0, macOS 27.0, watchOS 27.0, visionOS 27.0, *)
enum ServerModelState: Equatable {
    case available
    case approachingLimit
    case limitReached(resetDate: Date?)
    case unavailable(reason: String)

    var allowsRequests: Bool {
        switch self {
        case .available, .approachingLimit: true
        case .limitReached, .unavailable: false
        }
    }
}

@available(iOS 27.0, macOS 27.0, watchOS 27.0, visionOS 27.0, *)
@Observable
final class SummarizerModel {
    let model = PrivateCloudComputeLanguageModel()

    private(set) var state: ServerModelState = .available
    private(set) var summary: String = ""
    private(set) var isWorking = false

    /// Recompute from the two orthogonal sources of truth: availability, then quota.
    /// Call this on appear, on scene activation, and after every completed request —
    /// quota state changes underneath you as the user spends it in other apps.
    func refreshState() {
        switch model.availability {
        case .available:
            let quota = model.quotaUsage
            if quota.isLimitReached {
                state = .limitReached(resetDate: quota.resetDate)
            } else if case .belowLimit(let info) = quota.status, info.isApproachingLimit {
                state = .approachingLimit
            } else {
                state = .available
            }
        case .unavailable(.deviceNotEligible):
            state = .unavailable(reason: "This device doesn't support Apple Intelligence.")
        case .unavailable(.systemNotReady):
            state = .unavailable(reason: "Intelligence features aren't ready yet. Try again shortly.")
        case .unavailable:
            state = .unavailable(reason: "Intelligence features aren't available right now.")
        @unknown default:
            state = .unavailable(reason: "Intelligence features aren't available right now.")
        }
    }

    func summarize(_ document: String) async {
        guard state.allowsRequests else { return }
        isWorking = true
        defer { isWorking = false; refreshState() }   // ← re-read quota after every turn

        let session = LanguageModelSession(model: model) {
            "Summarize documents faithfully. Never invent facts or figures."
        }

        do {
            let response = try await session.respond(
                to: "Summarize this document:\n\n\(document)",
                contextOptions: ContextOptions(reasoningLevel: .moderate)
            )
            summary = response.content
        } catch PrivateCloudComputeLanguageModel.Error.quotaLimitReached {
            // Belt and braces: the preflight can go stale between check and call.
            // Land in the SAME state the preflight would have produced — no alert.
            state = .limitReached(resetDate: model.quotaUsage.resetDate)
        } catch {
            summary = ""
            // Route everything else through §9's ladder.
        }
    }
}

// MARK: - View

@available(iOS 27.0, macOS 27.0, watchOS 27.0, visionOS 27.0, *)
struct SummarizeView: View {
    @State private var viewModel = SummarizerModel()
    let document: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // RULE 3: the button reflects the state before the tap.
            Button("Summarize") {
                Task { await viewModel.summarize(document) }
            }
            .disabled(!viewModel.state.allowsRequests || viewModel.isWorking)

            // RULE 4: a SUBTLE label directly under the button.
            // RULE 1: it lives inside the existing layout, not over it.
            // RULE 2: there is no .alert() anywhere in this file.
            quotaLabel

            if !viewModel.summary.isEmpty {
                Text(viewModel.summary)
            }
        }
        .onAppear { viewModel.refreshState() }
    }

    @ViewBuilder
    private var quotaLabel: some View {
        switch viewModel.state {
        case .limitReached(let resetDate):
            VStack(alignment: .leading, spacing: 4) {
                Text(resetDate.map { "Daily limit reached. Resets \($0.formatted(.relative(presentation: .named)))." }
                     ?? "Daily limit reached.")
                    .font(.caption)
                    .foregroundStyle(Color.red)
                upgradeButton
            }

        case .approachingLimit:
            VStack(alignment: .leading, spacing: 4) {
                Text("Nearing your daily limit.")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                upgradeButton
            }

        case .unavailable(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)

        case .available:
            EmptyView()
        }
    }

    /// Only offer the affordance when the system actually has options to show.
    @ViewBuilder
    private var upgradeButton: some View {
        if let suggestion = viewModel.model.quotaUsage.limitIncreaseSuggestion {
            Button("Manage limit") { suggestion.show() }
                .font(.caption)
                .buttonStyle(.borderless)
        }
    }
}
```

**Evidence audit of that listing**, so you know exactly what you are copying:

| Element | Marker |
|---|---|
| `model.availability` switch with `.deviceNotEligible` / `.systemNotReady` / `let other` | ✅ verbatim structure from the docs article |
| `quotaUsage.isLimitReached`, `if case .belowLimit(let info)`, `info.isApproachingLimit` | ✅ verbatim from the docs article |
| `limitIncreaseSuggestion` optional + `.show()` | ✅ from the docs article |
| `resetDate` optional handling | 🟡 optionality inferred from "This value is empty…"; declared type unverified |
| `catch PrivateCloudComputeLanguageModel.Error.quotaLimitReached` | ✅ the case exists (`notes/web/apple-docs-fm-evals-speech.md:338`); the payload-less `catch` pattern is 🟡 — see §9.1 |
| `@unknown default` on the availability switch | 🟡 defensive; borrowed from shipping community code |
| `@Observable`, `LanguageModelSession(model:)` + trailing instructions closure | ✅ `Observable` conformance and the trailing-closure init are both attested |
| The four-rule UI structure, `.disabled(...)`, no `.alert` | ✅ Apple's stated rules, our composition |
| `ServerModelState` collapsing availability + quota | 🟡 our design; mirrors the shape of shipping community code |

### 7.5 Where to call `refreshState()`

Quota is not a value you read once at launch. It moves during your app's lifetime, and it moves for
reasons that have nothing to do with you — the user's other apps, their other devices, the daily
refresh. Three call sites, minimum:

1. **On appear / scene activation.** The user may have spent the quota in another app while you were
   backgrounded.
2. **After every completed request**, success or failure. Your own turn may have been the one that
   crossed the line — and note that a `.deep` reasoning turn is not one unit of anything you can
   predict.
3. **In the `catch` for `quotaLimitReached`.** The error *is* a state transition; treat it as one.

The listing above does 2 with `defer { refreshState() }` and 3 in the catch.

> **What we cannot tell you:** whether `QuotaUsage` updates observably — i.e. whether
> `PrivateCloudComputeLanguageModel`'s `Observable` conformance drives SwiftUI re-renders when quota
> changes without you re-reading it. The class **is** documented as conforming to `Observation`'s
> `Observable` (`notes/web/apple-docs-fm-evals-speech.md:1665`), which makes it plausible. Nothing
> confirms it. Poll at the three call sites above and you do not need to care.

### 7.6 ⚠️ You cannot build a usage meter

This is the complaint, and it is the single most-requested change to this API.

> ⚠️ **DESIGN CONSTRAINT — the quota API exposes three coarse states and no numbers.** Reached,
> below-limit, and below-limit-but-approaching. No percentage, no remaining count, no total. **A
> progress bar, a "17 of 50 requests" counter, or a ring gauge cannot be built on this API.**
>
> ✅ **VERIFIED** — Apple Developer Forums thread **835974**, "More Detailed Quota Usage for PCC"
> (Enderlyn, 24 June 2026), quoted at `notes/transcripts/fm-core.md:244-247`:
>
> > *"You can tell if you've reached your quota or are below it. If you are below your quota, you can
> > tell if you're approaching the limit, but **what does this actually mean? Am I over 50%, 90%,
> > 99%?**"*
>
> Filed as **FB23378161** — "Request for detailed PCC quota numbers"
> (`notes/forums/forum-pain-points.md:1420`). **No Apple answer in our capture.** Status as of
> 2026-07-27: open.

And "approaching" is not defined anywhere. You do not know whether `isApproachingLimit` flips at 80%,
at three requests remaining, or at some server-side heuristic that varies by tier. Which means:

- **Do not put a number in your string.** "Nearing your daily limit" is honest. "About 5 requests
  left" is a fabrication.
- **Do not build UI whose layout depends on granularity you may get later.** If Apple ships numbers,
  a label becomes a meter easily; a meter faked from a Bool becomes a lie you have to unship.
- **Do not infer usage by counting your own requests.** The quota is per-*user* across all PCC-using
  apps and devices (§7.1), so your count is not their count. This is the trap that looks cleverest and
  is most wrong.

There is a legitimate design response to the coarseness, and it is Apple's own framing from `319:90` —
the approaching state exists so users can *"make an informed decision for which requests they want to
make."* So instead of a meter, give the user a **choice**: when `state == .approachingLimit`, surface
the on-device path as an explicit, cheaper option rather than silently downgrading.

```swift prelude:guide-context
if viewModel.state == .approachingLimit {
    Toggle("Use on-device model (doesn't count toward your daily limit)",
           isOn: $viewModel.preferOnDevice)
        .font(.caption)
}
```

That is honest, it is actionable, it requires no numbers, and it maps onto the model swap you already
built in §4.4 — one stored property.

### 7.7 The thrown error path

The quota error is a real, typed error and it will reach you even with a perfect preflight, because
the preflight can go stale between check and call.

> ✅ **VERIFIED** — `PrivateCloudComputeLanguageModel.Error.quotaLimitReached(_:)` with payload type
> `.QuotaLimitReached` — *"The allotted usage quota has been reached."*
> (`notes/web/apple-docs-fm-evals-speech.md:338`). The doc path
> `privatecloudcomputelanguagemodel/error/quotalimitreached(_:)` is independently recorded at
> `notes/transcripts/fm-ecosystem.md:490-491`.

**Handle it by transitioning to the same state your preflight would have produced.** Do not show it.
That is the whole lesson of `319:77-78`: an error dialog for a quota limit is a report of something the
user cannot act on, delivered at the moment they were expecting a result. §9 covers the rest of the
ladder.

---

## 8. Simulating quota states in Xcode

You cannot exhaust an iCloud daily quota on demand, and you certainly cannot do it repeatedly while
iterating on a label. Xcode 27 ships a scheme option for exactly this.

> ✅ **VERIFIED** — verbatim from the PCC documentation article
> (`notes/web/apple-docs-fm-evals-speech.md:1764-1768`):
>
> 1. Choose **Product > Scheme > Edit Scheme**.
> 2. Select the **Run** page and choose the **Options** tab.
> 3. Select either **"Approaching Quota Usage Limit"** or **"Quota Usage Limit Reached"** from the
>    **"Simulated Apple Foundation Models Availability"** drop-down menu.
> 4. Click Close and run your project.

Session 319 demonstrates the same menu with slightly different strings, and the discrepancy is worth
knowing so you do not think the feature is missing when the label does not match:

> ⚠️ **CONFLICT — transcript vs docs on the menu strings.**
>
> | | Transcript (`319:92-95`) | Docs |
> |---|---|---|
> | Scheme page | "**Debug**" then "Options" | "**Run**" page → "Options" tab |
> | Menu title | "**Simulate** Apple Foundation Models Availability" | "**Simulated** Apple Foundation Models Availability" |
> | Limit-reached option | "Quota Usage Limit Reached" | "Quota Usage Limit Reached" ✅ same |
> | Approaching option | "**Nearing Usage Limit**" | "**Approaching Quota Usage Limit**" |
>
> **Ruling: trust the docs.** The transcript is narrated over a beta build and the docs were published
> later; both agree the menu exists and carries (at least) those two simulated states. Under this
> series' precedence, Apple documentation outranks a WWDC transcript.

Session 319 then shows the second state being coded against, which tells you the intended workflow:

> ✅ **VERIFIED** — `319:96-98`: *"We already handled the `isLimitReached` case in the code before. We
> can now also test the **`belowLimit`** case. Just like with `isLimitReached`, we can show a simple
> label."* And `319:102`: *"**And all this took just a few lines of code.**"*

### 8.1 How to use it without lying to yourself

Three practices, offered as ours rather than Apple's:

**Make two extra schemes rather than toggling one.** `MyApp (Quota Reached)` and
`MyApp (Nearing Limit)` alongside the normal scheme. A scheme *option* persists until you change it
back, which means the most likely way to waste an afternoon with this feature is to leave it set and
spend that afternoon debugging a quota state the server never sent. Separate schemes make the state
visible in the toolbar.

**Do not share those schemes into version control.** A teammate who picks up a shared "Quota Reached"
scheme and does not notice will file the bug you just avoided.

**Screenshot both states during design review.** The limit-reached and approaching states are the two
UI states in your app that no user will ever see during your own testing, and the two that a real user
will see on their worst day with your product. This scheme option is the only way to put them in front
of a designer.

> 🔴 **GAP — what the drop-down does to `availability` (as opposed to `quotaUsage`).** The menu is
> called "Simulated Apple Foundation Models **Availability**", but both documented options are quota
> states. Whether the same menu can simulate `.deviceNotEligible` / `.systemNotReady`, or whether the
> word "availability" is just the menu's umbrella term, is unverified — our sources enumerate exactly
> two options and neither is an availability reason. **What would resolve it:** a screenshot or a
> listing of the full drop-down on a released Xcode 27. **Safe default meanwhile:** test the
> unavailable branches by other means — on a device with Apple Intelligence disabled, or by
> temporarily forcing your `ServerModelState` in a debug build — and do not assume the menu covers
> them.

> 🔴 **GAP — whether the option works in the Simulator.** PCC itself does **not** work in the Simulator
> (§5.5), and this option simulates a *quota* state rather than performing inference — so it may or
> may not be useful there. Nothing in our corpus addresses it. **Safe default meanwhile:** exercise
> quota UI on a physical device, where you already have to be for everything else in this guide.

---

## 9. Errors

### 9.1 PCC has its own error type, with three cases

> ✅ **VERIFIED** — `PrivateCloudComputeLanguageModel.Error` (NEW, iOS 27), complete as documented
> (`notes/web/apple-docs-fm-evals-speech.md:337-340`):
>
> | Case | Payload | Apple's description |
> |---|---|---|
> | `.quotaLimitReached(_:)` | `.QuotaLimitReached` | "The allotted usage quota has been reached." |
> | `.networkFailure(_:)` | `.NetworkFailure` | "An error that occurs when a network is available, but PCC is inaccessible." |
> | `.serviceUnavailable(_:)` | `.ServiceUnavailable` | "Services are unavailable." |

Read `.networkFailure`'s description closely, because it is doing precise work: *"a network is
available, **but PCC is inaccessible**."* That is not "the user is offline" — offline is presumably a
plain `URLError`-flavoured failure surfaced elsewhere. `.networkFailure` is *"we can reach the
internet and cannot reach Apple's servers"*, which is the case that should trigger the documented
on-device retry (§5.6), whereas `.serviceUnavailable` is closer to "Apple is having a bad day" and
should trigger the same fallback with a different message.

> 🔴 **GAP (narrowed 2026-07-29) — the relationship between
> `PrivateCloudComputeLanguageModel.Error` and `LanguageModelError`.** The declaration side is now
> settled: PCC's error is `public enum Error : Swift.Error, Foundation.LocalizedError`, nested on
> the class, with exactly the three cases in the table and payload structs
> (`NetworkFailure`/`QuotaLimitReached`/`ServiceUnavailable`, each `Sendable` with
> `debugDescription`; `QuotaLimitReached` also carries `limitIncreaseSuggestion:` and
> `resetDate: Date?`) — ✅ **SDK-verified**
> (`FoundationModels-27.0-macos.swiftinterface:154-208`). So: yes, it conforms to `LocalizedError`
> (and `CustomDebugStringConvertible`, `:164-170`); it is a **disjoint type** from
> `LanguageModelError` with no conformance or wrapping relationship visible in the interface. What
> the interface cannot show is **runtime routing**: whether a PCC quota failure ever arrives as
> `LanguageModelError.rateLimited` instead (both types exist and both have a quota-ish case).
> **Safe default unchanged:** catch **both** types, and treat `LanguageModelError.rateLimited` as a
> quota-shaped condition too — the cost is one extra `catch` clause.

> 🟡 **RECONSTRUCTED — the payload-less catch pattern.** Every case carries an associated value, so
> `catch PrivateCloudComputeLanguageModel.Error.quotaLimitReached` (no binding) relies on Swift's
> pattern-matching sugar for enum cases with payloads in `catch` position. This compiles for
> `LanguageModelError` in Apple's own examples of the form
> `catch LanguageModelError.contextSizeExceeded(let context)` — i.e. with a binding
> (`notes/web/apple-docs-fm-evals-speech.md:1412`). If the payload-less form gives you trouble, bind
> and ignore: `catch PrivateCloudComputeLanguageModel.Error.quotaLimitReached(_)`.

### 9.2 The full catch ladder

There are **four** error types in play in the 27 cycle, and one deprecation that will bite anyone
shipping from an Xcode 26 project.

> ✅ **VERIFIED — Apple's own ladder**, verbatim code from a **Frameworks Engineer (Apple)** reply in
> thread 831404 (`notes/forums/forum-pain-points.md:437-453`):
>
> ```swift
> let session = LanguageModelSession()
> let stream = session.streamResponse(to: "Tell me about origami.")
>
> do {
>     for try await partialResponse in stream {
>
>     }
> } catch let error as LanguageModelError {
>
> } catch let error as LanguageModelSession.Error {
>
> } catch let error as LanguageModelSession.GenerationError {
>    // Deprecated in 27.0
> } catch {
>
> }
> ```

**On ordering, precisely, because this is where a previous audit of this series found a defect.**
`LanguageModelError`, `LanguageModelSession.Error`, `SystemLanguageModel.Error` and
`PrivateCloudComputeLanguageModel.Error` are four **disjoint concrete types**. Swift's `catch let e as
T` matches on dynamic type, and none of these is a supertype of another — so **their relative order is
cosmetic, not semantic.** What *is* semantic:

- A bare `catch` must come **last**. It swallows everything above it if placed earlier.
- `catch LanguageModelError.someCase(...)` (a *case* pattern) is narrower than
  `catch let e as LanguageModelError` (a *type* pattern). Case patterns must precede the type pattern
  for the same enum, or they are unreachable.
- The deprecated `LanguageModelSession.GenerationError` clause is only reachable in a binary built
  with the Xcode 26 SDK; see §9.3.

So the correct advice is not "put X before Y" — it is **enumerate all four types, put narrow case
patterns above their own type pattern, and end with a bare `catch`**:

```swift prelude:guide-context
import FoundationModels

@available(iOS 27.0, macOS 27.0, watchOS 27.0, visionOS 27.0, *)
func run(_ prompt: String, on session: LanguageModelSession,
         model: PrivateCloudComputeLanguageModel) async -> Outcome {
    do {
        let response = try await session.respond(
            to: prompt,
            contextOptions: ContextOptions(reasoningLevel: .moderate)
        )
        return .success(response.content)

    // --- PCC-specific, narrow cases first -------------------------------
    } catch PrivateCloudComputeLanguageModel.Error.quotaLimitReached(_) {
        // NOT an alert. A state. (§7)
        return .quotaExhausted(resetDate: model.quotaUsage.resetDate)

    } catch PrivateCloudComputeLanguageModel.Error.networkFailure(_) {
        // Apple's documented remedy: retry on the on-device model.
        return .retryOnDevice(reason: .network)

    } catch PrivateCloudComputeLanguageModel.Error.serviceUnavailable(_) {
        return .retryOnDevice(reason: .serviceDown)

    } catch let error as PrivateCloudComputeLanguageModel.Error {
        // The enum is not documented as frozen. Do not assume three cases forever.
        return .failed(String(describing: error))

    // --- Framework-level model errors -----------------------------------
    } catch LanguageModelError.contextSizeExceeded(let context) {
        // On PCC this most often means reasoning ate the budget (§6.4).
        return .contextOverflow(tokenCount: context.tokenCount)

    } catch LanguageModelError.rateLimited(_) {
        // Defensive: unverified whether PCC ever surfaces quota this way. (§9.1)
        return .quotaExhausted(resetDate: model.quotaUsage.resetDate)

    } catch LanguageModelError.unsupportedLanguageOrLocale(_) {
        return .unsupportedLocale

    } catch let error as LanguageModelError {
        return .failed(error.localizedDescription)

    // --- Session misuse (your bug, not the model's) ----------------------
    } catch let error as LanguageModelSession.Error {
        // .concurrentRequests / .transcriptMutationWhileResponding
        assertionFailure("Session misuse: \(error)")
        return .failed("Internal error.")

    } catch {
        return .failed(error.localizedDescription)
    }
}
```

Evidence for each case name:

> ✅ **VERIFIED** — `LanguageModelError`'s complete case list, with Apple's own one-liners
> (`notes/web/apple-docs-fm-evals-speech.md:303-323`): `.contextSizeExceeded(_:)`, `.rateLimited(_:)`,
> `.refusal(_:)`, `.timeout(_:)`, `.guardrailViolation(_:)`, `.unsupportedCapability(_:)`,
> `.unsupportedTranscriptContent(_:)`, `.unsupportedGenerationGuide(_:)`,
> `.unsupportedLanguageOrLocale(_:)`. `LanguageModelError.ContextSizeExceeded` has
> `init(contextSize:tokenCount:debugDescription:metadata:)` and a **`.tokenCount`** property.
>
> ✅ **VERIFIED** — `LanguageModelSession.Error` is **session misuse, not model failure**
> (`:5.2`): `.concurrentRequests` — *"Multiple requests were made to the session concurrently"* — and
> `.transcriptMutationWhileResponding` — *"The session's transcript was mutated while a request was in
> progress."* Both are **non-payload** cases, unlike the old `GenerationError.concurrentRequests(_:)`.
>
> ✅ **VERIFIED** — `SystemLanguageModel.Error` exists separately with `.assetsUnavailable(_:)`, and it
> has **no watchOS availability**. It is not in the ladder above because the ladder is for a PCC
> session; add it if the same function can run on-device.

> ⚠️ Note the ordering constraint in action: `catch LanguageModelError.contextSizeExceeded(let context)`
> **must** precede `catch let error as LanguageModelError`, or it is dead code. Same for the two
> PCC case patterns above `catch let error as PrivateCloudComputeLanguageModel.Error`. This — not the
> relative order of the four *types* — is the ordering rule that matters.

### 9.3 The deprecation that only bites on rebuild

> ✅ **VERIFIED** — verbatim deprecation notice on `LanguageModelSession.GenerationError`
> (`notes/web/apple-docs-fm-evals-speech.md:5.5`):
>
> > **Deprecated.** Use `LanguageModelError`, `SystemLanguageModel.Error`, or
> > `LanguageModelSession.Error` instead. **Apps built with Xcode 26 will continue to catch this error
> > until you rebuild with Xcode 27. You must update to Xcode 27 to catch the new error types before
> > submitting your app.**

That is the single most important migration fact in the framework, and it interacts badly with PCC
adoption: you cannot use `PrivateCloudComputeLanguageModel` at all without the 27 SDK, so **the moment
you adopt PCC, every `catch` in your existing on-device code changes type.** Audit your error handling
in the same commit as the model swap, not later.

Old → new mapping, for the ones that are not obvious
(`notes/web/apple-docs-fm-evals-speech.md`, "Old → new mapping"):

| Deprecated | Replacement |
|---|---|
| `exceededContextWindowSize` | `LanguageModelError.contextSizeExceeded` |
| `unsupportedGuide` | `LanguageModelError.unsupportedGenerationGuide` |
| `assetsUnavailable` | `SystemLanguageModel.Error.assetsUnavailable` |
| `concurrentRequests` | `LanguageModelSession.Error.concurrentRequests` |
| `decodingFailure` | ✅ `GeneratedContent.ParsingError` — stated by the SDK's own per-case deprecation message, *"Use ``GeneratedContent/ParsingError`` instead."* (`FoundationModels-27.0-macos.swiftinterface:3555-3558`, verified 2026-07-29) |

### 9.4 Two error codes that mean nothing and will still find you

Both are undocumented and both appear in PCC contexts. Neither is your bug.

| Symptom | What we know |
|---|---|
| `FoundationModels.LanguageModelError Code=-1` wrapping `ModelManagerServices.ModelManagerError Code=1046` | Simulator (§5.5) — but **also reported on a physical iPhone 17 Pro Max**. Code 1046 was never explained by Apple. Thread 831998. |
| `FoundationModels.LanguageModelError error -1` generally | Thread 831448, "How to obtain more value out of a generic error -1"; filed **FB23060822** |

If you see `-1`, check the device/OS/SDK triangle before you change any code: physical device,
27.0 or later, Xcode 27 SDK, entitlement present.

---

## 10. Context: 32K, and the cost of coming back down

The 32K window is the least surprising thing about PCC and the source of its most surprising bug.

### 10.1 The bug: switching back to the on-device model mid-conversation

Apple's own recommendation is to retry on the on-device model when PCC is unreachable (§5.6), and the
dynamic-profiles pattern makes model switching a one-property change (§4.4). Put those together and
you get a session whose transcript grew to 20K tokens on PCC and is now being handed to a 4K model.

> ✅ **VERIFIED — this throws, and Apple says so.** **Frameworks Engineer (Apple)**, thread **833626**
> ("Dynamic profile switching"), accepted answer (`notes/forums/forum-pain-points.md:393-405`):
>
> > "By default, **the same transcript is shared between each Profile**. So if you move from a Profile
> > using `PrivateCloudComputeLanguageModel` to one using `SystemLanguageModel` and the transcript is
> > over `SystemLanguageModel`'s context size limit, **you'll hit a context limit exceeded error**.
> >
> > The recommended approach here is to apply the **`historyTransform`** modifier to your
> > `SystemLanguageModel` Profile. There are also some other common strategies like using the
> > **'phone-a-friend' pattern** or **session properties** as well."

Nothing warns you at profile-definition time. The profile compiles, the switch happens, and the throw
arrives on the first turn after the switch — in the fallback path, which is the path you tested least.

The fix is one modifier, and Apple's own sample ships it:

> ✅ **VERIFIED** — Origami attaches `historyTransform` to exactly the on-device branches, with a
> comment that states the reason (`Origami/Models/OrchestratorProfile.swift`, recorded at
> `notes/web/apple-sample-code.md:274, 289-293`):
>
> ```swift
> Profile {
>     TutorialInstructions(orchestrator: orchestrator)
> }
> .model(SystemLanguageModel())
> .historyTransform(shortHistory(_:))
>
> /// Returns the most recent four entries so longer on-device sessions
> /// stay within the smaller context window.
> private func shortHistory(_ entries: [Transcript.Entry]) -> [Transcript.Entry] {
>     entries.suffix(4)
> }
> ```
>
> ✅ The signature is settled: **`historyTransform` takes `([Transcript.Entry]) -> [Transcript.Entry]`**
> — an entry *array*, not a `Transcript` — and a plain function reference is accepted
> (`notes/web/apple-sample-code.md:312-314`, correcting an earlier reconstruction in this series).

So the rule is: **every profile that uses a smaller model carries a `historyTransform`.** Not the
PCC profile — the *other* one. Attaching it to the large-context branch does nothing useful and costs
you the context you paid for.

`entries.suffix(4)` is crude and it is Apple's own choice in a sample; for production, the
`foundation-models-utilities` package ships composable history modifiers designed for exactly this —
`.summarizeHistory(entryThreshold:model:)`, `.rollingWindow(entries:)`,
`.droppingCompletedToolCalls()`, applied outside-in
(`notes/02-lead-agent-corpus-gaps-filled.md:52-71`). Part 3 covers them properly. One caveat to carry:

> ⚠️ **`summarizeHistory` destroys tool-call entries.** **Frameworks Engineer (Apple)**, thread 833706:
> *"The `summarizeHistory` modifier… **will condense all entries into a `.prompt` entry**. If you're
> looking to preserve `.toolCalls` entries during summarization, you should be able to implement your
> own modifier using `DynamicProfileModifier` and either `historyTransform` or lifecycle modifiers."*
> If your PCC feature is tool-heavy — which is one of the two use cases Apple names for PCC
> (`319:9`) — summarizing history on the fallback branch throws away exactly the structure that made
> the conversation work.

### 10.2 Reasoning is the invisible tenant of the 32K

Repeating §6.4's point in its budgeting form, because this is where it bites: your context budget on
PCC is **32K minus instructions minus schemas minus tools minus history minus reasoning**, and only
the last of those is invisible in your own source code. At `.deep`, where the reasoning segment *"may
be even longer than the actual response"* (`319:52`), it can be the largest line item.

Practical budget discipline:

1. Read `try await model.contextSize` rather than assuming 32768 (§3.3).[^pcc-context-size]
2. Log `usage.output.reasoningTokenCount` per turn (§6.4) and look at the distribution before you ship
   `.deep`.
3. Use `tokenCount(for:)` — ✅ shipped in **iOS 26.4** per DTS Engineer, thread 817502 — to size
   instructions and prompts *before* sending them, so that when you overflow you know which component
   grew.
4. Apply history management on the PCC branch too, once conversations run long. 32K is large; it is
   not unlimited, and reasoning is spending it on your behalf.

### 10.3 Guided generation costs context as well

> ✅ **VERIFIED** — from the guided-generation docs
> (`notes/web/apple-docs-fm-evals-speech.md:657-662`): *"For every `Generable` type in a request, the
> framework converts its type and format information to a JSON schema and provides it to the model.
> **This contributes to the available context window size.**"* Apple's own reduction advice: fewer
> properties, short clear names, `@Guide(description:)` only where it improves quality, and
> `maximumCount(_:)` to cap arrays.

On a 4K model that advice is survival. On PCC it is merely good hygiene — but combined with `.deep`
reasoning and a long transcript it is still how you reach `contextSizeExceeded` on a model with eight
times the room.

---

## 11. Generable, tools, and evaluating before you commit

### 11.1 Structured output and tools are unchanged

Session 319's claim (§4.3) is that `@Generable` and `Tool` work identically on PCC. Nothing in our
corpus contradicts it, and one thing corroborates it strongly: Apple's Book Tracker sample drives its
synthetic-data pipeline through a **PCC-backed session generating a `@Generable` type**.

> ✅ **VERIFIED** — `BookSampleGenerator/main.swift` (`notes/web/apple-sample-code.md:1356-1372`):
>
> ```swift
> let generator = SampleGenerator<ModelSample<BookTags>>(
>     prompt,
>     samples: dataset,
>     targetCount: targetCount,
>     // Uses Private Cloud Compute for larger, more diverse generations.
>     sessionProvider: {
>         LanguageModelSession(
>             model: PrivateCloudComputeLanguageModel(),
>             instructions: """
>             You are a synthetic data generator for a book-tracking app's evaluation suite.
>             …
>             """
>         )
>     },
>     validator: { sample in … }
> )
> ```
>
> `ModelSample<BookTags>` is a structured, `Codable` sample type and `BookTags` is the `@Generable`
> payload. So: PCC + `@Generable` + a session factory, in compiling Apple code, with the motive stated
> in the comment — *"larger, more diverse generations"*.

Note the `sessionProvider:` **factory** in that sample. It exists so the generator can spin up fresh
sessions across a 100-sample run rather than growing one transcript to death — the same context
discipline as §10, applied to a batch job.

Two forward-references rather than repetition:

- **Tools**: everything in Part 2's tool-calling guide applies unchanged. The one PCC-specific angle
  is economic — session 319 names *"features that rely on making lots of tool calls, with large
  outputs"* as a target use case (`319:9`), and each iteration of the tool loop is another inference
  against the user's daily quota. **One `respond(to:)` is not one request.**
- **`SpotlightSearchTool`**: works with any model, per session 246 (*"whether it's the
  `SystemLanguageModel` or a model of your choosing"*), but it is **not available on watchOS**, and
  its `.complete` guidance level injects on the order of 13K tokens of tool instructions
  (community-measured on macOS 27 beta, M4 Max, 2026-06-13). On a 4K model that is instant overflow;
  on PCC's 32K it is 40% of your window before the user says anything. Use `.focused(.items)` with
  `format: .compact` unless you have measured otherwise. Part 2's Spotlight guide covers this.

### 11.2 "Data, not vibes"

The strongest presenter recommendation in session 319 is not about PCC at all. It is about not
adopting PCC:

> ✅ **VERIFIED** — `319:61-64`: *"When deciding between the on-device and PCC model, or deciding the
> reasoning level to use, it's good to make that decision **based on data, not just vibes**.
> Evaluating lets you understand the quality of your specific feature. **You may be surprised how well
> the on-device model performs at certain tasks, especially with the updated model this year. But the
> only way to know is by evaluating.**"*
>
> The docs make it an ordering instruction (`notes/web/apple-docs-fm-evals-speech.md:1695`): *"**Start
> with the on-device model and evaluate it** with the Evaluations framework. If you determine your
> feature needs more reasoning capability or context size, then use PCC."*

There are three concrete reasons this is more than boilerplate:

1. **The on-device model was rebuilt in this cycle.** `241:12-13`: *"a new on-device model, rebuilt
   from the ground up, and better across the board… more intelligent; better at logic and tool
   calling."* Any judgement you formed on 26.0–26.3 is stale. The 26.4 refresh alone explicitly
   improved instruction-following and tool-calling.
2. **Every PCC request spends a stranger's budget.** Not yours. A feature that works acceptably
   on-device and beautifully on PCC still has to justify consuming a shared daily allowance the user
   might have wanted for something else.
3. **Your eligibility has a fuse** (§1.3). A feature you can only deliver at PCC quality is a feature
   you may have to withdraw within six months of succeeding.

And PCC responses are evaluable with the framework directly:

> ✅ **VERIFIED** — **Engineer (Apple)**, thread 832053, marked Recommended
> (`notes/forums/forum-pain-points.md:669-686`): *"You can use it [`ModelJudgeEvaluator`] to evaluate
> responses from the `PrivateCloudComputeLanguageModel`. You just need to set up your
> `LanguageModelSession` correctly:"* followed by the two-line PCC session snippet.

Apple's own recommended use of Evaluations is **regression testing across OS updates**, because there
is no model-pinning API and no version-retrieval API for either model
(`notes/forums/forum-pain-points.md:323-324, 1324-1325`). That applies with extra force to PCC: the
server model can change under you between one launch and the next, with no version string anywhere in
the API. Part 6 is the whole story.

> 🔴 **GAP — no published quality delta between the on-device model and PCC on any task.** Session 319
> asserts you "may be surprised how well the on-device model performs"; nobody publishes a benchmark,
> a win rate, or a task taxonomy. Our corpus contains no community comparison either (thread 832053's
> MLX-vs-AFM performance question was explicitly **not answered** by Apple). **What would resolve it:**
> your own evaluation suite — which is exactly Apple's point. **Safe default meanwhile:** treat the
> comparison table in §3.2 as a statement about *capacity* (context, reasoning), not *quality*, and
> measure quality yourself.

---

## 12. If you are not eligible

For readers who failed §1's checklist — and for readers whose six-month clock has started — this is
the shape of the alternative. Each backend has its own guide in Part 4; this is the decision, not the
implementation.

### 12.1 The three replacements

| Replacement | What it costs you | What it buys |
|---|---|---|
| **`ChatCompletionsLanguageModel`** → your own server, `mlx_lm.server`, Ollama, vLLM, LM Studio | Auth, keys, billing, hosting, a privacy disclosure | Any OpenAI-compatible endpoint behind `LanguageModelSession`, today |
| **`MLXLanguageModel`** → an MLX-community model on-device | Download size, memory, first-load latency | Thousands of Hugging Face models, no server, no quota |
| **`CoreAILanguageModel`** → a model you bundle | Conversion and packaging work | ANE execution, shipped in your app |

`ChatCompletionsLanguageModel` is the closest analogue to "PCC but mine", and it is real, shipping and
under-publicised:

> ✅ **VERIFIED** — it lives in **`apple/foundation-models-utilities`** (459 stars, last push
> 2026-07-16), a real SwiftPM package whose stated supported platforms are *"Apple platforms and
> select Linux distributions like Ubuntu"* (`notes/02-lead-agent-corpus-gaps-filled.md:7-46`):
>
> ```swift
> let model = ChatCompletionsLanguageModel(
>   name: "minimax-m2.5",
>   url: URL(string: "http://localhost/v1:8000")!,
>   supportsGuidedGeneration: false   // some local servers don't support it
> )
> let session = LanguageModelSession(model: model)
> ```
>
> ⚠️ **Known defect (forum 838444, FB23837262):** `buildURLRequest` decides versioning with
> `baseURL.pathComponents.contains("v1")` and appends `/chat/completions` or `/v1/chat/completions`.
> **Hardcoding `v1` breaks servers on other version paths.** Live limitation as of 2026-07-27.
>
> ⚠️ **Cadence caveat:** the utilities package ships **out of band with the OS** — Apple's own words,
> *"updated between OS releases… emerging and experimental building blocks"* (`241:5`). Treat its API
> surface as less stable than the in-OS framework.

### 12.2 The two things you inherit that PCC handled for you

**Authentication and key handling.** Session 339's guidance for provider packages is equally your
guidance as a consumer:

> ✅ **VERIFIED** — `339:157-167` and `241:51-53`: *"never store private keys in your app binary.
> Always fetch access tokens with a secure mechanism like OAuth, and store them securely using
> KeyChain."* Plus, for anything customer-facing: **App Attest** — *"verifying the device, catching
> tampered builds, signing payloads, and using Apple's fraud signal to keep bad traffic off your
> service."*

**Per-token billing, which is now yours.** `241:54-56` introduces `session.usage` / `response.usage`
precisely because *"you'll typically be billed per-token when using 3rd party models."* The `Usage`
API you used in §6.4 to watch reasoning becomes your cost meter.

### 12.3 ⚠️ The constraint nobody mentions: guided generation can disappear

This is the sharpest edge in the whole fallback story, and it is a first-class architectural
constraint rather than a footnote.

> ⚠️ **SILENT-ish FAILURE — bringing your own model can cost you `@Generable`, and it costs you exactly
> when you pick the fastest backend.** Grammar-constrained decoding requires access to engine
> **logits**. GPU-pipelined Core AI bundles never expose them. An app that moves off PCC onto a fast
> local backend can therefore lose Apple's flagship structured-generation feature.
>
> **Community-measured** — `notes/repos/john-rocky-models.md`, via
> `notes/CORRECTIONS-PENDING.md` C4. Attribute it as such; it is not an Apple statement.
>
> The failure is at least *typed*: a well-behaved provider throws
> `LanguageModelError.unsupportedCapability(.guidedGeneration)` rather than returning malformed JSON,
> and session 339's "approximate or throw" rule says it should
> (`339:143-156`; a real conformance does exactly this at `ZooExecutor.swift:119-128`). But a provider
> that declares `.guidedGeneration` it cannot honour will silently produce unconstrained text. **Check
> `model.capabilities.contains(.guidedGeneration)` before you call `respond(to:generating:)` on any
> third-party model** — Apple's docs show that exact guard (`notes/web/apple-docs-fm-evals-speech.md:1823`).

### 12.4 The architecture the community converged on

From the forum synthesis (`notes/forums/forum-pain-points.md:1309-1310`), and it matches what §4.4
already had you build:

> **Abstract inference behind a protocol; on-device first; PCC as one tier; a third-party provider as
> overflow via the `LanguageModel` protocol.**

Because every backend conforms to `LanguageModel`, that abstraction is *already written* — it is the
protocol. Your app-level seam is the one stored property from §4.4:

```swift prelude:guide-context
// The entire model-selection surface of the app.
var serverModel: any LanguageModel = {
    if isPCCEligibleBuild, #available(iOS 27.0, *) { PrivateCloudComputeLanguageModel() }
    else if let local = try? CoreAILanguageModel(resourcesAt: bundledModelURL) { local }
    else { SystemLanguageModel() }
}()
```

> 🟡 **RECONSTRUCTED** — the composition is ours. Verified components: `PrivateCloudComputeLanguageModel()`
> bare init (✅ docs + samples); `try await CoreAILanguageModel(resourcesAt: url)` (✅ Apple's own doc
> comment in `apple/coreai-models`, though note it is `async` — the `if`-expression above elides that
> and would need an `await` in a real async context); `SystemLanguageModel()` bare init (✅ 2026 house
> style per Apple samples). Whether `any LanguageModel` is accepted where `LanguageModelSession(model:)`
> expects a concrete type is the same open question as §4.2 — Apple's samples always pass a concrete
> type. **Safe default:** store the concrete type, as Origami does, and branch at the profile level.

---

## 13. Declared gaps

Everything in this guide that we could not verify, collected — plus, where a formerly open question
has since been settled (§13.1), the resolution. None of these contains a guess.

### 13.1 ✅ Image input is supported; operating limits remain open

The support question is settled by two Apple sources. Session 319's PCC demo feeds “the text and
images” from a Markdown file into a `LanguageModelSession`, and Apple's multimodal prompting article
explicitly recommends `PrivateCloudComputeLanguageModel` when image analysis needs more reasoning or
context.[^pcc-images] Build PCC multimodal features using the same labeled `Attachment` prompt surface;
keep an on-device fallback for availability, quota, and network failures.

The remaining unknowns are narrower and operational:

1. Whether images consume PCC quota differently from text.
2. PCC-specific size, resolution, format, or per-request image-count limits.
3. PCC image-token accounting and how it interacts with reasoning tokens.
4. Whether PCC advertises `.vision` through its concrete `capabilities` surface on every current SDK.

A capability check is still useful for defensive routing, but it is not the basis for claiming that
PCC image input is unsupported:

```swift prelude:guide-context
// 🟡 RECONSTRUCTED probe. `capabilities` is a LanguageModel protocol requirement (✅),
// `.vision` is a documented Capability member (✅ "The capability to accept image
// inputs in prompts"), and PCC conforms to LanguageModel (✅).
if model.capabilities.contains(.vision) {
    // send the attachment
} else {
    // OCR on-device, send text
}
```

### 13.2 The rest, in one table

| # | Unknown | What would resolve it | Safe default meanwhile |
|---|---|---|---|
| 1 | PCC-specific image limits and token/quota accounting (§13.1) | Published limits or a controlled entitled-device test | Use labeled attachments, instrument `Usage`, and retain the on-device fallback.[^pcc-images] |
| 2 | Full `QuotaUsage.Status` case list (§7.2) | `…/quotausage-swift.struct/status-swift.enum` | Test `isLimitReached` first, then `if case .belowLimit`; never `switch` exhaustively |
| 3 | `resetDate`'s declared type (§7.2) | The `resetdate` symbol page | Treat as optional; never force-unwrap |
| 4 | Relationship between `PrivateCloudComputeLanguageModel.Error` and `LanguageModelError` (§9.1) | The PCC `Error` page's conformance list | Catch both; treat `.rateLimited` as quota-shaped |
| 5 | `ReasoningLevel.custom(_:)` payload type (§6.2) | `…/reasoninglevel-swift.enum/custom(_:)` | Do not construct `.custom` against PCC |
| 6 | Whether PCC surfaces `capabilities` on the concrete class (§6.7) | PCC symbol page member list | Fall back to the documented capability table |
| 7 | tvOS / Mac Catalyst availability (§5.1) | PCC symbol page platform list | Ship only the four platforms Apple's snippet lists |
| 8 | PCC for non-App-Store macOS distribution (§1.6) | Apple-staff answer on a Developer ID thread | On-device baseline; PCC as a runtime-gated enhancement |
| 9 | Whether the Siri-enablement bug affects PCC `availability` (§5.8) | A device report with Siri disabled | Generic message on `.unavailable(other)`; never tell users to enable Siri |
| 10 | Whether the Xcode drop-down simulates *availability* reasons too (§8.1) | A listing of the full menu on released Xcode 27 | Test unavailable branches by other means |
| 11 | Whether the quota-simulation option works in the Simulator (§8.1) | A device/simulator comparison | Exercise quota UI on device |
| 12 | Latency and token cost per reasoning level (§6.6) | Instruments trace + `reasoningTokenCount` distribution from an entitled app | Instrument your own app before committing to `.deep` |
| 13 | Quality delta between on-device and PCC on any task (§11.2) | Your own Evaluations suite | Read §3.2 as capacity, not quality |
| 14 | Reading `String` out of a `Transcript.Segment` (§6.5) | `/documentation/foundationmodels/transcript/textsegment` | Use `Transcript.Reasoning.description` or `CustomStringConvertible` |
| 15 | Whether `QuotaUsage` changes drive `Observable` updates (§7.5) | Behavioural test on device | Re-read at three call sites |
| 16 | Watch-pairing requirement for PCC (§3.6) | Apple answer on thread 834652 | `model.availability` is the only truth on watchOS |
| 17 | Whether a `.contextOptions(_:)` profile modifier exists (§6.3) | Dynamic-profile modifier index | Use `.reasoningLevel(_:)`, as the sample does |
| 18 | Whether `.deep` reasoning has a server-side timeout | — nothing in our corpus mentions one | Handle `LanguageModelError.timeout(_:)` in the ladder; it is a documented case |

### 13.3 Things you may have read elsewhere that are wrong

Circulating claims about this API that our sources contradict or fail to support:

- **"PCC eligibility is 2 million downloads per year."** No. Lifetime, cumulative, across all your
  apps (§1.2).
- **"PCC eligibility is just the download threshold."** No. Three conditions; the Small Business
  Program one is in no session (§1.1).
- **"The PCC entitlement is a checkbox in Xcode."** No. It is **managed** — requested and assigned
  (§2.1). And its absence crashes rather than throws (§2.3).
- **"`isAvailable == true` means requests will succeed."** No. Quota is orthogonal to availability,
  in Apple's own words (§5.4).
- **"You can build a quota progress bar."** No. Three coarse states, no numbers, FB23378161 open
  (§7.6).
- **"Retry with backoff on a quota error."** No. It is a daily quota, not a rate limit; Apple draws
  the distinction explicitly (§7.1).
- **"`SystemLanguageModel` has a 4096-token context, always."** 4,096 was measured on the recorded
  runtime and is Apple's published figure, but it remains device-variable. Read `contextSize` and
  never hardcode the measurement (§3.2).
- **"`Profile(model:) { … }`."** Not the spelling. `Profile { … }.model(_:)` (§4.4).
- **"Reasoning appears in the response."** No. Separate transcript segment, absent from
  `response.content`, and it spends your context anyway (§6.4).

---

## 14. Quick reference

### 14.1 Eligibility and entitlement

| Item | Value | Source class |
|---|---|---|
| Condition 1 | Enrolled in **App Store Small Business Program** | Apple developer page (in **no** WWDC session) |
| Condition 2 | **< 2,000,000** first-time App Store downloads, **lifetime, all apps** | Apple developer page + DTS Engineer, 835897 |
| Condition 3 | **PCC entitlement** assigned to the account | Apple developer page |
| Entitlement key | `com.apple.developer.private-cloud-compute` (**managed**) | Docs + two Apple samples |
| Request URL | `https://developer.apple.com/private-cloud-compute/` and `…/contact/request/private-cloud-compute/` | Apple page + sample code comments |
| Dead URL | `…/apple-intelligence/private-cloud-compute/` **404s** | Verified |
| TestFlight / ad hoc installs | **Do not** count toward 2M | Apple page |
| Over the threshold | Notified; **6 months** to migrate | Apple page + Frameworks Engineer, 833641 |
| Cost to developer | **None** — no cloud API cost, no token cost | Apple page + `319:23` |
| Missing entitlement at runtime | **`fatalError`**, not a thrown error | Community, thread 831998 |

### 14.2 API surface

```swift illustrative
// iOS 27.0 / iPadOS 27.0 / macOS 27.0 / watchOS 27.0 / visionOS 27.0
final class PrivateCloudComputeLanguageModel
// Conforms: Copyable, Escapable, LanguageModel, Observable, Sendable, SendableMetatype
init()
var isAvailable: Bool
var availability: PrivateCloudComputeLanguageModel.Availability
var quotaUsage: PrivateCloudComputeLanguageModel.QuotaUsage
var contextSize: Int { get async throws }
var supportedLanguages
func supportsLocale(_:)

// Availability
case .available
case .unavailable(.deviceNotEligible)
case .unavailable(.systemNotReady)     // PCC-only reason
case .unavailable(let other)           // not frozen — keep this arm

// QuotaUsage
struct QuotaUsage                       // Sendable
var isLimitReached: Bool
var status: QuotaUsage.Status           // at least .belowLimit(_:) → .isApproachingLimit
var resetDate                           // empty when unknown or well below limit
var limitIncreaseSuggestion: QuotaUsage.LimitIncreaseSuggestion?   // .show() → system UI

// Errors
enum PrivateCloudComputeLanguageModel.Error
case .quotaLimitReached(_:)   // "The allotted usage quota has been reached."
case .networkFailure(_:)      // network up, PCC unreachable
case .serviceUnavailable(_:)  // "Services are unavailable."

// Reasoning
struct ContextOptions
init(includeSchemaInPrompt:reasoningLevel:)
enum ContextOptions.ReasoningLevel { case light, moderate, deep, custom(_:) }

try await session.respond(to: prompt, contextOptions: ContextOptions(reasoningLevel: .deep))
Profile { … }.model(pccModel).reasoningLevel(.deep)

// Reasoning lands here
Transcript.Entry.reasoning(Transcript.Reasoning)   // init(id:metadata:segments:signature:)

// Token accounting
session.usage / response.usage → Usage
Usage.input.totalTokenCount / .cachedTokenCount
Usage.output.totalTokenCount / .reasoningTokenCount
```

### 14.3 Adoption checklist

```text
BEFORE YOU WRITE CODE
[ ] Small Business Program enrolment confirmed
[ ] Lifetime first-time downloads across all apps < 2M
[ ] PCC entitlement requested and assigned
[ ] Evaluated the on-device model and measured that it is insufficient   (§11.2)

BUILD
[ ] Model stored as ONE property, not constructed inline                 (§4.4)
[ ] #available gate matches Apple's four-platform list                   (§5.1)
[ ] availability switch includes .unavailable(let other) + @unknown default
[ ] Quota checked SEPARATELY from availability                           (§5.4)
[ ] historyTransform on every SMALLER-model profile                      (§10.1)
[ ] reasoningLevel starts at .moderate                                   (§6.6)
[ ] usage.output.reasoningTokenCount logged                              (§6.4)
[ ] contextSize read, never hardcoded                                    (§3.3)

QUOTA UI
[ ] No .alert() anywhere near the quota path                             (§7.3)
[ ] Request button .disabled when limit reached
[ ] Subtle label under the button, red for reached / orange for nearing
[ ] "Manage limit" button shown ONLY when limitIncreaseSuggestion != nil
[ ] refreshState() on appear, after every turn, and in the catch         (§7.5)
[ ] No numbers, percentages or meters in the copy                        (§7.6)

ERRORS
[ ] All four error types caught; bare catch last                         (§9.2)
[ ] Case patterns above their own type pattern
[ ] quotaLimitReached transitions to a STATE, does not display
[ ] networkFailure / serviceUnavailable retry ON-DEVICE                  (§5.6)
[ ] Error handling re-audited after moving to the Xcode 27 SDK           (§9.3)

TEST
[ ] Physical device on 27.0+ — the Simulator cannot run PCC              (§5.5)
[ ] Both quota states exercised via the scheme option                    (§8)
[ ] Fallback path exercised with a long transcript                       (§10.1)
[ ] Privacy disclosure covers the on-device ↔ cloud boundary             (§3.5)
```

---

## 15. Sources

Ordered by this series' evidence precedence. Every claim in this guide traces to one of these.

### 15.1 Apple sample code (strongest)

- **Origami** (`OrigamiCraftingADynamicTutorialForAppleIntelligence`, 61 Swift files, iOS/macOS/visionOS
  27.0, Swift 6.0) — `Origami/Models/OrchestratorProfile.swift:11-75` for the PCC opt-in comment, the
  entitlement request URL, `Profile { … }.model(_:)`, `.reasoningLevel(.deep)`, `.temperature(1.0)`,
  `.historyTransform(shortHistory(_:))`, and the "model as one stored property" pattern.
  `Origami/Coach/CoachModel.swift:58-73` for the zero-partial stream guard.
  Entitlements file ships **only** `com.apple.security.app-sandbox`.
- **Book Tracker** (macOS 27) — `BookSampleGenerator/main.swift` for a PCC-backed session driving a
  `@Generable` synthetic-data pipeline via `sessionProvider:`.
- Recorded in `notes/web/apple-sample-code.md` (2,108 lines; §2 is a 66-row corrections table).
- ⚠️ **Excluded as stale:** the coffee/generative-game sample and the SpeechAnalyzer sample are iOS 26 /
  WWDC25 leftovers and are never cited here as 2026 evidence.

### 15.2 Apple documentation

- `/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute` — the
  PCC article. Capability table, availability switch, `QuotaUsage` snippet, quota-vs-rate-limit
  distinction, Xcode scheme steps, the `#available` snippet, the "start on-device and evaluate"
  ordering. Captured in `notes/web/apple-docs-fm-evals-speech.md` §14 and, in a second independent
  mirror, at `notes/transcripts/fm-ecosystem.md` A.2–A.10.
- `/documentation/foundationmodels/contextoptions` and `…/reasoninglevel-swift.enum` — the four
  `ReasoningLevel` cases with Apple's descriptions.
- `/documentation/foundationmodels/languagemodelerror`, `…/languagemodelsession/error`,
  `…/privatecloudcomputelanguagemodel/error` — the error reshuffle, §5.1–5.5 of the docs note.
- `/documentation/foundationmodels/transcript` — `Transcript.Entry.reasoning`, `Transcript.Reasoning`,
  `Transcript.Segment`.
- `/documentation/foundationmodels/systemlanguagemodel/contextsize` — the back-deployed declaration.
- `/documentation/foundationmodels/languagemodel` + `languagemodelcapabilities` — the protocol, the
  four `Capability` members, and the "framework can refuse to dispatch" rule.
- `https://developer.apple.com/private-cloud-compute/` — the three eligibility criteria, verbatim,
  fetched 2026-07-27.

### 15.3 Apple-staff answers on the Developer Forums

All fetched live and recorded in `notes/forums/forum-pain-points.md`.

| Thread | Who | What it settles |
|---|---|---|
| **835897** | DTS Engineer (Ziqiao Chen) | Lifetime download reading; on-device has no limits |
| **833641** | Frameworks Engineer (Recommended) | The 6-month migration window |
| **834749** | Apple Designer (accepted) | The entitlement application *is* the programme application |
| **829539** | Sla1708 / Sayan Lakhoua (accepted) | Direct entitlement request URL |
| **831998** | Frameworks Engineer (accepted) | **PCC does not work in simulators** — known issue **177684296** |
| **833626** | Frameworks Engineer (accepted) | PCC→on-device profile switch throws; use `historyTransform` |
| **833706** | Frameworks Engineer + Apple Designer | `summarizeHistory` condenses everything into a `.prompt` entry |
| **832053** | Engineer (Recommended) | `ModelJudgeEvaluator` can evaluate PCC responses |
| **836810** | Frameworks Engineer + Apple Designer | No Required Device Capability for AI; check availability before payment |
| **831404** | Apple Designer (accepted) + Frameworks Engineer | The Simulator punch-out explanation; the four-clause catch ladder |
| **835987** | Frameworks Engineer (accepted) | watchOS 27 b2 `CoreImage` build break is "a known bug" |
| **836760** | Frameworks Engineer | FM should work in Europe without Siri AI → the Siri coupling is a **bug** |
| **797271**, **817502**, **790736**, **833575**, **833666**, **832033** | various Apple staff | Locale, `tokenCount(for:)`, the 4K era, extensions, background, non-App-Store |

Developer reports without Apple answers, used only as attributed community evidence:
**835974** (quota too coarse, FB23378161 — open), **834652** (watch pairing, OP self-answer),
**838444** (`ChatCompletionsLanguageModel` `v1` path bug, FB23837262), **833642** (the 32K figure from
a *community* reply — the docs are what make 32K an Apple number).

### 15.4 WWDC26 transcripts

- **319 — "Build with the new Apple Foundation Model on Private Cloud Compute"** (Louis, 109 lines).
  The primary source for this guide: the eligibility sentence, the one-line switch, the comparison
  table, the reasoning definition, the whole quota-UX chapter, the Xcode scheme demo.
  Read in `notes/transcripts/fm-ecosystem.md` Part A.
- **241 — "What's new in Foundation Models"** (Erik & Zhen, 140 lines). The 32K figure, the reasoning
  announcement, watchOS via PCC, the privacy/economics pitch, `usage`.
  Read in `notes/transcripts/fm-core.md` §1.5.
- **339 — "Bring an LLM provider to the Foundation Models framework"** (Christopher Webb, 213 lines).
  `ContextOptions` vs `GenerationOptions`, the six transcript entry kinds including `reasoning`, the
  privacy-disclosure recommendation, "approximate or throw".
- **246 — "LLM search using Core Spotlight"** (Jennifer, 138 lines). Cited only for
  `SpotlightSearchTool`'s platform list and its model-agnosticism.

⚠️ Where a transcript and a doc page disagree — the Xcode menu strings (§8) — this guide follows
the doc, and says so at the point of disagreement (the on-device context size, once such a case,
is ✅ settled at 4,096 in §3.2). Where a sample project and a doc page disagree — the session
initializer's typing (§4.2), `Profile(model:)` vs `.model(_:)` (§4.4) — this guide follows the sample.

### 15.5 Community and third-party code

Always attributed as such in the text, never presented as an Apple figure.

- `frozen Noema 3.5 snapshot` — a shipping app with PCC integration: `AFMLLMClient.swift` (the
  `contextSize` 8K observation, the `supportsLocale` guard, the platform list drift),
  `AppleFoundationModelAvailability.swift` (the collapsed availability+quota enum),
  `AppleFoundationModelRegistry.swift` (`privateCloudContextLimit = 32_768`), and four `.entitlements`
  files carrying the PCC key.
- `apple/foundation-models-utilities` — `ChatCompletionsLanguageModel`, the history modifiers, and the
  `LanguageModel` protocol SKILL.md. Recorded in `notes/02-lead-agent-corpus-gaps-filled.md`.
- `ml-explore/mlx-swift-lm` (`MLXFoundationModels`) and `apple/coreai-models` — the capability-routing
  doc comment quoted in §6.7, and the executor conformances that confirm the `.reasoning` channel
  event.
- `john-rocky/coreai-model-zoo` — the logits/guided-generation constraint in §12.3
  (community-measured), and the `SpotlightSearchTool` guidance-level token measurement in §11.1
  (macOS 27 beta, M4 Max, 2026-06-13).

### 15.6 Related guides in this series

- **Part 1** — orientation, platform gating, the backend decision table, and the known-bad-claims
  reference.
- **Part 2** — `LanguageModelSession`, `@Generable`, streaming, the `Tool` protocol, errors,
  `SpotlightSearchTool`. Everything in front of the model.
- **Part 3** — dynamic profiles, `historyTransform`, context management, agentic sessions.
- **Part 4** (this part) — the other backends: `CoreAILanguageModel`, `MLXLanguageModel`,
  `ChatCompletionsLanguageModel`, and authoring your own `LanguageModel` provider.
- **Part 6** — Evaluations, which §11.2 says you should run before adopting anything here.
- **Part 15** — shipping and operating, including the regression-testing posture that a
  version-unpinnable server model forces on you.

---

*Guide last verified against the corpus on **2026-07-27**. Beta-era material: `PrivateCloudComputeLanguageModel`
is marked "iOS 27.0+ Beta" on every symbol page we hold, several forum threads describe unreleased
builds, and the eligibility page is a policy document that can change without a version number.
Re-verify §1 before you make a business decision on it.*

[^pcc-context-size]: Apple, [`PrivateCloudComputeLanguageModel.contextSize`](https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel/contextsize), declared as an asynchronous, throwing getter.
[^pcc-images]: [WWDC26 session 319 transcript, lines 74–76](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/transcripts/wwdc2026-319.txt#L74-L76), and Apple, [“Analyzing images with multimodal prompting”](https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting), which directs image tasks needing greater reasoning or context to `PrivateCloudComputeLanguageModel`.
