import json
from pathlib import Path

import yaml
from mlx_lm.lora import CONFIG_DEFAULTS

from eval.run_artifacts import sha256_file

ROOT = Path(__file__).resolve().parents[2]


def test_qlora_configuration_makes_every_mlx_lm_option_explicit():
    configuration = yaml.safe_load((ROOT / "fine-tuning/config/qlora.yaml").read_text())
    assert set(configuration) == set(CONFIG_DEFAULTS)
    assert configuration["seed"] == 424242
    assert configuration["iters"] == 600
    assert configuration["batch_size"] == 4
    assert configuration["num_layers"] == 16
    assert configuration["learning_rate"] == 1e-4
    assert configuration["mask_prompt"] is True
    assert configuration["fine_tune_type"] == "lora"


def test_sweeps_launch_the_experiment_runner_as_a_python_module():
    for path in sorted((ROOT / "fine-tuning/config/sweeps").glob("*.yaml")):
        sweep = yaml.safe_load(path.read_text())
        assert sweep["program"] == "tools.run_experiment"
        assert sweep["command"][:4] == [
            "${env}",
            "${interpreter}",
            "-m",
            "${program}",
        ]


def test_committed_corpus_matches_its_versioned_manifest():
    declaration = json.loads(
        (ROOT / "fine-tuning/config/corpus-manifest.json").read_text()
    )
    assert declaration["generator_seed"] == 424242
    assert declaration["schema_version"] == 2
    assert declaration["gold_holdouts"] == [
        "eval/gold/gold_v1.jsonl",
        "eval/gold/gold_v2.jsonl",
    ]
    assert declaration["prompt_contract"]["prompt_version"] == "reliability-v2"
    for file in declaration["files"]:
        assert sha256_file(ROOT / file["path"]) == file["sha256"]


def test_committed_corpus_excludes_all_gold_text_and_contains_repairs():
    def normalize(value: str) -> str:
        return "".join(
            character
            for character in value.lower()
            if character.isalnum() or character == " "
        ).strip()

    gold = {
        normalize(json.loads(line)["question"])
        for name in ("gold_v1.jsonl", "gold_v2.jsonl")
        for line in (ROOT / "eval" / "gold" / name).read_text().splitlines()
        if line.strip()
    }
    records = [
        json.loads(line)
        for name in ("train.jsonl", "valid.jsonl")
        for line in (ROOT / "fine-tuning" / "synth" / "out" / name)
        .read_text()
        .splitlines()
        if line.strip()
    ]
    user_messages = [record["messages"][1]["content"] for record in records]
    questions = {
        normalize(message.splitlines()[0].removeprefix("Question: "))
        for message in user_messages
    }
    assert gold.isdisjoint(questions)
    assert (
        sum("Your previous attempt failed" in message for message in user_messages)
        >= 16
    )
    assert any("trailing 3-month NOI" in message for message in user_messages)

    repair_messages = [
        message
        for message in user_messages
        if "Your previous attempt failed" in message
    ]
    assert all("Declared sources: " in message for message in repair_messages)
    assert all("Possible column owners: " in message for message in repair_messages)
    assert all(
        len(
            next(
                line.removeprefix("Prior failed fingerprints: ")
                for line in message.splitlines()
                if line.startswith("Prior failed fingerprints: ")
            )
        )
        == 64
        for message in repair_messages
    )
    assert all(
        next(
            line.removeprefix("Declared sources: ")
            for line in message.splitlines()
            if line.startswith("Declared sources: ")
        )
        for message in repair_messages
    )
    assert all(
        next(
            line.removeprefix("Possible column owners: ")
            for line in message.splitlines()
            if line.startswith("Possible column owners: ")
        )
        for message in repair_messages
    )

    pairs = [
        (record["messages"][1]["content"], record["messages"][2]["content"])
        for record in records
    ]
    tenant_counts = [
        sql
        for question, sql in pairs
        if "How many tenants have active leases in" in question
        or "Active tenant count at" in question
    ]
    lease_counts = [
        sql for question, sql in pairs if "How many active leases are at" in question
    ]
    assert tenant_counts and all(
        "COUNT(DISTINCT l.tenant_id)" in sql for sql in tenant_counts
    )
    assert lease_counts and all("COUNT(*)" in sql for sql in lease_counts)
