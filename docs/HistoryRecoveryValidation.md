# History recovery and notice presentation validation

## Review-comment follow-up (October 10, 2026)

Implemented against `8c68a224a52f4711e5d547934ea72e2d41ffc70b`. CI contracts now inspect clustered shell command options (`-lc`, `-ec`, `-fc`) and reject simulator create/boot commands, including supported shell wrappers. Both Swift dependency steps explicitly use `bash` in `${{ github.workspace }}`; their contracts reject reviewed job/step context overrides and report a shared job violation once. README build guidance now describes local XcodeBuildMCP validation.

`FailurePresentation.allowsConversationWriteRetry` defaults to true and is preserved conservatively when failures combine. A missing result-presentation fallback uses `history_result_preference_message_missing` with permanent recovery copy and retry eligibility false. Retry filtering and the owner projection use the same eligibility. Repeated retries and duplicate settlements preserve the blocked edit, revision, session preference, and notice occurrence without storage access. A fresh selection, including selection of the same display option, captures a valid message and can save. Retryable sibling targets remain eligible; their action on a permanent owner's notice is labeled “Retry other display choices.” Settlement/action shapes, persisted formats, title normalization, and existing duplicate-delivery behavior are unchanged.

Drawer row capture is now a non-observable MainActor reference owned by the performance fixture and injected through a DEBUG environment value defaulting to nil. Counters, accessibility identifiers, and the 200 ms polling interval are preserved. Independent instances using the same row ID and reset isolation have package coverage. The existing UI performance selector realized **20 rows**, recorded **21 initial row bodies**, and verified that an unrelated error did not change the render count.

The focused package run passed **135 tests in six suites** (`PR158RegressionFixTests`, `ConversationNoticeTests`, `HistoryRecoveryRegressionTests`, `DiagnosticsAndFailurePresentationTests`, `FeatureFailureDiagnosticsTests`, and `AccessibilityUITestConfigurationTests`; 43.482 seconds of test execution, 122.9 seconds through XcodeBuildMCP). New regressions cover permanent copy/combined eligibility, no-storage repeated retries, fresh selection recovery, mixed preference targets, Undo/failed/committed deletion, fixture isolation, and the two explicitly reviewed harness scenarios.

The initial four-selector UI run passed **3 tests** and failed the new mixed-owner selector at its post-retry lookup: XCTest's identifier shorthand rejects strings longer than 128 characters. The lookup now uses an exact identifier predicate, retaining the same disappearance assertion and product identifier. The affected selector passed its focused retest (**1 test, 0 failures**, 72.2 seconds through XcodeBuildMCP), covering both notices and Settings at AX5 with the existing accessible-control assertions. All four selected UI tests therefore passed across the initial run and retest. This was a new test-query failure, not an existing baseline failure.

The CI contract checker, package-pin checker, and whitespace check pass. **169 Python CI-contract tests pass** (2.01 seconds), including shell/simulator rejection, retained-work acceptance, both required steps' skipped/missing/changed mutations, and reviewed Swift job/step context overrides. No existing baseline failures occurred in the selected checks. The four historical chart assertions remain untouched and were not rerun. Compiler warnings remain in the build logs; no assertion was suppressed or weakened.

Before testing, CLI help, tool-specific help, repository/session-default loading, and simulator inventory were inspected. No repository `.xcodebuildmcp/config.yaml` was present; package/project paths and the selected scheme, configuration, and simulator were explicit. The existing iPhone 18 Pro / iOS 27 simulator (`31B09574-9781-45A7-816D-6A1916E1BA16`) was reused and preserved. No full Apple suite or canonical accessibility matrix was run, and no Apple execution or simulator provisioning was added to CI.

Commands were run from `/Users/haroldmartin/Downloads/creg/swift-mlx-text-to-sql`:

```sh
uv run --project fine-tuning --no-sync python fine-tuning/tools/check_ci_contracts.py
uv run --project fine-tuning --no-sync python -m pytest fine-tuning/tests/test_ci_contracts.py -q
uv run --project fine-tuning --no-sync python fine-tuning/tools/check_swift_package_pins.py
git diff --check

xcodebuildmcp swift-package test --package-path "$PWD/CREGKit" --filter 'PR158RegressionFixTests|ConversationNoticeTests|HistoryRecoveryRegressionTests|DiagnosticsAndFailurePresentationTests|FeatureFailureDiagnosticsTests|AccessibilityUITestConfigurationTests' --parallel false

xcodebuildmcp simulator test \
  --project-path "$PWD/CREG.xcodeproj" --scheme CREG --configuration Debug \
  --simulator-id 31B09574-9781-45A7-816D-6A1916E1BA16 \
  --extra-args \
  '-only-testing:CREGUITests/AccessibilityUITests/testConversationWriteInvariantHasNoRetryInNoticesAndSettings' \
  '-only-testing:CREGUITests/AccessibilityUITests/testConversationWriteInvariantAllowsRetryOfOtherDisplayChoices' \
  '-only-testing:CREGUITests/AccessibilityUITests/testConversationWriteRecoveryOffersRetryInNoticesAndSettings' \
  '-only-testing:CREGUITests/AccessibilityUITests/testDrawerRealizationStaysBoundedAndUnrelatedErrorsDoNotRedrawRows' \
  '-skipPackagePluginValidation' '-skipMacroValidation' \
  'CODE_SIGNING_ALLOWED=NO' 'CREG_ACCESSIBILITY_HARNESS_BUILD=YES'

xcodebuildmcp simulator test \
  --project-path "$PWD/CREG.xcodeproj" --scheme CREG --configuration Debug \
  --simulator-id 31B09574-9781-45A7-816D-6A1916E1BA16 \
  --extra-args \
  '-only-testing:CREGUITests/AccessibilityUITests/testConversationWriteInvariantAllowsRetryOfOtherDisplayChoices' \
  '-skipPackagePluginValidation' '-skipMacroValidation' \
  'CODE_SIGNING_ALLOWED=NO' 'CREG_ACCESSIBILITY_HARNESS_BUILD=YES'
```

| Run | Retained artifact |
| --- | --- |
| Focused package build/test | `/Users/haroldmartin/Library/Developer/XcodeBuildMCP/workspaces/swift-mlx-text-to-sql-364a2f3c2256/logs/swift_package_test_2026-10-10T22-17-00-468Z_pid47114_463f5428.log` |
| Package test detail | `/Users/haroldmartin/Library/Developer/XcodeBuildMCP/workspaces/swift-mlx-text-to-sql-364a2f3c2256/logs/swift_package_test_parser-debug_2026-10-10T22-19-03-384Z_pid47114_f7c5a1cb.log` |
| Initial four-selector UI result | `/Users/haroldmartin/Library/Developer/XcodeBuildMCP/workspaces/swift-mlx-text-to-sql-364a2f3c2256/result-bundles/test_sim_2026-10-10T22-17-48-829Z_pid52921_adc04113.xcresult` |
| Initial UI build/test log | `/Users/haroldmartin/Library/Developer/XcodeBuildMCP/workspaces/swift-mlx-text-to-sql-364a2f3c2256/logs/test_sim_2026-10-10T22-17-48-829Z_pid52921_22bc2b94.log` |
| Mixed-owner UI retest result | `/Users/haroldmartin/Library/Developer/XcodeBuildMCP/workspaces/swift-mlx-text-to-sql-364a2f3c2256/result-bundles/test_sim_2026-10-10T22-21-36-418Z_pid76693_9cc70e70.xcresult` |
| Retest build/test log | `/Users/haroldmartin/Library/Developer/XcodeBuildMCP/workspaces/swift-mlx-text-to-sql-364a2f3c2256/logs/test_sim_2026-10-10T22-21-36-418Z_pid76693_857915b5.log` |
| Package/UI CLI summaries | `/tmp/creg-review-fixes-2026-10-10-package-tests.log`, `/tmp/creg-review-fixes-2026-10-10-ui-tests.log`, `/tmp/creg-review-fixes-2026-10-10-ui-retest.log` |
| CI checker, Python tests, package pins, whitespace | `/tmp/creg-review-fixes-2026-10-10-ci-contract-check.log`, `/tmp/creg-review-fixes-2026-10-10-ci-contract-tests.log`, `/tmp/creg-review-fixes-2026-10-10-package-pins.log`, `/tmp/creg-review-fixes-2026-10-10-whitespace.log` |


## Local Apple testing policy and conversation recovery (October 10, 2026)

Apple tests now run locally through XcodeBuildMCP. CI retains Swift dependency pin agreement and checked-in package resolution, Python tests and corpus/schema checks, publisher contracts, security guards, and DocC generation. The accessibility shards, aggregate job, simulator provisioning/cleanup, Swift test step, and dependency job's Metal download are removed. CI contracts reject Apple test execution in any workflow and restoration of the removed accessibility jobs. Documentation builds retain their Metal toolchain requirement.

The root `AGENTS.md` requires affected package suites and UI selectors; full Apple suites and the canonical accessibility matrix require an explicit user request. Compatible simulators are reused, and commands, results, and artifact paths must be reported. No schema, dependency pin, or persistence format changes are included. The previously reported ghost-message retry and stale drag eligibility sequences remain deferred; gesture eligibility and release behavior are unchanged.

Missing preference-message fallbacks throw a typed invariant error and settle through the normal failure path without storage access. Root rename delegates normalize titles before optimistic display and persistence, ignoring empty normalized titles. Accepted rename/export failures and each feedback failure create a new notice occurrence. Duplicate settlements keep identity and ordering. Pending deletion carries per-owner occurrence intent, replacing and moving fresh deferred failures; Undo and failed deletion restore it, while committed deletion records diagnostics. Draft/preference settlements follow the same rule.

Preference saves use `history_result_preference_save_failed`, distinct from message saves. Per-operation copy is centralized before diagnostics, cause, and recovery are attached. Draft/preference copy is retained for unavailable history; other operations retain generic unavailable-history copy. Drawer interpolation capture is a fixture-owned, non-observable MainActor reference injected through a DEBUG environment value defaulting to nil. Sampling, reset behavior, accessibility format, and the 160-sample bound are preserved.

The final focused package run passed **118 tests in five suites** (`PR158RegressionFixTests`, `ConversationNoticeTests`, `HistoryRecoveryRegressionTests`, `DiagnosticsAndFailurePresentationTests`, and `FeatureFailureDiagnosticsTests`; 69.3 seconds including build overhead). This includes a no-storage invariant failure, direct delegate normalization with whitespace/newlines/long Unicode/empty titles, owner-specific retry success, A → B → fresh identical A ordering and displayed-notice dismissal, duplicate settlements, and deterministic held draft/preference/rename/export/feedback failures across Undo, failed deletion, and committed deletion. Probe tests verify nil environment defaults, independent instances, reset behavior, and the sample bound.

The CI checker, package-pin checker, and whitespace check pass; **129 Python CI-contract tests pass** (3.38 seconds). No existing baseline failures occurred in these focused checks. The four historical chart assertions described below were outside the selected suites and were not rerun. No full Apple suite was run.

Commands were run from the repository root:

```sh
xcodebuildmcp swift-package test --package-path "$PWD/CREGKit" --filter 'PR158RegressionFixTests|ConversationNoticeTests|HistoryRecoveryRegressionTests|DiagnosticsAndFailurePresentationTests|FeatureFailureDiagnosticsTests' --parallel false
xcodebuildmcp simulator test --project-path "$PWD/CREG.xcodeproj" --scheme CREG --configuration Debug --simulator-id 31B09574-9781-45A7-816D-6A1916E1BA16 --extra-args '-only-testing:CREGUITests/AccessibilityUITests/testDrawerCancellationAllowsTheFirstFollowingSwipe' '-only-testing:CREGUITests/AccessibilityUITests/testNoticeTechnicalDetailsKeepFailureIdentity' '-only-testing:CREGUITests/AccessibilityUITests/testHistoryProgressWarningsAreNeutralOnEverySurface' '-only-testing:CREGUITests/AccessibilityUITests/testConversationWriteRecoveryOffersRetryInNoticesAndSettings' '-skipPackagePluginValidation' '-skipMacroValidation' 'CODE_SIGNING_ALLOWED=NO' 'CREG_ACCESSIBILITY_HARNESS_BUILD=YES'
uv run --project fine-tuning --no-sync python fine-tuning/tools/check_ci_contracts.py
uv run --project fine-tuning --no-sync python -m pytest fine-tuning/tests/test_ci_contracts.py -q
uv run --project fine-tuning --no-sync python fine-tuning/tools/check_swift_package_pins.py
git diff --check
```

The first four-selector UI run passed notice identity and neutral history warnings. It exposed two test-expectation issues: recovery still searched for the old message-save code, and an added immediate-reset assertion expected a redraw from a non-observable probe. The recovery selector now uses the new preference code; reset is checked on the next interpolated sample, while the unit test checks reset directly. Both affected selectors were rerun with the same command and build settings, retaining only their two `-only-testing` arguments. The two-selector retest passed **2 tests, 0 failures** in **134.4 seconds**, so all four requested selectors passed across the initial run and retest. The existing iPhone 18 Pro / iOS 27 simulator was preserved. Drawer capture recorded **11/12 spring** and **10/10 Reduce Motion** opening/closing rollback frames; the opposite counter stayed zero after each reset.

| Run | Retained artifact |
| --- | --- |
| Final focused package | `/Users/haroldmartin/Library/Developer/XcodeBuildMCP/workspaces/swift-mlx-text-to-sql-364a2f3c2256/logs/swift_package_test_2026-10-10T17-38-42-443Z_pid60413_11d32032.log` |
| Initial four-selector UI run | `/Users/haroldmartin/Library/Developer/XcodeBuildMCP/workspaces/swift-mlx-text-to-sql-364a2f3c2256/result-bundles/test_sim_2026-10-10T17-37-42-420Z_pid54378_5397aadd.xcresult` |
| Drawer and write-recovery retest | `/Users/haroldmartin/Library/Developer/XcodeBuildMCP/workspaces/swift-mlx-text-to-sql-364a2f3c2256/result-bundles/test_sim_2026-10-10T17-40-35-732Z_pid73100_765c22d9.xcresult` |
| CI checker, Python tests, package pins, whitespace | `/tmp/creg-recovery-2026-10-10/ci-contract-check.log`, `/tmp/creg-recovery-2026-10-10/ci-contract-tests.log`, `/tmp/creg-recovery-2026-10-10/package-pin-check.log`, `/tmp/creg-recovery-2026-10-10/whitespace-check.log` |

Historical runs below remain historical evidence; their full-suite execution and CI policy do not authorize new full-suite runs.

## Conversation edit ledger and drawer follow-up (October 9, 2026)

Implemented from `48008632aab14af7b558e20e5dbabec0955bed22` on `codex/history-recovery-review-fixes`. This follow-up addresses comments **1–7, 10, 11, and 14**. Shared CI builds and the broader modal-retention, support-sheet identity, and temporary-file refactors from **8, 9, 12, and 13** remain deferred. No schema, dependency, or recovery-journal change is included.

The root now retains the latest draft and per-message presentation preference for this app session, including acknowledged writes. Loads overlay these fields onto the snapshot. Failed writes offer Retry saving in notices and Settings; dismissal keeps the edit.

Deterministic clocks and held saves cover return before debounce, navigation during a save, stale loads after success, newer edits overtaking older callbacks, submission clearing, retry failure/success and repeated pending taps, migration compare-and-set guards, multiple preference targets, notice dismissal, Undo, failed deletion, and committed deletion. Held operations have bounded start checks and release backstops. Committed deletion also prunes retained edits and cancels pending draft timers.

The drawer keeps finger tracking unanimated and uses an animated gesture-state reset. A separate release snapshot and live scene/modal guards remove reliance on gesture-reset ordering. Failure rows use owner plus occurrence identity: duplicate delivery preserves expansion, replacement collapses, and surviving rows retain expansion. Slow-history failures carry informational severity. Rename keeps normalization before optimistic display and at storage; redundant retention/normalization and the unused child failure route are removed.

The final focused XcodeBuildMCP package run passed **45 tests in four suites** (`ConversationNoticeTests`, `PR158RegressionFixTests`, `AccessibilityUITestConfigurationTests`, and `FeatureFailureDiagnosticsTests`; 42.3 seconds including build/test overhead). The final serial full package run completed **840 tests across 65 suites**, including 605 feature tests, with only the **four recorded baseline assertions in three chart tests**. Both opt-in performance tests were skipped. The failures are `tentativePreferenceRestorationIsAttemptedOnlyOnce`, `newerPreferenceWinsDuringRetryRestorationCallback`, and the two assertions in `retainedStalePreferenceWithSameReplacementIsReconciled`; they match the existing baseline recorded below and in [base-branch CI](https://github.com/hbmartin/swift-mlx-text-to-sql/actions/runs/37801842772). This follow-up updates preference-persistence fixtures without changing those assertions or the chart migration handlers.

Four affected simulator selectors passed together on iPhone 18 Pro / iOS 27 through XcodeBuildMCP in **175.7 seconds**:

- `testDrawerCancellationAllowsTheFirstFollowingSwipe`
- `testNoticeTechnicalDetailsKeepFailureIdentity`
- `testHistoryProgressWarningsAreNeutralOnEverySurface`
- `testConversationWriteRecoveryOffersRetryInNoticesAndSettings`

The retry selector exercises both draft and preference notices plus the production Settings sheet at effective AX5, including 44-point controls. The drawer selector covers short opening/closing releases, directional cancellation, Settings interruption, the first subsequent edge swipe, and both motion policies. After tightening the final live release guard, that selector passed again in **85.3 seconds**. The complete canonical matrix was not rerun for this follow-up.

| Final run | Retained XcodeBuildMCP artifact |
| --- | --- |
| Focused package | `swift_package_test_2026-10-09T21-11-14-123Z_pid39288_b573a82e.log` |
| Full package | `swift_package_test_2026-10-09T21-14-40-481Z_pid71217_38e1e41a.log` |
| Four simulator selectors | `test_sim_2026-10-09T21-17-30-590Z_pid89611_995b32a6.xcresult` |
| Final drawer guard retest | `test_sim_2026-10-09T21-21-03-312Z_pid99140_ad89998f.xcresult` |

These artifacts are retained beneath `/Users/haroldmartin/Library/Developer/XcodeBuildMCP/workspaces/swift-mlx-text-to-sql-364a2f3c2256/`, in `logs/` and `result-bundles/`. The existing simulator (`31B09574-9781-45A7-816D-6A1916E1BA16`) was preserved.

[Drawer rollback presentation samples](artifacts/drawer-rollback-motion.csv) retain **381 samples across four gestures** from a passing simulator run. The DEBUG capture modifier drives the actual chat offset with its animatable presentation value. Spring opening/closing rollbacks contain 19/11 intermediate frames; Reduce Motion opening/closing contain 10/10, reaching their endpoints in approximately 174/167 ms. This verifies interpolation rather than observing only endpoint state. XcodeBuildMCP video export was unavailable because its recording helper could not find the expected SimulatorKit framework; no video is claimed.

Each accessibility CI shard now creates its own ephemeral iPhone 18 Pro / iOS 27 simulator. Its name includes run, attempt, and shard; both build and test target the returned UDID. Cleanup always attempts shutdown and deletion after testing. The three-shard matrix, required aggregate check, budgets, and distinct result artifacts remain in place. Adding the retry selector brings the reviewed union to **36 selectors**, covered exactly once across canonical (1), interactions-a (18), and interactions-b (17).

The local CI checker passes, and **223 Python contract tests pass** (3.03 seconds). Mutation checks enforce creation, isolated naming, runtime/device, exported UDID, build/test destinations, unconditional cleanup, cleanup ordering, and complete selector coverage. CI provisioning itself has not been run on GitHub for these commits.

```sh
uv run --project fine-tuning --no-sync python fine-tuning/tools/check_ci_contracts.py
uv run --project fine-tuning --no-sync pytest fine-tuning/tests/test_ci_contracts.py -q
```

The earlier validation sections below describe historical code and runs before this follow-up.

## Earlier October 9 validation (before the edit ledger)

Implemented on `codex/history-recovery-review-fixes` from `b2a7b1911b4de672169a02e188c228b50bcf7577`. Comment #15's destination refactor remains deferred. Schema and dependency pins remain unchanged.

Draft and result-preference effects now belong to the root. Draft edits carry revisions allocated before delegation; the root owns the 500 ms timer and rejects delayed older delegates after submission clearing. Draft and message revisions use distinct queue targets. Accepted writes outlive chat removal, and actual errors retain separate operation owners through Undo and failed deletion or become diagnostics after committed deletion. Writes rejected before starting after committed deletion are discarded. Held-write tests cover all these outcomes; additional navigation tests verify values reloaded from a real SQLite history database.

Opening any competing modal during an export retains the request until explicit Share. This applies to Settings, Notices, result viewing, Rename, Delete confirmation, answer More and answer sharing, including opening and closing before export completion. Explicit Share regenerates and may replace its originating Notices sheet; opening another surface retains it again. Active conversation loading blocks automatic presentation, while failed opening preserves recovery controls and permits exports. Request identities, coalescing, file leases and stale-completion checks remain intact.

Support dismissal captures its identity before presentation state is cleared, with a root fallback when content never appeared. Cleanup runs once per launch and completes before the first support build: it removes abandoned UUID-named directories and legacy staging/ZIP paths, rejects symlinks, restricts removal to direct owned temporary paths and protects active artifacts. Existing 24-hour conversation-export aging is preserved. Fixture-directory, relaunch, protected-file, foreign-path and symlink tests pass.

Drawer translation and directional eligibility are gesture state. A simulator regression presents Settings during a recognized slow edge drag, dismisses Settings and verifies that the first following swipe opens the browser. Notices use semantic identities, show “History unavailable” after a dismissed failure, and classify slow-history warnings neutrally on chat, Settings and unavailable screens. Manual renames normalize before optimistic display and storage, including idempotent trimming at the 80-grapheme cap. Excerpts retain complete boundary words, count the ellipsis within 120/60 graphemes and only retreat inside a word when at least half the budget remains useful.

Accessibility scrolling identifies a control's owning scroller from the hierarchy. Fixed controls use the unobscured window and never cause transcript gestures. Gesture lanes respect window, keyboard and full-width chrome bounds while routing around partial overlays; unusable geometry and lack of progress produce retained screenshots and diagnostics. Compact near-height controls settle their tap centers, avoiding alternating overshoots; clipping/hit-region audit findings remain failures.

CI runs the entire canonical matrix in its own shard and distributes every other reviewed selector between two alphabetically alternating interaction shards. There are **35 selectors**, with no omitted or duplicated shard membership, and **34 canonical scenarios / 136 audited layouts**. Each shard has a 30-minute build step, 60-minute test step and 105-minute job limit. Matrix fail-fast is disabled; artifact names include the shard. The aggregate **Accessibility UI contracts** required check runs even after failures and requires every shard to succeed. Exact-command and mutation contracts check membership, budgets, skip arguments, artifacts and aggregate behavior.

The Darwin allocator subprocess regression passes six repeated subprocesses, each exercising eight fresh threads while the logger is active, owner-only byte/count accounting, previous-logger chaining and logger restoration. The documented scoped-optimization benchmark passed twice without crashes. Dependencies kept Debug settings, and both temporary `-O` flags were restored afterward.

| Run | Reviewed reads | Shared reads | Allocations (reviewed / shared) | Requested bytes (reviewed / shared) |
| --- | ---: | ---: | ---: | ---: |
| 1 | 3.82029 ms | 0.00322 ms | 78 / 5 | 597,872 / 3,880 |
| 2 | 3.77865 ms | 0.00280 ms | 78 / 5 | 597,872 / 3,880 |

These are seven-sample medians with one warmup on Apple M2 Pro / macOS 27, under concurrent local validation load, using the existing 1,000-row fixture and requested-byte semantics. They measure projection reads rather than rendering latency.

A focused run passed **68 tests in six suites**, including real-database navigation persistence; a subsequent 15-test run verified notice insertion/removal identities and the root regressions. The final full Swift package run completed **829 tests across 65 suites**, including 594 feature tests, the explicit support-dismissal-before-appearance regression and validation of the isolated Developer Mode fixture option, with only the four enabled baseline chart assertions below. Both opt-in performance tests were skipped in the ordinary full run. Python CI contracts and the repeated allocator regression passed **211 tests**.

The final three-shard simulator suite passed **all 35 reviewed CI selectors**, with zero failures or skipped selected tests. The canonical shard audited every one of the **136 layouts** (34 scenarios at Large, AX1, AX3 and AX5). The four originally failing selectors and all three new regression selectors passed in their complete interaction shards. All audit findings remain failures; no chart assertion or accessibility audit is suppressed.

| Shard | Selected tests / coverage | XcodeBuildMCP duration | Result bundle |
| --- | --- | ---: | --- |
| canonical | 1 selector / 136 audited layouts | 1,570.3 s | `test_sim_2026-10-09T17-03-26-614Z_pid63747_e4f7073f.xcresult` |
| interactions-a | 17 selectors | 1,497.2 s | `test_sim_2026-10-09T16-46-14-156Z_pid26338_8a102178.xcresult` |
| interactions-b | 17 selectors | 1,474.6 s | `test_sim_2026-10-09T16-46-14-157Z_pid26337_4f7e578a.xcresult` |

These final runs used the exact CI selector union and each shard's exclusion arguments through XcodeBuildMCP, on separate iPhone 18 Pro / iOS 27 simulators and build directories. Durations include build and test overhead. The tool retained result bundles and logs in its workspace artifact directories. Both temporary simulators were removed afterward; the original simulator remains available. A final package-pin check and `git diff --check` passed, and the current branch, package manifest and dependency resolutions remain unchanged.

The four baseline chart assertions remain enabled and unchanged: `tentativePreferenceRestorationIsAttemptedOnlyOnce`, `newerPreferenceWinsDuringRetryRestorationCallback`, and two assertions in `retainedStalePreferenceWithSameReplacementIsReconciled`. They also failed independently in [base-branch CI](https://github.com/hbmartin/swift-mlx-text-to-sql/actions/runs/37801842772). This patch updates persistence tests in the same file but does not change those four assertions or their chart handlers.

The earlier validation notes below describe historical runs and their then-current CI budgets and coverage.

Validated on October 8, 2026, on the existing `codex/history-recovery-review-fixes` branch against starting commit `d1088d3ee1f0f737f88ee267b07e754e59b5b018`. Builds and simulator tests use XcodeBuildMCP, Xcode 27, and the iPhone 18 Pro / iOS 27 simulator (`31B09574-9781-45A7-816D-6A1916E1BA16`). No database migration or dependency change is included.

## PR #158 follow-up against `630d471`

The follow-up preserves the schema, dependencies, durable settlement, export coalescing and database-read snapshots. Feedback persistence now runs in the root reducer: held-write tests showed that an optional chat reducer cancels its effects when deletion removes the chat, dropping the late failure before Undo can recover it. A separate feedback operation owner retains the originating conversation and preserves rename/export errors through navigation and deletion recovery.

The final focused follow-up run passed **132 tests in seven suites** (52 seconds of test execution). New deterministic tests hold feedback save, clear and typed correction through navigation, Undo, failed deletion, and failures before or after committed deletion. They also cover support request/completion separation, duplicate and stale callbacks, rebuilding, More ownership, leased-file protection and Discard identity, Unicode excerpt limits, 1,000 repeated opening failures, and a diagnostic number carried from interruption into retry settlement. The canonical scenario manifest explicitly includes all four new scenarios. The final full Features pass completed **580 tests in 38 suites**, with only the same four assertions in three recorded baseline chart tests listed below. The two opt-in benchmarks are skipped in the ordinary full run and the chrome benchmark is run separately. Chart migration handlers/tests and dependency pins are unchanged. Python CI contract checks and all **197 contract tests** pass.

The actual production `SettingsView` sheet binding passed **seven build/dismissal cycles in 141 seconds** on iPhone 18 Pro / iOS 27 at effective AX5: Done and simulated Mail cancel/send in portrait and landscape, plus interactive swipe dismissal in portrait. Every matching completion released its retained directory; native sharing was opened and cancelled first in each orientation. This replaces the standalone support fallback fixture with the real Settings binding. The harness writes inert ZIP fixture bytes in unique directories. Mail simulation invokes the same coordinator completion method used by the native delegate, without creating or sending email. It does not claim device Mail delivery or landscape swipe coverage; compact-height UIKit presents a full-screen surface.

Compact Jump to latest passed at **Large, AX3 and AX5 in both orientations with the keyboard and correction context**, including 44-point controls, source navigation, bottom scrolling and the production Reduce Motion branch (103 seconds). Long multi-paragraph drawer previews passed those same six layouts with bounded labels, Settings reachability and clipping/hit-region audits (83 seconds). Discard removes its notice and reduces the notice count while keeping unrelated errors. The optimized drawer again realizes **20 of 1,000 rows** initially, with **21 row-body evaluations before and after an unrelated error** (12 seconds).

The held-export/More interaction passed at **effective AX5 in portrait and landscape** (79 seconds). Fixture-controlled completion leaves More visible, with no export sheet and zero file leases. Closing More does not present the retained result; an explicit Share regenerates a second snapshot, opens native JSONL sharing, verifies its caption, cancels native sharing and dismisses the still-owned export panel. Matching export dismissal cleans its file.

The complete canonical clipping/hit-region matrix passed **all 124 layouts**: 31 scenarios at Large, AX1, AX3 and AX5 in portrait (1,117 seconds). The test treats every reported clipping or hit-region issue as a failure; there are no audit exemptions. Presented surfaces with a probe asserted their effective size before auditing. This full pass supersedes the earlier unrepeated 108-layout limit recorded below. Separate interaction selectors cover constrained landscape and keyboard layouts. The More arbitration fixture uses a short title and nonvisual status probes; long-title cases remain in the canonical matrix.

The final six-selector simulator group passed in 1,406 seconds, including the complete matrix and More interaction above. Notices, Settings and support sheets reported **effective AX5 in both orientations before passing their audits** (83 seconds). The actual held-export/navigation/completion sequence again prevented automatic sharing on return, then regenerated through explicit Share and passed native JSONL share/cancel/file-release checks in both orientations (69 seconds). Both answer-sharing return and cancellation selectors also passed (16 and 18 seconds). These checks verify the SwiftUI environment inside presented surfaces; they do not measure internal UIKit font sizes.

After sharing the same chrome projection with the no-chat recovery view, the final recovery retry selector passed at AX5 in both orientations (37 seconds). Discard's notice-count and preserved-error checks passed again on that build (48 seconds). The final delivery build contains no temporary optimization flags.

### Chrome state-read cost and allocations

An opt-in benchmark reproduces the `630d471` state reads for separate chat/notices chrome construction, then compares the shared projection. Its fixture has 1,000 live summaries, unread state on the final row, and ten failures. Both `CREGFeatures` and the benchmark test target use temporary scoped `-O` flags, preserving DEBUG probes; those flags are restored afterward. Dependencies retain normal Debug settings. This measures the changed state-read work, not end-to-end SwiftUI rendering or a complete Release dependency build.

One warmup precedes seven samples of 100 evaluations each; these are per-evaluation medians on Apple M2 Pro / macOS 27. Timing runs without allocator logging. Separate allocation samples count successful allocations and requested bytes on the synchronous benchmark thread via libmalloc's [host logger ABI](https://github.com/apple-oss-distributions/libmalloc/blob/main/private/stack_logging.h). The host-only probe is never linked into the app. Fixture setup and printing are outside the measured interval. Other local validation was running, so these are comparative local measurements rather than CI timing guarantees.

| Projection | Time | Allocations | Requested bytes |
| --- | ---: | ---: | ---: |
| `630d471` separate reads | 3.73054 ms | 78 | 597,872 |
| Shared reads | 0.00291 ms | 5 | 3,880 |

```sh
clang -dynamiclib -O2 tools/chrome_allocation_probe.c -o /tmp/creg-chrome-allocation-probe.dylib
CREG_CHROME_BENCHMARK=1 CREG_ALLOCATION_PROBE_PATH=/tmp/creg-chrome-allocation-probe.dylib \
  xcodebuildmcp swift-package test --package-path CREGKit --parallel false \
  --filter ChromeProjectionPerformanceTests
```

For comparable optimized measurements, temporarily add `-O` only to `CREGFeatures` and `CREGFeaturesTests` in the package manifest, then restore the manifest. The benchmark rejects missing instrumentation and zero allocation counts. Both the host benchmark and simulator drawer passed with the scoped optimization flags. The five new UI test selectors are added to CI and its exact-command checker together. The expanded 32-selector UI step, including the 124-layout canonical matrix, receives a 60-minute test budget; the build step remains 30 minutes and the overall job remains bounded at 75 minutes. Python budget mutation tests enforce each reviewed value.

## Initial PR #158 validation against `d1088d3`

### Reducer and diagnostic coverage

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
