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


def reviewed_shell_contract(expected: str, phase: dict[str, str]) -> bool:
    script = phase.get("shellScript")
    # ok: creg-shell-contracts-require-structured-validation
    return script == expected


def documentation_contains_fragment(fragment: str, documentation: str) -> bool:
    # ok: creg-shell-contracts-require-structured-validation
    return fragment in documentation
