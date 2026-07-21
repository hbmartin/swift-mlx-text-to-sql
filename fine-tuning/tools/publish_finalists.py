"""Publish completed fine-tunes and verify fresh pinned downloads.

The authenticated Hugging Face CLI credential is used implicitly. Tokens are
never accepted as arguments and never serialized.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import tempfile
from pathlib import Path
from typing import Any

from huggingface_hub import HfApi, hf_hub_download, snapshot_download

from eval.run_artifacts import (
    REPO_ROOT,
    command_line,
    create_run_directory,
    git_provenance,
    hardware_provenance,
    input_hash,
    sha256_file,
    write_json,
)
from eval.wandb_evidence import require_wandb_complete
from eval.wandb_evidence import EVIDENCE_FILE
from eval.file_integrity import transactionally_replace_directory
from eval.selection import load_run
from tools.fetch_model import (
    LOCK_FILE,
    directory_digest,
    directory_inventory,
    distribution_files,
    full_directory_inventory,
    load_manifest,
    notice_file,
)

MODEL_MANIFEST = REPO_ROOT / "model-manifest.json"
DEFAULT_PUBLICATIONS = REPO_ROOT / "eval" / "publications"
DEFAULT_FRESH_DOWNLOADS = REPO_ROOT / "models" / "fresh-downloads"
DEFAULT_STAGING = REPO_ROOT / "models" / "publication-staging"
DEFAULT_PUBLISHED_TREES = REPO_ROOT / "models" / "published"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--training-run",
        type=Path,
        action="append",
        required=True,
        help="completed immutable training-run directory (one or more)",
    )
    parser.add_argument(
        "--result-run",
        type=Path,
        action="append",
        required=True,
        help="completed evaluation run used in model-card results",
    )
    parser.add_argument(
        "--publications-dir",
        type=Path,
        default=DEFAULT_PUBLICATIONS,
    )
    parser.add_argument(
        "--fresh-downloads-dir",
        type=Path,
        default=DEFAULT_FRESH_DOWNLOADS,
    )
    parser.add_argument(
        "--staging-dir",
        type=Path,
        default=DEFAULT_STAGING,
        help=(
            "ignored local staging root; completed training artifacts remain "
            "untouched until the public snapshot passes fresh verification"
        ),
    )
    parser.add_argument(
        "--published-trees-dir",
        type=Path,
        default=DEFAULT_PUBLISHED_TREES,
        help="distinct verified public snapshots; training-fused trees are immutable",
    )
    return parser.parse_args()


def repository_slug(repository: str) -> str:
    """The documented full-base-model-slug transformation."""
    return re.sub(r"[^a-z0-9]+", "-", repository.lower()).strip("-")


def summary(path: Path) -> dict[str, Any]:
    # load_run verifies completeness plus the recorded summary/items hashes,
    # so a post-run edit to summary.json can never reach the model card.
    run = load_run(path)
    result = dict(run.summary)
    result["_evidence"] = {
        "run_id": run.manifest["run_id"],
        "manifest_sha256": sha256_file(path / "manifest.json"),
        "summary_sha256": sha256_file(path / "summary.json"),
    }
    result["_model_directory_sha256"] = run.manifest["model"].get(
        "directory_sha256"
    )
    return result


def verify_fused_tree_for_publication(
    directory: Path,
    lock: dict[str, Any],
    *,
    training: dict[str, Any] | None = None,
    evidence_path: Path | None = None,
) -> tuple[str, list[dict[str, Any]]]:
    """Verify the exact local tree that will be copied for publication."""
    if not directory.is_dir():
        raise RuntimeError(f"fused model directory is missing: {directory}")
    inventory = directory_inventory(directory)
    actual = directory_digest(inventory)
    expected = lock.get("directory_sha256")
    if actual != expected:
        raise RuntimeError(
            f"fused model tree changed after training/evaluation: {directory} "
            f"({actual} != {expected})"
        )
    if lock.get("all_files") != inventory:
        raise RuntimeError(
            f"fused model inventory no longer matches its artifact lock: "
            f"{directory}"
        )
    if training is not None:
        fused_reference = training.get("fused_reference", {})
        candidate = training.get("candidate_manifest_entry", {})
        recorded_lock_sha256 = (
            fused_reference.get("lock_sha256")
            or training.get("fused_lock", {}).get("sha256")
        )
        actual_lock_sha256 = sha256_file(directory / LOCK_FILE)
        if recorded_lock_sha256 != actual_lock_sha256:
            raise RuntimeError(
                "training manifest fused lock SHA-256 does not match the "
                f"actual lock ({recorded_lock_sha256} != {actual_lock_sha256})"
            )
        recorded_digests = {
            "fused_reference.directory_sha256": fused_reference.get(
                "directory_sha256"
            ),
            "candidate snapshot_directory_sha256": candidate.get(
                "snapshot_directory_sha256"
            ),
        }
        for label, recorded in recorded_digests.items():
            if recorded != actual:
                raise RuntimeError(
                    f"{label} does not match fused bytes ({recorded} != {actual})"
                )
        if candidate.get("required_files") != inventory:
            raise RuntimeError(
                "candidate required_files do not match the fused inventory"
            )

        receipt = training.get("wandb", {}).get("receipt", {})
        canonical_sha256 = receipt.get("canonical_evidence_sha256")
        if evidence_path is None or not evidence_path.is_file():
            raise RuntimeError("local canonical W&B evidence is missing")
        actual_evidence_sha256 = sha256_file(evidence_path)
        if canonical_sha256 != actual_evidence_sha256:
            raise RuntimeError(
                "local canonical W&B evidence does not match its receipt "
                f"({actual_evidence_sha256} != {canonical_sha256})"
            )
        lock_evidence_sha256 = lock.get("training_provenance", {}).get(
            "canonical_evidence_sha256"
        )
        candidate_evidence_sha256 = candidate.get("training_provenance", {}).get(
            "canonical_evidence_sha256"
        )
        if (
            lock_evidence_sha256 != candidate_evidence_sha256
            or lock_evidence_sha256 != canonical_sha256
        ):
            raise RuntimeError(
                "fused lock, candidate manifest, and W&B receipt must cite "
                "the same canonical training authorization evidence"
            )
    return actual, inventory


def unexpected_fresh_paths(
    fresh: Path,
    staged_paths: set[str],
    revision: str | None = None,
) -> list[str]:
    """Find public snapshot files absent from the staged publication tree."""
    unexpected = []
    for item in full_directory_inventory(fresh):
        relative_path = item["path"]
        if relative_path == ".gitattributes":
            continue
        if relative_path in {
            ".cache/huggingface/.gitignore",
            ".cache/huggingface/CACHEDIR.TAG",
        }:
            continue
        download_prefix = ".cache/huggingface/download/"
        if relative_path.startswith(download_prefix):
            payload_path = relative_path.removeprefix(download_prefix)
            for suffix in (".metadata", ".lock"):
                if payload_path.endswith(suffix):
                    payload_path = payload_path.removesuffix(suffix)
                    break
            else:
                payload_path = ""
            if payload_path in staged_paths:
                continue
        tree_prefix = ".cache/huggingface/trees/"
        if relative_path.startswith(tree_prefix):
            tree_name = relative_path.removeprefix(tree_prefix)
            if tree_name == f"{revision}.json" and revision is not None:
                continue
        if relative_path not in staged_paths:
            unexpected.append(relative_path)
    return sorted(unexpected)


def model_card(
    *,
    repo_id: str,
    training: dict[str, Any],
    training_configuration_yaml: str,
    results: list[dict[str, Any]],
    license_id: str,
    license_url: str,
    commercial: bool,
    output_inventory: list[dict[str, Any]],
    training_fused_tree_sha256: str,
) -> str:
    base = training["base"]
    corpus = training["corpus"]
    config = training["configuration"]
    training_provenance = training["candidate_manifest_entry"][
        "training_provenance"
    ]
    qwen_notice = ""
    if "qwen-research" in license_id:
        qwen_notice = """
## License and required notice

This is a modified derivative of Qwen2.5-Coder-3B-Instruct. It is provided
under the Qwen Research License included in this repository, together with
any additional upstream license file identified by the base artifact.
**Non-commercial use only.** Built/Improved using Qwen. Qwen, the base-model
authors, and any intermediate model authors are attributed through the
base-model link, `NOTICE`, modification notice, and included license files.
"""
    else:
        qwen_notice = f"""
## License

License inheritance: [{license_id}]({license_url}). Review the upstream terms
before redistribution or deployment.
"""
    result_lines = "\n".join(
        (
            f"- `{result['gold']}`; GCD `{result['gcd']}`; "
            f"temperature `{result['temperature']}`; seed `{result['seed']}`: "
            f"EX {result['ex']:.3f}, valid SQL "
            f"{result['valid_sql_rate']:.3f}, p95 "
            f"{result['p95_microseconds']} μs; immutable run "
            f"`{result['_evidence']['run_id']}` "
            f"(manifest SHA-256 "
            f"`{result['_evidence']['manifest_sha256']}`, summary SHA-256 "
            f"`{result['_evidence']['summary_sha256']}`)"
        )
        for result in results
    )
    corpus_lines = "\n".join(
        (
            f"- `{item['committed']['path']}`: "
            f"`{item['committed']['sha256']}` "
            f"(byte-for-byte regeneration: "
            f"`{str(item['byte_for_byte_equal']).lower()}`)"
        )
        for item in corpus["files"]
    )
    inventory_digest = directory_digest(output_inventory)
    adapter_digest = directory_digest(
        training_provenance["adapter_files"]
    )
    return f"""---
library_name: mlx
pipeline_tag: text-generation
license: {"other" if "qwen-research" in license_id else license_id}
base_model: {base["repository"]}
tags:
- mlx
- text-to-sql
- qlora
---

# {repo_id}

An MLX 4-bit text-to-SQL derivative for the frozen synthetic CREG commercial
real-estate portfolio. This artifact is a research prototype, not a general
SQL model.

## Reproducibility

- Base: `{base["repository"]}@{base["revision"]}`
- Verified base artifact tree SHA-256:
  `{training_provenance["base_directory_sha256"]}`
- Base artifact lock SHA-256: `{base["lock"]["sha256"]}`
- Code revision: `{training["git"]["commit"]}` (dirty state:
  `{str(training["git"]["dirty"]).lower()}`)
- Training run: `{training["run_id"]}`
- Training runner SHA-256:
  `{training["inputs"]["training_runner"]["sha256"]}`
- Corpus generator SHA-256:
  `{training["inputs"]["corpus_generator"]["sha256"]}`
- Model manifest input SHA-256:
  `{training["inputs"]["model_manifest"]["sha256"]}`
- Pinned Python lock SHA-256: `{training["inputs"]["uv_lock"]["sha256"]}`
- Training configuration SHA-256: `{config["sha256"]}`
- Corpus manifest SHA-256: `{corpus["manifest"]["sha256"]}`
- Gold set remained held out: `{corpus["gold_v2_held_out"]["sha256"]}`
- Adapter tree SHA-256: `{adapter_digest}`
- Training log SHA-256:
  `{training_provenance["training_log_sha256"]}`
- Fused output tree SHA-256 before publication documentation:
  `{training_fused_tree_sha256}`
- Model payload SHA-256 excluding documentation, license, and notice files:
  `{inventory_digest}`
- Quantization: fused 4-bit affine, group size 64
- Commercial use allowed by the declared inherited license:
  `{str(commercial).lower()}`

Training corpus inputs:

{corpus_lines}

The complete YAML configuration uses seed 424242, 600 iterations, batch size
4, 16 adapted layers, learning rate 1e-4, prompt masking, and explicit
mlx-lm defaults. The immutable training run retains the complete commands,
per-file adapter inventory, training log, and fused output inventory.

```yaml
{training_configuration_yaml.rstrip()}
```

## Evaluation

{result_lines}

Execution accuracy is order-insensitive typed row-multiset equality with
four-decimal half-even numeric normalization. These scores apply only to the
frozen CREG schema/database/gold set and their immutable run manifests.

## Limitations

- Narrow synthetic domain and fixed SQLite schema.
- May generate semantically incorrect, incomplete, or non-executable SQL.
- Not evaluated for arbitrary databases, adversarial prompts, or production
  financial decision-making.
- Generated SQL must execute under a read-only connection and should be
  independently reviewed.

{qwen_notice}
"""


def main() -> None:
    args = parse_args()
    if len(set(args.training_run)) != len(args.training_run):
        raise SystemExit("--training-run values must be distinct")
    model_manifest = load_manifest(MODEL_MANIFEST)
    bases = {model["key"]: model for model in model_manifest["models"]}
    result_summaries = [summary(path.resolve()) for path in args.result_run]
    api = HfApi()
    publications = []
    for run_path in args.training_run:
        run_path = run_path.resolve()
        training = json.loads((run_path / "manifest.json").read_text())
        if training.get("status") != "complete":
            raise RuntimeError(f"training run is not complete: {run_path}")
        require_wandb_complete(training, operation="finalist publication")
        base = bases[training["base"]["key"]]
        fused = Path(training["outputs"]["fused"])
        lock = json.loads((fused / LOCK_FILE).read_text())
        (
            training_fused_tree_sha256,
            verified_fused_inventory,
        ) = verify_fused_tree_for_publication(
            fused,
            lock,
            training=training,
            evidence_path=run_path / EVIDENCE_FILE,
        )
        key = lock["key"]
        results = [
            result
            for result in result_summaries
            if result["model_key"] == key
        ]
        if not results:
            raise RuntimeError(f"no evaluation results supplied for {key}")
        for result in results:
            # A model_key string match is not identity: the run must have
            # scored the exact tree being published.
            recorded = result.get("_model_directory_sha256")
            if recorded != training_fused_tree_sha256:
                raise RuntimeError(
                    f"evaluation run {result['_evidence']['run_id']} scored "
                    f"model tree {recorded}, not the tree being published "
                    f"({training_fused_tree_sha256})"
                )
        repo_id = (
            "hbmartin/creg-sql-"
            f"{repository_slug(base['repository'])}-mlx-4bit"
        )
        publication_directory = create_run_directory(
            args.publications_dir.resolve(),
            f"publish-{training['run_id']}",
        )
        publication_path = publication_directory / "publication.json"
        publication_manifest = {
            "schema_version": 1,
            "run_id": publication_directory.name,
            "status": "running",
            "command": command_line(),
            "git": git_provenance(),
            "hardware": hardware_provenance(),
            "repository": repo_id,
            "training_run": {
                "path": str(run_path.relative_to(REPO_ROOT)),
                "manifest_sha256": sha256_file(run_path / "manifest.json"),
            },
            "inputs": {
                "model_manifest": input_hash(MODEL_MANIFEST),
                "publisher": input_hash(Path(__file__)),
            },
            "evaluation_runs": [
                result["_evidence"] for result in results
            ],
        }
        write_json(
            publication_directory / "manifest.json",
            publication_manifest,
        )
        staging = args.staging_dir.resolve() / training["run_id"]
        if staging.exists():
            raise RuntimeError(
                f"publication staging directory already exists: {staging}"
            )
        shutil.copytree(
            fused,
            staging,
            symlinks=True,
            ignore=shutil.ignore_patterns(LOCK_FILE, ".cache"),
        )
        staged_source_sha256 = directory_digest(directory_inventory(staging))
        if staged_source_sha256 != training_fused_tree_sha256:
            raise RuntimeError(
                "publication staging copy differs from the verified fused "
                f"tree ({staged_source_sha256} != "
                f"{training_fused_tree_sha256})"
            )
        license_declaration = base["license"]
        declared_licenses = distribution_files(license_declaration)
        declared_notice = notice_file(license_declaration)
        license_paths = {item["path"] for item in declared_licenses}
        if declared_notice is not None:
            license_paths.add(declared_notice["path"])
        model_inventory = [
            file
            for file in verified_fused_inventory
            if file["path"] not in {"README.md", *license_paths}
        ]
        training_configuration = (
            REPO_ROOT / training["configuration"]["path"]
        )
        if (
            not training_configuration.is_file()
            or training_configuration.stat().st_size
            != training["configuration"]["size"]
            or sha256_file(training_configuration)
            != training["configuration"]["sha256"]
        ):
            raise RuntimeError(
                "training configuration no longer matches immutable run: "
                f"{training_configuration}"
            )
        (staging / "README.md").write_text(
            model_card(
                repo_id=repo_id,
                training=training,
                training_configuration_yaml=(
                    training_configuration.read_text()
                ),
                results=results,
                license_id=license_declaration["id"],
                license_url=license_declaration["url"],
                commercial=license_declaration["commercial_use"],
                output_inventory=model_inventory,
                training_fused_tree_sha256=training_fused_tree_sha256,
            )
        )
        base_directory = (
            REPO_ROOT / training["base"]["lock"]["path"]
        ).parent
        for required_license in declared_licenses:
            license_source = Path(
                hf_hub_download(
                    repo_id=required_license["source_repository"],
                    filename=required_license["source_path"],
                    revision=required_license["source_revision"],
                )
            )
            if (
                license_source.stat().st_size != required_license["size"]
                or sha256_file(license_source) != required_license["sha256"]
            ):
                raise RuntimeError(
                    f"pinned license verification failed: {license_source}"
                )
            target = staging / required_license["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(license_source, target)
        if declared_notice is not None:
            notice_source = REPO_ROOT / declared_notice["source_path"]
            if (
                not notice_source.is_file()
                or notice_source.stat().st_size != declared_notice["size"]
                or sha256_file(notice_source) != declared_notice["sha256"]
            ):
                raise RuntimeError(
                    f"pinned notice verification failed: {notice_source}"
                )
            notice_target = staging / declared_notice["path"]
            notice_target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(notice_source, notice_target)
        if not declared_licenses and (base_directory / "LICENSE").is_file():
            shutil.copy2(base_directory / "LICENSE", staging / "LICENSE")
        elif (
            "qwen-research" in license_declaration["id"]
            and not declared_licenses
        ):
            raise RuntimeError(
                f"Qwen Research License is missing from {base_directory}"
            )

        inventory = directory_inventory(staging)
        api.create_repo(repo_id=repo_id, private=False, exist_ok=False)
        commit = api.upload_folder(
            repo_id=repo_id,
            folder_path=staging,
            ignore_patterns=[LOCK_FILE, ".cache/**"],
            commit_message=(
                f"Publish {key} from immutable training run "
                f"{training['run_id']}"
            ),
        )
        revision = commit.oid
        fresh_directory = (
            args.fresh_downloads_dir.resolve() / training["run_id"]
        )
        if fresh_directory.exists():
            raise RuntimeError(
                f"fresh-download directory already exists: {fresh_directory}"
            )
        fresh = Path(
            snapshot_download(
                repo_id=repo_id,
                revision=revision,
                local_dir=fresh_directory,
                force_download=True,
            )
        )
        mismatches = []
        for file in inventory:
            downloaded = fresh / file["path"]
            if (
                not downloaded.is_file()
                or downloaded.stat().st_size != file["size"]
                or sha256_file(downloaded) != file["sha256"]
            ):
                mismatches.append(file["path"])
        if mismatches:
            raise RuntimeError(
                f"fresh-download verification failed for {repo_id}: "
                f"{mismatches}"
            )
        # Verification is two-way: every staged file must round-trip, and
        # the public snapshot must not contain files that were never staged
        # (the Hub's .gitattributes and local download metadata are the only
        # expected additions).
        staged_paths = {file["path"] for file in inventory}
        unexpected = unexpected_fresh_paths(fresh, staged_paths, revision)
        if unexpected:
            raise RuntimeError(
                f"fresh download of {repo_id} contains files that were "
                f"never staged: {unexpected}"
            )
        fresh_inventory = directory_inventory(fresh)
        # Preserve the immutable training output. Materialize the independently
        # verified public snapshot into a distinct same-filesystem tree.
        published_root = args.published_trees_dir.resolve()
        published_root.mkdir(parents=True, exist_ok=True)
        published = published_root / training["run_id"]
        if published.exists() or published.is_symlink():
            raise RuntimeError(
                f"published snapshot already exists and is immutable: {published}"
            )
        published_staging = Path(tempfile.mkdtemp(
            prefix=f".{published.name}.staging-", dir=published_root
        ))
        try:
            shutil.copytree(
                fresh,
                published_staging,
                dirs_exist_ok=True,
                symlinks=True,
                ignore=shutil.ignore_patterns(".cache"),
            )
            local_public_inventory = directory_inventory(published_staging)
            if local_public_inventory != fresh_inventory:
                raise RuntimeError(
                    f"local/public snapshot inventories differ for {repo_id}"
                )
            public_lock = {
                **lock,
                "repository": repo_id,
                "revision": revision,
                "verified_files": fresh_inventory,
                "all_files": fresh_inventory,
                "directory_sha256": directory_digest(fresh_inventory),
                "training_directory_sha256": training_fused_tree_sha256,
                "training_lock_sha256": sha256_file(fused / LOCK_FILE),
            }
            write_json(published_staging / LOCK_FILE, public_lock)
            transactionally_replace_directory(published_staging, published)
        finally:
            if published_staging.exists():
                shutil.rmtree(published_staging)
        local_public_inventory = directory_inventory(published)
        if local_public_inventory != fresh_inventory:
            raise RuntimeError(
                f"local/public snapshot inventories differ for {repo_id}"
            )
        shutil.rmtree(staging)
        publication = {
            "schema_version": 1,
            "publication_run_id": publication_directory.name,
            "training_run_id": training["run_id"],
            "repository": repo_id,
            "revision": revision,
            "public": True,
            "fresh_download_verified": True,
            "fresh_snapshot": str(fresh.relative_to(REPO_ROOT)),
            "published_snapshot": str(published.relative_to(REPO_ROOT)),
            "model_files": fresh_inventory,
            "training_fused_tree_sha256": training_fused_tree_sha256,
            "model_tree_sha256": directory_digest(fresh_inventory),
            "evaluation_runs": [
                result["_evidence"] for result in results
            ],
            "model_card": input_hash(published / "README.md"),
            "licenses": [
                input_hash(published / item["path"])
                for item in declared_licenses
            ],
            "notice": (
                input_hash(published / declared_notice["path"])
                if declared_notice is not None
                else None
            ),
            "license": (
                input_hash(published / "LICENSE")
                if (published / "LICENSE").is_file()
                else None
            ),
        }
        publication["publication_record"] = str(
            publication_path.relative_to(REPO_ROOT)
        )
        write_json(publication_path, publication)
        publication_manifest["status"] = "complete"
        publication_manifest["revision"] = revision
        publication_manifest["fresh_download_verified"] = True
        publication_manifest["outputs"] = {
            "publication": {
                "path": "publication.json",
                "sha256": sha256_file(publication_path),
            }
        }
        write_json(
            publication_directory / "manifest.json",
            publication_manifest,
        )
        publications.append(publication)
    print(json.dumps(publications, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
