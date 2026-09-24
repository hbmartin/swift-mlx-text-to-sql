"""Gate a 200-item balanced-prefill run against qualification and remainder.

The report is written even when the gate fails so every changed SQL output
remains available for review. Run this against outputs from the same optimized
creg-eval-cli binary for the two chunking modes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


SUMMARY_IDENTITY = (
    "model",
    "gcd",
    "temperature",
    "seed",
    "topP",
    "topK",
    "maxTokens",
    "rowCap",
)
PROVENANCE_IDENTITY = (
    "modelDirectorySHA256",
    "systemPromptSHA256",
    "schemaPromptSHA256",
    "grammarSHA256",
)
REQUIRED_EFFECTIVE_SETTINGS = (
    "gcd", "temperature", "seed", "maxTokens", "maxItems", "rowCap",
    "kvBits", "wiredMemory", "directPromptSuffix", "prefillChunking",
    "compiledQwen2MLPFusion", "compiledQwen2QKVVerificationFusion",
    "verificationMLPSkipLayers", "verificationMLPLongBatchExtraSkipLayers",
    "verificationMLPConfidenceSkip", "verificationMLPAdditionalConfidenceSkips",
    "questionAwareOutputHead", "compactQuestionAwareOutputHead",
    "productionNGram", "ngramDraftCorpusSHA256", "ngramDraftTokens",
    "ngramSerialPrefixTokens", "ngramAdaptiveMinimumSupport",
    "fallbackModelKey", "fallbackModelRevision",
)


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def load_run(path: Path) -> tuple[dict, dict[str, dict]]:
    run = json.loads(path.read_text())
    items = run["results"]
    by_id = {item["id"]: item for item in items}
    if len(items) != 200 or len(by_id) != 200 or run["summary"]["itemCount"] != 200:
        raise ValueError(f"{path}: expected 200 distinct evaluated items")
    return run, by_id


def identity_mismatches(reference: dict, candidate: dict) -> list[str]:
    mismatches = []
    for label, run in (("reference", reference), ("candidate", candidate)):
        if run.get("schemaVersion", 0) < 3:
            mismatches.append(f"{label}.schemaVersion")
        provenance = run.get("provenance") or {}
        for key in PROVENANCE_IDENTITY:
            value = provenance.get(key)
            if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
                mismatches.append(f"{label}.provenance.{key}.missing")
        for key in ("gold", "database", "packageLock", "executable"):
            value = (provenance.get(key) or {}).get("sha256")
            if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
                mismatches.append(f"{label}.provenance.{key}.sha256.missing")
        settings = provenance.get("effectiveSettings") or {}
        for key in REQUIRED_EFFECTIVE_SETTINGS:
            if not isinstance(settings.get(key), str):
                mismatches.append(f"{label}.effectiveSettings.{key}.missing")
    for field in SUMMARY_IDENTITY:
        if reference["summary"].get(field) != candidate["summary"].get(field):
            mismatches.append(f"summary.{field}")
    for field in PROVENANCE_IDENTITY:
        if (reference.get("provenance") or {}).get(field) != (
            candidate.get("provenance") or {}
        ).get(field):
            mismatches.append(f"provenance.{field}")
    for field in ("gold", "database", "packageLock", "executable"):
        if ((reference.get("provenance") or {}).get(field) or {}).get("sha256") != (
            (candidate.get("provenance") or {}).get(field) or {}
        ).get("sha256"):
            mismatches.append(f"provenance.{field}.sha256")
    ref_settings = (reference.get("provenance") or {}).get("effectiveSettings") or {}
    candidate_settings = (candidate.get("provenance") or {}).get("effectiveSettings") or {}
    for field in REQUIRED_EFFECTIVE_SETTINGS:
        if field != "prefillChunking" and ref_settings.get(field) != candidate_settings.get(field):
            mismatches.append(f"effectiveSettings.{field}")
    return mismatches


def outcomes(items: dict[str, dict]) -> dict:
    return {
        "ex": sum(bool(item["ex"]) for item in items.values()),
        "validSQL": sum(bool(item["validSQL"]) for item in items.values()),
    }


def losses(reference: dict[str, dict], candidate: dict[str, dict]) -> dict:
    return {
        "ex": sorted(
            item_id for item_id in reference
            if reference[item_id]["ex"] and not candidate[item_id]["ex"]
        ),
        "validSQL": sorted(
            item_id for item_id in reference
            if reference[item_id]["validSQL"] and not candidate[item_id]["validSQL"]
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--qualified", type=Path)
    parser.add_argument("--balanced", type=Path, required=True)
    parser.add_argument("--remainder", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    balanced, balanced_items = load_run(args.balanced)
    remainder, remainder_items = load_run(args.remainder)
    qualified, qualified_items = (
        load_run(args.qualified) if args.qualified and args.qualified.exists()
        else (None, None)
    )
    item_ids = set(balanced_items)
    if item_ids != set(remainder_items) or (
        qualified_items is not None and item_ids != set(qualified_items)
    ):
        raise ValueError("the runs must evaluate the same 200 item IDs")
    if balanced["summary"].get("prefillChunking") != "balanced":
        raise ValueError("balanced run does not record balanced prefill")
    if remainder["summary"].get("prefillChunking") != "remainder":
        raise ValueError("remainder run does not record remainder prefill")

    qualified_mismatches = (
        identity_mismatches(balanced, qualified) if qualified is not None
        else ["qualified.artifactMissing"]
    )
    control_mismatches = identity_mismatches(balanced, remainder)
    binary_hash = digest(args.binary)
    for label, run in (("balanced", balanced), ("remainder", remainder),
                       ("qualified", qualified)):
        if run is not None and (run.get("provenance") or {}).get(
            "executable", {}
        ).get("sha256") != binary_hash:
            control_mismatches.append(f"{label}.executableSHA256")

    qualified_losses = (
        losses(qualified_items, balanced_items)
        if qualified_items is not None else None
    )
    remainder_losses = losses(remainder_items, balanced_items)
    changed = []
    for item_id in sorted(item_ids):
        old = qualified_items[item_id] if qualified_items is not None else None
        new = balanced_items[item_id]
        control = remainder_items[item_id]
        sql_outputs = {new["predictedSQL"], control["predictedSQL"]}
        if old is not None:
            sql_outputs.add(old["predictedSQL"])
        if len(sql_outputs) == 1:
            continue
        changed.append({
            "id": item_id,
            "qualified": {
                "sql": old["predictedSQL"], "ex": old["ex"],
                "validSQL": old["validSQL"],
            } if old is not None else None,
            "balanced": {
                "sql": new["predictedSQL"], "ex": new["ex"],
                "validSQL": new["validSQL"],
            },
            "remainder": {
                "sql": control["predictedSQL"], "ex": control["ex"],
                "validSQL": control["validSQL"],
            },
        })

    blocked = bool(
        qualified_mismatches or control_mismatches
        or (qualified_losses is not None and any(qualified_losses.values()))
        or any(remainder_losses.values())
    )
    runs = {
        name: {
            "path": str(path),
            "sha256": digest(path),
            "outcomes": outcomes(items),
        }
        for name, path, items in (
            ("balanced", args.balanced, balanced_items),
            ("remainder", args.remainder, remainder_items),
        )
    }
    runs["qualified"] = (
        {
            "path": str(args.qualified),
            "sha256": digest(args.qualified),
            "outcomes": outcomes(qualified_items),
        }
        if qualified_items is not None else None
    )
    report = {
        "schemaVersion": 1,
        "status": "blocked" if blocked else "passed",
        "itemCount": 200,
        "binarySHA256": binary_hash,
        "runs": runs,
        "qualifiedIdentityMismatches": qualified_mismatches,
        "sameBinaryControlIdentityMismatches": control_mismatches,
        "balancedLossesAgainstQualified": qualified_losses,
        "balancedLossesAgainstRemainder": remainder_losses,
        "changedSQL": changed,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps({
        "status": report["status"],
        "outcomes": {
            key: value["outcomes"] if value is not None else None
            for key, value in report["runs"].items()
        },
        "qualifiedIdentityMismatches": qualified_mismatches,
        "sameBinaryControlIdentityMismatches": control_mismatches,
        "balancedLossesAgainstQualified": qualified_losses,
        "balancedLossesAgainstRemainder": remainder_losses,
        "changedSQLCount": len(changed),
    }, indent=2))
    return 2 if blocked else 0


if __name__ == "__main__":
    raise SystemExit(main())
