"""Shared, dependency-free text-to-SQL prompt contract."""

from __future__ import annotations

import hashlib
import re
import json
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
INFERENCE_RESOURCE_DIRECTORY = (
    REPO_ROOT / "CREGKit" / "Sources" / "CREGInference" / "Resources"
)
DATA_RESOURCE_DIRECTORY = (
    REPO_ROOT / "CREGKit" / "Sources" / "CREGData" / "Resources"
)
SQL_GRAMMAR_PATH = INFERENCE_RESOURCE_DIRECTORY / "sql_grammar.ebnf"
SCHEMA_PROMPT_PATH = INFERENCE_RESOURCE_DIRECTORY / "schema_prompt.txt"
SYSTEM_PROMPT_TEMPLATE_PATH = (
    INFERENCE_RESOURCE_DIRECTORY / "system_prompt_template.txt"
)
REPAIR_PROMPT_TEMPLATE_PATH = (
    INFERENCE_RESOURCE_DIRECTORY / "repair_prompt_template.txt"
)
SCHEMA_CATALOG_PATH = DATA_RESOURCE_DIRECTORY / "schema_catalog.json"
PROMPT_VERSION = "reliability-v4"
POLICY_VERSION = "bounded-repair-state-machine-v2"


def _template(path: Path) -> str:
    return path.read_text().rstrip("\r\n")


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prompt_contract_receipt(schema: str | None = None) -> dict[str, Any]:
    """Return the immutable prompt/catalog identity recorded by every run."""

    catalog = json.loads(SCHEMA_CATALOG_PATH.read_text())
    receipt: dict[str, Any] = {
        "prompt_version": PROMPT_VERSION,
        "policy_version": POLICY_VERSION,
        "system_template_sha256": _sha256(SYSTEM_PROMPT_TEMPLATE_PATH),
        "repair_template_sha256": _sha256(REPAIR_PROMPT_TEMPLATE_PATH),
        "schema_catalog_sha256": _sha256(SCHEMA_CATALOG_PATH),
        "schema_catalog_version": catalog["schema_version"],
    }
    if schema is not None:
        receipt["rendered_system_prompt_sha256"] = hashlib.sha256(
            build_system_prompt(schema).encode()
        ).hexdigest()
    return receipt


def build_system_prompt(schema: str) -> str:
    return _template(SYSTEM_PROMPT_TEMPLATE_PATH).replace("{{SCHEMA}}", schema)


def build_repair_prompt(
    *,
    question: str,
    failed_sql: str,
    sqlite_error: str,
    issue_type: str,
    issue_disposition: str,
    invalid_reference: str = "",
    declared_sources: list[str] | tuple[str, ...] = (),
    possible_column_owners: list[str] | tuple[str, ...] = (),
    source_columns: dict[str, list[str] | tuple[str, ...]] | None = None,
    relevant_foreign_keys: list[str] | tuple[str, ...] = (),
    corrective_instruction: str = "",
    failed_fingerprints: list[str] | tuple[str, ...] = (),
) -> str:
    del failed_fingerprints  # Fingerprints are telemetry identity, not model guidance.
    source_columns = source_columns or {}
    replacements = {
        "{{QUESTION}}": question,
        "{{FAILED_SQL}}": failed_sql,
        "{{SQLITE_ERROR}}": sqlite_error,
        "{{ISSUE_TYPE}}": issue_type,
        "{{ISSUE_DISPOSITION}}": issue_disposition,
        "{{INVALID_REFERENCE}}": invalid_reference,
        "{{DECLARED_SOURCES}}": ", ".join(declared_sources),
        "{{SOURCE_COLUMNS}}": "; ".join(
            f"{table}({', '.join(columns)})"
            for table, columns in sorted(source_columns.items())
        ),
        "{{POSSIBLE_COLUMN_OWNERS}}": ", ".join(possible_column_owners),
        "{{RELEVANT_FOREIGN_KEYS}}": "; ".join(relevant_foreign_keys),
        "{{CORRECTIVE_INSTRUCTION}}": corrective_instruction,
    }
    return re.sub(
        r"\{\{[A-Z_]+\}\}",
        lambda match: replacements.get(match.group(0), match.group(0)),
        _template(REPAIR_PROMPT_TEMPLATE_PATH),
    )
