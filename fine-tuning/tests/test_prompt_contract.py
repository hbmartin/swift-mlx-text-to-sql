import hashlib

from eval.prompt_contract import (
    DATA_RESOURCE_DIRECTORY,
    INFERENCE_RESOURCE_DIRECTORY,
    REPAIR_PROMPT_TEMPLATE_PATH,
    SCHEMA_CATALOG_PATH,
    SCHEMA_PROMPT_PATH,
    SQL_GRAMMAR_PATH,
    SYSTEM_PROMPT_TEMPLATE_PATH,
    build_repair_prompt,
    build_system_prompt,
    prompt_contract_receipt,
)
from tools.generate_grammar import DATA_RESOURCE_DIR, INFERENCE_RESOURCE_DIR


def test_system_prompt_matches_the_swift_parity_contract() -> None:
    schema = SCHEMA_PROMPT_PATH.read_text().strip()
    digest = hashlib.sha256(build_system_prompt(schema).encode()).hexdigest()
    assert digest == "f9edfd023d97867fbd8ea178ddff374de8daef080bff96b2082896971b0dfddc"


def test_generator_and_prompt_contract_share_split_resource_targets() -> None:
    assert INFERENCE_RESOURCE_DIR == INFERENCE_RESOURCE_DIRECTORY
    assert DATA_RESOURCE_DIR == DATA_RESOURCE_DIRECTORY
    assert SQL_GRAMMAR_PATH.parent == INFERENCE_RESOURCE_DIRECTORY
    assert SCHEMA_PROMPT_PATH.parent == INFERENCE_RESOURCE_DIRECTORY
    assert SYSTEM_PROMPT_TEMPLATE_PATH.parent == INFERENCE_RESOURCE_DIRECTORY
    assert REPAIR_PROMPT_TEMPLATE_PATH.parent == INFERENCE_RESOURCE_DIRECTORY
    assert SCHEMA_CATALOG_PATH.parent == DATA_RESOURCE_DIRECTORY


def test_repair_prompt_matches_the_swift_runtime_contract() -> None:
    assert (
        build_repair_prompt(
            question="Total fund value?",
            failed_sql="SELECT current_market_value FROM funds",
            sqlite_error="no such column: current_market_value",
            issue_type="binding",
            issue_disposition="repairable",
            invalid_reference="current_market_value",
            declared_sources=["funds"],
            possible_column_owners=["properties"],
            source_columns={"funds": ["fund_id", "name"]},
            relevant_foreign_keys=["properties.fund_id -> funds.fund_id"],
            corrective_instruction="Join properties and use properties.current_market_value.",
        )
        == """Question: Total fund value?

The previous SQL failed SQLite validation.
Failed SQL: SELECT current_market_value FROM funds
Validation error: no such column: current_market_value
Issue type: binding
Issue disposition: repairable
Invalid reference: current_market_value
Declared sources: funds
Declared source schemas: funds(fund_id, name)
Possible owning tables: properties
Relevant join paths: properties.fund_id -> funds.fund_id
Required correction: Join properties and use properties.current_market_value.

Return exactly one corrected SQLite SELECT statement. Use only columns owned by declared sources, add a schema-valid join when another table owns the needed value, and do not repeat the failed SQL."""
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
    assert "Failed SQL: SELECT {{QUESTION}}" in rendered
    assert "Validation error: no such column: {{ISSUE_TYPE}}" in rendered


def test_prompt_receipt_binds_both_templates_and_generated_catalog() -> None:
    receipt = prompt_contract_receipt("example schema")
    assert receipt["prompt_version"] == "reliability-v4"
    assert receipt["policy_version"] == "bounded-repair-state-machine-v2"
    assert receipt["schema_catalog_version"] == 2
    for name in (
        "system_template_sha256",
        "repair_template_sha256",
        "schema_catalog_sha256",
        "rendered_system_prompt_sha256",
    ):
        assert len(receipt[name]) == 64
