"""Download SQL-model weights into models/ (gitignored).

The app resolves the model in this order: bundled `SQLModel` folder in the app
bundle, then the Hugging Face cache / on-device download. This script fetches
weights for (a) the Mac eval harness and (b) bundling into the app for the
fully-offline build (add the downloaded folder to the CREG target as a folder
reference named `SQLModel`).

Usage:  uv run python tools/fetch_model.py [model_id ...]

The default release-base download is pinned to the revision used for the v1
fine-tune. Explicit model IDs remain an opt-in request for the repository's
current revision.
"""

import sys
from pathlib import Path

from huggingface_hub import snapshot_download

REPO_ROOT = Path(__file__).resolve().parents[2]
MODELS_DIR = REPO_ROOT / "models"

DEFAULT_MODELS = [
    (
        "mlx-community/Qwen2.5-Coder-3B-Instruct-4bit",
        "3dd939c621c08e5753d5b89f35a2642cd83b98ca",
    )
]


def main() -> None:
    requested = [(model_id, None) for model_id in sys.argv[1:]]
    for model_id, revision in requested or DEFAULT_MODELS:
        target = MODELS_DIR / model_id.split("/")[-1]
        revision_label = revision or "repository default"
        print(f"fetching {model_id}@{revision_label} -> {target}")
        snapshot_download(repo_id=model_id, local_dir=target, revision=revision)
        print(f"done: {target}")


if __name__ == "__main__":
    main()
