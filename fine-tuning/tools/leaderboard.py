"""Assemble eval/out/*.summary.json into a markdown leaderboard.

Usage:  uv run python -m tools.leaderboard [--out ../docs/leaderboard.md]
"""

import argparse
import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = REPO_ROOT / "eval" / "out"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()

    summaries = []
    for path in sorted(OUT_DIR.glob("*.summary.json")):
        if path.stem.startswith("smoke"):
            continue
        summaries.append(json.loads(path.read_text()))
    summaries.sort(key=lambda s: (-s["ex"], s["mean_seconds"]))

    lines = [
        "# Evaluation leaderboard",
        "",
        "| config | gold | SQL scored / total | EX | valid SQL | T1 | T2 | T3 | s/item | top failure buckets |",
        "|---|---|---|---|---|---|---|---|---|---|",
    ]
    for s in summaries:
        tiers = s.get("ex_by_tier", {})
        buckets = sorted(s.get("failure_buckets", {}).items(), key=lambda kv: -kv[1])[:3]
        bucket_str = ", ".join(f"{k}:{v}" for k, v in buckets) or "—"
        lines.append(
            f"| {s['label']} | {s['gold']} "
            f"| {s.get('scored_n', s['n'])}/{s['n']} | **{s['ex']:.3f}** "
            f"| {s['valid_sql_rate']:.3f} | {tiers.get('1', '—')} | {tiers.get('2', '—')} "
            f"| {tiers.get('3', '—')} | {s['mean_seconds']} | {bucket_str} |"
        )
    table = "\n".join(lines)
    print(table)
    if args.out:
        args.out.write_text(table + "\n")


if __name__ == "__main__":
    main()
