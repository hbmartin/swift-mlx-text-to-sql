---
name: publish-creg-testflight
description: Prepare, validate, upload, and verify CREG's internal-only TestFlight Beta build. Use when asked to preflight, archive, export, publish, upload, or confirm the processing status of a CREG TestFlight build.
---

# Publish CREG to TestFlight

Publish only CREG's `Beta` configuration. Preserve the repository's experimental-model and artifact-integrity gates; never substitute `Release` or a generic iOS publishing workflow.

## Choose the operation

- For prepare, check, validate, or preflight requests, run `preflight`.
- For an explicit publish or upload request, run `publish`. Treat that request as authorization for the upload after every local gate passes; do not ask for another confirmation.
- Add `--dry-run` when the user requests command generation without an archive or network upload.

Run from the repository root:

```bash
python3 .agents/skills/publish-creg-testflight/scripts/publish_testflight.py preflight
python3 .agents/skills/publish-creg-testflight/scripts/publish_testflight.py publish
```

Use raw `xcodebuild` only through the bundled script. The installed XcodeBuildMCP CLI has no archive, export, or App Store upload workflow.

## Enforce the local gates

Let `scripts/publish_testflight.py` own command construction and ordering. Do not reproduce, bypass, or weaken its checks.

The script must stop before creating an archive unless:

- the complete Git worktree is clean;
- the shared `CREG` scheme archives `Beta`;
- bundle identifier, team, automatic signing, build channel, and pinned training run match the CREG contract;
- the source build-number stamp and export-compliance declaration remain present;
- the pinned training run, adapter checkpoint, base model, and fused-model cache exist; and
- `git`, `xcodebuild`, and `uv` are available.

For `publish`, the script must then:

1. Archive once with automatic signing and provisioning updates.
2. Export an internal-only App Store Connect IPA without changing the stamped build number.
3. Run the existing archive-and-IPA inspector and require two matching, complete artifacts.
4. Upload from that same archive only after inspection succeeds.
5. Write sanitized logs and `release.json` beneath the unique ignored `build/testflight/<run-id>/` directory.

Surface the exact sanitized Xcode failure and the release-state path. Never pass credentials on a command line, print environment variables, inspect browser cookies/storage, or copy secrets into logs or reports. Assume the Xcode account, automatic distribution signing, and App Store Connect app record are configured; report Xcode's error if they are not.

## Verify App Store Connect

Do not call an upload successful merely because Xcode accepted it. After `publish` returns `upload_accepted_awaiting_app_store_connect`:

1. Read the exact bundle identifier, marketing version, and build number from `release.json`.
2. Check available tools for a purpose-built App Store Connect API or connector. If none can use the configured Xcode-account authentication, use an authenticated browser and follow the available browser-control skill before interacting with the page.
3. Open App Store Connect, select CREG by bundle identifier, open TestFlight, and match the exact version and build number. Never infer identity from the most recent row alone.
4. Monitor pending processing states with concise progress updates until the matched build becomes `Ready to Test` or `Testing`. If authentication is required, ask the user to sign in in the selected browser and resume after they confirm.
5. Fail on `Invalid Binary` or `Rejected`. Report other action-required states, such as missing compliance, as blocked with the visible remediation.
6. Do not assign tester groups, enable external testing, submit for review, or change metadata. The uploaded build is permanently internal-only.

Keep `release.json` as the immutable local upload record. Report the separately observed App Store Connect status, exact version/build number, and release-state path in the final response.
