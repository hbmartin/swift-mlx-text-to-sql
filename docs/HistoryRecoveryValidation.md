# History recovery and notice presentation validation

Validated on October 8, 2026, on the existing `codex/history-recovery-review-fixes` branch against starting commit `d1088d3ee1f0f737f88ee267b07e754e59b5b018`. Builds and simulator tests use XcodeBuildMCP, Xcode 27, and the iPhone 18 Pro / iOS 27 simulator (`31B09574-9781-45A7-816D-6A1916E1BA16`). No database migration or dependency change is included.

## Reducer and diagnostic coverage

The expanded focused run passed **119 tests in seven suites**; the final recovery/history/correction/notice rerun passed **112 tests in five suites**. Coverage includes warning-only slow reads, eventual completion with accepted New chat intent, explicit restart and stale-result rejection, background/resume timer generations, deletion during a failed opening, successful store reopening followed by summary-read failure, conditional unread rollback, separate rename/export failures (including Undo recovery), held support builds, stale support completions, and isolated support artifacts. Pending answer sharing retains an export; result viewing and rename presentation also prevent automatic export presentation.

The live-history export regression holds A's actual database export after its snapshot is read, navigates to B, persists two separate questions and their events in A before releasing the held completion, then returns to A. It verifies that the retained snapshot still has one line and that both Export and Share regenerate all three event lines. The strengthened test passed for both request types. Additional tests cover coalescing, pending navigation, inactive completion, notice-panel dismissal during regeneration, Undo/failed/committed deletion outcomes, identity-aware file consumption, aged-file protection, and symlink safeguards. Correction tests verify that typed Send and focus-settled submission capture feedback while chips, follow-ups, Try again, and Ask Again preserve the draft and correction context.

Deletion cleanup tests seed the failure before deleting. Deduplication tests resend the identical failure. A temporary mutation run removed the relevant deletion cleanup and deduplication guard: both tests failed at their targeted assertions. The mutations were restored before the passing focused run. Held-operation helpers retain bounded start backstops and suite time limits.

```sh
xcodebuildmcp swift-package test --package-path CREGKit --parallel false \
  --filter 'HistoryRecoveryRegressionTests|HistoryClientTests|ChatFeatureConversationTests|ConversationNoticeTests|FeatureFailureDiagnosticsTests'
```

The final full Features run completed **571 tests in 36 suites** and reported only four assertions in three existing chart tests:

- `tentativePreferenceRestorationIsAttemptedOnlyOnce`: preference was not restored to `.table`.
- `newerPreferenceWinsDuringRetryRestorationCallback`: retry application was not `.superseded`.
- `retainedStalePreferenceWithSameReplacementIsReconciled`: session restart count and restoration-attempt expectations failed.

The preceding validation recorded all four assertions on untouched `a113d1e` in a separate managed worktree, which was then archived. Comparing `a113d1e` with this request's `d1088d3` baseline shows no changes to the chart migration implementation, `AutoChartIntegrationTests`, or dependency pins. Those handlers and tests remain unchanged by this patch. Result presentation changes forward Dynamic Type, add the harness probe, and allow its title to grow at accessibility sizes. The current failures match the recorded baseline; this run did not repeat the archived baseline experiment.

## Presentation and CI contracts

Passing simulator tests verify notice-panel scrolling, recovery/export control reachability, dismissal and reopening at Large and AX5 in portrait and landscape, and an actual held-export/navigation/completion/share sequence. The final retained-export flow passed in **72 seconds across AX5 portrait and landscape**. It checks that returning does not automatically present sharing, explicitly regenerates through Share, audits the export panel, opens the JSONL in the native share popover, verifies its file caption, cancels native sharing, and dismisses the still-owned export panel. Both answer-sharing return/cancel flows also passed. The root presentation retains its file while a nested native sharing surface covers its content. Its harness uses compact Finish/Return labels with descriptive accessibility labels so the test controls fit AX5. Search text and keyboard focus survive history retry at Large and AX5 in both orientations (55 seconds in the final rerun). The known icon controls pass explicit 44-point checks.

Each root sheet explicitly receives Dynamic Type from its presenting root. A DEBUG-only probe inside the presented content reports its effective value. The probe reported **`accessibility5` inside notices, Settings, and the support fallback in both orientations**, followed by passing hit-region/text-clipping audits (89 seconds in the final rerun). The actual held-export test separately confirmed **`accessibility5` inside the export presentation in both orientations before passing its audits**. This evidence replaces the earlier assumption that a root AX5 override necessarily propagated into sheets. A probe around a native sharing controller reports the SwiftUI environment; it does not verify the controller's internal UIKit font sizes.

The recovery fixture enables the production Reduce Motion branches through a DEBUG-only environment override because SwiftUI's system `accessibilityReduceMotion` value is read-only. This exercises the branch without claiming that simulator system settings were changed. Gesture eligibility and direction-change cancellation also have state-level tests.

The canonical clipping/hit-region selector, sheet-probe selector, bounded drawer-realization selector, keyboard/correction selector, and header-wrapping selector are added to CI and the Python contract checker together.

`testCorrectionControlsRemainReachableWithKeyboardAndReduceMotion` passes at **Large, AX3, and AX5 in portrait and landscape**. It audits the initial recovery layout, opens the keyboard, and checks the correction source link, dismissal, navigation, and notices controls. It follows the source link, dismisses correction, rejects a horizontal flick starting inside a result table in the actual `AppRootView`, and verifies the visible Apple Intelligence Settings instructions. The final rerun passed in 155 seconds. The table-flick assertion now uses the root recovery harness rather than a standalone chat, so the drawer gesture participates in the test. Constrained layouts use a compact footer; narrow layouts move its controls into two rows. Drawer titles and previews wrap, and the support disclosure uses a full-height scrolling sheet.

The full canonical audit exercised **108 layouts** (27 scenarios at Large, AX1, AX3, and AX5). Its first run found six clipping reports: the conversation title at AX5 in recovery, notices, and Apple Intelligence readiness; and the UIKit result-explorer navigation title at AX1, AX3, and AX5. The conversation title now requests its complete wrapped height, and the result title appears in the content at accessibility sizes. A targeted regression subsequently passed **24 layouts** across those four scenarios at AX1, AX3, and AX5 in portrait and landscape (236 seconds in the final rerun), including the visible Settings instructions. In compact layouts, those instructions remain reachable in the transcript. These findings are fixed rather than exempted from the audit. The full 108-layout matrix was not repeated after those fixes. The support-warning AX5 portrait/landscape selector passed separately in 40 seconds.

The answer-actions popover passed its effective-size assertions and hit-region/text-clipping audits at Large and AX5 in both orientations (120 seconds). The scrolling helper constrains transcript gestures to the visible area between header and composer while allowing fixed drawer and panel controls outside their scrollers. It treats the prediction row separately in landscape.

## Optimized drawer realization

`testDrawerRealizationStaysBoundedAndUnrelatedErrorsDoNotRedrawRows` passes on the supported iPhone 18 Pro / iOS 27 simulator with 1,000 summaries: **20 initially realized rows**, **21 row-body evaluations**, and **21 evaluations after injecting and settling an unrelated failure**. Initial realization is below the required 100-row limit. The row probe counts unique `onAppear` identities and all row-body evaluations independently.

The drawer's `CREGFeatures` module was compiled with **`-O`**, preserving DEBUG harness probes. A temporary target-specific compiler flag was restored after the run; no package or pin change is retained. Dependencies used their normal Debug settings. Forcing global `-O` (with either incremental or whole-module compilation) crashed Swift 6.4's IR generator in the pinned `IssueReporting` dependency's `_recordIssue` function. The successful scoped build measures the optimized drawer without claiming that a complete Release dependency graph was validated.

The CI contract checker passes, and its **197 Python tests pass**:

```sh
uv run --project fine-tuning --no-sync python fine-tuning/tools/check_ci_contracts.py
uv run --project fine-tuning --no-sync pytest fine-tuning/tests/test_ci_contracts.py -q
```

Named SwiftUI previews remain available. Validation here uses built simulator applications and XCTest. The scroll helper stops when a gesture makes no progress and permits sufficient scrolling for the full AX5 notice fixture; it does not silently exempt audit findings.

## Previously recorded optimized summary merge measurements

These measurements are retained from the preceding validation against `a113d1e`; they were not rerun for this patch. Release configuration, Apple M2 Pro, macOS 27.0. Fixed fixtures contain 1,000, 5,000, or 10,000 rows. Fixture setup is outside the timed interval. Each implementation receives one warmup followed by seven samples; the table reports medians. The comparison reproduces the previous observable collection assignment per row and compares it with the local merge, one sort, and one assignment. Other local validation was running, so these are local measurements rather than CI timing guarantees.

| Rows | Previous merge | Optimized merge | Speedup |
| ---: | ---: | ---: | ---: |
| 1,000 | 56.134 ms | 2.628 ms | 21.36× |
| 5,000 | 1,300.252 ms | 12.906 ms | 100.75× |
| 10,000 | 5,251.040 ms | 26.190 ms | 200.50× |

```sh
CREG_MERGE_BENCHMARK=1 xcodebuildmcp swift-package test \
  --package-path CREGKit --configuration release \
  --filter HistorySummaryMergePerformanceTests --parallel false
```
