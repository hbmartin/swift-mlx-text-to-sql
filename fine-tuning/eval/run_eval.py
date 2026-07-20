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
from mlx_lm.sample_utils import make_logits_processors, make_sampler

from eval.ex import ExecutionError, RowCapExceeded, execute, results_match

REPO_ROOT = Path(__file__).resolve().parents[2]
DB = REPO_ROOT / "db" / "creg.sqlite"
GRAMMAR_PATH = REPO_ROOT / "CREGKit" / "Sources" / "CREGEngine" / "Resources" / "sql_grammar.ebnf"
SCHEMA_PROMPT_PATH = REPO_ROOT / "CREGKit" / "Sources" / "CREGEngine" / "Resources" / "schema_prompt.txt"
AS_OF_DATE_PATH = REPO_ROOT / "CREGKit" / "Sources" / "CREGEngine" / "Resources" / "as_of_date.txt"
OUT_DIR = REPO_ROOT / "eval" / "out"
REPETITION_PENALTY = 1.1
REPETITION_CONTEXT_SIZE = 64

# Mirrors the app's system prompt (SQLGenClient.swift) for Mac/app parity.
SYSTEM_PROMPT = """You translate questions about a commercial real estate portfolio into a single \
SQLite SELECT statement. Only SELECT is possible. Use only these tables and columns:

{schema}

Rules:
- Vacancy means 1 - occupancy_rate from each property's latest monthly \
property_financials row, never derived from leases.
- "Current value" of a property is properties.current_market_value; the \
valuations table is appraisal history only.
- Dates are ISO text (YYYY-MM-DD); today is {as_of_date}.
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


def strip_special_tokens(text: str) -> str:
    """Some tokenizers leak chat-template specials (<|im_end|>) into decoded
    text; strip them before executing anything."""
    return re.sub(r"<\|[a-zA-Z0-9_]+\|>", "", text)


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


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def rounded_mean(values: list[float], digits: int) -> float | None:
    return round(float(np.mean(values)), digits) if values else None


def report_sql_score(
    sql_role: str, sql_ex: bool | None, sql_score_status: str, sql_bucket: str
) -> tuple[bool | None, str, str, bool | None, str | None, str | None]:
    """Keep fallback SQL diagnostics without adding them to primary EX."""
    if sql_role == "best_guess_fallback":
        return (
            None,
            "excluded-fallback-sql",
            "excluded-fallback-sql",
            sql_ex,
            sql_score_status,
            sql_bucket,
        )
    return sql_ex, sql_score_status, sql_bucket, None, None, None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, help="local path or HF id")
    parser.add_argument("--gcd", choices=["on", "off"], default="on")
    parser.add_argument("--gold", type=Path, default=REPO_ROOT / "eval" / "gold" / "gold_v1.jsonl")
    parser.add_argument("--label", required=True, help="config label for output files")
    parser.add_argument("--max-tokens", type=positive_int, default=512)
    parser.add_argument("--max-items", type=positive_int, default=None)
    args = parser.parse_args()

    schema = SCHEMA_PROMPT_PATH.read_text().strip()
    as_of_date = AS_OF_DATE_PATH.read_text().strip()
    system_prompt = SYSTEM_PROMPT.format(schema=schema, as_of_date=as_of_date)
    items = [json.loads(line) for line in args.gold.read_text().splitlines() if line.strip()]
    if args.max_items is not None:
        items = items[: args.max_items]
    if not items:
        parser.error("the selected gold set is empty")

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
        repetition_processors = make_logits_processors(
            repetition_penalty=REPETITION_PENALTY,
            repetition_context_size=REPETITION_CONTEXT_SIZE,
        )
        text = generate(model, tokenizer, prompt=prompt, max_tokens=args.max_tokens,
                        sampler=sampler,
                        logits_processors=[processor, *repetition_processors])
        elapsed = time.perf_counter() - start

        text = strip_special_tokens(text)
        predicted_sql = text.strip() if args.gcd == "on" else extract_sql(text)
        gold_rows = None
        gold_cap_error = None
        try:
            gold_rows = execute(DB, item["sql"])
        except RowCapExceeded as exc:
            gold_cap_error = str(exc)
        error = None
        predicted_rows = None
        entropies = processor.entropies
        generation_truncated = len(entropies) >= args.max_tokens
        predicted_cap_error = None
        if not generation_truncated:
            try:
                predicted_rows = execute(DB, predicted_sql)
            except RowCapExceeded as exc:
                predicted_cap_error = str(exc)
            except ExecutionError as exc:
                error = str(exc)

        if generation_truncated:
            sql_ex = False
            sql_score_status = "generation-truncated"
            sql_bucket = "generation-truncated"
        elif gold_cap_error is not None or predicted_cap_error is not None:
            sql_ex = None
            sql_score_status = "row-cap-exceeded"
            sql_bucket = "row-cap-exceeded"
        elif error is not None:
            sql_ex = False
            sql_score_status = "execution-error"
            sql_bucket = "execution-error"
        else:
            sql_ex = results_match(predicted_rows, gold_rows)
            sql_score_status = "scored"
            sql_bucket = "correct" if sql_ex else taxonomy(
                predicted_sql, item["sql"], None, predicted_rows, gold_rows)
        sql_role = item.get("sql_role", "primary")
        (
            ex, score_status, bucket,
            fallback_ex, fallback_score_status, fallback_bucket,
        ) = report_sql_score(sql_role, sql_ex, sql_score_status, sql_bucket)
        valid_sql = not generation_truncated and error is None
        results.append({
            "id": item["id"], "tier": item["tier"], "tags": item.get("tags", []),
            "expected_gate_action": item.get("expected_gate_action"),
            "sql_role": sql_role,
            "question": question, "gold_sql": item["sql"], "predicted_sql": predicted_sql,
            "ex": ex, "score_status": score_status, "bucket": bucket, "error": error,
            "fallback_ex": fallback_ex,
            "fallback_score_status": fallback_score_status,
            "fallback_bucket": fallback_bucket,
            "valid_sql": valid_sql,
            "row_cap_error": gold_cap_error or predicted_cap_error,
            "predicted_rowcount": None if predicted_rows is None else len(predicted_rows),
            "gold_rowcount": None if gold_rows is None else len(gold_rows),
            "seconds": round(elapsed, 2),
            "gen_tokens": len(entropies),
            "mean_entropy": round(float(np.mean(entropies)), 4) if entropies else None,
            "max_entropy": round(float(np.max(entropies)), 4) if entropies else None,
        })
        status = "✓" if ex is True else f"{'–' if ex is None else '✗'} {bucket}"
        print(f"[{item['id']}] {status} ({elapsed:.1f}s)", flush=True)

    n = len(results)
    scored = [r for r in results if r["ex"] is not None]
    fallback_scored = [r for r in results if r["fallback_ex"] is not None]
    ex_n = sum(r["ex"] is True for r in scored)
    valid_n = sum(r["valid_sql"] for r in results)
    buckets: dict[str, int] = {}
    for r in results:
        if r["ex"] is False:
            buckets[r["bucket"]] = buckets.get(r["bucket"], 0) + 1
    by_tier = {}
    for tier in sorted({r["tier"] for r in results}):
        tier_rs = [r for r in scored if r["tier"] == tier]
        by_tier[str(tier)] = (
            round(sum(r["ex"] is True for r in tier_rs) / len(tier_rs), 3)
            if tier_rs else None
        )
    summary = {
        "label": args.label, "model": args.model, "gcd": args.gcd,
        "gold": args.gold.name, "n": n, "scored_n": len(scored),
        "unscorable_n": n - len(scored),
        "fallback_sql_n": sum(r["sql_role"] == "best_guess_fallback" for r in results),
        "fallback_sql_scored_n": len(fallback_scored),
        "fallback_sql_ex": (
            round(sum(r["fallback_ex"] is True for r in fallback_scored)
                  / len(fallback_scored), 3)
            if fallback_scored else None
        ),
        "ex": round(ex_n / len(scored), 3) if scored else None,
        "valid_sql_rate": round(valid_n / n, 3),
        "ex_by_tier": by_tier, "failure_buckets": buckets,
        "mean_seconds": round(float(np.mean([r["seconds"] for r in results])), 2),
        "mean_entropy_correct": rounded_mean(
            [r["mean_entropy"] for r in results
             if r["ex"] is True and r["mean_entropy"] is not None], 4),
        "mean_entropy_wrong": rounded_mean(
            [r["mean_entropy"] for r in results
             if r["ex"] is False and r["mean_entropy"] is not None], 4),
    }
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    (OUT_DIR / f"{args.label}.jsonl").write_text(
        "\n".join(json.dumps(r) for r in results) + "\n")
    (OUT_DIR / f"{args.label}.summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
