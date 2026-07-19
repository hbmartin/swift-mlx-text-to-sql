# MLX runtime, not Core ML

Grammar-constrained decoding requires per-token access to the logits so a mask can be applied at every step. MLX exposes this via a logit-processor hook; Core ML does not support structured-output or grammar-constrained decoding at all. Converting the SQL model to Core ML for ANE efficiency would therefore break the single most valuable part of the architecture — do not "optimize" this. Full rationale in the PRD §8.1. Revisit only for v2 on iOS 27 "Core AI," and only with a plan for re-solving grammar constraints outside the runtime.
