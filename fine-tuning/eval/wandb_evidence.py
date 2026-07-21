"""W&B synchronization for locally canonical, content-addressed evidence.

The local evidence file is finalized before upload and deliberately excludes
``manifest.json``. W&B receives that evidence file and its SHA-256; only after
the upload succeeds does the mutable run manifest receive the W&B receipt.
This ordering prevents a circular hash dependency.
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any, Protocol

from eval.experiment import canonical_sha256, worst_tier_ex
from eval.file_integrity import regular_files, sha256_file
from eval.run_artifacts import REPO_ROOT, write_json


EVIDENCE_FILE = "wandb-evidence.json"
DEFAULT_PROJECT = "creg-sql"
SUCCESS_STATES = frozenset({"complete", "backfilled"})


class WandbEvidenceError(RuntimeError):
    """Raised when shared-authority evidence is absent or inconsistent."""


class EvidenceUploader(Protocol):
    def upload(
        self,
        manifest: dict[str, Any],
        evidence_path: Path,
        evidence_sha256: str,
    ) -> dict[str, Any]: ...


def required_wandb_environment(
    environment: dict[str, str] | None = None,
) -> dict[str, str]:
    values = os.environ if environment is None else environment
    missing = [name for name in ("WANDB_API_KEY", "WANDB_ENTITY") if not values.get(name)]
    if missing:
        raise WandbEvidenceError(
            "authenticated online W&B logging requires " + ", ".join(missing)
        )
    return {
        "entity": values["WANDB_ENTITY"],
        "project": values.get("WANDB_PROJECT", DEFAULT_PROJECT),
    }


def _repository_name(path: Path) -> str:
    resolved = path.resolve()
    try:
        return resolved.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return str(resolved)


def file_receipt(path: Path) -> dict[str, Any]:
    absolute = path.absolute()
    digest = sha256_file(absolute)
    return {
        "path": _repository_name(absolute),
        "size": absolute.lstat().st_size,
        "sha256": digest,
    }


def _tree_files(directory: Path) -> list[Path]:
    if not directory.is_dir():
        return []
    return regular_files(
        directory,
        include=lambda relative: (
            relative.name != EVIDENCE_FILE and "wandb" not in relative.parts
        ),
    )


def evidence_paths(run_directory: Path, manifest: dict[str, Any]) -> list[Path]:
    """Resolve the bounded local bytes that W&B mirrors or references."""

    candidates: list[Path] = []
    for name in ("effective-config.yaml", "training.log"):
        path = run_directory / name
        if path.is_file():
            candidates.append(path)
    candidates.extend(_tree_files(run_directory / "regenerated-corpus"))
    candidates.extend(_tree_files(run_directory / "checkpoint-evaluations"))

    adapter_value = manifest.get("outputs", {}).get("adapter")
    if adapter_value:
        adapter = Path(adapter_value)
        config = adapter / "adapter_config.json"
        if config.is_file():
            candidates.append(config)
        checkpoint_evaluation = manifest.get("checkpoint_evaluation", {})
        selected = checkpoint_evaluation.get("selected", {}).get("checkpoint_path")
        if manifest.get("experiment", {}).get("stage") == "screening":
            if selected and Path(selected).is_file():
                candidates.append(Path(selected))
        else:
            candidates.extend(sorted(adapter.glob("*_adapters.safetensors")))

    # Fused weights remain outside W&B, but the local lock and its inventory
    # bind the immutable external reference without duplicating large bytes.
    fused_value = manifest.get("outputs", {}).get("fused")
    if fused_value:
        lock = Path(fused_value) / ".creg-artifact.json"
        if lock.is_file():
            candidates.append(lock)
    publication_value = manifest.get("fused_reference", {}).get(
        "publication_path"
    )
    if publication_value and Path(publication_value).is_file():
        candidates.append(Path(publication_value))

    final_evaluation = manifest.get("final_evaluation", {})
    for value in final_evaluation.get("files", []):
        path = Path(value)
        if path.is_file():
            candidates.append(path)

    for record in manifest.get("post_selection_evidence", {}).values():
        for value in record.get("files", []):
            path = Path(value)
            if path.is_file():
                candidates.append(path)

    # Do not resolve here: resolving a symlink before hashing would turn an
    # unsafe evidence path into an apparently regular target.
    unique = {path.absolute(): path.absolute() for path in candidates}
    return sorted(unique.values(), key=_repository_name)


def canonical_evidence(
    run_directory: Path,
    manifest: dict[str, Any],
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "run_id": manifest["run_id"],
        "experiment": manifest.get("experiment"),
        "git": manifest.get("git"),
        "hardware": manifest.get("hardware"),
        "base": manifest.get("base"),
        "corpus": manifest.get("corpus"),
        "prompt_contract": manifest.get("prompt_contract"),
        "checkpoint_evaluation": manifest.get("checkpoint_evaluation"),
        "fused_reference": manifest.get("fused_reference"),
        "final_evaluation": manifest.get("final_evaluation"),
        "post_selection_evidence": manifest.get("post_selection_evidence"),
        "headline_metrics": manifest.get("headline_metrics"),
        "files": [file_receipt(path) for path in evidence_paths(run_directory, manifest)],
    }


def write_canonical_evidence(
    manifest_path: Path,
    manifest: dict[str, Any] | None = None,
) -> tuple[Path, str, dict[str, Any]]:
    manifest_path = manifest_path.resolve()
    payload = (
        json.loads(manifest_path.read_text()) if manifest is None else manifest
    )
    evidence = canonical_evidence(manifest_path.parent, payload)
    evidence_path = manifest_path.parent / EVIDENCE_FILE
    write_json(evidence_path, evidence)
    return evidence_path, sha256_file(evidence_path), evidence


def require_wandb_complete(
    manifest: dict[str, Any],
    *,
    operation: str,
) -> None:
    wandb_record = manifest.get("wandb", {})
    if manifest.get("status") == "awaiting_wandb":
        raise WandbEvidenceError(
            f"{operation} refuses {manifest.get('run_id')}: W&B synchronization is pending"
        )
    if wandb_record.get("required"):
        receipt = wandb_record.get("receipt", {})
        try:
            validate_wandb_receipt(receipt)
        except WandbEvidenceError as error:
            raise WandbEvidenceError(
                f"{operation} requires a complete W&B evidence receipt for "
                f"{manifest.get('run_id')}: {error}"
            ) from error


def validate_wandb_receipt(receipt: dict[str, Any]) -> None:
    if receipt.get("status") != "complete":
        raise WandbEvidenceError("W&B receipt is incomplete")
    required = (
        "entity",
        "project",
        "run_id",
        "url",
        "canonical_evidence_sha256",
    )
    missing = [name for name in required if not receipt.get(name)]
    if missing:
        raise WandbEvidenceError(f"W&B receipt is missing {missing}")
    artifacts = receipt.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        raise WandbEvidenceError("W&B receipt has no artifact versions")
    for artifact in artifacts:
        absent = [
            name
            for name in ("name", "version", "digest", "type")
            if not artifact.get(name)
        ]
        if absent:
            raise WandbEvidenceError(
                f"artifact receipt {artifact.get('name')} is missing {absent}"
            )
        for file in artifact.get("files", []):
            if not file.get("path") or not file.get("sha256"):
                raise WandbEvidenceError(
                    "artifact file receipt lacks repository SHA-256"
                )


def _artifact_record(artifact: Any, files: list[Path]) -> dict[str, Any]:
    resolved = artifact.wait() if hasattr(artifact, "wait") else artifact
    return {
        "name": getattr(resolved, "name", getattr(artifact, "name", None)),
        "version": getattr(resolved, "version", None),
        "digest": getattr(resolved, "digest", None),
        "type": getattr(resolved, "type", getattr(artifact, "type", None)),
        "files": [file_receipt(path) for path in files],
    }


def _safe_artifact_name(value: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_.-]+", "-", value).strip("-")


class WandbUploader:
    """Production uploader. Importing W&B is delayed for offline unit tests."""

    def __init__(self, wandb_module: Any | None = None):
        if wandb_module is None:
            import wandb as wandb_module  # type: ignore[no-redef]

        self.wandb = wandb_module

    def _log_artifact(
        self,
        run: Any,
        *,
        name: str,
        artifact_type: str,
        files: list[Path],
        metadata: dict[str, Any],
        references: list[str] | None = None,
    ) -> dict[str, Any]:
        artifact = self.wandb.Artifact(
            _safe_artifact_name(name),
            type=artifact_type,
            metadata={
                **metadata,
                "repository_sha256": {
                    _repository_name(path): sha256_file(path) for path in files
                },
            },
        )
        for path in files:
            artifact.add_file(str(path), name=_repository_name(path))
        for reference in references or []:
            artifact.add_reference(reference)
        logged = run.log_artifact(artifact)
        return _artifact_record(logged, files)

    def _log_checkpoint_metrics_and_table(
        self,
        run: Any,
        manifest: dict[str, Any],
    ) -> None:
        evaluation = manifest.get("checkpoint_evaluation", {})
        comparisons = evaluation.get("checkpoints", [])
        columns = [
            "checkpoint_iteration",
            "id",
            "tier",
            "tags",
            "question",
            "gold_sql",
            "predicted_sql",
            "gold_rows",
            "predicted_rows",
            "ex",
            "bucket",
            "error",
            "elapsed_microseconds",
            "generation_microseconds",
            "mean_entropy",
            "max_entropy",
        ]
        table = self.wandb.Table(columns=columns)
        for checkpoint in comparisons:
            summary = checkpoint["summary"]
            iteration = int(checkpoint["iteration"])
            metrics: dict[str, Any] = {
                "checkpoint/iteration": iteration,
                "checkpoint/gold_v1/ex": summary["ex"],
                "checkpoint/gold_v1/valid_sql_rate": summary["valid_sql_rate"],
                "checkpoint/gold_v1/worst_tier_ex": worst_tier_ex(summary),
                "checkpoint/gold_v1/p95_latency_us": summary["p95_microseconds"],
                "checkpoint/gold_v1/mean_entropy_correct": summary[
                    "mean_entropy_correct"
                ],
                "checkpoint/gold_v1/mean_entropy_wrong": summary[
                    "mean_entropy_wrong"
                ],
                "checkpoint/gold_v1/adapter_size_bytes": checkpoint[
                    "adapter_size_bytes"
                ],
            }
            metrics.update(
                {
                    f"checkpoint/gold_v1/tier/{tier}/ex": value
                    for tier, value in summary.get("ex_by_tier", {}).items()
                }
            )
            metrics.update(
                {
                    f"checkpoint/gold_v1/failure/{bucket}": value
                    for bucket, value in summary.get("failure_buckets", {}).items()
                }
            )
            # MLX logs its own training/validation history first and may have
            # advanced W&B beyond the numeric checkpoint iteration (for
            # example, validation after iteration 100 lands at step 101).
            # Append evaluation metrics monotonically and retain the actual
            # checkpoint iteration as a metric instead of backdating `step`.
            run.log(metrics)

            items_path = Path(checkpoint["items_path"])
            for line in items_path.read_text().splitlines():
                if not line.strip():
                    continue
                item = json.loads(line)
                table.add_data(
                    iteration,
                    item["id"],
                    item["tier"],
                    json.dumps(item.get("tags", []), ensure_ascii=False),
                    item["question"],
                    item["gold_sql"],
                    item["predicted_sql"],
                    json.dumps(item["gold"]["rows"], ensure_ascii=False),
                    json.dumps(
                        None if item["predicted"] is None else item["predicted"]["rows"],
                        ensure_ascii=False,
                    ),
                    item["ex"],
                    item["bucket"],
                    item["error"],
                    item["elapsed_microseconds"],
                    item["generation_microseconds"],
                    item["mean_entropy"],
                    item["max_entropy"],
                )
        if comparisons:
            run.log({"checkpoint/gold_v1/examples": table})

    def upload(
        self,
        manifest: dict[str, Any],
        evidence_path: Path,
        evidence_sha256: str,
    ) -> dict[str, Any]:
        wandb_record = manifest["wandb"]
        experiment = manifest["experiment"]
        final_tags = [
            tag for tag in wandb_record["tags"] if not tag.startswith("status:")
        ] + ["status:complete"]
        run = self.wandb.init(
            entity=wandb_record["entity"],
            project=wandb_record["project"],
            id=wandb_record["run_id"],
            name=manifest["run_id"],
            group=experiment["campaign_id"],
            job_type=wandb_record.get("job_type", experiment["stage"]),
            tags=final_tags,
            config={
                **experiment,
                "prompt_contract": manifest.get("prompt_contract"),
                "corpus_sha256": manifest.get("corpus", {})
                .get("manifest", {})
                .get("sha256"),
            },
            resume="allow",
        )
        artifacts: list[dict[str, Any]] = []
        try:
            self._log_checkpoint_metrics_and_table(run, manifest)
            selected = manifest.get("checkpoint_evaluation", {}).get("selected")
            if selected:
                summary = selected["summary"]
                run.summary["development/checkpoint_iteration"] = selected["iteration"]
                run.summary["development/ex"] = summary["ex"]
                run.summary["development/valid_sql_rate"] = summary["valid_sql_rate"]
                run.summary["development/worst_tier_ex"] = worst_tier_ex(summary)
                run.summary["development/p95_latency_us"] = summary[
                    "p95_microseconds"
                ]
            run.summary["evidence/sha256"] = evidence_sha256
            run.summary["evidence/configuration_sha256"] = experiment[
                "configuration_sha256"
            ]
            for name, value in manifest.get("durations", {}).items():
                run.summary[f"duration/{name}_seconds"] = value

            run_directory = evidence_path.parent
            corpus_files = _tree_files(run_directory / "regenerated-corpus")
            corpus_manifest = Path(manifest["corpus"]["manifest"]["path"])
            if not corpus_manifest.is_absolute():
                corpus_manifest = REPO_ROOT / corpus_manifest
            corpus_files.append(corpus_manifest)
            artifacts.append(
                self._log_artifact(
                    run,
                    name=f"{manifest['run_id']}-corpus",
                    artifact_type="dataset",
                    files=corpus_files,
                    metadata={"evidence_sha256": evidence_sha256},
                )
            )

            evaluation = manifest.get("checkpoint_evaluation", {})
            if selected:
                evaluation_files = [
                    Path(evaluation["comparison_path"]),
                    Path(selected["manifest_path"]),
                    Path(selected["summary_path"]),
                    Path(selected["items_path"]),
                ]
                artifacts.append(
                    self._log_artifact(
                        run,
                        name=f"{manifest['run_id']}-development-evaluation",
                        artifact_type="evaluation",
                        files=evaluation_files,
                        metadata={
                            "evidence_sha256": evidence_sha256,
                            "checkpoint_iteration": selected["iteration"],
                        },
                    )
                )

                adapter_files = [Path(manifest["outputs"]["adapter"]) / "adapter_config.json"]
                if experiment["stage"] == "screening":
                    adapter_files.append(Path(selected["checkpoint_path"]))
                else:
                    adapter_files.extend(
                        sorted(
                            Path(manifest["outputs"]["adapter"]).glob(
                                "*_adapters.safetensors"
                            )
                        )
                    )
                artifacts.append(
                    self._log_artifact(
                        run,
                        name=f"{manifest['run_id']}-adapters",
                        artifact_type="model",
                        files=adapter_files,
                        metadata={
                            "evidence_sha256": evidence_sha256,
                            "stage": experiment["stage"],
                        },
                    )
                )

            base = manifest["base"]
            base_reference = (
                f"https://huggingface.co/{base['repository']}/tree/{base['revision']}"
            )
            artifacts.append(
                self._log_artifact(
                    run,
                    name=f"{manifest['run_id']}-base-reference",
                    artifact_type="model-reference",
                    files=[],
                    references=[base_reference],
                    metadata={
                        "evidence_sha256": evidence_sha256,
                        "repository": base["repository"],
                        "revision": base["revision"],
                        "repository_directory_sha256": base[
                            "directory_sha256"
                        ],
                    },
                )
            )

            fused_reference = manifest.get("fused_reference")
            if fused_reference:
                references = []
                fused_files = [Path(fused_reference["lock_path"])]
                publication_path = fused_reference.get("publication_path")
                if publication_path:
                    fused_files.append(Path(publication_path))
                if fused_reference.get("repository") and fused_reference.get("revision"):
                    references.append(
                        "https://huggingface.co/"
                        f"{fused_reference['repository']}/tree/"
                        f"{fused_reference['revision']}"
                    )
                artifacts.append(
                    self._log_artifact(
                        run,
                        name=f"{manifest['run_id']}-fused-reference",
                        artifact_type="model-reference",
                        files=fused_files,
                        references=references,
                        metadata={
                            "evidence_sha256": evidence_sha256,
                            **fused_reference,
                        },
                    )
                )

            final_files = [
                Path(value)
                for value in manifest.get("final_evaluation", {}).get("files", [])
            ]
            if final_files:
                artifacts.append(
                    self._log_artifact(
                        run,
                        name=f"{manifest['run_id']}-final-evaluation",
                        artifact_type="evaluation",
                        files=final_files,
                        metadata={
                            "evidence_sha256": evidence_sha256,
                            "selection_use": "forbidden",
                        },
                    )
                )

            for category, record in sorted(
                manifest.get("post_selection_evidence", {}).items()
            ):
                category_files = [Path(value) for value in record.get("files", [])]
                if not category_files:
                    continue
                artifacts.append(
                    self._log_artifact(
                        run,
                        name=f"{manifest['run_id']}-{category}",
                        artifact_type=record.get("artifact_type", "evidence"),
                        files=category_files,
                        metadata={
                            "evidence_sha256": evidence_sha256,
                            "selection_use": "forbidden",
                            "category": category,
                        },
                    )
                )

            for name, value in sorted(manifest.get("headline_metrics", {}).items()):
                run.summary[f"final/{name}"] = value

            evidence_artifact = self._log_artifact(
                run,
                name=f"{manifest['run_id']}-canonical-evidence",
                artifact_type="evidence",
                files=[evidence_path],
                metadata={"canonical_evidence_sha256": evidence_sha256},
            )
            artifacts.append(evidence_artifact)
            run.finish(exit_code=0)
        except BaseException:
            run.finish(exit_code=1)
            raise

        return {
            "status": "complete",
            "entity": wandb_record["entity"],
            "project": wandb_record["project"],
            "run_id": wandb_record["run_id"],
            "url": getattr(run, "url", None),
            "canonical_evidence_sha256": evidence_sha256,
            "artifacts": artifacts,
        }


def synchronize_manifest(
    manifest_path: Path,
    *,
    uploader: EvidenceUploader | None = None,
) -> dict[str, Any]:
    """Upload or resume one run, preserving local evidence on any failure."""

    manifest_path = manifest_path.resolve()
    manifest = json.loads(manifest_path.read_text())
    if not manifest.get("wandb", {}).get("required"):
        raise WandbEvidenceError("manifest does not require W&B evidence")
    if uploader is None and not os.environ.get("WANDB_API_KEY"):
        raise WandbEvidenceError("WANDB_API_KEY is required for synchronization")

    evidence_path, evidence_sha256, _ = write_canonical_evidence(
        manifest_path, manifest
    )
    prior = manifest["wandb"].get("receipt")
    if (
        prior
        and prior.get("status") == "complete"
        and prior.get("canonical_evidence_sha256") == evidence_sha256
    ):
        return prior

    manifest["status"] = "synchronizing_wandb"
    manifest["wandb"].pop("last_error", None)
    write_json(manifest_path, manifest)
    active_uploader = WandbUploader() if uploader is None else uploader
    try:
        receipt = active_uploader.upload(manifest, evidence_path, evidence_sha256)
    except BaseException as error:
        manifest["status"] = "awaiting_wandb"
        manifest["wandb"]["last_error"] = {
            "type": type(error).__name__,
            "message": str(error),
        }
        write_json(manifest_path, manifest)
        raise

    if receipt.get("status") != "complete":
        raise WandbEvidenceError("uploader returned an incomplete receipt")
    if receipt.get("canonical_evidence_sha256") != evidence_sha256:
        raise WandbEvidenceError("uploader receipt does not match canonical evidence")
    manifest["wandb"]["receipt"] = receipt
    manifest["status"] = (
        "complete"
        if manifest.get("experiment", {}).get("stage") == "screening"
        else "wandb_complete"
    )
    write_json(manifest_path, manifest)
    return receipt


def receipt_identity(receipt: dict[str, Any]) -> str:
    """Stable test/debug identity for a complete W&B receipt."""

    return canonical_sha256(
        {
            "entity": receipt.get("entity"),
            "project": receipt.get("project"),
            "run_id": receipt.get("run_id"),
            "canonical_evidence_sha256": receipt.get(
                "canonical_evidence_sha256"
            ),
            "artifacts": receipt.get("artifacts", []),
        }
    )
