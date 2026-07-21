import hashlib
from pathlib import Path

from eval.prompt_contract import build_system_prompt

ROOT = Path(__file__).resolve().parents[2]


def test_system_prompt_matches_the_swift_parity_contract() -> None:
    schema = (
        ROOT
        / "CREGKit"
        / "Sources"
        / "CREGEngine"
        / "Resources"
        / "schema_prompt.txt"
    ).read_text().strip()
    digest = hashlib.sha256(build_system_prompt(schema).encode()).hexdigest()
    assert (
        digest
        == "28f89133847e9383cb8a0426ba612735bb1fd278ad5246df578b8e799a9571b3"
    )
