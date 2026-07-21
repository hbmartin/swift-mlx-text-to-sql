"""Statistical selection helpers for immutable evaluation runs.

All comparisons are paired by gold item. Multi-seed configurations are first
averaged within item, then item IDs are sampled with replacement so repeated
seeds never masquerade as independent gold examples.
"""

from __future__ import annotations

import hashlib
import json
import random
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from eval.run_artifacts import percentile, sha256_file

BOOTSTRAP_SEED = 424242
BOOTSTRAP_REPETITIONS = 10_000


class SelectionError(RuntimeError):
    pass


@dataclass(frozen=True)
class Run:
    directory: Path
    manifest: dict[str, Any]
    summary: dict[str, Any]
    items: tuple[dict[str, Any], ...]

    @property
    def model_key(self) -> str:
        return self.summary["model_key"]

    @property
    def configuration(self) -> tuple[str, float]:
        return (self.summary["gcd"], float(self.summary["temperature"]))


@dataclass(frozen=True)
class Aggregate:
    model_key: str
    gcd: str
    temperature: float
    seeds: tuple[int, ...]
    item_scores: dict[str, float]
    item_valid: dict[str, float]
    item_tiers: dict[str, int]
    timings_microseconds: tuple[int, ...]
    bundle_size_bytes: int

    @property
    def ex(self) -> float:
        return sum(self.item_scores.values()) / len(self.item_scores)

    @property
    def valid_sql_rate(self) -> float:
        return sum(self.item_valid.values()) / len(self.item_valid)

    @property
    def worst_tier_ex(self) -> float:
        tiers = sorted(set(self.item_tiers.values()))
        return min(
            sum(
                score
                for item_id, score in self.item_scores.items()
                if self.item_tiers[item_id] == tier
            )
            / sum(tier == value for value in self.item_tiers.values())
            for tier in tiers
        )

    @property
    def p95_microseconds(self) -> int:
        return percentile(list(self.timings_microseconds), 0.95)

    def metrics(self) -> dict[str, Any]:
        return {
            "model_key": self.model_key,
            "gcd": self.gcd,
            "temperature": self.temperature,
            "seeds": list(self.seeds),
            "n_items": len(self.item_scores),
            "ex": self.ex,
            "valid_sql_rate": self.valid_sql_rate,
            "worst_tier_ex": self.worst_tier_ex,
            "p95_microseconds": self.p95_microseconds,
            "bundle_size_bytes": self.bundle_size_bytes,
        }


def load_run(directory: Path) -> Run:
    directory = directory.resolve()
    manifest_path = directory / "manifest.json"
    summary_path = directory / "summary.json"
    items_path = directory / "items.jsonl"
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("status") != "complete":
        raise SelectionError(f"run is not complete: {directory}")
    outputs = manifest.get("outputs", {})
    for key, path in (("summary", summary_path), ("items", items_path)):
        expected = outputs.get(key, {}).get("sha256")
        actual = sha256_file(path)
        if expected != actual:
            raise SelectionError(
                f"{directory}: {key} hash mismatch ({expected} != {actual})"
            )
    summary = json.loads(summary_path.read_text())
    items = tuple(
        json.loads(line) for line in items_path.read_text().splitlines() if line
    )
    if len(items) != summary["n"]:
        raise SelectionError(f"{directory}: item count does not match summary")
    return Run(
        directory=directory,
        manifest=manifest,
        summary=summary,
        items=items,
    )


def artifact_size(run: Run) -> int:
    # The run manifest snapshots size at evaluation time. Reading a mutable
    # local artifact directory here would let later model-card/license files
    # retroactively change an immutable analysis.
    return int(run.manifest["model"]["bundle_size_bytes"])


def aggregate(runs: Iterable[Run]) -> Aggregate:
    runs = tuple(runs)
    if not runs:
        raise SelectionError("cannot aggregate zero runs")
    identity = {
        (run.model_key, run.summary["gcd"], float(run.summary["temperature"]))
        for run in runs
    }
    if len(identity) != 1:
        raise SelectionError(f"runs do not share one configuration: {identity}")
    item_sets = [{item["id"] for item in run.items} for run in runs]
    if any(item_set != item_sets[0] for item_set in item_sets[1:]):
        raise SelectionError("paired runs do not contain identical item IDs")

    scores: dict[str, list[float]] = {}
    valid: dict[str, list[float]] = {}
    tiers: dict[str, int] = {}
    timings: list[int] = []
    for run in runs:
        for item in run.items:
            scores.setdefault(item["id"], []).append(float(item["ex"]))
            valid.setdefault(item["id"], []).append(float(item["error"] is None))
            tiers[item["id"]] = int(item["tier"])
            timings.append(int(item["elapsed_microseconds"]))
    model_key, gcd, temperature = identity.pop()
    return Aggregate(
        model_key=model_key,
        gcd=gcd,
        temperature=temperature,
        seeds=tuple(sorted(int(run.summary["seed"]) for run in runs)),
        item_scores={
            item_id: sum(values) / len(values)
            for item_id, values in scores.items()
        },
        item_valid={
            item_id: sum(values) / len(values)
            for item_id, values in valid.items()
        },
        item_tiers=tiers,
        timings_microseconds=tuple(timings),
        bundle_size_bytes=artifact_size(runs[0]),
    )


def paired_item_bootstrap(
    candidate: Aggregate,
    baseline: Aggregate,
    *,
    repetitions: int = BOOTSTRAP_REPETITIONS,
    seed: int = BOOTSTRAP_SEED,
) -> dict[str, Any]:
    ids = sorted(candidate.item_scores)
    if ids != sorted(baseline.item_scores):
        raise SelectionError("paired bootstrap requires identical item IDs")
    differences = [
        candidate.item_scores[item_id] - baseline.item_scores[item_id]
        for item_id in ids
    ]
    generator = random.Random(seed)
    bootstrapped = sorted(
        sum(generator.choice(differences) for _ in ids) / len(ids)
        for _ in range(repetitions)
    )

    def quantile(value: float) -> float:
        index = round((len(bootstrapped) - 1) * value)
        return bootstrapped[index]

    difference = sum(differences) / len(differences)
    return {
        "schema_version": 1,
        "method": "paired-item-clustered-bootstrap",
        "seed": seed,
        "repetitions": repetitions,
        "n_items": len(ids),
        "candidate_minus_baseline": difference,
        "ci95": [quantile(0.025), quantile(0.975)],
    }


def rank_key(result: Aggregate) -> tuple[float, float, float, int, int, str]:
    """Ascending key implementing the approved deterministic tie-breaks."""
    return (
        -result.ex,
        -result.valid_sql_rate,
        -result.worst_tier_ex,
        result.p95_microseconds,
        result.bundle_size_bytes,
        result.model_key,
    )


def production_tie_key(
    result: Aggregate,
) -> tuple[float, float, int, int, str]:
    """Tie-break a production equivalence pool without reusing EX."""
    return (
        -result.valid_sql_rate,
        -result.worst_tier_ex,
        result.p95_microseconds,
        result.bundle_size_bytes,
        result.model_key,
    )


def best_gcd(configurations: Iterable[Aggregate]) -> Aggregate:
    values = tuple(configurations)
    if not values:
        raise SelectionError("no GCD configurations supplied")
    return sorted(values, key=rank_key)[0]


def temperature_is_eligible(
    candidate: Aggregate, baseline: Aggregate
) -> tuple[bool, dict[str, Any]]:
    comparison = paired_item_bootstrap(candidate, baseline)
    lower, _ = comparison["ci95"]
    eligible = (
        comparison["candidate_minus_baseline"] >= 0.02 and lower > 0
    )
    comparison["eligible"] = eligible
    comparison["rule"] = (
        "mean EX improvement >= 0.02 and paired item-clustered "
        "bootstrap 95% interval excludes zero"
    )
    return eligible, comparison


def configurations_are_tied(
    candidate: Aggregate, incumbent: Aggregate
) -> tuple[bool, dict[str, Any]]:
    comparison = paired_item_bootstrap(candidate, incumbent)
    lower, upper = comparison["ci95"]
    tied = (
        abs(comparison["candidate_minus_baseline"]) < 0.02
        or lower <= 0 <= upper
    )
    comparison["tied"] = tied
    return tied, comparison


def analysis_id(payload: Any) -> str:
    encoded = json.dumps(
        payload, sort_keys=True, separators=(",", ":")
    ).encode()
    return hashlib.sha256(encoded).hexdigest()[:16]
