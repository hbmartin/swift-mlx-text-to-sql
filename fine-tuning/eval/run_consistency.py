"""Calibrate the bounded three-generation production policy.

Each item gets exactly three generation calls. A valid temperature-zero
anchor is followed by two independently seeded 0.7 candidates. A repairable
anchor failure is followed by one temperature-zero repair and one 0.7 repair.
Underlying single-candidate Evaluation Runs remain immutable evidence.

The evidence contract is schema_version 3. Older always-vote evidence is
historical only and cannot satisfy the bounded-policy release gate.

- Candidates group by canonical result digest; a strict majority of the
  configured candidate count wins.
- Empty results carry no consensus evidence — every empty result shares one
  digest regardless of the query that produced it — but an empty anchor
  remains deliverable through the no-consensus path.
- Results wider than the production row cap (500) would be truncated in the
  app, so they are never vote-eligible here even though calibration executes
  with the 10,000-row evaluation cap.
- With no majority, selection follows the production precedence: valid
  deterministic repair, sampled repair, or initial anchor as applicable.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any

from eval.prompt_contract import (
    REPAIR_PROMPT_TEMPLATE_PATH,
    SCHEMA_CATALOG_PATH,
    SYSTEM_PROMPT_TEMPLATE_PATH,
    build_repair_prompt,
    build_system_prompt,
)
from eval.run_artifacts import (
    DEFAULT_RUNS_DIR,
    REPO_ROOT,
    create_run_directory,
    hardware_provenance,
    percentile,
    sha256_bytes,
    sha256_file,
    write_json,
)
from eval.selection import Run, SelectionError, load_run
from tools.fetch_model import load_manifest, verify_artifact_tree_at_use

GOLD_V2 = REPO_ROOT / "eval" / "gold" / "gold_v2.jsonl"
DATABASE = REPO_ROOT / "db" / "creg.sqlite"
GRAMMAR = (
    REPO_ROOT
    / "CREGKit"
    / "Sources"
    / "CREGEngine"
    / "Resources"
    / "sql_grammar.ebnf"
)
SCHEMA_PROMPT = (
    REPO_ROOT
    / "CREGKit"
    / "Sources"
    / "CREGEngine"
    / "Resources"
    / "schema_prompt.txt"
)
SWIFT_LOCK = REPO_ROOT / "CREGKit" / "Package.resolved"
UV_LOCK = REPO_ROOT / "fine-tuning" / "uv.lock"
DEFAULT_CONSISTENCY = REPO_ROOT / "eval" / "consistency-runs"
MODEL_MANIFEST = REPO_ROOT / "model-manifest.json"

CANDIDATE_COUNT = 3
POLICY_SCHEMA_VERSION = 3
POLICY_VERSION = "bounded-three-generation-v1"
# DatabaseClient.defaultRowCap in the app. Calibration source runs execute
# with the 10,000-row evaluation cap, so any result wider than this would
# have been truncated in production.
PRODUCTION_ROW_CAP = 500


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-key", required=True)
    parser.add_argument("--gcd", choices=["on", "off"], required=True)
    parser.add_argument("--runs-dir", type=Path, default=DEFAULT_RUNS_DIR)
    parser.add_argument(
        "--consistency-runs-dir", type=Path, default=DEFAULT_CONSISTENCY
    )
    return parser.parse_args()


def run_id(model: str, gcd: str, temperature: float, seed: int) -> str:
    return (
        f"policy-v{POLICY_SCHEMA_VERSION}-source-{model}-gcd-{gcd}-"
        f"t-{str(temperature).replace('.', '_')}-s-{seed}"
    )


def run_is_compatible(
    run: Run,
    *,
    model: str,
    repository: str,
    revision: str,
    gcd: str,
    temperature: float,
    seed: int,
    gold_sha256: str,
    input_sha256: dict[str, str] | None = None,
    artifact_lock_sha256: str | None = None,
    directory_sha256: str | None = None,
    hardware: dict[str, Any] | None = None,
) -> bool:
    """Return whether an immutable Evaluation Run is the exact required cell."""
    configuration = run.manifest.get("configuration", {})
    model_identity = run.manifest.get("model", {})
    gold = run.manifest.get("inputs", {}).get("gold", {})
    compatible = (
        run.summary.get("model_key") == model
        and model_identity.get("repository") == repository
        and model_identity.get("revision") == revision
        and run.summary.get("gcd") == gcd
        and float(run.summary.get("temperature", -1)) == temperature
        and int(run.summary.get("seed", -1)) == seed
        and gold.get("sha256") == gold_sha256
        and int(run.summary.get("n", -1)) == 200
        and configuration.get("top_p") == 1.0
        and configuration.get("top_k") == 0
        and configuration.get("max_tokens") == 512
        and configuration.get("item_seed_formula")
        == "run_seed * 1000000 + zero_based_item_index"
        and (hardware is None or run.manifest.get("hardware") == hardware)
    )
    if not compatible:
        return False
    inputs = run.manifest.get("inputs", {})
    if input_sha256 is not None:
        for name, expected in input_sha256.items():
            if name == "system_prompt_sha256":
                if inputs.get(name) != expected:
                    return False
            elif inputs.get(name, {}).get("sha256") != expected:
                return False
    if (
        artifact_lock_sha256 is not None
        and model_identity.get("artifact_lock", {}).get("sha256")
        != artifact_lock_sha256
    ):
        return False
    return (
        directory_sha256 is None
        or model_identity.get("directory_sha256") == directory_sha256
    )


def current_identity(model: str) -> dict[str, Any]:
    """Hashes of every frozen input for the requested cell.

    Unpublished local models use their measured directory digest as the
    revision, so their evidence is reusable without inventing a repository.
    """
    manifest = load_manifest(MODEL_MANIFEST)
    artifact = next(
        (item for item in manifest["models"] if item["key"] == model), None
    )
    if artifact is None:
        raise SelectionError(f"model is not declared in the manifest: {model}")
    repository = artifact.get("repository")
    revision = artifact.get("revision")
    conversion = artifact.get("conversion")
    local_directory = (
        conversion["output_directory"]
        if conversion is not None
        else artifact["local_directory"]
    )
    model_directory = REPO_ROOT / "models" / local_directory
    artifact_lock = model_directory / ".creg-artifact.json"
    tokenizer = model_directory / "tokenizer.json"
    if not artifact_lock.is_file() or not tokenizer.is_file():
        raise SelectionError(
            f"model identity inputs are missing: {artifact_lock}, {tokenizer}"
        )
    # The lock records fetch-time state. Re-hash the bytes currently on disk
    # before deciding that an immutable run still represents this artifact.
    actual_directory_sha256 = verify_artifact_tree_at_use(
        model_directory, artifact
    )
    repository = repository or "local-derived"
    revision = revision or f"sha256:{actual_directory_sha256}"
    return {
        "repository": repository,
        "revision": revision,
        "gold_sha256": sha256_file(GOLD_V2),
        "input_sha256": {
            "database": sha256_file(DATABASE),
            "gold": sha256_file(GOLD_V2),
            "grammar": sha256_file(GRAMMAR),
            "schema_prompt": sha256_file(SCHEMA_PROMPT),
            "swift_package_lock": sha256_file(SWIFT_LOCK),
            "uv_lock": sha256_file(UV_LOCK),
            "tokenizer": sha256_file(tokenizer),
            "system_prompt_sha256": sha256_bytes(
                build_system_prompt(SCHEMA_PROMPT.read_text().strip()).encode()
            ),
            "system_prompt_template": sha256_file(SYSTEM_PROMPT_TEMPLATE_PATH),
            "repair_prompt_template": sha256_file(REPAIR_PROMPT_TEMPLATE_PATH),
            "schema_catalog": sha256_file(SCHEMA_CATALOG_PATH),
        },
        "artifact_lock_sha256": sha256_file(artifact_lock),
        "directory_sha256": actual_directory_sha256,
        "hardware": hardware_provenance(),
    }


def identity_matches(
    run: Run,
    identity: dict[str, Any],
    *,
    model: str,
    gcd: str,
    temperature: float,
    seed: int,
) -> bool:
    return run_is_compatible(
        run,
        model=model,
        repository=identity["repository"],
        revision=identity["revision"],
        gcd=gcd,
        temperature=temperature,
        seed=seed,
        gold_sha256=identity["gold_sha256"],
        input_sha256=identity["input_sha256"],
        artifact_lock_sha256=identity["artifact_lock_sha256"],
        directory_sha256=identity["directory_sha256"],
        hardware=identity["hardware"],
    )


def find_compatible_run(
    *,
    model: str,
    gcd: str,
    temperature: float,
    seed: int,
    runs_dir: Path,
    identity: dict[str, Any] | None = None,
) -> Path | None:
    """Find verified prior evidence instead of regenerating an identical cell."""
    identity = identity or current_identity(model)
    for directory in sorted(path for path in runs_dir.iterdir() if path.is_dir()):
        try:
            run = load_run(directory)
        except (OSError, ValueError, KeyError, SelectionError):
            continue
        if identity_matches(
            run,
            identity,
            model=model,
            gcd=gcd,
            temperature=temperature,
            seed=seed,
        ):
            return directory
    return None


def ensure_run(
    model: str,
    gcd: str,
    temperature: float,
    seed: int,
    runs_dir: Path,
    identity: dict[str, Any] | None = None,
) -> Path:
    identifier = run_id(model, gcd, temperature, seed)
    directory = runs_dir / identifier
    if directory.exists():
        # A deterministic-ID directory is reused only after the same
        # input-hash verification the search path performs; otherwise a
        # stale anchor would be voted against candidates generated from
        # different frozen inputs.
        run = load_run(directory)
        identity = identity or current_identity(model)
        if not identity_matches(
            run,
            identity,
            model=model,
            gcd=gcd,
            temperature=temperature,
            seed=seed,
        ):
            raise SelectionError(
                f"immutable run {directory} does not match the current frozen "
                "inputs (database, gold set, prompts, locks, or model "
                "artifact changed after it was created); move it aside and "
                "regenerate instead of mixing evidence"
            )
        return directory
    reusable = find_compatible_run(
        model=model,
        gcd=gcd,
        temperature=temperature,
        seed=seed,
        runs_dir=runs_dir,
        identity=identity,
    )
    if reusable is not None:
        print(f"Reusing compatible immutable run: {reusable}")
        return reusable
    subprocess.run(
        [
            sys.executable,
            "-m",
            "eval.run_eval",
            "--model-key",
            model,
            "--gold",
            str(GOLD_V2),
            "--gcd",
            gcd,
            "--temperature",
            str(temperature),
            "--seed",
            str(seed),
            "--run-id",
            identifier,
            "--runs-dir",
            str(runs_dir),
        ],
        cwd=REPO_ROOT / "fine-tuning",
        check=True,
    )
    generated = load_run(directory)
    identity = identity or current_identity(model)
    if not identity_matches(
        generated,
        identity,
        model=model,
        gcd=gcd,
        temperature=temperature,
        seed=seed,
    ):
        raise SelectionError(
            f"new run {directory} does not match the calibration-start "
            "identity; frozen inputs changed while evidence was generated"
        )
    return directory


def write_prompt_overrides(
    root: Path,
    label: str,
    records: list[dict[str, str]],
) -> Path:
    payload = "".join(
        json.dumps(record, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + "\n"
        for record in sorted(records, key=lambda item: item["id"])
    ).encode()
    digest = hashlib.sha256(payload).hexdigest()
    directory = root / ".policy-inputs"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{label}-{digest}.jsonl"
    if path.exists():
        if path.read_bytes() != payload:
            raise SelectionError(f"content-addressed prompt collision: {path}")
    else:
        with path.open("xb") as output:
            output.write(payload)
    return path


def ensure_override_run(
    *,
    identifier: str,
    model: str,
    gcd: str,
    temperature: float,
    seed: int,
    runs_dir: Path,
    identity: dict[str, Any],
    prompt_overrides: Path,
) -> Path:
    directory = runs_dir / identifier
    prompt_digest = sha256_file(prompt_overrides)
    if directory.exists():
        run = load_run(directory)
        compatible = identity_matches(
            run,
            identity,
            model=model,
            gcd=gcd,
            temperature=temperature,
            seed=seed,
        )
        recorded = run.manifest.get("inputs", {}).get("prompt_overrides", {})
        if not compatible or recorded.get("sha256") != prompt_digest:
            raise SelectionError(
                f"immutable repair run {directory} does not match its frozen inputs"
            )
        return directory
    subprocess.run(
        [
            sys.executable,
            "-m",
            "eval.run_eval",
            "--model-key",
            model,
            "--gold",
            str(GOLD_V2),
            "--gcd",
            gcd,
            "--temperature",
            str(temperature),
            "--seed",
            str(seed),
            "--prompt-overrides",
            str(prompt_overrides),
            "--run-id",
            identifier,
            "--runs-dir",
            str(runs_dir),
        ],
        cwd=REPO_ROOT / "fine-tuning",
        check=True,
    )
    generated = load_run(directory)
    recorded = generated.manifest.get("inputs", {}).get("prompt_overrides", {})
    if (
        not identity_matches(
            generated,
            identity,
            model=model,
            gcd=gcd,
            temperature=temperature,
            seed=seed,
        )
        or recorded.get("sha256") != prompt_digest
    ):
        raise SelectionError(
            f"new repair run {directory} does not match the calibration-start identity"
        )
    return directory


def sql_fingerprint(sql: str) -> str:
    normalized = sql.replace("\r\n", "\n").replace("\r", "\n").strip()
    return hashlib.sha256(normalized.encode()).hexdigest()


def repair_prompt_for(
    initial: dict[str, Any],
    *,
    subsequent: dict[str, Any] | None = None,
) -> str:
    error = initial.get("error") or "unknown SQLite validation failure"
    kind = (
        "binding"
        if re.search(r"(?i)no such|ambiguous|has no column", error)
        else "syntax"
    )
    sources = sorted(
        set(
            re.findall(
                r"(?i)\b(?:FROM|JOIN)\s+([A-Za-z_][A-Za-z0-9_]*)",
                initial.get("predicted_sql", ""),
            )
        )
    )
    catalog = json.loads(SCHEMA_CATALOG_PATH.read_text())["tables"]
    match = re.search(
        r"(?i)(?:no such|ambiguous) column:\s*(?:\w+\.)?([A-Za-z_][A-Za-z0-9_]*)",
        error,
    )
    owners = (
        sorted(
            table
            for table, columns in catalog.items()
            if match.group(1).lower() in {column.lower() for column in columns}
        )
        if match
        else []
    )
    fingerprints = [sql_fingerprint(initial.get("predicted_sql", ""))]
    if subsequent is not None and subsequent.get("error") is not None:
        fingerprints.append(sql_fingerprint(subsequent.get("predicted_sql", "")))
        error += (
            "\nSubsequent deterministic repair evidence: "
            + str(subsequent["error"])
        )
    return build_repair_prompt(
        question=initial["question"],
        failed_sql=initial.get("predicted_sql", ""),
        sqlite_error=error,
        issue_type=kind,
        issue_disposition="repairable",
        declared_sources=sources,
        possible_column_owners=owners,
        failed_fingerprints=fingerprints,
    )


def executed_within_production_cap(item: dict[str, Any]) -> bool:
    predicted = item.get("predicted")
    return (
        item.get("error") is None
        and predicted is not None
        and not predicted["is_truncated"]
        and predicted["digest"] is not None
        and predicted["row_count"] <= PRODUCTION_ROW_CAP
    )


def vote_eligible(item: dict[str, Any]) -> bool:
    """A result that production could group for consensus: complete within
    the production row cap and non-empty."""
    return (
        executed_within_production_cap(item)
        and item["predicted"]["row_count"] > 0
    )


def emulate_duplicate_policy(
    candidates: list[tuple[str, dict[str, Any]]],
) -> tuple[list[tuple[str, dict[str, Any]]], int, int]:
    """Apply the runtime's duplicate behavior to immutable eval records.

    A repeat of failed SQL is suppressed. A repeat of valid SQL remains an
    independent generation for voting, but reuses the first validation and
    execution result instead of executing again.
    """
    usable: list[tuple[str, dict[str, Any]]] = []
    failed_fingerprints: set[str] = set()
    valid_by_fingerprint: dict[str, dict[str, Any]] = {}
    suppressions = 0
    reuses = 0
    for role, item in candidates:
        fingerprint = sql_fingerprint(item.get("predicted_sql", role))
        if fingerprint in failed_fingerprints:
            suppressions += 1
            continue
        if fingerprint in valid_by_fingerprint:
            reuses += 1
            original = valid_by_fingerprint[fingerprint]
            reused = dict(item)
            reused["error"] = original.get("error")
            reused["predicted"] = original.get("predicted")
            reused["ex"] = original.get("ex", False)
            usable.append((role, reused))
            continue
        usable.append((role, item))
        if item.get("error") is not None:
            failed_fingerprints.add(fingerprint)
        elif item.get("predicted") is not None:
            valid_by_fingerprint[fingerprint] = item
    return usable, suppressions, reuses


def policy_latency_microseconds(
    candidates: list[tuple[str, dict[str, Any]]],
) -> int:
    """Measure the work production performs for a three-generation turn.

    Source-run elapsed time includes executing the gold SQL, which the app
    never does. Duplicate candidates cost generation time only because their
    validation/execution is either suppressed or reused.
    """
    seen_fingerprints: set[str] = set()
    total = 0
    for role, item in candidates:
        generation = int(item["generation_microseconds"])
        fingerprint = sql_fingerprint(item.get("predicted_sql", role))
        if fingerprint in seen_fingerprints:
            total += generation
            continue
        seen_fingerprints.add(fingerprint)
        elapsed_without_gold = int(item["elapsed_microseconds"]) - int(
            item["gold_execution_microseconds"]
        )
        total += max(generation, elapsed_without_gold)
    return total


def vote_trial(
    candidates: list[tuple[str, dict[str, Any]]],
    candidate_count: int = CANDIDATE_COUNT,
) -> dict[str, Any]:
    """Apply duplicate suppression, consensus, and fallback selection."""
    usable, duplicate_suppressions, duplicate_reuses = emulate_duplicate_policy(
        candidates
    )
    duplicate_count = duplicate_suppressions + duplicate_reuses
    groups = Counter(
        item["predicted"]["digest"]
        for _, item in usable
        if vote_eligible(item)
    )
    ranked = sorted(groups.items(), key=lambda pair: (-pair[1], pair[0]))
    majority = next(
        (
            (digest, count)
            for digest, count in ranked
            if count > candidate_count // 2
        ),
        None,
    )
    if majority is not None:
        digest, agreement = majority
        role, item = next(
            candidate
            for candidate in usable
            if vote_eligible(candidate[1])
            and candidate[1]["predicted"]["digest"] == digest
        )
        return {
            "outcome": "consensus",
            "confidence": "confirmed",
            "no_consensus_reason": None,
            "agreement": agreement,
            "anchor_failed": candidates[0][1].get("error") is not None,
            "selected_role": role,
            "ex": bool(item["ex"]),
            "valid_sql": item["error"] is None,
            "duplicate_count": duplicate_count,
            "duplicate_suppressions": duplicate_suppressions,
            "duplicate_reuses": duplicate_reuses,
        }

    initial_failed = candidates[0][1].get("error") is not None
    precedence = (
        ["deterministic-repair", "sampled-repair"]
        if initial_failed
        else ["anchor"]
    )
    selected: tuple[str, dict[str, Any]] | None = None
    for preferred_role in precedence:
        selected = next(
            (
                candidate
                for candidate in usable
                if candidate[0] == preferred_role
                and candidate[1].get("error") is None
                and candidate[1].get("predicted") is not None
            ),
            None,
        )
        if selected is not None:
            break
    # Compatibility for unit fixtures and historical role labels.
    if selected is None:
        selected = next(
            (
                candidate
                for candidate in usable
                if candidate[1].get("error") is None
                and candidate[1].get("predicted") is not None
            ),
            None,
        )
    eligible_digests = {
        item["predicted"]["digest"]
        for _, item in usable
        if vote_eligible(item)
    }
    reason = (
        "conflicting-results"
        if len(eligible_digests) >= 2
        else "insufficient-non-empty-evidence"
    )
    if selected is not None:
        role, item = selected
        production_eligible = executed_within_production_cap(item)
        return {
            "outcome": "no-consensus",
            "confidence": "unconfirmed",
            "no_consensus_reason": reason,
            "agreement": 0,
            "anchor_failed": initial_failed,
            "selected_role": role,
            "ex": bool(item["ex"]) if production_eligible else False,
            "valid_sql": True,
            "duplicate_count": duplicate_count,
            "duplicate_suppressions": duplicate_suppressions,
            "duplicate_reuses": duplicate_reuses,
        }
    return {
        "outcome": "no-valid-candidate",
        "confidence": None,
        "no_consensus_reason": None,
        "agreement": 0,
        "anchor_failed": initial_failed,
        "selected_role": None,
        "ex": False,
        "valid_sql": False,
        "duplicate_count": duplicate_count,
        "duplicate_suppressions": duplicate_suppressions,
        "duplicate_reuses": duplicate_reuses,
    }


def main() -> None:
    args = parse_args()
    runs_dir = args.runs_dir.resolve()
    # Hash the multi-gigabyte model tree once for this calibration process.
    # Any newly generated run independently re-verifies the same tree at its
    # own time of use inside eval.run_eval.
    identity = current_identity(args.model_key)
    sample_temperature = 0.7
    identifier = (
        f"policy-v{POLICY_SCHEMA_VERSION}-{args.model_key}-gcd-{args.gcd}-"
        "bounded-three-generation"
    )
    destination = args.consistency_runs_dir.resolve() / identifier
    if destination.exists():
        raise SelectionError(
            f"immutable policy-calibration output already exists: {destination}"
        )
    anchor_path = ensure_run(
        args.model_key, args.gcd, 0.0, 0, runs_dir, identity
    )
    anchor = load_run(anchor_path)
    anchor_items = {item["id"]: item for item in anchor.items}
    source_paths = [anchor_path]
    samples: dict[int, dict[str, dict[str, Any]]] = {}
    for seed in range(10):
        path = ensure_run(
            args.model_key,
            args.gcd,
            sample_temperature,
            seed,
            runs_dir,
            identity,
        )
        source_paths.append(path)
        samples[seed] = {item["id"]: item for item in load_run(path).items}

    deterministic_prompts = write_prompt_overrides(
        args.consistency_runs_dir.resolve(),
        f"{args.model_key}-deterministic-repair",
        [
            {
                "id": item_id,
                "user_content": (
                    repair_prompt_for(item)
                    if item.get("error") is not None
                    else f"Question: {item['question']}"
                ),
            }
            for item_id, item in anchor_items.items()
        ],
    )
    deterministic_path = ensure_override_run(
        identifier=(
            f"policy-v{POLICY_SCHEMA_VERSION}-repair-deterministic-"
            f"{args.model_key}-gcd-{args.gcd}"
        ),
        model=args.model_key,
        gcd=args.gcd,
        temperature=0.0,
        seed=90,
        runs_dir=runs_dir,
        identity=identity,
        prompt_overrides=deterministic_prompts,
    )
    source_paths.append(deterministic_path)
    deterministic_items = {
        item["id"]: item for item in load_run(deterministic_path).items
    }

    sampled_prompts = write_prompt_overrides(
        args.consistency_runs_dir.resolve(),
        f"{args.model_key}-sampled-repair",
        [
            {
                "id": item_id,
                "user_content": (
                    repair_prompt_for(
                        item,
                        subsequent=deterministic_items[item_id],
                    )
                    if item.get("error") is not None
                    else f"Question: {item['question']}"
                ),
            }
            for item_id, item in anchor_items.items()
        ],
    )
    sampled_repairs: dict[int, dict[str, dict[str, Any]]] = {}
    for trial_seed in range(5):
        path = ensure_override_run(
            identifier=(
                f"policy-v{POLICY_SCHEMA_VERSION}-repair-sampled-"
                f"{args.model_key}-gcd-{args.gcd}-s-{trial_seed}"
            ),
            model=args.model_key,
            gcd=args.gcd,
            temperature=sample_temperature,
            seed=100 + trial_seed,
            runs_dir=runs_dir,
            identity=identity,
            prompt_overrides=sampled_prompts,
        )
        source_paths.append(path)
        sampled_repairs[trial_seed] = {
            item["id"]: item for item in load_run(path).items
        }

    directory = create_run_directory(
        args.consistency_runs_dir.resolve(), identifier
    )
    records = []
    for trial_seed in range(5):
        for item_id in sorted(anchor_items):
            anchor_item = anchor_items[item_id]
            repairing = anchor_item.get("error") is not None
            candidates = (
                [
                    ("anchor", anchor_item),
                    ("deterministic-repair", deterministic_items[item_id]),
                    ("sampled-repair", sampled_repairs[trial_seed][item_id]),
                ]
                if repairing
                else [
                    ("anchor", anchor_item),
                    ("sample-1", samples[trial_seed * 2][item_id]),
                    ("sample-2", samples[trial_seed * 2 + 1][item_id]),
                ]
            )
            vote = vote_trial(candidates)
            records.append(
                {
                    "schema_version": POLICY_SCHEMA_VERSION,
                    "policy_version": POLICY_VERSION,
                    "id": item_id,
                    "trial_seed": trial_seed,
                    "sample_temperature": sample_temperature,
                    "outcome": vote["outcome"],
                    "confidence": vote["confidence"],
                    "no_consensus_reason": vote["no_consensus_reason"],
                    "agreement": vote["agreement"],
                    "anchor_failed": vote["anchor_failed"],
                    "selected_role": vote["selected_role"],
                    "generated_count": 3,
                    "repair_attempts": 2 if repairing else 0,
                    "duplicate_count": vote["duplicate_count"],
                    "duplicate_suppressions": vote["duplicate_suppressions"],
                    "duplicate_reuses": vote["duplicate_reuses"],
                    "ex": vote["ex"],
                    "valid_sql": vote["valid_sql"],
                    "latency_microseconds": policy_latency_microseconds(candidates),
                    "candidates": [
                        {
                            "role": role,
                            "run_seed": item["run_seed"],
                            "item_seed": item["item_seed"],
                            "fingerprint": sql_fingerprint(item["predicted_sql"]),
                            "sql": item["predicted_sql"],
                            "error": item["error"],
                            "result": item["predicted"],
                            "ex": item["ex"],
                            "elapsed_microseconds": item["elapsed_microseconds"],
                        }
                        for role, item in candidates
                    ],
                }
            )

    items_path = directory / "items.jsonl"
    with items_path.open("x") as output:
        for record in records:
            output.write(
                json.dumps(
                    record,
                    ensure_ascii=False,
                    sort_keys=True,
                    separators=(",", ":"),
                )
                + "\n"
            )
    timings = [record["latency_microseconds"] for record in records]
    count = len(records)
    outcomes = Counter(record["outcome"] for record in records)
    confirmed = outcomes["consensus"]
    unconfirmed = outcomes["no-consensus"]
    repair_trials = sum(record["repair_attempts"] > 0 for record in records)
    repair_recoveries = sum(
        record["repair_attempts"] > 0 and record["valid_sql"]
        for record in records
    )
    summary = {
        "schema_version": POLICY_SCHEMA_VERSION,
        "policy_version": POLICY_VERSION,
        "model_key": args.model_key,
        "gcd": args.gcd,
        "bounded_policy": True,
        "always_vote": False,
        "candidate_count": CANDIDATE_COUNT,
        "production_row_cap": PRODUCTION_ROW_CAP,
        "sample_temperature": sample_temperature,
        "trial_seeds": list(range(5)),
        "n_trials": count,
        "ex": sum(record["ex"] for record in records) / count,
        "valid_sql_rate": sum(record["valid_sql"] for record in records) / count,
        "confirmed": confirmed,
        "unconfirmed": unconfirmed,
        "confirmed_rate": confirmed / count,
        "unconfirmed_rate": unconfirmed / count,
        "repair_trials": repair_trials,
        "repair_recoveries": repair_recoveries,
        "repair_recovery_rate": (
            repair_recoveries / repair_trials if repair_trials else 1.0
        ),
        "duplicate_suppressions": sum(
            record["duplicate_suppressions"] for record in records
        ),
        "duplicate_reuses": sum(
            record["duplicate_reuses"] for record in records
        ),
        "duplicates": sum(
            record["duplicate_count"] for record in records
        ),
        "timeouts": 0,
        "no_valid_candidate": outcomes["no-valid-candidate"],
        "anchor_failures": sum(record["anchor_failed"] for record in records),
        "mean_latency_microseconds": round(sum(timings) / count),
        "p95_latency_microseconds": percentile(timings, 0.95),
    }
    write_json(directory / "summary.json", summary)
    manifest = {
        "schema_version": POLICY_SCHEMA_VERSION,
        "policy_version": POLICY_VERSION,
        "run_id": identifier,
        "status": "complete",
        "hardware": identity["hardware"],
        "configuration": {
            "bounded_policy": True,
            "generation_ceiling": CANDIDATE_COUNT,
            "anchor_temperature": 0.0,
            "deterministic_repair_temperature": 0.0,
            "sample_temperature": sample_temperature,
            "trial_seeds": list(range(5)),
            "top_p": 1.0,
            "top_k": 0,
            "max_tokens": 512,
            "production_row_cap": PRODUCTION_ROW_CAP,
            "majority_rule": (
                "two matching non-empty complete results within production_row_cap"
            ),
            "fallback_rule": (
                "deterministic repair, sampled repair, or initial anchor"
            ),
        },
        "prompt_inputs": {
            "deterministic_repair": {
                "path": str(deterministic_prompts),
                "sha256": sha256_file(deterministic_prompts),
            },
            "sampled_repair": {
                "path": str(sampled_prompts),
                "sha256": sha256_file(sampled_prompts),
            },
        },
        "sources": [
            {
                "path": str(path),
                "manifest_sha256": sha256_file(path / "manifest.json"),
            }
            for path in source_paths
        ],
        "outputs": {
            "items": {"path": "items.jsonl", "sha256": sha256_file(items_path)},
            "summary": {
                "path": "summary.json",
                "sha256": sha256_file(directory / "summary.json"),
            },
        },
    }
    write_json(directory / "manifest.json", manifest)
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
