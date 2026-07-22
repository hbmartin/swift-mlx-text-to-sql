"""Regenerate the three canonical reliability-v3 repair-ratio corpora."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

from eval.prompt_contract import prompt_contract_receipt
from eval.run_artifacts import REPO_ROOT, sha256_file, write_json
from synth.generate_training import CORPUS_VERSION, SEED


OUTPUT_ROOT = REPO_ROOT / "fine-tuning" / "synth" / "out"
MANIFEST = REPO_ROOT / "fine-tuning" / "config" / "corpus-manifest.json"
VARIANTS = {
    0.05: OUTPUT_ROOT / "repair-05",
    0.10: OUTPUT_ROOT,
    0.20: OUTPUT_ROOT / "repair-20",
}
FILENAMES = ("train.jsonl", "valid.jsonl", "gate_stats.json", "split_manifest.json")


def corpus_sha256(repair_fraction: float, files: list[dict]) -> str:
    payload = {
        "corpus_version": CORPUS_VERSION,
        "repair_fraction": repair_fraction,
        "files": sorted(
            ({"name": Path(item["path"]).name, "sha256": item["sha256"]} for item in files),
            key=lambda item: item["name"],
        ),
    }
    return hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def generate() -> dict:
    variants = {}
    for repair_fraction, output in VARIANTS.items():
        subprocess.run(
            [
                sys.executable,
                "-m",
                "synth.generate_training",
                "--out-dir",
                str(output),
                "--repair-fraction",
                str(repair_fraction),
            ],
            cwd=REPO_ROOT / "fine-tuning",
            check=True,
        )
        files = [
            {
                "path": path.relative_to(REPO_ROOT).as_posix(),
                "sha256": sha256_file(path),
            }
            for filename in FILENAMES
            for path in (output / filename,)
        ]
        key = f"repair-{round(repair_fraction * 100):02d}"
        variants[key] = {
            "repair_fraction": repair_fraction,
            "corpus_sha256": corpus_sha256(repair_fraction, files),
            "files": files,
        }
    manifest = {
        "schema_version": 3,
        "corpus_version": CORPUS_VERSION,
        "generator_seed": SEED,
        "default_variant": "repair-10",
        "repair_fraction_probe": [0.05, 0.10, 0.20],
        "gold_holdouts": [
            "eval/gold/gold_v1.jsonl",
            "eval/gold/gold_v2.jsonl",
        ],
        "prompt_contract": prompt_contract_receipt(),
        "split_contract": {
            "strategy": "sql-structure-family-held-out",
            "validation_fraction": 0.05,
            "maximum_sql_structure_overlap": 0,
        },
        "files": variants["repair-10"]["files"],
        "variants": variants,
    }
    write_json(MANIFEST, manifest)
    return manifest


def main() -> None:
    print(json.dumps(generate(), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
