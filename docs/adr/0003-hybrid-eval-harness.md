# Two eval harnesses on purpose: Python for breadth, Swift for truth

The Python/uv harness runs the full model and generation sweep, while `creg-eval-cli` links the app's MLX-Swift prompt, grammar, execution, and typed result identity. A production choice is blocked until both stacks run all 200 gold_v2 items: absolute EX and valid-SQL deltas must each be at most two points, and every item disagreement must be listed and explained. A smaller smoke subset cannot establish parity because runtime, tokenizer, sampling, and grammar drift are exactly what this gate is meant to expose.
