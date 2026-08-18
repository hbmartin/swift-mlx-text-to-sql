import hashlib
import json
from pathlib import Path

from tools.build_sql_draft_corpus import build_payload
from tools.fetch_model import DEVICE_RUNTIME_SPECULATIVE_DECODING

ROOT = Path(__file__).resolve().parents[2]
TRAINING_CORPUS = (
    ROOT
    / "eval/training-runs/qlora-qwen25-coder-3b-seed-424242"
    / "regenerated-corpus/train.jsonl"
)
DRAFT_RESOURCE = (
    ROOT / "CREGKit/Sources/CREGInference/Resources/sql_draft_corpus.json"
)


def test_checked_in_sql_draft_corpus_is_exactly_reproducible():
    resource_bytes = DRAFT_RESOURCE.read_bytes()
    resource = json.loads(resource_bytes)

    assert resource == build_payload(TRAINING_CORPUS)
    assert resource["statement_count"] == 1_353
    assert resource["source_sha256"] == hashlib.sha256(
        TRAINING_CORPUS.read_bytes()
    ).hexdigest()
    assert hashlib.sha256(resource_bytes).hexdigest() == (
        DEVICE_RUNTIME_SPECULATIVE_DECODING["corpus_sha256"]
    )
