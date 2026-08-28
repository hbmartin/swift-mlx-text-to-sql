def raw_shell_check(fragment: str, script: str) -> bool:
    # ruleid: creg-shell-contracts-require-structured-validation
    return fragment in script


def raw_shell_source_check(fragment: str, source: str) -> bool:
    # ruleid: creg-shell-contracts-require-structured-validation
    return fragment in source


def raw_shell_find(expected: str, script: str) -> bool:
    # ruleid: creg-shell-contracts-require-structured-validation
    return script.find(expected) >= 0


def raw_shell_prefix(required_prefix: str, command: str) -> bool:
    # ruleid: creg-shell-contracts-require-structured-validation
    return command.startswith(required_prefix)


def reviewed_shell_contract(expected: str, script: str) -> bool:
    # ok: creg-shell-contracts-require-structured-validation
    return script == expected


def documentation_contains_fragment(fragment: str, documentation: str) -> bool:
    # ok: creg-shell-contracts-require-structured-validation
    return fragment in documentation
