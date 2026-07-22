import base64
import hashlib
import json
import subprocess
from pathlib import Path

import pytest
import yaml

from eval.experiment import (
    ExperimentConfig,
    ExperimentConfigurationError,
    campaign_tags,
    immutable_run_id,
    select_development_checkpoint,
)
from eval.run_artifacts import sha256_file, write_json
from eval.wandb_evidence import (
    WandbEvidenceError,
    WandbUploader,
    require_wandb_complete,
    required_wandb_environment,
    synchronize_manifest,
    write_canonical_evidence,
)
from eval.file_integrity import IntegrityError
from tools.sync_wandb import attach_post_selection_evidence, attach_selection_evidence
from tools.evaluate_checkpoints import (
    evaluate_training_checkpoints,
)
from tools.import_wandb_history import parse_training_log
from tools.run_experiment import (
    _wandb_subprocess_environment,
    materialize_adapter_artifact,
    TrainingNumericalIntegrityError,
    verify_training_numerics,
)
from tools.promote_experiment import base_artifact_for, require_promotion_eligibility


ROOT = Path(__file__).resolve().parents[2]


def experiment(**overrides):
    values = {
        "model_key": "qwen25-coder-3b",
        "seed": 424242,
        "fine_tune_type": "lora",
        "trainable_layers": "last-16",
        "rank": 8,
        "scale_ratio": 2.5,
        "dropout": 0.0,
        "learning_rate": 1e-4,
        "iterations": 600,
        "campaign_id": "campaign-test",
    }
    values.update(overrides)
    return ExperimentConfig(**values)


def test_configuration_hash_and_run_id_bind_every_identity_axis():
    first = experiment()
    equivalent = experiment(campaign_id="another-campaign", stage="promoted")
    changed = experiment(rank=16)
    assert first.configuration_sha256 == equivalent.configuration_sha256
    assert first.configuration_sha256 != changed.configuration_sha256
    assert immutable_run_id(first, "wandb-a") != immutable_run_id(first, "wandb-b")
    assert immutable_run_id(first, "wandb-a") != immutable_run_id(changed, "wandb-a")


def test_v3_training_requires_gradient_checkpointing():
    assert experiment().grad_checkpoint is True
    with pytest.raises(
        ExperimentConfigurationError, match="gradient checkpointing must remain enabled"
    ):
        experiment(grad_checkpoint=False)


def test_training_numerics_reject_non_finite_loss_and_impossible_token_counts(
    tmp_path,
):
    config = experiment(iterations=100)
    valid = tmp_path / "valid.log"
    valid.write_text(
        "Iter 1: Val loss 1.600, Val took 1.000s\n"
        "Iter 100: Val loss 0.900, Val took 1.000s\n"
        "Iter 100: Train loss 0.055, Learning Rate 1.000e-04, "
        "It/sec 0.100, Tokens/sec 10.000, Trained Tokens 18833, "
        "Peak mem 20.000 GB\n"
    )
    receipt = verify_training_numerics(valid, config)
    assert receipt["status"] == "finite"
    assert receipt["final_trained_tokens"] == 18833

    non_finite = tmp_path / "non-finite.log"
    non_finite.write_text(
        "Iter 1: Val loss 1.600, Val took 1.000s\n"
        "Iter 100: Train loss nan, Learning Rate 1.000e-04, "
        "It/sec 0.100, Tokens/sec 10.000, Trained Tokens 18833, "
        "Peak mem 20.000 GB\n"
    )
    with pytest.raises(TrainingNumericalIntegrityError, match="non-finite train loss"):
        verify_training_numerics(non_finite, config)

    impossible = tmp_path / "impossible.log"
    impossible.write_text(
        "Iter 1: Val loss 1.600, Val took 1.000s\n"
        "Iter 100: Train loss 0.055, Learning Rate 1.000e-04, "
        "It/sec 0.100, Tokens/sec 10.000, Trained Tokens 900000, "
        "Peak mem 20.000 GB\n"
    )
    with pytest.raises(
        TrainingNumericalIntegrityError, match="impossible trained-token counter"
    ):
        verify_training_numerics(impossible, config)


def test_promotion_reports_a_missing_base_model_key():
    with pytest.raises(SystemExit, match="missing-model"):
        base_artifact_for({"models": []}, "missing-model")


def test_reused_screening_run_requires_a_matching_eligibility_receipt(tmp_path):
    manifest = {
        "run_id": "screening-run",
        "checkpoint_evaluation": {
            "selected": {"checkpoint_sha256": "a" * 64}
        },
    }
    with pytest.raises(SystemExit, match="promotion-eligibility"):
        require_promotion_eligibility(manifest)
    receipt = tmp_path / "eligibility.json"
    receipt.write_text(
        json.dumps(
            {
                "analysis": "reliability-v3-promotion-eligibility",
                "pass": True,
                "candidate_run_id": "screening-run",
                "selected_checkpoint_sha256": "a" * 64,
            }
        )
    )
    manifest["selection_evidence"] = {
        "promotion-eligibility": {
            "selection_use": "required",
            "files": [str(receipt)],
        }
    }
    require_promotion_eligibility(manifest)


def test_campaign_tags_preserve_full_corpus_digest_within_wandb_limit():
    corpus_sha256 = hashlib.sha256(b"corpus").hexdigest()
    tags = campaign_tags(
        experiment(),
        corpus_sha256=corpus_sha256,
        git_commit="a" * 40,
        status="running",
        prompt_version="reliability-v3",
        policy_version="bounded-three-generation-v1",
        corpus_version="reliability-v3",
    )

    assert all(1 <= len(tag) <= 64 for tag in tags)
    encoded = next(tag for tag in tags if tag.startswith("corpus-sha256:"))
    encoded = encoded.removeprefix("corpus-sha256:")
    decoded = base64.urlsafe_b64decode(encoded + "=")
    assert decoded.hex() == corpus_sha256
    assert "corpus:reliability-v3" in tags
    assert "repair:10pct" in tags


def test_training_wandb_environment_keeps_transport_out_of_adapter(tmp_path):
    manifest = minimal_manifest(tmp_path)
    manifest["wandb"].update(
        {
            "group": "campaign-test",
            "job_type": "confirmation",
            "tags": ["prompt:reliability-v3"],
        }
    )
    manifest["experiment"]["stage"] = "promoted"

    environment = _wandb_subprocess_environment(manifest, tmp_path)

    assert environment["WANDB_DIR"] == str(tmp_path)
    assert environment["WANDB_JOB_TYPE"] == "confirmation"
    assert environment["WANDB_RUN_GROUP"] == "campaign-test"


def test_adapter_materialization_excludes_wandb_transport_symlinks(tmp_path):
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    payload = {
        "adapter_config.json": b"{}\n",
        "adapters.safetensors": b"final",
        "0000100_adapters.safetensors": b"checkpoint",
    }
    for name, value in payload.items():
        (scratch / name).write_bytes(value)
    transport = scratch / "wandb"
    transport.mkdir()
    (transport / "run").mkdir()
    (transport / "latest-run").symlink_to("run", target_is_directory=True)
    destination = tmp_path / "adapters" / "immutable-run"

    inventory = materialize_adapter_artifact(
        scratch, destination, experiment(iterations=100)
    )

    assert {item["path"] for item in inventory} == set(payload)
    assert not scratch.exists()
    assert not (destination / "wandb").exists()


def test_adapter_materialization_rejects_unexpected_payload(tmp_path):
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    for name in (
        "adapter_config.json",
        "adapters.safetensors",
        "0000100_adapters.safetensors",
        "planted.bin",
    ):
        (scratch / name).write_bytes(b"payload")

    with pytest.raises(RuntimeError, match="extras=.*planted.bin"):
        materialize_adapter_artifact(
            scratch, tmp_path / "adapter", experiment(iterations=100)
        )


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("rank", 32),
        ("scale_ratio", 3.0),
        ("dropout", 0.1),
        ("learning_rate", 1e-6),
        ("fine_tune_type", "full"),
        ("trainable_layers", "last-8"),
    ],
)
def test_unsupported_sweep_values_are_rejected(field, value):
    with pytest.raises(ExperimentConfigurationError):
        experiment(**{field: value})


def test_checkpoint_selection_uses_declared_tie_break_order():
    base = {
        "ex": 0.8,
        "valid_sql_rate": 0.9,
        "ex_by_tier": {"1": 0.8, "2": 0.7},
        "p95_microseconds": 100,
    }
    candidates = [
        {"iteration": 200, "summary": base},
        {"iteration": 100, "summary": base},
        {
            "iteration": 300,
            "summary": {**base, "valid_sql_rate": 0.89},
        },
    ]
    assert select_development_checkpoint(candidates)["iteration"] == 100


def test_authenticated_online_environment_is_required():
    with pytest.raises(WandbEvidenceError, match="WANDB_API_KEY, WANDB_ENTITY"):
        required_wandb_environment({})
    assert required_wandb_environment(
        {"WANDB_API_KEY": "secret", "WANDB_ENTITY": "team"}
    ) == {"entity": "team", "project": "creg-sql"}


class RecordingUploader:
    def __init__(self, failures=0):
        self.failures = failures
        self.calls = []

    def upload(self, manifest, evidence_path, evidence_sha256):
        self.calls.append((manifest, evidence_path, evidence_sha256))
        if len(self.calls) <= self.failures:
            raise OSError("network unavailable")
        return {
            "status": "complete",
            "entity": manifest["wandb"]["entity"],
            "project": manifest["wandb"]["project"],
            "run_id": manifest["wandb"]["run_id"],
            "url": "https://wandb.invalid/run",
            "canonical_evidence_sha256": evidence_sha256,
            "artifacts": [
                {
                    "name": "evidence",
                    "version": "v0",
                    "digest": "digest",
                    "type": "evidence",
                    "files": [],
                }
            ],
        }


def minimal_manifest(run_directory):
    effective = run_directory / "effective-config.yaml"
    effective.write_text("seed: 424242\n")
    return {
        "schema_version": 2,
        "run_id": "immutable-run",
        "status": "local_complete",
        "experiment": experiment().manifest_payload(),
        "git": {"commit": "a" * 40, "dirty": False},
        "hardware": {"platform": "test"},
        "base": {
            "key": "qwen25-coder-3b",
            "repository": "org/model",
            "revision": "b" * 40,
            "directory_sha256": "c" * 64,
        },
        "corpus": {
            "manifest": {"path": str(effective), "sha256": sha256_file(effective)}
        },
        "outputs": {"adapter": None, "fused": None},
        "wandb": {
            "required": True,
            "entity": "team",
            "project": "creg-sql",
            "run_id": "wb123",
            "tags": [],
        },
    }


def test_wandb_failure_preserves_local_evidence_and_recovers_idempotently(tmp_path):
    manifest_path = tmp_path / "manifest.json"
    write_json(manifest_path, minimal_manifest(tmp_path))
    uploader = RecordingUploader(failures=1)
    with pytest.raises(OSError, match="network unavailable"):
        synchronize_manifest(manifest_path, uploader=uploader)
    failed = json.loads(manifest_path.read_text())
    assert failed["status"] == "awaiting_wandb"
    assert (tmp_path / "wandb-evidence.json").is_file()

    receipt = synchronize_manifest(manifest_path, uploader=uploader)
    assert receipt["status"] == "complete"
    assert json.loads(manifest_path.read_text())["status"] == "complete"
    synchronize_manifest(manifest_path, uploader=uploader)
    assert len(uploader.calls) == 2


def test_publication_gate_rejects_incomplete_shared_evidence(tmp_path):
    manifest = minimal_manifest(tmp_path)
    manifest["status"] = "complete"
    with pytest.raises(WandbEvidenceError, match="requires a complete"):
        require_wandb_complete(manifest, operation="publication")
    manifest["wandb"]["receipt"] = {
        "status": "complete",
        "entity": "team",
        "project": "creg-sql",
        "run_id": "wb123",
        "url": "https://wandb.invalid/run",
        "canonical_evidence_sha256": "a" * 64,
        "artifacts": [
            {
                "name": "evidence",
                "version": "v0",
                "digest": "digest",
                "type": "evidence",
                "files": [],
            }
        ],
    }
    require_wandb_complete(manifest, operation="publication")


def _fake_evaluation_runner(command, **_kwargs):
    def value(flag):
        return command[command.index(flag) + 1]

    iteration = int(Path(value("--adapter-checkpoint")).name[:7])
    directory = Path(value("--runs-dir")) / value("--run-id")
    directory.mkdir()
    write_json(directory / "manifest.json", {"status": "complete"})
    summary = {
        "run_id": value("--run-id"),
        "gold": "gold_v1.jsonl",
        "n": 60,
        "ex": 0.8,
        "valid_sql_rate": 0.9,
        "ex_by_tier": {"1": 0.7},
        "p95_microseconds": 100,
        "snapshot_count": 3,
        "database_set_sha256": "d" * 64,
        "failure_buckets": {"wrong-filter-or-value": 12},
        "mean_entropy_correct": 0.1,
        "mean_entropy_wrong": 0.2,
    }
    write_json(directory / "summary.json", summary)
    rows = [
        json.dumps(
            {
                "id": f"item-{index}",
                "tier": 1,
                "tags": [],
                "question": "question",
                "gold_sql": "SELECT 1",
                "predicted_sql": "SELECT 1",
                "gold": {"rows": []},
                "predicted": {"rows": []},
                "ex": True,
                "bucket": "correct",
                "error": None,
                "elapsed_microseconds": 100,
                "generation_microseconds": 90,
                "mean_entropy": 0.1,
                "max_entropy": 0.2,
                "iteration": iteration,
            }
        )
        for index in range(60)
    ]
    (directory / "items.jsonl").write_text("\n".join(rows) + "\n")
    return subprocess.CompletedProcess(command, 0)


def test_mocked_checkpoint_evaluation_never_exposes_final_gold(tmp_path):
    adapter = tmp_path / "adapter"
    adapter.mkdir()
    (adapter / "adapter_config.json").write_text("{}\n")
    for iteration in (100, 200):
        (adapter / f"{iteration:07d}_adapters.safetensors").write_bytes(
            f"checkpoint-{iteration}".encode()
        )
    run = tmp_path / "run"
    run.mkdir()
    config = experiment(iterations=200).manifest_payload()
    manifest_path = run / "manifest.json"
    write_json(
        manifest_path,
        {
            "run_id": "mock-training",
            "status": "training_complete",
            "experiment": config,
            "outputs": {"adapter": str(adapter)},
        },
    )
    result = evaluate_training_checkpoints(
        manifest_path,
        model_manifest=tmp_path / "models.json",
        models_dir=tmp_path,
        runner=_fake_evaluation_runner,
    )
    assert result["selected"]["iteration"] == 100
    source = (ROOT / "fine-tuning/tools/evaluate_checkpoints.py").read_text()
    forbidden = "gold" + "_v2"
    assert forbidden not in source


class FakeTable:
    def __init__(self, columns):
        self.columns = columns
        self.data = []

    def add_data(self, *values):
        self.data.append(values)


class FakeArtifact:
    def __init__(self, name, type, metadata):
        self.name = name
        self.type = type
        self.metadata = metadata
        self.version = "v0"
        self.digest = hashlib.sha256(name.encode()).hexdigest()
        self.files = []
        self.references = []

    def add_file(self, path, name):
        self.files.append((path, name))

    def add_reference(self, reference):
        self.references.append(reference)

    def wait(self):
        return self


class FakeRun:
    def __init__(self):
        self.summary = {}
        self.logs = []
        self.artifacts = []
        self.url = "https://wandb.invalid/fake"
        self.exit_code = None

    def log(self, values, step=None):
        self.logs.append((values, step))

    def log_artifact(self, artifact):
        self.artifacts.append(artifact)
        return artifact

    def finish(self, exit_code):
        self.exit_code = exit_code


class FakeWandb:
    Table = FakeTable
    Artifact = FakeArtifact

    def __init__(self):
        self.run = FakeRun()
        self.init_kwargs = None

    def init(self, **kwargs):
        self.init_kwargs = kwargs
        return self.run


def test_wandb_test_double_observes_group_metrics_tables_artifacts_and_receipts(
    tmp_path,
):
    corpus_manifest = tmp_path / "corpus-manifest.json"
    corpus_manifest.write_text("{}\n")
    corpus = tmp_path / "regenerated-corpus"
    corpus.mkdir()
    (corpus / "train.jsonl").write_text("{}\n")
    adapter = tmp_path / "adapter"
    adapter.mkdir()
    (adapter / "adapter_config.json").write_text("{}\n")
    checkpoint = adapter / "0000100_adapters.safetensors"
    checkpoint.write_bytes(b"adapter")
    evaluation = tmp_path / "evaluation"
    evaluation.mkdir()
    paths = {
        name: evaluation / name
        for name in ("comparison.json", "manifest.json", "summary.json", "items.jsonl")
    }
    for name, path in paths.items():
        path.write_text("{}\n")
    item = {
        "id": "id-1",
        "tier": 1,
        "tags": ["tag"],
        "question": "question",
        "gold_sql": "SELECT 1",
        "predicted_sql": "SELECT 1",
        "gold": {"rows": [[{"type": "integer", "value": "1"}]]},
        "predicted": {"rows": [[{"type": "integer", "value": "1"}]]},
        "ex": True,
        "bucket": "correct",
        "error": None,
        "elapsed_microseconds": 100,
        "generation_microseconds": 90,
        "mean_entropy": 0.1,
        "max_entropy": 0.2,
    }
    paths["items.jsonl"].write_text(json.dumps(item) + "\n")
    summary = {
        "ex": 1.0,
        "valid_sql_rate": 1.0,
        "ex_by_tier": {"1": 1.0},
        "p95_microseconds": 100,
        "failure_buckets": {},
        "mean_entropy_correct": 0.1,
        "mean_entropy_wrong": 0.0,
    }
    selected = {
        "iteration": 100,
        "checkpoint_path": str(checkpoint),
        "checkpoint_sha256": sha256_file(checkpoint),
        "adapter_size_bytes": checkpoint.stat().st_size,
        "manifest_path": str(paths["manifest.json"]),
        "summary_path": str(paths["summary.json"]),
        "items_path": str(paths["items.jsonl"]),
        "summary": summary,
    }
    manifest = minimal_manifest(tmp_path)
    manifest["outputs"]["adapter"] = str(adapter)
    manifest["corpus"]["manifest"] = {
        "path": str(corpus_manifest),
        "sha256": sha256_file(corpus_manifest),
    }
    manifest["wandb"]["tags"] = ["family:qwen25-coder-3b"]
    manifest["checkpoint_evaluation"] = {
        "comparison_path": str(paths["comparison.json"]),
        "checkpoints": [selected],
        "selected": selected,
    }
    evidence = tmp_path / "wandb-evidence.json"
    evidence.write_text("{}\n")
    fake = FakeWandb()
    receipt = WandbUploader(fake).upload(manifest, evidence, sha256_file(evidence))
    assert fake.init_kwargs["group"] == "campaign-test"
    assert fake.init_kwargs["job_type"] == "screening"
    metric_names = {
        key
        for values, _step in fake.run.logs
        for key in values
        if not isinstance(values[key], FakeTable)
    }
    assert "checkpoint/gold_v1/ex" in metric_names
    checkpoint_metric_logs = [
        (values, step)
        for values, step in fake.run.logs
        if "checkpoint/gold_v1/ex" in values
    ]
    assert checkpoint_metric_logs[0][1] is None
    assert checkpoint_metric_logs[0][0]["checkpoint/iteration"] == 100
    tables = [
        value
        for values, _ in fake.run.logs
        for value in values.values()
        if isinstance(value, FakeTable)
    ]
    assert tables[0].data[0][0] == 100
    assert {artifact.type for artifact in fake.run.artifacts} >= {
        "dataset",
        "evaluation",
        "model",
        "model-reference",
        "evidence",
    }
    assert receipt["artifacts"]
    assert all(
        item["version"] == "v0" and item["digest"] for item in receipt["artifacts"]
    )


def test_wandb_evidence_rejects_symlinked_attachment(tmp_path):
    manifest = minimal_manifest(tmp_path)
    target = tmp_path / "target.json"
    target.write_text("{}\n")
    linked = tmp_path / "linked.json"
    linked.symlink_to(target)
    manifest["final_evaluation"] = {"files": [str(linked)]}
    manifest_path = tmp_path / "manifest.json"
    write_json(manifest_path, manifest)

    with pytest.raises(IntegrityError, match="symbolic links"):
        write_canonical_evidence(manifest_path)


def test_promotion_eligibility_becomes_required_wandb_selection_evidence(tmp_path):
    manifest = minimal_manifest(tmp_path)
    manifest["checkpoint_evaluation"] = {
        "selected": {"checkpoint_sha256": "a" * 64}
    }
    manifest_path = tmp_path / "manifest.json"
    write_json(manifest_path, manifest)
    eligibility = tmp_path / "eligibility.json"
    write_json(
        eligibility,
        {
            "schema_version": 1,
            "analysis": "reliability-v3-promotion-eligibility",
            "pass": True,
            "candidate_run_id": manifest["run_id"],
            "selected_checkpoint_sha256": "a" * 64,
        },
    )
    attach_selection_evidence(manifest_path, [eligibility])
    updated = json.loads(manifest_path.read_text())
    assert updated["selection_evidence"]["promotion-eligibility"] == {
        "selection_use": "required",
        "artifact_type": "evaluation",
        "files": [str(eligibility.absolute())],
    }
    _, _, evidence = write_canonical_evidence(manifest_path)
    assert evidence["selection_evidence"] == updated["selection_evidence"]


def test_wandb_evidence_rejects_attachment_through_symlinked_directory(
    tmp_path,
):
    manifest = minimal_manifest(tmp_path)
    target = tmp_path / "target-directory"
    target.mkdir()
    (target / "evidence.json").write_text("{}\n")
    linked = tmp_path / "linked-directory"
    linked.symlink_to(target, target_is_directory=True)
    manifest["final_evaluation"] = {"files": [str(linked / "evidence.json")]}
    manifest_path = tmp_path / "manifest.json"
    write_json(manifest_path, manifest)

    with pytest.raises(IntegrityError, match="path ancestors"):
        write_canonical_evidence(manifest_path)


def test_final_run_accepts_separate_post_selection_artifacts_and_metrics(tmp_path):
    manifest = minimal_manifest(tmp_path)
    manifest["experiment"]["stage"] = "final"
    manifest_path = tmp_path / "manifest.json"
    write_json(manifest_path, manifest)
    policy = tmp_path / "policy.json"
    parity = tmp_path / "parity.json"
    release = tmp_path / "release.json"
    device = tmp_path / "device.json"
    for path in (policy, parity, release, device):
        path.write_text("{}\n")
    metrics = tmp_path / "headline.json"
    metrics.write_text(json.dumps({"ex": 0.7, "release_verified": True}))

    attach_post_selection_evidence(
        manifest_path,
        final_evaluations=[],
        publication_path=None,
        policy_calibrations=[policy],
        parity_evidence=[parity],
        release_inspections=[release],
        device_evidence=[device],
        headline_metrics_path=metrics,
    )

    updated = json.loads(manifest_path.read_text())
    assert set(updated["post_selection_evidence"]) == {
        "policy-calibration",
        "swift-python-parity",
        "release-bundle-inspection",
        "physical-device-evidence",
        "headline-metrics",
    }
    assert updated["headline_metrics"]["release_verified"] is True


def test_sweep_files_define_v3_screening_and_controlled_repair_ablation():
    sweeps = sorted((ROOT / "fine-tuning/config/sweeps").glob("*.yaml"))
    assert len(sweeps) == 3
    screening = [path for path in sweeps if "repair-ratio" not in path.name]
    assert len(screening) == 2
    for path in screening:
        config = yaml.safe_load(path.read_text())
        assert config["method"] == "random"
        assert config["run_cap"] == 18
        assert "reliability-v3" in config["name"]
        campaign_argument = next(
            value
            for value in config["command"]
            if isinstance(value, str) and value.startswith("--campaign-id=")
        )
        assert campaign_argument.removeprefix("--campaign-id=") == config["name"]
        assert config["metric"] == {"name": "development/ex", "goal": "maximize"}
        assert config["parameters"]["seed"]["value"] == 424242
        assert config["parameters"]["repair-fraction"]["value"] == 0.10
    ablation = yaml.safe_load(
        (ROOT / "fine-tuning/config/sweeps/repair-ratio-ablation.yaml").read_text()
    )
    assert ablation["method"] == "grid"
    assert ablation["parameters"]["repair-fraction"]["values"] == [0.05, 0.10, 0.20]


def test_backfill_parser_reads_current_logs_without_mutating_manifests():
    run = ROOT / "eval/training-runs/qlora-qwen25-coder-3b-seed-424242"
    before = sha256_file(run / "manifest.json")
    metrics = parse_training_log(run / "training.log")
    assert metrics[0]["val_loss"] == 0.917
    assert metrics[-1]["iteration"] == 600
    assert metrics[-1]["trained_tokens"] == 107177
    assert sha256_file(run / "manifest.json") == before
