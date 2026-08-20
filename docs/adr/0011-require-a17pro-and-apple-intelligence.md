# Require iPhone 15 Pro and Apple Intelligence

## Status

Accepted (2026-08-19).

## Context

CREG's original device floor was the base iPhone 15 (`iPhone15,4`), chosen for
the ~1.75 GB resident footprint of the bundled 4-bit 3B SQL model. Apple
Foundation Models were treated as optional garnish: every FM call site
silently degraded to `FMClient.fallback()` (no rewrite, no gate, templated
narration, zero follow-up suggestions), and the specific unavailability reason
was stringified and discarded.

The Turn Failure work (`docs/turn-failure-plan.md`) makes Foundation Models
load-bearing: scope verdicts, recovery-suggestion generation, and the
conversational glue all assume an FM. Designing every one of those features
twice — once for FM devices and once for a fallback tier consisting of exactly
two phones (iPhone 15 and 15 Plus, the only supported devices without Apple
Intelligence) — doubles the surface for the product's least capable
experience.

Apple's model identifier families make the boundary exact: `iPhone16,1` /
`iPhone16,2` are the iPhone 15 Pro and 15 Pro Max (A17 Pro, Apple
Intelligence-capable), while `iPhone15,4` / `iPhone15,5` are the base
iPhone 15 and 15 Plus (A16, not capable). Major ≥ 16 is therefore precisely
the Apple Intelligence line.

## Decision

1. **The hardware floor is iPhone 15 Pro and newer**: `DeviceCapability`
   admits `iPhone<major>,<minor>` identifiers with major ≥ 16 and nothing
   else. The iOS 26 deployment target already stands.
2. **Apple Intelligence is required for all new turns.** `FMAvailability`
   carries typed reasons mapped from
   `SystemLanguageModel.Availability.UnavailableReason`; the reducer refreshes
   availability on every scene activation and gates submission (free-form,
   starter, benchmark, and queued dispatch alike) on it:
   - `appleIntelligenceNotEnabled` → a blocking callout with the manual
     Settings › Apple Intelligence & Siri path. This is the product's only
     designed no-FM surface.
   - `modelNotReady` → a transient "Preparing Apple Intelligence" state.
   - `deviceNotEligible` → logged and rendered as unavailable. It should be
     unreachable in Release behind the floor, but Debug intentionally bypasses
     that floor for previews and simulator work.
3. **`FMClient.fallback()` survives strictly as a mid-turn safety net**: a
   turn already in flight when availability flips degrades gracefully
   (templated narration) instead of crashing. No feature is designed around
   it.

## Consequences

- The no-FM population collapses from a hardware tier to a single
  settings/transient state with one honest UI. Features built on the FM
  (scope verdicts, recovery suggestions) need no per-device design.
- iPhone 15 and 15 Plus lose access. CREG ships as an internal-only
  TestFlight build, so the cut is a fleet-composition question, not an App
  Store regression.
- Reading history never requires the FM; only new turns gate on it.
- The floor is not enforced in Debug builds (unchanged), which is what the
  preview/simulator harness relies on.
