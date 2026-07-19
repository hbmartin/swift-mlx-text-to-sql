"""Eval harness runner: gold set -> model -> (optional GCD) -> execute -> EX.

One invocation = one config cell of the PRD §12 matrix. Emits per-item results
JSONL and a summary JSON into eval/out/, and prints the summary.

Usage:
  uv run python -m eval.run_eval --model ../models/Qwen2.5-Coder-3B-Instruct-4bit \
      --gcd on --gold ../eval/gold/gold_v1.jsonl --label qwen25c-3b-gcd
"""

import argparse
import json
import re
import time
from pathlib import Path

import mlx.core as mx
import numpy as np
import xgrammar
from mlx_lm import generate, load
from mlx_lm.sample_utils import make_sampler

from eval.ex import ExecutionError, execute, results_match

REPO_ROOT = Path(__file__).resolve().parents[2]
DB = REPO_ROOT / "db" / "creg.sqlite"
GRAMMAR_PATH = REPO_ROOT / "CREGKit" / "Sources" / "CREGEngine" / "Resources" / "sql_grammar.ebnf"
SCHEMA_PROMPT_PATH = REPO_ROOT / "CREGKit" / "Sources" / "CREGEngine" / "Resources" / "schema_prompt.txt"
OUT_DIR = REPO_ROOT / "eval" / "out"

# Mirrors the app's system prompt (SQLGenClient.swift) for Mac/app parity.
SYSTEM_PROMPT = """You translate questions about a commercial real estate portfolio into a single \
SQLite SELECT statement. Only SELECT is possible. Use only these tables and columns:

{schema}

Rules:
- Vacancy means 1 - occupancy_rate from each property's latest monthly \
property_financials row, never derived from leases.
- "Current value" of a property is properties.current_market_value; the \
valuations table is appraisal history only.
- Dates are ISO text (YYYY-MM-DD); today is 2026-07-01.
- Rates are 0-1 fractions.
Output only the SQL statement."""

AGG_RE = re.compile(r"\b(COUNT|SUM|AVG|MIN|MAX|TOTAL)\s*\(", re.I)
TABLE_RE = re.compile(r"\b(?:FROM|JOIN)\s+([a-zA-Z_][a-zA-Z0-9_]*)", re.I)


class XGrammarLogitsProcessor:
    """Grammar-constrained decoding for mlx_lm via xgrammar token bitmasks.

    Also records mean pre-mask token entropy per step — the signal the M4
    uncertainty gate (correction layer D) thresholds on.
    """

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
            return logits  # grammar complete; let the model emit EOS freely

        flat = np.array(logits.astype(mx.float32)).reshape(-1)
        probs = np.exp(flat - flat.max())
        probs /= probs.sum()
        self.entropies.append(float(-(probs * np.log(probs + 1e-12)).sum()))

        self.matcher.fill_next_token_bitmask(self.bitmask)
        bits = self.bitmask.numpy().astype(np.uint32)
        allowed = ((bits[:, :, None] >> np.arange(32, dtype=np.uint32)) & 1).astype(bool)
        allowed = allowed.reshape(1, -1)[:, : self.vocab_size]

        width = logits.shape[-1]
        mask = np.full((width,), -np.inf, dtype=np.float32)
        n = min(width, self.vocab_size)
        mask[:n][allowed[0, :n]] = 0.0
        return logits + mx.array(mask).reshape(logits.shape[-1:])


class EntropyOnlyProcessor:
    """Records entropy without constraining (for GCD-off runs)."""

    def __init__(self):
        self.entropies: list[float] = []

    def __call__(self, tokens: mx.array, logits: mx.array) -> mx.array:
        flat = np.array(logits.astype(mx.float32)).reshape(-1)
        probs = np.exp(flat - flat.max())
        probs /= probs.sum()
        self.entropies.append(float(-(probs * np.log(probs + 1e-12)).sum()))
        return logits


def extract_sql(text: str) -> str:
    """Pull the SQL statement out of unconstrained model output."""
    text = text.strip()
    fence = re.search(r"```(?:sql)?\s*(.*?)```", text, re.S | re.I)
    if fence:
        text = fence.group(1).strip()
    match = re.search(r"(SELECT|WITH)\b.*", text, re.S | re.I)
    if match:
        text = match.group(0)
    return text.split(";")[0].strip()


def taxonomy(predicted_sql: str, gold_sql: str, error: str | None,
             predicted_rows, gold_rows) -> str:
    if error is not None:
        return "execution-error"
    if predicted_rows is not None and gold_rows and len(predicted_rows) == 0:
        return "empty-when-expected"
    pred_tables = set(t.lower() for t in TABLE_RE.findall(predicted_sql))
    gold_tables = set(t.lower() for t in TABLE_RE.findall(gold_sql))
    if pred_tables != gold_tables:
        return "wrong-table-or-join"
    pred_aggs = sorted(a.upper() for a in AGG_RE.findall(predicted_sql))
    gold_aggs = sorted(a.upper() for a in AGG_RE.findall(gold_sql))
    if pred_aggs != gold_aggs:
        return "wrong-aggregation"
    if (predicted_rows is not None and gold_rows is not None
            and len(predicted_rows) > 0 and len(gold_rows) > 0
            and len(predicted_rows[0]) != len(gold_rows[0])):
        return "wrong-projection"
    return "wrong-filter-or-value"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, help="local path or HF id")
    parser.add_argument("--gcd", choices=["on", "off"], default="on")
    parser.add_argument("--gold", type=Path, default=REPO_ROOT / "eval" / "gold" / "gold_v1.jsonl")
    parser.add_argument("--label", required=True, help="config label for output files")
    parser.add_argument("--max-tokens", type=int, default=512)
    parser.add_argument("--max-items", type=int, default=None)
    args = parser.parse_args()

    schema = SCHEMA_PROMPT_PATH.read_text().strip()
    system_prompt = SYSTEM_PROMPT.format(schema=schema)
    items = [json.loads(line) for line in args.gold.read_text().splitlines() if line.strip()]
    if args.max_items:
        items = items[: args.max_items]

    model, tokenizer = load(args.model)
    hf_tokenizer = getattr(tokenizer, "_tokenizer", tokenizer)

    compiled = None
    if args.gcd == "on":
        tokenizer_info = xgrammar.TokenizerInfo.from_huggingface(hf_tokenizer)
        compiler = xgrammar.GrammarCompiler(tokenizer_info)
        compiled = compiler.compile_grammar(GRAMMAR_PATH.read_text())
        vocab_size = tokenizer_info.vocab_size

    sampler = make_sampler(temp=0.0)
    results = []
    for item in items:
        question = item.get("standalone") or item["question"]
        messages = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": f"Question: {question}"},
        ]
        try:
            prompt = hf_tokenizer.apply_chat_template(
                messages, add_generation_prompt=True, tokenize=False, enable_thinking=False)
        except TypeError:
            prompt = hf_tokenizer.apply_chat_template(
                messages, add_generation_prompt=True, tokenize=False)

        processor = (XGrammarLogitsProcessor(compiled, vocab_size)
                     if compiled is not None else EntropyOnlyProcessor())
        start = time.perf_counter()
        text = generate(model, tokenizer, prompt=prompt, max_tokens=args.max_tokens,
                        sampler=sampler, logits_processors=[processor])
        elapsed = time.perf_counter() - start

        predicted_sql = text.strip() if args.gcd == "on" else extract_sql(text)
        gold_rows = execute(DB, item["sql"])
        error = None
        predicted_rows = None
        try:
            predicted_rows = execute(DB, predicted_sql)
        except ExecutionError as exc:
            error = str(exc)
        ex = predicted_rows is not None and results_match(predicted_rows, gold_rows)
        bucket = "correct" if ex else taxonomy(predicted_sql, item["sql"], error,
                                               predicted_rows, gold_rows)
        entropies = processor.entropies
        results.append({
            "id": item["id"], "tier": item["tier"], "tags": item.get("tags", []),
            "question": question, "gold_sql": item["sql"], "predicted_sql": predicted_sql,
            "ex": ex, "bucket": bucket, "error": error,
            "predicted_rowcount": None if predicted_rows is None else len(predicted_rows),
            "gold_rowcount": len(gold_rows),
            "seconds": round(elapsed, 2),
            "gen_tokens": len(entropies),
            "mean_entropy": round(float(np.mean(entropies)), 4) if entropies else None,
            "max_entropy": round(float(np.max(entropies)), 4) if entropies else None,
        })
        status = "✓" if ex else f"✗ {bucket}"
        print(f"[{item['id']}] {status} ({elapsed:.1f}s)", flush=True)

    n = len(results)
    ex_n = sum(r["ex"] for r in results)
    valid_n = sum(r["error"] is None for r in results)
    buckets: dict[str, int] = {}
    for r in results:
        if not r["ex"]:
            buckets[r["bucket"]] = buckets.get(r["bucket"], 0) + 1
    by_tier = {}
    for tier in sorted({r["tier"] for r in results}):
        tier_rs = [r for r in results if r["tier"] == tier]
        by_tier[str(tier)] = round(sum(r["ex"] for r in tier_rs) / len(tier_rs), 3)
    summary = {
        "label": args.label, "model": args.model, "gcd": args.gcd,
        "gold": args.gold.name, "n": n,
        "ex": round(ex_n / n, 3), "valid_sql_rate": round(valid_n / n, 3),
        "ex_by_tier": by_tier, "failure_buckets": buckets,
        "mean_seconds": round(float(np.mean([r["seconds"] for r in results])), 2),
        "mean_entropy_correct": round(float(np.mean(
            [r["mean_entropy"] for r in results if r["ex"] and r["mean_entropy"]] or [0])), 4),
        "mean_entropy_wrong": round(float(np.mean(
            [r["mean_entropy"] for r in results if not r["ex"] and r["mean_entropy"]] or [0])), 4),
    }
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    (OUT_DIR / f"{args.label}.jsonl").write_text(
        "\n".join(json.dumps(r) for r in results) + "\n")
    (OUT_DIR / f"{args.label}.summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
