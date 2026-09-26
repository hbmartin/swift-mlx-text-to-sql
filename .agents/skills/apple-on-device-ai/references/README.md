# Apple on-device AI — a developer's guide series

**Covers:** iOS 27 · iPadOS 27 · macOS 27 · watchOS 27 · visionOS 27 · tvOS 27 · Xcode 27
**Frameworks:** Foundation Models · Core AI · MLX · Evaluations · Speech · Metal Performance Primitives
**Series status:** 17 parts · 77 guides · verified against the macOS 26.5 and 27.0-beta SDK
interfaces on 2026-07-29 — [full verification details](#verification-and-series-status).

Seventeen parts covering Apple's 2026 on-device AI stack end to end — from a three-line
`LanguageModelSession` call down to a hand-written Metal matmul kernel, and back up through
shipping, updating and evaluating a model in production.

## Pick your path

<div class="docc-topic-grid" markdown>

<div class="docc-topic-card" markdown>

**[New to the stack? Start with Part 1](part-01-orientation-and-gating/README.md)**

How the four product lines fit together, how to choose a model backend, and every version,
hardware and entitlement gate.

</div>

<div class="docc-topic-card" markdown>

**[Build an AI feature in a Swift app](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/README.md)**

`LanguageModelSession`, guided generation, tools, and failure handling — then Parts 3–4 for
agentic sessions and custom backends.

</div>

<div class="docc-topic-card" markdown>

**[Convert a PyTorch model for on-device use](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md)**

`torch.export` to `.aimodel`, then Parts 9–10 for compression, hardware authoring, and LLM
deployment.

</div>

<div class="docc-topic-card" markdown>

**[Work in Python with MLX](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/README.md)**

Fundamentals through fine-tuning and serving — and Part 13 when the model needs to ship inside
a Swift app.

</div>

<div class="docc-topic-card" markdown>

**[Debug something that fails silently](SILENT-FAILURES.md)**

The silent-failure index, sorted by the symptom you observe: wrong output, empty output,
performance cliff, version drift.

</div>

<div class="docc-topic-card" markdown>

**[Migrate a pre-iOS-27 app](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md)**

What changed between iOS 26 and 27, the adapter sunset, error-taxonomy migration, and
dual-SDK builds.

</div>

</div>

**Two cross-cutting indexes:**

- **[The silent-failure index](SILENT-FAILURES.md)** — every warning callout in the series (1,789,
  of which 1,427 describe a concrete silent failure), in one page, sorted by the symptom you
  observe: wrong output, empty output, performance cliff, version drift, …
- **[The API & symbol index](API-INDEX.md)** — ~1,200 symbols → the guides that cover them, with
  presence flags against the captured 26.5 / 27.0-beta SDK interfaces.

---

## How the series is organized

Each part is a directory:

```
part-NN-<slug>/
  README.md          ← the part's master guide: orientation, reading order, decision tables
  references/        ← the individual deep-dive guides for that part
    <nn>-<slug>.md
```

Read a part's `README.md` first. It tells you which reference guides you actually need and in
what order; most readers need two or three of them, not all.

---

## The one-paragraph map

In 2026 the four product lines stopped being alternatives and became **layers**. The Foundation
Models framework is no longer "the API for Apple's on-device LLM" — `LanguageModelSession` now
sits on a public `LanguageModel` / `LanguageModelExecutor` protocol pair, and there are five
conformers: `SystemLanguageModel` (rebuilt, 4,096-token context, now accepts images),
`PrivateCloudComputeLanguageModel` (32K, three reasoning levels, no API keys, per-user quota),
`CoreAILanguageModel`, `MLXLanguageModel`, and `ChatCompletionsLanguageModel` — which quietly
turns `mlx_lm.server`, Ollama, vLLM and LM Studio into Foundation Models backends today. So the
question stopped being *"which framework do I choose"* and became *"which backend do I choose
behind one session API."* That reframing is the spine of this series.

Underneath, **Core AI** is the inference framework that powers on-device Apple Intelligence, now
public: a portable `.aimodel` → specialization → `AIModel` → `InferenceFunction` → `NDArray`.
**MLX** is the open array framework and the fastest path from a Hugging Face checkpoint to
something running. **Evaluations** cuts across everything and is Apple's answer to the fact that
there is no model version pinning API. **Metal Performance Primitives / TensorOps** is the floor
both Core AI and MLX stand on.

---

## The parts

| Part | Title | For |
|---|---|---|
| [1](part-01-orientation-and-gating/README.md) | Orientation and gating | Everyone. Read first. |
| [2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/README.md) | Foundation Models: the everyday API | Swift app developers |
| [3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md) | Context, profiles, and agentic sessions | Swift app developers |
| [4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md) | Beyond the built-in model | App developers + package authors |
| [5](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-05-prototyping-profiling-non-swift/README.md) | Prototyping, profiling, non-Swift access | Everyone |
| [6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md) | Evaluations | Anyone shipping an AI feature |
| [7](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md) | Core AI: the Swift runtime | Swift developers shipping a model |
| [8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md) | Core AI: converting a model from PyTorch | Python ML engineers |
| [9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md) | Core AI: compression and numeric formats | Python ML engineers |
| [10](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/README.md) | Core AI: hardware authoring, debugging, and LLM deployment | Python ML engineers |
| [11](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/README.md) | Metal and TensorOps | Kernel authors |
| [12](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/README.md) | MLX in Python | Python ML engineers |
| [13](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/README.md) | MLX in Swift | Swift app developers |
| [14](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-14-bridges-between-stacks/README.md) | Bridges between stacks | Anyone moving a model between stacks |
| [15](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/README.md) | Shipping and operating on device | Everyone shipping |
| [16](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/README.md) | Adjacent capabilities | Developers wiring an app into the system |
| [17](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md) | Migration from pre-iOS 27 | Anyone with a shipping iOS 26 app |

---

## Every guide in the series

All 60 reference guides, by part. Each part's `README.md` is the entry point and tells you which of
its references you actually need.

**[Part 1 — Orientation and gating](part-01-orientation-and-gating/README.md)**
- [The 2026 Apple AI stack, and how to choose a model backend](part-01-orientation-and-gating/references/01-apple-ai-stack-2026-map.md)
- [Every version, hardware, entitlement and runtime-surface gate](part-01-orientation-and-gating/references/02-platform-and-version-gating.md)

**[Part 2 — Foundation Models: the everyday API](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/README.md)**
- [`LanguageModelSession` end to end](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md)
- [Guided generation and snapshot streaming](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md)
- [The `Tool` protocol, calling modes, and the required-mode loop](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md)
- [Local RAG with `SpotlightSearchTool`, plus OCR and barcodes](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md)
- [Image input, and what the model cannot do with pixels](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md)
- [The complete failure taxonomy: availability, errors, guardrails and refusals](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md)

**[Part 3 — Context, profiles, and agentic sessions](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md)**
- [Token budgeting, transcript anatomy, and KV-cache economics](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md)
- [Dynamic Profiles, modifiers, and session state](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md)
- [`foundation-models-utilities`: Skills and history transforms](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md)
- [Baton-pass, phone-a-friend, model routing, and tool-calling control](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/references/04-agentic-orchestration.md)

**[Part 4 — Beyond the built-in model](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md)**
- [Private Cloud Compute: eligibility, reasoning, and quota UX](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md)
- [Core AI, MLX, and any OpenAI-compatible server behind `LanguageModelSession`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md)
- [Authoring a `LanguageModel` provider package](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md)
- [Executor lifecycle, configuration identity, and preserving work across calls](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md)

**[Part 5 — Prototyping, profiling, and non-Swift access](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-05-prototyping-profiling-non-swift/README.md)**
- [`#Playground`, scheme simulation, and reading a Foundation Models trace](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md)
- [The `fm` CLI and the Foundation Models SDK for Python](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md)

**[Part 6 — Evaluations](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md)**
- [Building blocks, Swift Testing integration, and evaluation-driven development](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/references/01-foundations-and-hill-climbing.md)
- [Model judges, score dimensions, drift, and Cohen's kappa](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/references/02-model-judges-and-alignment.md)
- [`SampleGenerator`, synthetic datasets, and evaluating tool trajectories](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md)

**[Part 7 — Core AI: the Swift runtime](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md)**
- [`AIModel`, `InferenceFunction`, `NDArray`, and the memory model](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md)
- [Specialization, the model cache, and ahead-of-time compilation](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md)
- [States as KV cache, and pipelined execution](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md)
- [Model bundles, the LLM engines, and grammar-constrained decoding](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md)
- [Non-LLM engines: bundles, function structure, warmup, specialization, and caching](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md)

**[Part 8 — Core AI: converting a model from PyTorch](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md)**
- [`torch.export` to `.aimodel`, and the IO / state / dynamic-shape contract](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md)
- [When an op will not convert: coverage, composites, custom lowerings, externalization](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md)
- [`TorchMetalKernel`: writing and embedding a custom Metal kernel](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md)

**[Part 9 — Core AI: compression and numeric formats](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md)**
- [`coreai-opt` quantization: configs, GRAPH vs EAGER, calibration and QAT](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/references/01-quantization.md)
- [Palettization, pruning, joint compression, and mixed precision](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md)
- [int4 to MX: which layer supports which numeric format](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md)

**[Part 10 — Core AI: hardware authoring, debugging, and LLM deployment](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/README.md)**
- [Authoring for the Neural Engine and for the GPU: two opposite rulesets](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md)
- [The debug gauge, the Core AI Instrument, and the Core AI Debugger](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md)
- [From a Hugging Face checkpoint to a loadable LLM bundle](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md)

**[Part 11 — Metal and TensorOps](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/README.md)**
- [TensorOps: `matmul2d`, tensor types, and what quantization actually looks like](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md)
- [Cooperative tensors, reductions, and building a fused attention kernel](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md)

**[Part 12 — MLX in Python](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/README.md)**
- [MLX fundamentals: unified memory, lazy evaluation, transforms, and `compile`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/references/01-core-fundamentals.md)
- [Numerics, hardware gating, and writing custom Metal kernels from Python](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md)
- [MLX quantization: modes, group sizes, gates, and the corruption bugs](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/references/03-quantization.md)
- [mlx-lm: the CLI surface, the generation API, and KV caching](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md)
- [`mlx_lm.server`, local agents, and distributed inference over Thunderbolt](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/references/05-serving-and-distributed.md)
- [LoRA and DoRA fine-tuning, and adding a new architecture](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/references/06-finetuning-and-porting-models.md)

**[Part 13 — MLX in Swift](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/README.md)**
- [mlx-swift-lm in an app: setup, concurrency, memory, and media input](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md)
- [Generation, tool calling, and KV cache management in Swift](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/references/02-generation-tools-and-caching.md)
- [MLXFoundationModels and MLXGuidedGeneration: backing `LanguageModelSession` with an MLX model](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md)

**[Part 14 — Bridges between stacks](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-14-bridges-between-stacks/README.md)**
- [Bridges into Core AI: `mlx2coreai`, `swift-lm`, and the community zoo](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md)

**[Part 15 — Shipping and operating on device](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/README.md)**
- [Shipping models: Background Assets, per-architecture variants, and updates](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md)
- [Memory, jetsam, thermals, energy, and measuring honestly](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md)

**[Part 16 — Adjacent capabilities](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/README.md)**
- [SpeechAnalyzer: live transcription, assets, and custom vocabulary](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md)
- [App Schema Domains: the complete map of what Siri can actually do](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/02-app-schema-domains.md)
- [On-screen awareness: making Siri understand "this"](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/03-onscreen-awareness.md)
- [One index, three consumers: entities, Spotlight, and Foundation Models](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md)
- [DNIKit: auditing datasets and networks before you convert](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md)

**[Part 17 — Migration from pre-iOS 27](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md)**
- [What changed between iOS 26 and iOS 27: the complete checklist](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md)
- [The adapter sunset: migrating off custom LoRA adapters](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md)
- [Error taxonomy migration: `GenerationError` → `LanguageModelError`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md)
- [Building for two SDKs: conditional compilation across 26 and 27](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md)
- [Core ML to Core AI: what moves, what stays, and how](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md)
- [Toolchain and asset compatibility: when your build artifacts stop working](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md)

---

## Editorial conventions

These are load-bearing. A large fraction of the source material for this series is **beta-era**,
and a meaningful fraction of the API spellings in circulation are reconstructions from *spoken*
WWDC narration rather than anything anyone has seen in writing. The conventions below exist so you
always know which is which.

### Evidence markers

Every non-obvious API claim carries one of these:

> ✅ **VERIFIED** — quoted from a header, SDK, shipping source file, or Apple documentation page.
> The citation follows the claim.

> 🟡 **RECONSTRUCTED** — the concept is attested (usually from a WWDC session), but the exact
> spelling is inferred. Treat the shape as right and the identifiers as provisional.

> 🟠 **Suggestive, \<date\>** — measured, but not on the target configuration: a dated probe run
> on the simulator or partial hardware (cited by `probes/` probe ID), or a community measurement
> (spelled **COMMUNITY-MEASURED**). Directional evidence only; each box names the clean
> MAC-27/DEVICE-27 pass that would promote or retire it.

> 🔴 **GAP** — we could not verify this and are telling you so rather than inventing it. The
> callout names exactly what is unknown and what it would take to resolve.

A `🔴 GAP` box never contains a guess. If a guide needs `fm --help` output and nobody has run
`fm` on macOS 27, the guide says that.

### Silent-failure callouts

> ⚠️ **SILENT FAILURE** — the defining property of this stack is that most defects *do not throw*.

Every guide carries at least one of these where applicable. Known examples, so you know what
kind of thing to expect: a `@Guide(.anyOf:)` that doesn't constrain; `AIProgram.optimize()`
deleting broadcasting-significant axis moves; fused SDPA falling back without a warning;
`reduce_rows` defaulting its identity to zero regardless of the reduction operation; a tool named
in your instructions but absent from the toolset, producing an infinite loop and no error.

### Version floor

Every guide states its version floor in the first 200 words, and every API is marked with the
earliest OS that has it — **26.0**, **26.2**, **26.4** and **27.0** all matter and are routinely
confused. Version confusion is the single largest source of phantom bug reports in the developer
forums.

### Measurement attribution

Every number is attributed: **Apple-published**, **community-measured**, or **measured by us** —
with hosting mode, hardware/device, OS and runtime build, Xcode build, destination, build
configuration, exceptions, and date. A community benchmark is never presented as an Apple figure.
Where community numbers complicate Apple's claims, both are given. Never carry a measured default
between tool-hosted, app-hosted, and device-hosted processes merely because the runtime build
matches; `contextSize` has already disproved that shortcut.

### Defect state and resolution

Repository state is mechanical evidence, not a resolution claim. Write “PR merged” or “issue
closed” separately from the semantic disposition: `fixed`, `fixed-with-residual`,
`merged-unreleased`, `closed-unfixed`, `closed-unmerged`, `superseded`, `consolidated`, or
`unknown`. A closure without code or maintainer evidence is never described as fixed. Use
`unknown` when the evidence does not establish what happened, and retain the workaround or hazard
until a dated target-specific verification retires it.

### Known-bad claims

There is material circulating about this stack that is simply fabricated — invented file
extensions (`.coreaimodel`, `.aiasset`), a `coreai-torch convert` CLI that does not exist, "iOS 20
/ macOS 17", and an on-device LoRA training API that was never shipped. Part 1 carries a
known-bad-claims reference so these don't get reintroduced by a well-meaning reader or coding
agent.

### Precedence when sources conflict

1. Headers and SDK sources you can read on disk
2. Apple documentation pages
3. Apple-staff answers on the Developer Forums
4. WWDC session transcripts
5. Community repositories and blog posts

Several WWDC transcript claims are already superseded — custom adapters, PCC eligibility, the
model-tier split. Where a forum answer from Apple staff conflicts with a session, the forum wins,
and the guide says so.

---

## Known gaps, and what would close them

The series ships **~470 `🔴 GAP` callouts** — roughly 664 lines carry a `🔴` gap marker of some
form. That number is a feature, not a defect: a `🔴 GAP` box is a *refusal to guess*. It names the
exact thing that is unknown, why it could not be verified from the corpus, and what it would take
to resolve — a header to read, a command to run, a device to test on. Nothing inside one is
invented, and no gap has been quietly papered over with a plausible-looking identifier.

The single largest cluster has one cause: **this series was written on macOS 26.5.2 / Xcode 26.6.**
Some questions require a macOS 27 runtime (`fm --help`, Instruments 27 lane names); others require
the Xcode 27 SDK or one of its separately installed components. The `CoreAI` and
`FoundationModels` interfaces were captured from Xcode 27.0 beta on 2026-07-29. `coreai-build` was
captured on the same host on 2026-07-31 after installing the optional **Metal Toolchain component**
with `xcodebuild -downloadComponent MetalToolchain`; it is not part of the Xcode app bundle and
does not require upgrading the host OS merely to inspect its CLI. The affected guides carry dated
resolution notes and the capture lives at `notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`.

[`../notes/NEEDED-FROM-A-MACOS-27-MACHINE.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/NEEDED-FROM-A-MACOS-27-MACHINE.md) is the
precise shopping list: seven independent items, each with the literal commands to run and the guides
they would close. If you have a macOS 27 / Xcode 27 machine, working through that file is the
highest-leverage contribution available to this series.

---

## Verification and series status

**17-part published corpus, scope-audited as of 2026-07-28; SDK-verification pass 2026-07-29.**
All 77 guides exist (17 part READMEs + 60 reference guides), and each contents list is expected
to name only sections present in its file. Declared evidence gaps remain explicit rather than
being counted as unwritten sections.[^series-scope]

On 2026-07-29 the series was verified against the real macOS **26.5 and 27.0-beta SDK Swift
interfaces** (Xcode 27.0 beta `27A5228h`, captured in `notes/sdk-interfaces/` — including the
Core AI SubFrameworks, the `_Vision_FoundationModels` / `_CoreSpotlight_FoundationModels`
cross-import overlays, and Xcode-bundled `Evaluations`), and every GitHub-tracked defect status
was re-checked live. The 2026-07-31 refresh workflow also binds each stable SDK-named artifact to
its Xcode, SDK, and Metal-component identity in a hashed manifest, refuses a
same-SDK/different-Xcode overwrite, and runs ordinary drift checks from a temporary capture. CLI
evidence follows the same rule, including the separately installed
`coreai-build` surface.[^capture-workflow]

---

## Corpus

The research behind this series lives in [`../notes/`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/tree/main/notes) — roughly 90,000 lines across
46 files, indexed at [`../notes/synthesis/RESEARCH-INDEX.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/synthesis/RESEARCH-INDEX.md).
Primary sources: 16 WWDC26 / Meet-with-Apple transcripts, 6 Apple documentation articles, 4 Apple
Developer Forums topic captures, 16 pinned repository checkouts, the MetalPerformancePrimitives
headers shipped in the Xcode SDK, and a crawl of the MLX documentation site.[^repository-snapshots]

[^series-scope]: The inventory in [Every guide in the series](#every-guide-in-the-series) links
    every part and reference. The intentionally shorter MLX
    references declare their terminal sections in [Part 12](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/README.md#reading-order-and-what-you-can-defer).
    Apple's [TN3193](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window)
    specifies the on-device model's 4,096-token context window.
[^repository-snapshots]: The reproducibility manifest in
    [`scripts/clone-research-repos.sh`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/scripts/clone-research-repos.sh) records the 16 repositories
    and exact full commit SHA for each checkout.
[^capture-workflow]: [`scripts/dump-sdk-interfaces.sh`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/scripts/dump-sdk-interfaces.sh) owns the
    managed capture and `capture-manifest.json`; [`scripts/diff-interfaces.sh`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/scripts/diff-interfaces.sh)
    performs read-only temporary drift captures. The operational steps live in
    [`notes/NEXT-BETA-CHECKLIST.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/NEXT-BETA-CHECKLIST.md) and
    [`notes/FRESHNESS-RUNBOOK.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/FRESHNESS-RUNBOOK.md). Apple's
    [Core AI AOT documentation](https://developer.apple.com/documentation/coreai/compiling-core-ai-models-ahead-of-time)
    is the primary source for installing the Metal Toolchain component before capturing
    `coreai-build`.
