"""Execute named, resumable cells of the approved evaluation matrix.

Run IDs are deterministic and immutable. A completed matching directory is
reused; an incomplete directory is never overwritten and stops the matrix.
Adaptive phases require the selected artifact keys/GCD modes from the prior
immutable analysis rather than silently choosing defaults.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from eval.run_artifacts import DEFAULT_RUNS_DIR, REPO_ROOT
from tools.fetch_model import load_manifest

GOLD_V1 = REPO_ROOT / "eval" / "gold" / "gold_v1.jsonl"
GOLD_V2 = REPO_ROOT / "eval" / "gold" / "gold_v2.jsonl"
MANIFEST = REPO_ROOT / "model-manifest.json"


@dataclass(frozen=True)
class Cell:
    model_key: str
    gold: Path
    gcd: str
    temperature: float
    seed: int
    label: str

    @property
    def run_id(self) -> str:
        temperature = str(self.temperature).replace(".", "_")
        return (
            f"matrix-{self.label}-{self.model_key}-gcd-{self.gcd}"
            f"-t-{temperature}-s-{self.seed}"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "phase",
        choices=["screen", "gcd", "fine-tune-gcd", "temperature"],
    )
    parser.add_argument(
        "--artifact",
        action="append",
        help=(
            "Adaptive artifact as MODEL_KEY:GCD. Required twice for gcd and "
            "fine-tune-gcd, and four times for temperature."
        ),
    )
    parser.add_argument("--runs-dir", type=Path, default=DEFAULT_RUNS_DIR)
    parser.add_argument("--max-items", type=int)
    parser.add_argument(
        "--dry-run", action="store_true", help="print without executing"
    )
    return parser.parse_args()


def artifact_specs(values: list[str] | None) -> list[tuple[str, str]]:
    specs = []
    for value in values or []:
        try:
            model, gcd = value.rsplit(":", 1)
        except ValueError as error:
            raise SystemExit(
                f"invalid --artifact {value!r}; expected MODEL_KEY:on|off"
            ) from error
        if gcd not in {"on", "off"}:
            raise SystemExit(f"invalid GCD mode in --artifact {value!r}")
        specs.append((model, gcd))
    return specs


def cells(args: argparse.Namespace) -> list[Cell]:
    models = [
        model["key"] for model in load_manifest(MANIFEST)["models"]
        if not model.get("derived")
    ]
    specs = artifact_specs(args.artifact)
    if args.phase == "screen":
        if specs:
            raise SystemExit("screen does not accept --artifact")
        return [
            Cell(model, GOLD_V1, gcd, 0.0, 0, "screen-gold-v1")
            for model in models
            for gcd in ("on", "off")
        ]
    if args.phase in {"gcd", "fine-tune-gcd"}:
        if len(specs) != 2:
            raise SystemExit(
                f"{args.phase} requires exactly two selected --artifact values"
            )
        label = (
            "base-gold-v2"
            if args.phase == "gcd"
            else "fine-tune-gold-v2"
        )
        return [
            Cell(model, GOLD_V2, gcd, 0.0, 0, label)
            for model, _ in specs
            for gcd in ("on", "off")
        ]
    if len(specs) != 4:
        raise SystemExit(
            "temperature requires exactly four eligible --artifact values"
        )
    return [
        Cell(model, GOLD_V2, gcd, temperature, seed, "temperature-gold-v2")
        for model, gcd in specs
        for temperature in (0.0, 0.1, 0.3, 0.7)
        for seed in range(5)
    ]


def complete(directory: Path) -> bool:
    manifest = directory / "manifest.json"
    if not manifest.is_file():
        return False
    return json.loads(manifest.read_text()).get("status") == "complete"


def main() -> None:
    args = parse_args()
    runs_dir = args.runs_dir.resolve()
    for cell in cells(args):
        directory = runs_dir / cell.run_id
        if directory.exists():
            if complete(directory):
                print(f"reuse complete run {cell.run_id}", flush=True)
                continue
            raise SystemExit(
                f"immutable run exists but is incomplete: {directory}"
            )
        command = [
            sys.executable,
            "-m",
            "eval.run_eval",
            "--model-key",
            cell.model_key,
            "--gold",
            str(cell.gold),
            "--gcd",
            cell.gcd,
            "--temperature",
            str(cell.temperature),
            "--seed",
            str(cell.seed),
            "--run-id",
            cell.run_id,
            "--runs-dir",
            str(runs_dir),
        ]
        if args.max_items is not None:
            command.extend(["--max-items", str(args.max_items)])
        print(" ".join(command), flush=True)
        if not args.dry_run:
            subprocess.run(command, cwd=REPO_ROOT / "fine-tuning", check=True)


if __name__ == "__main__":
    main()
