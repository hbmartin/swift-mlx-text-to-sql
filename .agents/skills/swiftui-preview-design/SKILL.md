---
name: swiftui-preview-design
description: "Use SwiftUI #Preview as the default visual harness when implementing or reviewing UI from screenshots, mockups, Figma frames, or design specifications. Create deterministic named preview states, render and compare them, and avoid launching the full app in Simulator unless validation requires app lifecycle, navigation integration, system services, real runtime data, or interaction behavior a preview cannot faithfully exercise. Do not use for nonvisual Swift changes or end-to-end app validation."
---

# SwiftUI Preview Design

## Purpose

Use the smallest faithful SwiftUI `#Preview` to answer visual design questions before building, launching, and navigating the full app.

A completed preview-first loop should leave behind:

- A deterministic, descriptively named preview for each relevant design state.
- An actual rendered image comparison when preview-rendering tools are available.
- The narrowest appropriate build or test verification.
- A clear statement that the full app was not launched, or the concrete reason it was required.

This policy is **preview-first, not simulator-forbidden**. Xcode may use preview infrastructure or a simulator runtime internally. The avoided operation is launching the app through its normal entry point and navigating the full runtime flow without a concrete need.

## When to Use

Use this skill when the task is primarily visual:

- Implementing a SwiftUI view from a screenshot, mockup, Figma frame, or design specification.
- Adjusting layout, spacing, typography, color, materials, assets, or component styling.
- Reviewing a SwiftUI change for visual fidelity or regressions.
- Comparing loading, empty, error, selected, disabled, or other local presentation states.
- Checking relevant appearance, locale, orientation, or Dynamic Type variants.

Do not use this skill as the primary workflow for:

- Nonvisual model, networking, persistence, or concurrency changes.
- End-to-end flows whose correctness depends on the running app.
- Performance profiling, launch behavior, lifecycle behavior, or device hardware integration.

## Core Decision Rule

Start with a preview when the question is:

> Does this view, in this known state, match the design?

Launch the full app only when the question is:

> Does this work correctly inside the real app or operating-system runtime?

A preview is sufficient when the target state can be reproduced by constructing a view with deterministic inputs and the necessary local environment. Simulator use requires at least one concrete capability that the preview cannot faithfully provide.

The following are **not** sufficient reasons to launch the app:

- The code belongs to an iOS target.
- An app scheme already exists.
- A screenshot is desired but a preview renderer is available.
- The view normally appears inside navigation, a list, a sheet, or another container that can be represented by a preview wrapper.
- Simulator launch is more familiar than creating a proper preview fixture.

## Workflow

### 1. Inspect the repository before running anything

1. Read `AGENTS.md` and any nearer scoped instructions.
2. Find the target view, its existing previews, preview fixtures, development assets, theme setup, and dependency-injection conventions.
3. Look for a repository-provided preview renderer, snapshot command, Xcode MCP guidance, or established design-capture workflow.
4. Reuse the project's existing preview conventions. Do not introduce a parallel preview framework without a demonstrated need.
5. Do not boot Simulator or launch the app during discovery.

### 2. Choose the smallest faithful preview boundary

Preview the smallest view that still contains the visual context required by the design.

- Prefer a component or screen view over the entire app root.
- Wrap the view in `NavigationStack`, `List`, a representative background, safe-area treatment, or another container when that context affects appearance.
- If the view is tightly coupled to global state, make the smallest reasonable dependency-explicit refactor rather than launching the app merely to obtain data.
- Do not add production branches that detect preview execution and change behavior.
- Do not weaken access control, error handling, or runtime invariants solely to make a preview compile.

### 3. Create deterministic named states

If the design source supplies frame or state names, use those names exactly. Otherwise use:

```text
<Feature> — <State> [— <Variant>]
```

Examples:

```swift
#Preview("Profile — Loaded") {
    NavigationStack {
        ProfileView(model: .previewLoaded)
    }
    .environment(PreviewDependencies.stub)
}

#Preview("Profile — Empty — Dark") {
    NavigationStack {
        ProfileView(model: .previewEmpty)
    }
    .environment(PreviewDependencies.stub)
    .preferredColorScheme(.dark)
}
```

For local interactive state, use the project's supported preview pattern. When the toolchain supports it, `@Previewable` is appropriate:

```swift
#Preview("Player Controls — Paused") {
    @Previewable @State var isPlaying = false
    PlayerControls(isPlaying: $isPlaying)
}
```

Preview data must be stable and side-effect free:

- No live network requests, authentication, analytics, database mutation, Keychain access, or notification registration.
- No uncontrolled current date, random values, generated identifiers, or locale-dependent fixtures.
- Use fixed dates, fixed identifiers, fixture factories, in-memory stores, stub services, and development assets.
- Use production fonts, themes, localization paths, and asset-loading behavior whenever they are part of the design being evaluated.

Create only the states needed for the design comparison plus targeted stress states relevant to the change. Do not generate a combinatorial preview matrix by default.

### 4. Match the reference conditions

Before comparing, identify and align these conditions:

- Platform and device or viewport size.
- Orientation and safe-area behavior.
- Light or dark appearance.
- Dynamic Type size.
- Locale and layout direction.
- Content state and representative text length.
- Any navigation bar, tab bar, sheet, list, or container context visible in the design.

Use the design's conditions when specified. Otherwise use the repository's canonical design device or active preview destination, standard Dynamic Type, and the appearance shown by the reference.

For a component, a content-fitting preview can be appropriate. For a full screen, render in a real device-sized context. Do not claim pixel-level fidelity when the reference and render use materially different dimensions, crops, or scale.

### 5. Render the preview without launching the app

Use this precedence:

1. The repository's own preview-render or snapshot command.
2. Xcode's MCP preview-rendering tool, such as `RenderPreview` or the equivalent preview-snapshot tool exposed by the installed Xcode version.
3. A human-visible Xcode canvas render.
4. Full-app Simulator rendering only under the escalation rules below.

Inspect the available tool schema instead of assuming a command name or parameters. Select the named preview and the matching device or variant when the tool supports those inputs.

`xcrun simctl io <device> screenshot ...` is **not** a named SwiftUI preview renderer. It captures whatever is currently displayed by a simulator. Do not present such a screenshot as proof that a particular `#Preview` was rendered unless the preview was actually hosted and displayed through a documented project tool.

If no agent-visible preview renderer is available:

- Keep the preview mandatory in code.
- Run the narrowest build that proves the preview and target compile.
- State that visual comparison is pending a human Xcode render.
- Do not claim that the implementation visually matches the reference.
- Use the full app only when visual proof is required now and no preview-render path is available; record that tooling limitation as the escalation reason.

### 6. Compare the render to the design

Compare the actual rendered preview—not just the source code—against the reference at matching conditions.

Review in this order:

1. Overall hierarchy, frame, safe areas, and major regions.
2. Alignment, padding, gaps, sizing, and relative proportions.
3. Typography: family, weight, size, line height, wrapping, truncation, and baseline alignment.
4. Colors, gradients, materials, borders, shadows, corner radii, and opacity.
5. Images and symbols: asset, rendering mode, aspect ratio, crop, scale, and alignment.
6. State-specific content and visibility.
7. Overflow, clipping, localization expansion, and relevant Dynamic Type behavior.

Use side-by-side viewing, overlay, or image-difference tooling when available. Treat antialiasing and rendering noise separately from substantive layout or styling differences.

Iterate in the preview loop until the preview matches the design within the requested tolerance or a concrete blocker is identified. Do not describe a view as “matching,” “pixel-perfect,” or “visually verified” based only on code inspection.

### 7. Verify at the narrowest appropriate level

After the visual iteration:

- Re-render every canonical preview affected by the change.
- Run the narrowest target, package, or scheme build that verifies compilation.
- Run focused unit or snapshot tests when logic, state derivation, or an established snapshot contract changed.
- Do not run UI tests or launch the full app solely to confirm a static visual change already verified in a preview.
- Do not commit rendered PNGs unless the repository or design contract explicitly requires committed captures.

### 8. Escalate to the full app only for a concrete runtime need

A full Simulator or device run is justified when validation depends on one or more of the following and a live preview cannot reproduce it faithfully:

- App or scene lifecycle, launch routing, restoration, or multi-window behavior.
- Real navigation, deep-link, presentation, tab, or coordinator integration across screens.
- Keyboard, focus, drag-and-drop, complex gesture, scrolling, animation timing, or interaction behavior that cannot be validated in the live preview.
- Permissions, system sheets, camera, Photos, location, StoreKit, notifications, background execution, or other operating-system services.
- Real authentication, networking, database migration, Keychain, entitlements, or app-container state.
- UIKit or AppKit behavior that depends on a real window or controller hierarchy not reproduced by the preview.
- Performance, memory, accessibility-tree, or launch diagnostics.
- A preview-renderer limitation or failure after a bounded repair attempt, when agent-visible visual proof is still required.
- An explicit user request to run the app.

Before launching, state the exact reason the preview is insufficient. Use the smallest existing route to reach the target state, such as an established deep link, fixture account, or debug menu. Do not add a new production bypass or debug route solely for this task without approval or an existing project convention.

After runtime validation, keep the deterministic preview as the fast regression and iteration harness.

## Error Handling

| Problem | Response |
|---|---|
| Missing environment object or dependency | Inject the project's stub, in-memory implementation, or preview fixture. |
| Preview starts network or persistence work | Move the side effect behind an injectable dependency and provide a deterministic preview implementation. |
| Preview changes on every render | Replace current time, randomness, generated IDs, and unordered data with fixed fixtures. |
| Preview is blank, black, or zero-sized | Check compile diagnostics, container sizing, background, asset loading, and the selected preview/device. |
| Preview compile fails because the boundary is too coupled | Make the smallest dependency-explicit refactor; do not jump directly to app launch. |
| Preview renderer is unavailable | Compile the preview, report visual verification as pending, and escalate only if visual proof is required now. |
| Reference dimensions are unknown or incompatible | Match as closely as possible and report the unresolved viewport assumption. |
| Simulator was launched without a concrete reason | Stop, return to the preview workflow, and record that the launch did not provide necessary evidence. |

## Completion Report

Report the result in this format:

```text
Previews: <names created or updated>
Reference conditions: <device/viewport, appearance, type size, locale, state>
Visual comparison: <matched, remaining differences, or pending render>
Verification: <render/build/tests actually completed>
Full app: not launched | launched because <specific preview limitation>
Limitations: <none or explicit unverified items>
```

## Non-Negotiable Rules

- Never fabricate a preview render or screenshot.
- Never claim visual parity without inspecting an actual render at comparable conditions.
- Never treat a generic Simulator screenshot as a named `#Preview` capture.
- Never launch the full app by default for a static SwiftUI design task.
- Never let preview convenience alter production behavior.
