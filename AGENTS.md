# Repository validation

Apple tests run locally through XcodeBuildMCP. CI verifies Swift dependency pins and package resolution, Python tests and corpus/schema determinism, publisher contracts, security guards, and DocC generation. Do not add Apple test execution or simulator provisioning to CI.

For changes affecting Apple code, run the affected package suites and UI selectors. A full Apple package suite, full UI suite, or full canonical accessibility matrix requires an explicit user request. Use focused validation by default; building test targets does not authorize running every test.

Check `xcodebuildmcp --help`, tool-specific help, and repository/session defaults before testing. Pass explicit paths and selectors. Reuse a compatible simulator from `xcodebuildmcp simulator list`; prefer the existing iPhone 18 Pro on iOS 27 for CREG UI tests. Use its actual UDID, and preserve shared simulators after validation. If no compatible device exists, select or provision one through XcodeBuildMCP.

Filtered package example (from the repository root):

```sh
xcodebuildmcp swift-package test \
  --package-path "$PWD/CREGKit" \
  --filter 'PR158RegressionFixTests|ConversationNoticeTests|HistoryRecoveryRegressionTests|DiagnosticsAndFailurePresentationTests|FeatureFailureDiagnosticsTests' \
  --parallel false
```

Filtered UI example (replace the UDID with the compatible device discovered locally):

```sh
xcodebuildmcp simulator test \
  --project-path "$PWD/CREG.xcodeproj" \
  --scheme CREG --configuration Debug \
  --simulator-id 31B09574-9781-45A7-816D-6A1916E1BA16 \
  --extra-args \
  '-only-testing:CREGUITests/AccessibilityUITests/testDrawerCancellationAllowsTheFirstFollowingSwipe' \
  '-only-testing:CREGUITests/AccessibilityUITests/testNoticeTechnicalDetailsKeepFailureIdentity' \
  '-only-testing:CREGUITests/AccessibilityUITests/testHistoryProgressWarningsAreNeutralOnEverySurface' \
  '-only-testing:CREGUITests/AccessibilityUITests/testConversationWriteRecoveryOffersRetryInNoticesAndSettings' \
  '-skipPackagePluginValidation' '-skipMacroValidation' \
  'CODE_SIGNING_ALLOWED=NO' 'CREG_ACCESSIBILITY_HARNESS_BUILD=YES'
```

`CREG_ACCESSIBILITY_HARNESS_BUILD=YES` is required for the inert accessibility fixture build. It is valid only for Debug simulator builds and must not be used for release/device builds or distribution. Both drawer motion policies and capture resets are covered by the drawer selector above.

Run the CI contract checker, its affected Python tests, the package-pin checker, and the whitespace check for workflow/contract changes:

```sh
uv run --project fine-tuning --no-sync python fine-tuning/tools/check_ci_contracts.py
uv run --project fine-tuning --no-sync python -m pytest fine-tuning/tests/test_ci_contracts.py -q
uv run --project fine-tuning --no-sync python fine-tuning/tools/check_swift_package_pins.py
git diff --check
```

Report the exact commands/selectors, results, and absolute log/xcresult artifact paths. Report existing baseline failures separately from new failures; do not suppress or weaken their assertions. Keep dated validation documentation and historical run records in `docs/HistoryRecoveryValidation.md`.
