"""Download SQL-model weights into models/ (gitignored).

The app resolves the model in this order: bundled `SQLModel` folder in the app
bundle, then the Hugging Face cache / on-device download. This script fetches
weights for (a) the Mac eval harness and (b) bundling into the app for the
fully-offline build (add the downloaded folder to the CREG target as a folder
reference named `SQLModel`).

Usage:  uv run python tools/fetch_model.py [model_id ...]
"""

import sys
from pathlib import Path

from huggingface_hub import snapshot_download

REPO_ROOT = Path(__file__).resolve().parents[2]
MODELS_DIR = REPO_ROOT / "models"

DEFAULT_MODELS = ["mlx-community/Qwen2.5-Coder-3B-Instruct-4bit"]


def main() -> None:
    model_ids = sys.argv[1:] or DEFAULT_MODELS
    for model_id in model_ids:
        target = MODELS_DIR / model_id.split("/")[-1]
        print(f"fetching {model_id} -> {target}")
        snapshot_download(repo_id=model_id, local_dir=target)
        print(f"done: {target}")


if __name__ == "__main__":
    main()
