"""Manifest-backed text-to-SQL evaluation runner.

One invocation is one immutable model × gold × GCD × temperature × seed cell.
It emits manifest.json, items.jsonl, and summary.json under eval/runs/<run-id>.

Example:
  uv run python -m eval.run_eval \
    --model-key qwen25-coder-3b --gcd on --temperature 0 --seed 0 \
    --gold ../eval/gold/gold_v1.jsonl
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

import mlx.core as mx
import numpy as np
import xgrammar
from mlx_lm import generate, load
from mlx_lm.sample_utils import make_sampler

from eval.ex import (
    ExecutionError,
    QueryExecution,
    execute_with_metadata,
    result_digest,
    results_match,
    typed_rows,
)
from eval.prompt_contract import build_system_prompt
from eval.run_artifacts import (
    DEFAULT_RUNS_DIR,
    REPO_ROOT,
    command_line,
    create_run_directory,
    default_run_id,
    dependency_versions,
    git_provenance,
    hardware_provenance,
    input_hash,
    percentile,
    sha256_bytes,
    sha256_file,
    write_json,
)
from tools.fetch_model import (
    ArtifactError,
    load_manifest,
    verify_artifact_tree_at_use,
)

DB = REPO_ROOT / "db" / "creg.sqlite"
MODEL_MANIFEST = REPO_ROOT / "model-manifest.json"
GRAMMAR_PATH = (
    REPO_ROOT
    / "CREGKit"
    / "Sources"
    / "CREGEngine"
    / "Resources"
    / "sql_grammar.ebnf"
)
SCHEMA_PROMPT_PATH = (
    REPO_ROOT
    / "CREGKit"
    / "Sources"
    / "CREGEngine"
    / "Resources"
    / "schema_prompt.txt"
)

AGG_RE = re.compile(r"\b(COUNT|SUM|AVG|MIN|MAX|TOTAL)\s*\(", re.I)
TABLE_RE = re.compile(r"\b(?:FROM|JOIN)\s+([a-zA-Z_][a-zA-Z0-9_]*)", re.I)


class XGrammarLogitsProcessor:
    def __init__(self, compiled_grammar, vocab_size: int):
        self.matcher = xgrammar.GrammarMatcher(compiled_grammar)
        self.bitmask = xgrammar.allocate_token_bitmask(1, vocab_size)
        self.vocab_size = vocab_size
        self.prev_len: int | None = None
        self.entropies: list[float] = []

    def __call__(self, tokens: mx.array, logits: mx.array) -> mx.array:
        if self.prev_len is not None and tokens.shape[-1] > self.prev_len:
            if not self.matcher.is_terminated():
                self.matcher.accept_token(int(tokens[-1].item()))
        self.prev_len = tokens.shape[-1]
        if self.matcher.is_terminated():
            return logits

        flat = np.array(logits.astype(mx.float32)).reshape(-1)
        probabilities = np.exp(flat - flat.max())
        probabilities /= probabilities.sum()
        self.entropies.append(
            float(-(probabilities * np.log(probabilities + 1e-12)).sum())
        )

        self.matcher.fill_next_token_bitmask(self.bitmask)
        bits = self.bitmask.numpy().astype(np.uint32)
        allowed = (
            (bits[:, :, None] >> np.arange(32, dtype=np.uint32)) & 1
        ).astype(bool)
        allowed = allowed.reshape(1, -1)[:, : self.vocab_size]
        mask = np.full((logits.shape[-1],), -np.inf, dtype=np.float32)
        count = min(logits.shape[-1], self.vocab_size)
        mask[:count][allowed[0, :count]] = 0.0
        return logits + mx.array(mask).reshape(logits.shape[-1:])


class EntropyOnlyProcessor:
    def __init__(self):
        self.entropies: list[float] = []

    def __call__(self, tokens: mx.array, logits: mx.array) -> mx.array:
        flat = np.array(logits.astype(mx.float32)).reshape(-1)
        probabilities = np.exp(flat - flat.max())
        probabilities /= probabilities.sum()
        self.entropies.append(
            float(-(probabilities * np.log(probabilities + 1e-12)).sum())
        )
        return logits


def strip_special_tokens(text: str) -> str:
    return re.sub(r"<\|[a-zA-Z0-9_]+\|>", "", text)


def truncate_at_statement_end(sql: str) -> str:
    """Cut at the first semicolon outside a single-quoted SQL string, so a
    literal like 'A; B' cannot truncate an otherwise correct statement.
    Mirrors the Swift engine byte-for-byte."""
    inside_string = False
    for index, character in enumerate(sql):
        if character == "'":
            inside_string = not inside_string
        elif character == ";" and not inside_string:
            return sql[:index]
    return sql


def extract_sql(text: str) -> str:
    text = text.strip()
    fence = re.search(r"```(?:sql)?\s*(.*?)```", text, re.S | re.I)
    if fence:
        text = fence.group(1).strip()
    match = re.search(r"(SELECT|WITH)\b.*", text, re.S | re.I)
    if match:
        text = match.group(0)
    return truncate_at_statement_end(text).strip()


def taxonomy(
    predicted_sql: str,
    gold_sql: str,
    error: str | None,
    predicted: QueryExecution | None,
    gold: QueryExecution,
) -> str:
    if error is not None:
        return "execution-error"
    if predicted is not None and predicted.is_truncated:
        return "predicted-result-truncated"
    if gold.is_truncated:
        return "gold-result-truncated"
    if predicted is not None and len(gold) > 0 and len(predicted) == 0:
        return "empty-when-expected"
    predicted_tables = {table.lower() for table in TABLE_RE.findall(predicted_sql)}
    gold_tables = {table.lower() for table in TABLE_RE.findall(gold_sql)}
    if predicted_tables != gold_tables:
        return "wrong-table-or-join"
    predicted_aggregates = sorted(
        aggregate.upper() for aggregate in AGG_RE.findall(predicted_sql)
    )
    gold_aggregates = sorted(
        aggregate.upper() for aggregate in AGG_RE.findall(gold_sql)
    )
    if predicted_aggregates != gold_aggregates:
        return "wrong-aggregation"
    if (
        predicted
        and gold
        and len(predicted[0]) != len(gold[0])
    ):
        return "wrong-projection"
    return "wrong-filter-or-value"


def artifact_path(artifact: dict[str, Any], models_dir: Path) -> Path:
    conversion = artifact.get("conversion")
    directory = (
        conversion["output_directory"]
        if conversion is not None
        else artifact["local_directory"]
    )
    return models_dir / directory


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-key", required=True)
    parser.add_argument("--manifest", type=Path, default=MODEL_MANIFEST)
    parser.add_argument("--models-dir", type=Path, default=REPO_ROOT / "models")
    parser.add_argument("--gcd", choices=["on", "off"], required=True)
    parser.add_argument("--temperature", type=float, required=True)
    parser.add_argument("--seed", type=int, required=True)
    parser.add_argument(
        "--gold",
        type=Path,
        default=REPO_ROOT / "eval" / "gold" / "gold_v1.jsonl",
    )
    parser.add_argument("--run-id")
    parser.add_argument("--runs-dir", type=Path, default=DEFAULT_RUNS_DIR)
    parser.add_argument("--max-tokens", type=int, default=512)
    parser.add_argument("--max-items", type=int)
    parser.add_argument(
        "--adapter-path",
        type=Path,
        help="MLX-LM adapter directory applied to the verified base model",
    )
    parser.add_argument(
        "--adapter-checkpoint",
        type=Path,
        help=(
            "specific checkpoint weights; requires --adapter-path for its "
            "adapter_config.json"
        ),
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.temperature < 0:
        raise SystemExit("--temperature must be non-negative")
    if args.adapter_checkpoint is not None and args.adapter_path is None:
        raise SystemExit("--adapter-checkpoint requires --adapter-path")
    manifest_path = args.manifest.resolve()
    manifest = load_manifest(manifest_path)
    artifacts = {model["key"]: model for model in manifest["models"]}
    if args.model_key not in artifacts:
        raise SystemExit(
            f"unknown --model-key {args.model_key!r}; choose one of {sorted(artifacts)}"
        )
    artifact = artifacts[args.model_key]
    model_path = artifact_path(artifact, args.models_dir.resolve())
    artifact_lock = model_path / ".creg-artifact.json"
    if not model_path.is_dir() or not artifact_lock.is_file():
        raise SystemExit(
            f"verified model is missing: run `uv run python tools/fetch_model.py "
            f"--model {args.model_key}` first"
        )
    # Re-hash the tree this run actually loads; the recorded model digest is
    # a fresh measurement, never a claim copied forward from the lock file.
    verified_directory_sha256 = verify_artifact_tree_at_use(
        model_path, artifact
    )

    gold_path = args.gold.resolve()
    items = [
        json.loads(line)
        for line in gold_path.read_text().splitlines()
        if line.strip()
    ]
    if args.max_items is not None:
        items = items[: args.max_items]
    if not items:
        raise SystemExit("gold set is empty")

    run_id = args.run_id or default_run_id(
        args.model_key, gold_path, args.gcd, args.temperature, args.seed
    )
    run_directory = create_run_directory(args.runs_dir.resolve(), run_id)
    schema = SCHEMA_PROMPT_PATH.read_text().strip()
    system_prompt = build_system_prompt(schema)
    artifact_lock_payload = json.loads(artifact_lock.read_text())
    adapter_record = None
    if args.adapter_path is not None:
        adapter_path = args.adapter_path.resolve()
        adapter_config = adapter_path / "adapter_config.json"
        adapter_weights = (
            args.adapter_checkpoint.resolve()
            if args.adapter_checkpoint is not None
            else adapter_path / "adapters.safetensors"
        )
        if not adapter_config.is_file() or not adapter_weights.is_file():
            raise SystemExit(
                "adapter evaluation requires adapter_config.json and checkpoint weights"
            )
        adapter_record = {
            "directory": str(adapter_path),
            "configuration": input_hash(adapter_config),
            "checkpoint": input_hash(adapter_weights),
        }

    run_manifest: dict[str, Any] = {
        "schema_version": 1,
        "run_id": run_id,
        "status": "running",
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "command": command_line(),
        "git": git_provenance(),
        "hardware": hardware_provenance(),
        "dependencies": dependency_versions(),
        "model": {
            "key": args.model_key,
            "repository": artifact.get("repository") or "local-derived",
            "revision": artifact.get("revision")
            or f"sha256:{verified_directory_sha256}",
            "path": str(model_path),
            "artifact_lock": input_hash(artifact_lock),
            "directory_sha256": verified_directory_sha256,
            "bundle_size_bytes": sum(
                file["size"]
                for file in (
                    artifact_lock_payload.get("all_files")
                    or artifact_lock_payload["verified_files"]
                )
            ),
            "training_provenance": artifact_lock_payload.get(
                "training_provenance"
            ),
        },
        "configuration": {
            "gcd": args.gcd,
            "temperature": args.temperature,
            "run_seed": args.seed,
            "item_seed_formula": "run_seed * 1000000 + zero_based_item_index",
            "top_p": 1.0,
            "top_k": 0,
            "max_tokens": args.max_tokens,
            "timing_unit": "microseconds",
        },
        "inputs": {
            "model_manifest": input_hash(manifest_path),
            "uv_lock": input_hash(REPO_ROOT / "fine-tuning" / "uv.lock"),
            "swift_package_lock": input_hash(
                REPO_ROOT / "CREGKit" / "Package.resolved"
            ),
            "database": input_hash(DB),
            "gold": input_hash(gold_path),
            "grammar": input_hash(GRAMMAR_PATH),
            "schema_prompt": input_hash(SCHEMA_PROMPT_PATH),
            "system_prompt_sha256": sha256_bytes(system_prompt.encode()),
            "tokenizer": input_hash(model_path / "tokenizer.json"),
        },
        "item_count": len(items),
    }
    if adapter_record is not None:
        run_manifest["adapter"] = adapter_record
    write_json(run_directory / "manifest.json", run_manifest)

    if adapter_record is None:
        model, tokenizer = load(str(model_path))
    elif args.adapter_checkpoint is None:
        model, tokenizer = load(
            str(model_path), adapter_path=str(args.adapter_path.resolve())
        )
    else:
        # MLX-LM resolves a checkpoint by fixed filenames. A private temporary
        # view avoids mutating the immutable adapter directory or swapping the
        # final checkpoint in place.
        with tempfile.TemporaryDirectory(prefix="creg-adapter-checkpoint-") as value:
            adapter_view = Path(value)
            shutil.copy2(
                args.adapter_path.resolve() / "adapter_config.json",
                adapter_view / "adapter_config.json",
            )
            shutil.copy2(
                args.adapter_checkpoint.resolve(),
                adapter_view / "adapters.safetensors",
            )
            model, tokenizer = load(
                str(model_path), adapter_path=str(adapter_view)
            )
    hf_tokenizer = getattr(tokenizer, "_tokenizer", tokenizer)
    compiled = None
    vocabulary_size = None
    if args.gcd == "on":
        tokenizer_info = xgrammar.TokenizerInfo.from_huggingface(hf_tokenizer)
        compiler = xgrammar.GrammarCompiler(tokenizer_info)
        compiled = compiler.compile_grammar(GRAMMAR_PATH.read_text())
        vocabulary_size = tokenizer_info.vocab_size

    sampler = make_sampler(
        temp=args.temperature,
        top_p=1.0,
        top_k=0,
    )
    results: list[dict[str, Any]] = []
    items_path = run_directory / "items.jsonl"
    with items_path.open("x") as output:
        for index, item in enumerate(items):
            item_seed = args.seed * 1_000_000 + index
            mx.random.seed(item_seed)
            question = item.get("standalone") or item["question"]
            messages = [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": f"Question: {question}"},
            ]
            try:
                prompt = hf_tokenizer.apply_chat_template(
                    messages,
                    add_generation_prompt=True,
                    tokenize=False,
                    enable_thinking=False,
                )
            except TypeError:
                prompt = hf_tokenizer.apply_chat_template(
                    messages, add_generation_prompt=True, tokenize=False
                )

            processor = (
                XGrammarLogitsProcessor(compiled, vocabulary_size)
                if compiled is not None and vocabulary_size is not None
                else EntropyOnlyProcessor()
            )
            item_started_ns = time.perf_counter_ns()
            generation_started_ns = time.perf_counter_ns()
            text = generate(
                model,
                tokenizer,
                prompt=prompt,
                max_tokens=args.max_tokens,
                sampler=sampler,
                logits_processors=[processor],
            )
            generation_microseconds = (
                time.perf_counter_ns() - generation_started_ns
            ) // 1_000

            text = strip_special_tokens(text)
            predicted_sql = text.strip() if args.gcd == "on" else extract_sql(text)
            gold = execute_with_metadata(DB, item["sql"])
            predicted: QueryExecution | None = None
            error: str | None = None
            try:
                predicted = execute_with_metadata(DB, predicted_sql)
            except ExecutionError as execution_error:
                error = str(execution_error)
            ex = predicted is not None and results_match(predicted, gold)
            bucket = (
                "correct"
                if ex
                else taxonomy(predicted_sql, item["sql"], error, predicted, gold)
            )
            entropies = processor.entropies
            record = {
                "schema_version": 1,
                "id": item["id"],
                "tier": item["tier"],
                "tags": item.get("tags", []),
                "question": question,
                "gold_sql": item["sql"],
                "predicted_sql": predicted_sql,
                "ex": ex,
                "bucket": bucket,
                "error": error,
                "run_seed": args.seed,
                "item_seed": item_seed,
                "generation_microseconds": generation_microseconds,
                "predicted_execution_microseconds": (
                    predicted.elapsed_microseconds
                    if predicted is not None
                    else None
                ),
                "gold_execution_microseconds": gold.elapsed_microseconds,
                "elapsed_microseconds": (
                    time.perf_counter_ns() - item_started_ns
                )
                // 1_000,
                "generation_tokens": len(entropies),
                "mean_entropy": float(np.mean(entropies)) if entropies else None,
                "max_entropy": float(np.max(entropies)) if entropies else None,
                "predicted": (
                    None
                    if predicted is None
                    else {
                        "row_count": len(predicted),
                        "is_truncated": predicted.is_truncated,
                        "digest": (
                            None
                            if predicted.is_truncated
                            else result_digest(predicted)
                        ),
                        "rows": typed_rows(predicted),
                    }
                ),
                "gold": {
                    "row_count": len(gold),
                    "is_truncated": gold.is_truncated,
                    "digest": (
                        None if gold.is_truncated else result_digest(gold)
                    ),
                    "rows": typed_rows(gold),
                },
            }
            results.append(record)
            output.write(
                json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n"
            )
            output.flush()
            status = "✓" if ex else f"✗ {bucket}"
            print(
                f"[{item['id']}] {status} ({record['elapsed_microseconds'] / 1_000_000:.3f}s)",
                flush=True,
            )

    count = len(results)
    correct = sum(record["ex"] for record in results)
    valid = sum(record["error"] is None for record in results)
    buckets: dict[str, int] = {}
    for record in results:
        if not record["ex"]:
            buckets[record["bucket"]] = buckets.get(record["bucket"], 0) + 1
    by_tier: dict[str, float] = {}
    for tier in sorted({record["tier"] for record in results}):
        tier_results = [record for record in results if record["tier"] == tier]
        by_tier[str(tier)] = sum(
            record["ex"] for record in tier_results
        ) / len(tier_results)
    timings = [record["elapsed_microseconds"] for record in results]
    summary = {
        "schema_version": 1,
        "run_id": run_id,
        "model_key": args.model_key,
        "model_repository": artifact.get("repository") or "local-derived",
        "model_revision": artifact.get("revision")
        or f"sha256:{verified_directory_sha256}",
        "bundle_size_bytes": run_manifest["model"]["bundle_size_bytes"],
        "adapter_size_bytes": (
            0
            if adapter_record is None
            else int(adapter_record["checkpoint"]["size"])
        ),
        "gcd": args.gcd,
        "temperature": args.temperature,
        "seed": args.seed,
        "gold": gold_path.name,
        "n": count,
        "ex": correct / count,
        "valid_sql_rate": valid / count,
        "ex_by_tier": by_tier,
        "failure_buckets": buckets,
        "mean_microseconds": round(sum(timings) / len(timings)),
        "p95_microseconds": percentile(timings, 0.95),
        "mean_entropy_correct": float(
            np.mean(
                [
                    record["mean_entropy"]
                    for record in results
                    if record["ex"] and record["mean_entropy"] is not None
                ]
                or [0]
            )
        ),
        "mean_entropy_wrong": float(
            np.mean(
                [
                    record["mean_entropy"]
                    for record in results
                    if not record["ex"] and record["mean_entropy"] is not None
                ]
                or [0]
            )
        ),
    }
    write_json(run_directory / "summary.json", summary)
    run_manifest["status"] = "complete"
    run_manifest["completed_at"] = time.strftime(
        "%Y-%m-%dT%H:%M:%SZ", time.gmtime()
    )
    run_manifest["outputs"] = {
        "items": {
            "path": "items.jsonl",
            "sha256": sha256_file(items_path),
        },
        "summary": {
            "path": "summary.json",
            "sha256": sha256_file(run_directory / "summary.json"),
        },
    }
    write_json(run_directory / "manifest.json", run_manifest)
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except ArtifactError as error:
        print(f"evaluation failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
