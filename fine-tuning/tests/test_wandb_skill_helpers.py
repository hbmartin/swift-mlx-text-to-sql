import importlib.util
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[2]
HELPER = (
    ROOT / ".agents" / "skills" / "wandb-primary" / "scripts" / "weave_helpers_impl.py"
)


def load_helpers():
    spec = importlib.util.spec_from_file_location("weave_helpers_impl", HELPER)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_zero_success_evaluation_has_no_rounded_infinity():
    helpers = load_helpers()
    evaluation = SimpleNamespace(
        summary={
            "weave": {
                "status": "success",
                "status_counts": {"success": 99, "error": 0},
            },
            "status_counts": {"success": 0, "error": 1},
            "usage": {"model": {"total_tokens": 1_000}},
        },
        display_name="zero-success",
        started_at=None,
        id="eval-id",
    )

    assert helpers.eval_efficiency([evaluation]) == [
        {
            "display_name": "zero-success",
            "total_tokens": 1_000,
            "success_count": 0,
            "error_count": 1,
            "tokens_per_success": None,
        }
    ]
