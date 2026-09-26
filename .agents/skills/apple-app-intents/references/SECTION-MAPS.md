# Section maps for the deep reference guides

The deep guides are bundled with this skill. Each entry links the local file, then lists every **top-level** (`##`) section as an anchor; a guide's own `## Contents` lists its subsections. Open the narrowest relevant section first.

> Generated 2026-09-22 from the guide headings. Regenerate with `./scripts/build-skills.sh` rather than editing by hand.

## Part 16 — Adjacent capabilities

### 16.2 — App Schema Domains: the complete map of what Siri can actually do

The enumeration is the product: **all 23 domains in three tiers — 182 intents, 74 entities and 50 enums, censused symbol-by-symbol against the macOS 27.0 beta SDK interface on 2026-07-29** — in one place for the first time, with per-domain commentary on what each one's shape tells you.

**Local reference:** [part-16-adjacent-capabilities/references/02-app-schema-domains.md](part-16-adjacent-capabilities/references/02-app-schema-domains.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| ⚠️ Read this before you trust a symbol name below | `#️-read-this-before-you-trust-a-symbol-name-below` |
| Contents | `#contents` |
| 1. Three systems people conflate | `#1-three-systems-people-conflate` |
| 2. Discovery versus action — the framing everything else follows from | `#2-discovery-versus-action--the-framing-everything-else-follows-from` |
| 3. The macro system, and the build errors it generates | `#3-the-macro-system-and-the-build-errors-it-generates` |
| 4. The three tiers, and what each one reaches | `#4-the-three-tiers-and-what-each-one-reaches` |
| 5. The complete enumeration — all 23 domains | `#5-the-complete-enumeration--all-23-domains` |
| 6. The absences — what has no domain at all | `#6-the-absences--what-has-no-domain-at-all` |
| 7. Deprecations, and where generic search went | `#7-deprecations-and-where-generic-search-went` |
| 8. `.system.searchInApp` — the escape hatch | `#8-systemsearchinapp--the-escape-hatch` |
| 9. Decision tree: which route is open to you | `#9-decision-tree-which-route-is-open-to-you` |
| 10. Query protocols and how entity resolution works | `#10-query-protocols-and-how-entity-resolution-works` |
| 11. Shaping the response: dialog, questions, and snippets | `#11-shaping-the-response-dialog-questions-and-snippets` |
| 12. Donations, confirmations, and entity ownership | `#12-donations-confirmations-and-entity-ownership` |
| 13. The new execution model | `#13-the-new-execution-model` |
| 14. Silent failures | `#14-silent-failures` |
| 15. Testing: the four-stage ladder | `#15-testing-the-four-stage-ladder` |
| 16. Gap register | `#16-gap-register` |
| 17. Sources | `#17-sources` |

### 16.3 — On-screen awareness: making Siri understand "this"

This guide exists to answer two live forum threads Apple did not: a cycling app whose `AppEntity` executes but which Siri answers from screen text, and an image app whose `entities(for:)` **never fires**.

**Local reference:** [part-16-adjacent-capabilities/references/03-onscreen-awareness.md](part-16-adjacent-capabilities/references/03-onscreen-awareness.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| ⚠️ Read this before you trust a symbol name below | `#️-read-this-before-you-trust-a-symbol-name-below` |
| Contents | `#contents` |
| 1. The two paths | `#1-the-two-paths` |
| 2. `EntityIdentifier` | `#2-entityidentifier` |
| 3. The four annotation shapes | `#3-the-four-annotation-shapes` |
| 4. Fast resolution | `#4-fast-resolution` |
| 5. Handing content to another app | `#5-handing-content-to-another-app` |
| 6. Beyond the screen | `#6-beyond-the-screen` |
| 7. Adoption order and the diagnostic playbook | `#7-adoption-order-and-the-diagnostic-playbook` |
| 8. Silent failures | `#8-silent-failures` |
| 9. A complete worked integration | `#9-a-complete-worked-integration` |
| 10. What is still open | `#10-what-is-still-open` |
| 11. Gap register | `#11-gap-register` |
| 12. Sources | `#12-sources` |

### 16.4 — One index, three consumers: entities, Spotlight, and Foundation Models

Session 246's one-line prerequisite — *"donated searchable items to Core Spotlight, **or indexed entities for Apple Intelligence**"* — left a second on-ramp nobody could identify.

**Local reference:** [part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| ⚠️ Read this before you trust a symbol name below | `#️-read-this-before-you-trust-a-symbol-name-below` |
| Contents | `#contents` |
| 1. The question, and its answer | `#1-the-question-and-its-answer` |
| 2. The thesis: one index, three consumers | `#2-the-thesis-one-index-three-consumers` |
| 3. On-ramp A: `CSSearchableItem` donation | `#3-on-ramp-a-cssearchableitem-donation` |
| 4. On-ramp B: `IndexedEntity` and `indexAppEntities(_:)` | `#4-on-ramp-b-indexedentity-and-indexappentities_` |
| 5. Where the two on-ramps differ | `#5-where-the-two-on-ramps-differ` |
| 6. Consumer 1 — Siri entity resolution | `#6-consumer-1--siri-entity-resolution` |
| 7. Consumer 2 — `SpotlightSearchTool`, i.e. your own model | `#7-consumer-2--spotlightsearchtool-ie-your-own-model` |
| 8. Consumer 3 — Spotlight search itself | `#8-consumer-3--spotlight-search-itself` |
| 9. The hydration hook, and why it exists | `#9-the-hydration-hook-and-why-it-exists` |
| 10. 🔴 The gap that stays open | `#10--the-gap-that-stays-open` |
| 11. Session 343's three retrieval paths | `#11-session-343s-three-retrieval-paths` |
| 12. `RelevantEntities` — the third discovery mechanism | `#12-relevantentities--the-third-discovery-mechanism` |
| 13. Failure modes, four of them silent | `#13-failure-modes-four-of-them-silent` |
| 14. The adoption sequence | `#14-the-adoption-sequence` |
| 15. Gap index, evidence ledger, related guides | `#15-gap-index-evidence-ledger-related-guides` |
