"""Canonical experiment configuration and deterministic checkpoint selection."""

from __future__ import annotations

import base64
import hashlib
import json
import math
import re
from dataclasses import asdict, dataclass
from typing import Any, Iterable


MODEL_KEYS = frozenset({"qwen25-coder-3b", "xiyansql-qwencoder-3b"})
FINE_TUNE_TYPES = frozenset({"lora", "dora"})
TRAINABLE_LAYERS = frozenset({"last-16", "all"})
RANKS = frozenset({4, 8, 16})
SCALE_RATIOS = (1.0, 2.0, 2.5)
DROPOUTS = (0.0, 0.05)
STAGES = frozenset({"screening", "promoted", "final"})
MIN_LEARNING_RATE = 2e-5
MAX_LEARNING_RATE = 2e-4


class ExperimentConfigurationError(ValueError):
    """Raised when a run falls outside the supported campaign contract."""


def canonical_json(value: Any) -> str:
    """Return the one JSON encoding used for all content identities."""

    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    )


def canonical_sha256(value: Any) -> str:
    return hashlib.sha256(canonical_json(value).encode()).hexdigest()


def _one_of_float(value: float, choices: tuple[float, ...]) -> bool:
    return any(math.isclose(value, choice, rel_tol=0, abs_tol=1e-12) for choice in choices)


@dataclass(frozen=True, slots=True)
class ExperimentConfig:
    """The reproducible controls for one immutable MLX-LM experiment."""

    model_key: str
    seed: int
    fine_tune_type: str
    trainable_layers: str
    rank: int
    scale_ratio: float
    dropout: float
    learning_rate: float
    iterations: int
    campaign_id: str
    stage: str = "screening"
    batch_size: int = 4
    grad_accumulation_steps: int = 1
    max_seq_length: int = 2048
    save_every: int = 100
    mask_prompt: bool = True
    learning_rate_schedule: str = "constant"

    def __post_init__(self) -> None:
        if self.model_key not in MODEL_KEYS:
            raise ExperimentConfigurationError(
                f"unsupported model_key {self.model_key!r}; choose {sorted(MODEL_KEYS)}"
            )
        if self.seed < 0:
            raise ExperimentConfigurationError("seed must be non-negative")
        if self.fine_tune_type not in FINE_TUNE_TYPES:
            raise ExperimentConfigurationError(
                f"unsupported fine_tune_type {self.fine_tune_type!r}"
            )
        if self.trainable_layers not in TRAINABLE_LAYERS:
            raise ExperimentConfigurationError(
                f"unsupported trainable_layers {self.trainable_layers!r}"
            )
        if self.rank not in RANKS:
            raise ExperimentConfigurationError(f"unsupported rank {self.rank}")
        if not _one_of_float(self.scale_ratio, SCALE_RATIOS):
            raise ExperimentConfigurationError(
                f"unsupported scale_ratio {self.scale_ratio}"
            )
        if not _one_of_float(self.dropout, DROPOUTS):
            raise ExperimentConfigurationError(f"unsupported dropout {self.dropout}")
        if not MIN_LEARNING_RATE <= self.learning_rate <= MAX_LEARNING_RATE:
            raise ExperimentConfigurationError(
                "learning_rate must be between 2e-5 and 2e-4"
            )
        if self.iterations <= 0 or self.iterations % self.save_every:
            raise ExperimentConfigurationError(
                "iterations must be a positive multiple of save_every"
            )
        if self.stage not in STAGES:
            raise ExperimentConfigurationError(f"unsupported stage {self.stage!r}")
        if not self.campaign_id.strip():
            raise ExperimentConfigurationError("campaign_id must not be empty")
        if self.batch_size != 4:
            raise ExperimentConfigurationError("batch_size is fixed at 4")
        if self.grad_accumulation_steps != 1:
            raise ExperimentConfigurationError(
                "grad_accumulation_steps is fixed at 1"
            )
        if self.max_seq_length != 2048:
            raise ExperimentConfigurationError("max_seq_length is fixed at 2048")
        if self.save_every != 100:
            raise ExperimentConfigurationError("save_every is fixed at 100")
        if not self.mask_prompt:
            raise ExperimentConfigurationError("prompt masking must remain enabled")
        if self.learning_rate_schedule != "constant":
            raise ExperimentConfigurationError(
                "learning_rate_schedule must remain constant"
            )

    @property
    def effective_scale(self) -> float:
        return self.rank * self.scale_ratio

    def hash_payload(self) -> dict[str, Any]:
        """Controls that define byte-affecting training behavior.

        Campaign, stage, model, and seed identify orchestration rather than the
        recipe. They are represented separately in the immutable run identity.
        """

        return {
            "fine_tune_type": self.fine_tune_type,
            "trainable_layers": self.trainable_layers,
            "rank": self.rank,
            "scale_ratio": self.scale_ratio,
            "effective_scale": self.effective_scale,
            "dropout": self.dropout,
            "learning_rate": self.learning_rate,
            "iterations": self.iterations,
            "batch_size": self.batch_size,
            "grad_accumulation_steps": self.grad_accumulation_steps,
            "max_seq_length": self.max_seq_length,
            "save_every": self.save_every,
            "mask_prompt": self.mask_prompt,
            "learning_rate_schedule": self.learning_rate_schedule,
        }

    @property
    def configuration_sha256(self) -> str:
        return canonical_sha256(self.hash_payload())

    def manifest_payload(self) -> dict[str, Any]:
        payload = asdict(self)
        payload["effective_scale"] = self.effective_scale
        payload["configuration_sha256"] = self.configuration_sha256
        return payload


def immutable_run_id(config: ExperimentConfig, wandb_run_id: str) -> str:
    """Bind recipe, seed, family, and W&B identity without truncation risk."""

    normalized_wandb_id = re.sub(r"[^a-zA-Z0-9_-]+", "-", wandb_run_id).strip("-")
    if not normalized_wandb_id:
        raise ExperimentConfigurationError("W&B run ID must not be empty")
    return (
        f"{config.model_key}-{config.configuration_sha256}-"
        f"seed-{config.seed}-wb-{normalized_wandb_id}"
    )


def worst_tier_ex(summary: dict[str, Any]) -> float:
    values = [float(value) for value in summary.get("ex_by_tier", {}).values()]
    return min(values, default=0.0)


def checkpoint_rank_key(candidate: dict[str, Any]) -> tuple[float, float, float, int, int]:
    """Higher is better, including negated latency and iteration tie-breaks."""

    summary = candidate.get("summary", candidate)
    return (
        float(summary["ex"]),
        float(summary["valid_sql_rate"]),
        worst_tier_ex(summary),
        -int(summary["p95_microseconds"]),
        -int(candidate["iteration"]),
    )


def select_development_checkpoint(
    candidates: Iterable[dict[str, Any]],
) -> dict[str, Any]:
    choices = list(candidates)
    if not choices:
        raise ExperimentConfigurationError("no checkpoint evaluations were supplied")
    return max(choices, key=checkpoint_rank_key)


def campaign_tags(
    config: ExperimentConfig,
    *,
    corpus_sha256: str,
    git_commit: str,
    status: str,
    prompt_version: str,
    policy_version: str,
) -> list[str]:
    stage = "confirmation" if config.stage == "promoted" else config.stage
    try:
        corpus_digest = bytes.fromhex(corpus_sha256)
    except ValueError as error:
        raise ExperimentConfigurationError(
            "corpus_sha256 must be a hexadecimal SHA-256 digest"
        ) from error
    if len(corpus_digest) != 32:
        raise ExperimentConfigurationError(
            "corpus_sha256 must be a hexadecimal SHA-256 digest"
        )
    # W&B tags are limited to 64 characters. Base64url retains all 256 bits
    # in 43 characters; the canonical local/config digest remains hex.
    corpus_tag = base64.urlsafe_b64encode(corpus_digest).decode().rstrip("=")
    return [
        f"family:{config.model_key}",
        f"fine-tune:{config.fine_tune_type}",
        f"corpus-sha256:{corpus_tag}",
        f"git:{git_commit}",
        f"status:{status}",
        f"stage:{stage}",
        f"prompt:{prompt_version}",
        f"policy:{policy_version}",
    ]
