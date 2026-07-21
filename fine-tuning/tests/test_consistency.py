from pathlib import Path

from eval.run_consistency import run_is_compatible
from eval.selection import Run


def compatible_run() -> Run:
    return Run(
        directory=Path("/tmp/run"),
        manifest={
            "model": {
                "repository": "owner/model",
                "revision": "a" * 40,
            },
            "configuration": {
                "top_p": 1.0,
                "top_k": 0,
                "max_tokens": 512,
                "item_seed_formula":
                    "run_seed * 1000000 + zero_based_item_index",
            },
            "inputs": {"gold": {"sha256": "b" * 64}},
        },
        summary={
            "model_key": "winner",
            "gcd": "on",
            "temperature": 0.3,
            "seed": 4,
            "n": 200,
        },
        items=(),
    )


def test_run_is_compatible_requires_exact_evaluation_identity() -> None:
    run = compatible_run()
    arguments = {
        "model": "winner",
        "repository": "owner/model",
        "revision": "a" * 40,
        "gcd": "on",
        "temperature": 0.3,
        "seed": 4,
        "gold_sha256": "b" * 64,
    }
    assert run_is_compatible(run, **arguments)

    for key, incompatible in (
        ("model", "other"),
        ("repository", "other/model"),
        ("revision", "c" * 40),
        ("gcd", "off"),
        ("temperature", 0.7),
        ("seed", 3),
        ("gold_sha256", "d" * 64),
    ):
        changed = dict(arguments)
        changed[key] = incompatible
        assert not run_is_compatible(run, **changed)


def test_run_is_compatible_rejects_noncanonical_sampler_settings() -> None:
    run = compatible_run()
    run.manifest["configuration"]["top_k"] = 20
    assert not run_is_compatible(
        run,
        model="winner",
        repository="owner/model",
        revision="a" * 40,
        gcd="on",
        temperature=0.3,
        seed=4,
        gold_sha256="b" * 64,
    )


def test_run_is_compatible_requires_all_frozen_input_hashes() -> None:
    run = compatible_run()
    run.manifest["model"].update(
        {
            "artifact_lock": {"sha256": "c" * 64},
            "directory_sha256": "d" * 64,
        }
    )
    input_sha256 = {
        "database": "e" * 64,
        "grammar": "f" * 64,
        "schema_prompt": "0" * 64,
        "swift_package_lock": "1" * 64,
        "uv_lock": "2" * 64,
        "tokenizer": "3" * 64,
        "system_prompt_sha256": "4" * 64,
    }
    run.manifest["inputs"].update(
        {
            name: (
                digest
                if name == "system_prompt_sha256"
                else {"sha256": digest}
            )
            for name, digest in input_sha256.items()
        }
    )
    arguments = {
        "model": "winner",
        "repository": "owner/model",
        "revision": "a" * 40,
        "gcd": "on",
        "temperature": 0.3,
        "seed": 4,
        "gold_sha256": "b" * 64,
        "input_sha256": input_sha256,
        "artifact_lock_sha256": "c" * 64,
        "directory_sha256": "d" * 64,
    }
    assert run_is_compatible(run, **arguments)

    run.manifest["inputs"]["grammar"]["sha256"] = "9" * 64
    assert not run_is_compatible(run, **arguments)
