import json
from pathlib import Path

import yaml
from mlx_lm.lora import CONFIG_DEFAULTS

from eval.run_artifacts import sha256_file

ROOT = Path(__file__).resolve().parents[2]


def test_qlora_configuration_makes_every_mlx_lm_option_explicit():
    configuration = yaml.safe_load(
        (ROOT / "fine-tuning/config/qlora.yaml").read_text()
    )
    assert set(configuration) == set(CONFIG_DEFAULTS)
    assert configuration["seed"] == 424242
    assert configuration["iters"] == 600
    assert configuration["batch_size"] == 4
    assert configuration["num_layers"] == 16
    assert configuration["learning_rate"] == 1e-4
    assert configuration["mask_prompt"] is True
    assert configuration["fine_tune_type"] == "lora"


def test_committed_corpus_matches_its_versioned_manifest():
    declaration = json.loads(
        (ROOT / "fine-tuning/config/corpus-manifest.json").read_text()
    )
    assert declaration["generator_seed"] == 424242
    assert declaration["gold_holdout"] == "eval/gold/gold_v2.jsonl"
    for file in declaration["files"]:
        assert sha256_file(ROOT / file["path"]) == file["sha256"]
