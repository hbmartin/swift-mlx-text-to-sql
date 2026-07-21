import hashlib
from pathlib import Path

from eval.prompt_contract import (
    build_repair_prompt,
    build_system_prompt,
    prompt_contract_receipt,
)

ROOT = Path(__file__).resolve().parents[2]


def test_system_prompt_matches_the_swift_parity_contract() -> None:
    schema = (
        (
            ROOT
            / "CREGKit"
            / "Sources"
            / "CREGEngine"
            / "Resources"
            / "schema_prompt.txt"
        )
        .read_text()
        .strip()
    )
    digest = hashlib.sha256(build_system_prompt(schema).encode()).hexdigest()
    assert digest == "61a7b58025395428e9e4c701d26969cea9c9b2f25d49f752d7429d2aa54922b5"


def test_repair_prompt_matches_the_swift_runtime_contract() -> None:
    assert (
        build_repair_prompt(
            question="Total fund value?",
            failed_sql="SELECT current_market_value FROM funds",
            sqlite_error="no such column: current_market_value",
            issue_type="binding",
            issue_disposition="repairable",
            declared_sources=["funds"],
            possible_column_owners=["properties"],
            failed_fingerprints=["abc123"],
        )
        == """Question: Total fund value?

Your previous attempt failed. Fix it.
Previous SQL: SELECT current_market_value FROM funds
SQLite error: no such column: current_market_value
Issue type: binding
Issue disposition: repairable
Declared sources: funds
Possible column owners: properties
Prior failed fingerprints: abc123"""
    )


def test_repair_prompt_substitutes_original_template_only_once() -> None:
    rendered = build_repair_prompt(
        question="Why did {{FAILED_SQL}} fail?",
        failed_sql="SELECT {{QUESTION}}",
        sqlite_error="no such column: {{ISSUE_TYPE}}",
        issue_type="binding",
        issue_disposition="repairable",
    )
    assert "Question: Why did {{FAILED_SQL}} fail?" in rendered
    assert "Previous SQL: SELECT {{QUESTION}}" in rendered
    assert "SQLite error: no such column: {{ISSUE_TYPE}}" in rendered


def test_prompt_receipt_binds_both_templates_and_generated_catalog() -> None:
    receipt = prompt_contract_receipt("example schema")
    assert receipt["prompt_version"] == "reliability-v2"
    assert receipt["policy_version"] == "bounded-three-generation-v1"
    assert receipt["schema_catalog_version"] == 1
    for name in (
        "system_template_sha256",
        "repair_template_sha256",
        "schema_catalog_sha256",
        "rendered_system_prompt_sha256",
    ):
        assert len(receipt[name]) == 64
