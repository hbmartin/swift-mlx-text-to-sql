"""Create evidence-based explanations for Python/Swift parity divergences.

Generated-SQL differences are attributed only after every input identity
matches. Identical SQL can be explained only when both artifacts persist
different SQLite engine versions; this records an engine-compatibility
difference instead of mislabeling it as model-generation drift.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from eval.run_artifacts import write_json
from eval.selection import SelectionError, load_run


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python-run", type=Path, required=True)
    parser.add_argument("--swift-output", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.out.exists():
        raise SelectionError(f"refusing to overwrite explanations: {args.out}")
    python_run = load_run(args.python_run)
    swift = json.loads(args.swift_output.read_text())
    python_by_id = {item["id"]: item for item in python_run.items}
    swift_by_id = {item["id"]: item for item in swift["results"]}
    if set(python_by_id) != set(swift_by_id):
        raise SelectionError("Python and Swift item IDs differ")
    expected_model = python_run.manifest["model"]
    expected_gcd = python_run.summary["gcd"]
    expected_temperature = float(python_run.summary["temperature"])
    python_sqlite = python_run.manifest.get("dependencies", {}).get("sqlite")
    swift_sqlite = swift.get("provenance", {}).get("sqliteVersion")
    if not python_sqlite or not swift_sqlite:
        raise SelectionError(
            "both parity artifacts must persist their SQLite engine version"
        )

    explanations: dict[str, str] = {}
    for item_id in sorted(python_by_id):
        python_item = python_by_id[item_id]
        swift_item = swift_by_id[item_id]
        swift_item_model = swift_item.get("model", {})
        if (
            int(swift_item.get("seed", -1))
            != int(python_item["item_seed"])
            or int(swift_item.get("tier", -1))
            != int(python_item["tier"])
            or swift_item.get("goldSQL") != python_item["gold_sql"]
            or swift_item.get("gcd") != expected_gcd
            or float(swift_item.get("temperature", -1))
            != expected_temperature
            or swift_item_model.get("key") != python_run.model_key
            or swift_item_model.get("repository")
            != expected_model["repository"]
            or swift_item_model.get("revision")
            != expected_model["revision"]
        ):
            raise SelectionError(
                f"{item_id}: Python and Swift per-item parity inputs differ"
            )
        python_digest = (python_item.get("predicted") or {}).get("digest")
        swift_digest = swift_item.get("predictedDigest")
        python_valid = python_item.get("error") is None
        swift_valid = bool(swift_item.get("validSQL"))
        python_ex = bool(python_item.get("ex"))
        swift_ex = bool(swift_item.get("ex"))
        python_sql = python_item.get("predicted_sql")
        swift_sql = swift_item.get("predictedSQL")
        differs = (
            python_sql != swift_sql
            or python_digest != swift_digest
            or python_valid != swift_valid
            or python_ex != swift_ex
        )
        if not differs:
            continue
        if python_sql == swift_sql:
            if python_sqlite == swift_sqlite:
                raise SelectionError(
                    f"{item_id}: identical SQL on the same SQLite version "
                    "produced different parity data; fix runtime/comparator "
                    "drift before explaining it"
                )
            effect = (
                f"The identical SQL ran on SQLite {python_sqlite} in Python "
                f"and SQLite {swift_sqlite} in Swift. The engine-version "
                "difference changed "
                + (
                    "executability."
                    if python_valid != swift_valid
                    else "the complete typed result or EX classification."
                )
            )
            explanations[item_id] = (
                "The matched artifact, GCD mode, temperature, item seed, "
                "prompt, database, gold SQL, and canonical gold digest rule "
                "out model-input and comparator drift. "
                + effect
            )
            continue

        if not python_valid and not swift_valid:
            effect = (
                "Both SQL forms were invalid and EX was false; the generated "
                "text differed but neither execution produced a Result Group."
            )
        elif python_digest is not None and python_digest == swift_digest:
            effect = (
                "Both SQL forms executed to the same complete typed-result "
                "SHA-256, so this is a semantically equivalent generation "
                "difference with no EX or validity impact."
            )
        elif python_valid != swift_valid:
            effect = (
                f"The Python SQL was {'valid' if python_valid else 'invalid'} "
                f"and the Swift SQL was {'valid' if swift_valid else 'invalid'}, "
                "so the generated-token difference changed executability."
            )
        elif python_ex != swift_ex:
            effect = (
                f"Python EX was {str(python_ex).lower()} and Swift EX was "
                f"{str(swift_ex).lower()}, so the generated-token difference "
                "changed correctness."
            )
        else:
            effect = (
                "Both outputs had the same validity and EX classification but "
                "different complete typed-result SHA-256 values."
            )
        explanations[item_id] = (
            "The matched artifact, GCD mode, temperature, item seed, prompt, "
            "database, and typed-result fixtures isolate this to SQL generation "
            "drift between the pinned MLX Python and MLX Swift runtimes. "
            + effect
        )

    args.out.parent.mkdir(parents=True, exist_ok=True)
    write_json(args.out, explanations)
    print(
        json.dumps(
            {
                "output": str(args.out.resolve()),
                "explained_disagreements": len(explanations),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    try:
        main()
    except SelectionError as error:
        raise SystemExit(f"parity explanation failed: {error}") from error
