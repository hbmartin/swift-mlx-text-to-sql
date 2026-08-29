from pathlib import Path


def raw_membership(needle: str, step: dict[str, str]) -> bool:
    haystack = step.get("run", "")
    # ruleid: creg-shell-contracts-require-structured-validation
    return needle in haystack


def raw_negative_membership(needle: str, phase: dict[str, str]) -> bool:
    payload = phase.get("shellScript")
    # ruleid: creg-shell-contracts-require-structured-validation
    return needle not in payload


def raw_find(needle: str, step: dict[str, str]) -> bool:
    payload = step["run"]
    # ruleid: creg-shell-contracts-require-structured-validation
    return payload.find(needle) >= 0


def raw_index(needle: str, phase: dict[str, str]) -> int:
    payload = phase["shellScript"]
    # ruleid: creg-shell-contracts-require-structured-validation
    return payload.index(needle)


def raw_prefix(needle: str, step: dict[str, str]) -> bool:
    payload = step.get("run")
    # ruleid: creg-shell-contracts-require-structured-validation
    return payload.startswith(needle)


def raw_suffix(needle: str, phase: dict[str, str]) -> bool:
    payload = phase.get("shellScript", "")
    # ruleid: creg-shell-contracts-require-structured-validation
    return payload.endswith(needle)


def raw_inline(needle: str, step: dict[str, str]) -> bool:
    # ruleid: creg-shell-contracts-require-structured-validation
    return needle in step.get("run", "")


def raw_parameter_membership(expected_fragment: str, script: str) -> bool:
    # ruleid: creg-shell-contracts-require-structured-validation
    return expected_fragment in script


def validate_in_helper(expected_fragment: str, step: dict[str, str]) -> bool:
    # ok: creg-shell-contracts-require-structured-validation
    return raw_parameter_membership(expected_fragment, step.get("run", ""))


def reviewed_parsed_tokens(flag: str, step: dict[str, str]) -> bool:
    parsed = _parse_single_shell_command(step.get("run", ""))
    # ok: creg-shell-contracts-require-structured-validation
    return flag in parsed.tokens


def reviewed_path_membership(fragment: str, script: Path) -> bool:
    # ok: creg-shell-contracts-require-structured-validation
    return fragment in script.parts


def reviewed_documentation_source(fragment: str, source: str) -> bool:
    # ok: creg-shell-contracts-require-structured-validation
    return fragment in source


def reviewed_shell_contract(expected: str, phase: dict[str, str]) -> bool:
    script = phase.get("shellScript")
    # ok: creg-shell-contracts-require-structured-validation
    return script == expected


def reviewed_command_set(step: dict[str, str], reviewed: set[str]) -> bool:
    script = step.get("run", "")
    # ok: creg-shell-contracts-require-structured-validation
    return script in reviewed


def documentation_contains_fragment(fragment: str, documentation: str) -> bool:
    # ok: creg-shell-contracts-require-structured-validation
    return fragment in documentation
