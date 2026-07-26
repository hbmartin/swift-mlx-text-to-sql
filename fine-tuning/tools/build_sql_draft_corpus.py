#!/usr/bin/env python3
"""Build the compact, deterministic SQL-only speculative-draft resource."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def build_payload(input_path: Path) -> dict[str, object]:
    """Extract the exact assistant SQL used by the production draft table."""
    source = input_path.read_bytes()
    statements: list[str] = []
    for line_number, raw_line in enumerate(source.splitlines(), start=1):
        if not raw_line.strip():
            continue
        document = json.loads(raw_line)
        assistant = [
            message["content"]
            for message in document["messages"]
            if message["role"] == "assistant"
        ]
        if len(assistant) != 1:
            raise ValueError(
                f"line {line_number} must contain exactly one assistant message"
            )
        sql = assistant[0]
        leading_keyword = sql.lstrip().upper()
        if not leading_keyword.startswith(("SELECT", "WITH")):
            raise ValueError(f"line {line_number} assistant output is not query SQL")
        statements.append(sql)

    return {
        "schema_version": 1,
        "source_sha256": hashlib.sha256(source).hexdigest(),
        "statement_count": len(statements),
        "statements": statements,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    payload = build_payload(args.input)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
