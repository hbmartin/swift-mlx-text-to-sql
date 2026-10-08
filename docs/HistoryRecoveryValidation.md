# History recovery and notice presentation validation

Validated on the existing `codex/history-recovery-review-fixes` branch against starting commit `a113d1e`, using XcodeBuildMCP, Xcode 27, and an iPhone simulator. No database migration or dependency change is included.

## Reducer and diagnostic coverage

The focused run passed **215 tests in eight suites**. It covers request ownership, initial-load timeout and retry, immediate/coalesced New chat, deletion during an opening, obsolete creation settlement, optimistic summary preservation, retry-error retirement, exact-owner saving/drain warning cleanup, retained exports, diagnostic redaction, and dismissal logging.

The A → B → A selection race, deletion during another opening, and export completion after switching conversations each run ten times. Held-operation helpers have five-second start backstops and the recovery suite has a one-minute limit. The strengthened Undo tests explicitly check the resulting failure state.

```sh
xcodebuildmcp swift-package test --package-path CREGKit --parallel false \
  --filter 'HistoryRecoveryRegressionTests|DiagnosticsAndFailurePresentationTests|ReviewFixRegressionTests|LifecycleOwnershipTests|RetrySettlementRegressionTests|FeatureFailureDiagnosticsTests|AppFeatureSchedulerTests|AccessibilityUITestConfigurationTests'
```

The final full serialized package run completed. Core (34), Engine (79), Data (59), Inference (62), and SQL runtime router (1) tests passed. The Features run (547 tests) reported four assertions in three chart tests:

- `tentativePreferenceRestorationIsAttemptedOnlyOnce`: preference was not restored to `.table`.
- `newerPreferenceWinsDuringRetryRestorationCallback`: retry application was not `.superseded`.
- `retainedStalePreferenceWithSameReplacementIsReconciled`: session restart count and restoration-attempt expectations failed.

All four assertions reproduced when those three tests ran on untouched starting commit `a113d1e` in a separate managed worktree. That worktree was archived after validation. Chart implementation and these tests are unchanged by this work.

## Presentation and CI contracts

The actual simulator harness verifies compact notices, scrolling to recovery/export controls, notice dismissal and reopening, retained-export sharing and consumption, opening-failure recovery, history retry, interrupted-turn inspection, and 44-point controls. The notice panel is checked at standard size and AX5 in portrait and landscape, including XCTest hit-region and text-clipping audits. Search text and keyboard focus survive history retry at those same four combinations. The search field stays outside the scrolling recovery content; the brand heading collapses while search is focused. Retry appears before New chat so a disabled creation control does not push recovery out of the landscape viewport. Vertical scrolling coexists with the horizontal drawer gesture, and swiping the dimmed foreground chat closed and reopening the browser are checked. The focused CI test list and its Python contract checker are updated together.

The CI contract checker passes, and its **197 Python tests pass**:

```sh
uv run --project fine-tuning --no-sync python fine-tuning/tools/check_ci_contracts.py
uv run --project fine-tuning --no-sync pytest fine-tuning/tests/test_ci_contracts.py -q
```

Named SwiftUI previews cover compact notices, stacked content, the full panel, and retained exports. Xcode's native preview renderer required agent authorization that was unavailable in this session; simulator builds and actual UI harness tests supplied layout verification instead.

The settle helper now stops when a gesture makes no progress and reports an unreachable control clearly. In the local known-icon validation, the first processing-queue Stop lookup went from 12 ineffective drags to zero. This is an observed lookup improvement, not a projection of total CI savings; the supplied 25–50 second estimate is not adopted.

## Optimized summary merge measurements

Release configuration, Apple M2 Pro, macOS 27.0. Fixed fixtures contain 1,000, 5,000, or 10,000 rows. Fixture setup is outside the timed interval. Each implementation receives one warmup followed by seven samples; the table reports medians. The comparison reproduces the previous observable collection assignment per row and compares it with the new local merge, one sort, and one assignment. Other local validation was running, so these are local measurements rather than CI timing guarantees.

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

The unspecified review note about an assertion that can never fail remains unverified because its exact location was not supplied. No speculative assertion change is included.
