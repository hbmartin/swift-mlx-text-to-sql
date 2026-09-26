# Section maps for the deep reference guides

The deep guides are bundled with this skill. Each entry links the local file, then lists every **top-level** (`##`) section as an anchor; a guide's own `## Contents` lists its subsections. Open the narrowest relevant section first.

> Generated 2026-09-22 from the guide headings. Regenerate with `./scripts/build-skills.sh` rather than editing by hand.

## Part 12 — MLX in Python

### 12.1 — MLX fundamentals: unified memory, lazy evaluation, transforms, and `compile`

The conceptual primer the other five assume, built on five ideas: unified memory (you never move arrays, you choose per-op *which device runs it*), lazy evaluation, the composable function transforms (`grad`, `vjp`, `jvp`, `vmap`, `checkpoint`, `custom_function`, `compile` — each returns something the others can transform again), what `mx.compile` fuses and what makes it recompile, and `nn.Module` as a plain parameter tree that is a `dict` subclass, not a PyTorch module respelled.

**Local reference:** [part-12-mlx-python/references/01-core-fundamentals.md](part-12-mlx-python/references/01-core-fundamentals.md)

| Section | Anchor |
|---|---|
| Version floor | `#version-floor` |
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| ⚠️ Read this before you trust a signature below | `#️-read-this-before-you-trust-a-signature-below` |
| Contents | `#contents` |
| 0. Orientation: five ideas, one page | `#0-orientation-five-ideas-one-page` |
| 1. Unified memory: the defining design decision | `#1-unified-memory-the-defining-design-decision` |
| 2. Lazy evaluation: nothing computes until you force it | `#2-lazy-evaluation-nothing-computes-until-you-force-it` |
| 3. When to evaluate — and the two ways to get it wrong | `#3-when-to-evaluate--and-the-two-ways-to-get-it-wrong` |
| 4. Function transforms | `#4-function-transforms` |
| 5. `custom_function`: teaching MLX your own derivative | `#5-custom_function-teaching-mlx-your-own-derivative` |
| 6. `mx.compile`: what it actually does | `#6-mxcompile-what-it-actually-does` |
| 7. Capturing state: `inputs=` and `outputs=` | `#7-capturing-state-inputs-and-outputs` |
| 8. What causes recompilation — the verified cache key | `#8-what-causes-recompilation--the-verified-cache-key` |
| 9. Shapeless compilation and its constraints | `#9-shapeless-compilation-and-its-constraints` |
| 10. Streams and devices | `#10-streams-and-devices` |
| 11. `nn.Module`: parameters as a tree | `#11-nnmodule-parameters-as-a-tree` |
| 12. Saving, loading, exporting, and interop | `#12-saving-loading-exporting-and-interop` |

### 12.2 — Numerics, hardware gating, and writing custom Metal kernels from Python

Where MLX stops being a portable array library and becomes a program on one specific piece of Apple silicon.

**Local reference:** [part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| ⚠️ Read this before you trust a signature below | `#️-read-this-before-you-trust-a-signature-below` |
| Contents | `#contents` |
| 0. Orientation: the three questions | `#0-orientation-the-three-questions` |
| 1. The numeric types | `#1-the-numeric-types` |
| 2. Choosing a dtype in practice | `#2-choosing-a-dtype-in-practice` |
| 3. TF32 and the hardware gate — one feature, two halves | `#3-tf32-and-the-hardware-gate--one-feature-two-halves` |
| 4. NAX, the M5 neural accelerator, and how to tell whether you are on the fast path | `#4-nax-the-m5-neural-accelerator-and-how-to-tell-whether-you-are-on-the-fast-path` |
| 5. ⚠️ The silent SDPA fallback | `#5-️-the-silent-sdpa-fallback` |
| 6. The rest of `mx.fast`, and why fused beats hand-composed | `#6-the-rest-of-mxfast-and-why-fused-beats-hand-composed` |
| 7. `mx.fast.metal_kernel`: the complete API | `#7-mxfastmetal_kernel-the-complete-api` |
| 8. A complete worked example | `#8-a-complete-worked-example` |
| 9. The advanced options | `#9-the-advanced-options` |

### 12.3 — MLX quantization: modes, group sizes, gates, and the corruption bugs

Quantization in MLX is four things wearing one name: a numeric format (affine at 2/3/4/5/6/8 bits, or `mxfp4`/`mxfp8`/`nvfp4`), a memory layout (**three arrays** — packed `uint32` weights, scales, and for affine a biases array), a kernel-dispatch problem (`K % 64 == 0`, `transpose=True`, a gather tile constant of `BK = 64`), and a calibration procedure.

**Local reference:** [part-12-mlx-python/references/03-quantization.md](part-12-mlx-python/references/03-quantization.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| ⚠️ Read this before you trust a number below | `#️-read-this-before-you-trust-a-number-below` |
| Contents | `#contents` |
| 1. The mental model: quantization is three arrays | `#1-the-mental-model-quantization-is-three-arrays` |
| 2. The mode inventory | `#2-the-mode-inventory` |
| 3. Sizing: what bits and group size actually cost | `#3-sizing-what-bits-and-group-size-actually-cost` |
| 4. The array API | `#4-the-array-api` |
| 5. The module API: `nn.quantize` and friends | `#5-the-module-api-nnquantize-and-friends` |
| 6. The gates: what decides whether you get the fast kernel | `#6-the-gates-what-decides-whether-you-get-the-fast-kernel` |
| 7. `gather_qmm`, MoE, and why routed-only reads matter | `#7-gather_qmm-moe-and-why-routed-only-reads-matter` |
| 8. Learned quantization: AWQ, GPTQ, DWQ, dynamic | `#8-learned-quantization-awq-gptq-dwq-dynamic` |
| 9. ⚠️ The corruption bugs | `#9-️-the-corruption-bugs` |
| 10. The verification recipe | `#10-the-verification-recipe` |
| 11. KV-cache quantization is a different thing | `#11-kv-cache-quantization-is-a-different-thing` |
| 12. Selection table: what to pick | `#12-selection-table-what-to-pick` |
| 13. Declared gaps | `#13-declared-gaps` |
| 14. Sources | `#14-sources` |

### 12.4 — mlx-lm: the CLI surface, the generation API, and KV caching

The layer where MLX becomes an LLM runtime: **18 command-line entry points** enumerated from `setup.py`; the Python generation API (`load`, `generate`, `stream_generate`, and the `generate_step` generator underneath, with how samplers and logits processors compose and where their defaults disagree); and the deepest treatment in this part — **nine concrete KV-cache classes**, the trimmability contract everything else rests on, prompt caching to disk, quantized KV (which can *increase* peak memory), speculative decoding and continuous batching.

**Local reference:** [part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| ⚠️ Read this before you trust a flag name below | `#️-read-this-before-you-trust-a-flag-name-below` |
| Contents | `#contents` |
| 1. Where mlx-lm sits | `#1-where-mlx-lm-sits` |
| 2. The CLI surface | `#2-the-cli-surface` |
| 3. The Python generation API | `#3-the-python-generation-api` |
| 4. KV caching: the nine cache classes | `#4-kv-caching-the-nine-cache-classes` |
| 5. Prompt caching to disk | `#5-prompt-caching-to-disk` |
| 6. Quantized KV: capacity, not throughput | `#6-quantized-kv-capacity-not-throughput` |
| 7. Speculative decoding | `#7-speculative-decoding` |
| 8. Batch generation and continuous batching | `#8-batch-generation-and-continuous-batching` |
| 9. The silent-failure register | `#9-the-silent-failure-register` |
| 10. Decision tables, cross-links, and the gap register | `#10-decision-tables-cross-links-and-the-gap-register` |
| Sources | `#sources` |

### 12.5 — `mlx_lm.server`, local agents, and distributed inference over Thunderbolt

Two halves.

**Local reference:** [part-12-mlx-python/references/05-serving-and-distributed.md](part-12-mlx-python/references/05-serving-and-distributed.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| ⚠️ Read this before you trust a signature below | `#️-read-this-before-you-trust-a-signature-below` |
| Contents | `#contents` |
| 1. The four-layer local agent stack | `#1-the-four-layer-local-agent-stack` |
| 2. Launching the server: every flag | `#2-launching-the-server-every-flag` |
| 3. The endpoints | `#3-the-endpoints` |
| 4. The request body | `#4-the-request-body` |
| 5. The response body | `#5-the-response-body` |
| 6. Structured tool calling | `#6-structured-tool-calling` |
| 7. Reasoning models | `#7-reasoning-models` |
| 8. Continuous batching — the feature that makes subagents work | `#8-continuous-batching--the-feature-that-makes-subagents-work` |
| 9. The prompt cache, and what `cached_tokens` is telling you | `#9-the-prompt-cache-and-what-cached_tokens-is-telling-you` |
| 10. Why prompt processing dominates agentic work | `#10-why-prompt-processing-dominates-agentic-work` |
| 11. Pointing agents at it | `#11-pointing-agents-at-it` |
| 12. Load testing and capacity planning | `#12-load-testing-and-capacity-planning` |
| 13. Operational reality: the open server defects | `#13-operational-reality-the-open-server-defects` |
| 14. The four-layer distributed stack | `#14-the-four-layer-distributed-stack` |
| 15. Topology: mesh is strictly better than ring | `#15-topology-mesh-is-strictly-better-than-ring` |
| 16. Turning RDMA on — the setup sequence | `#16-turning-rdma-on--the-setup-sequence` |
| 17. The hostfile | `#17-the-hostfile` |
| 18. `mlx.distributed_config` | `#18-mlxdistributed_config` |
| 19. `mlx.launch` | `#19-mlxlaunch` |
| 20. Running the server across machines | `#20-running-the-server-across-machines` |
| 21. Tensor vs pipeline parallelism | `#21-tensor-vs-pipeline-parallelism` |
| 22. Distributed fine-tuning, and the `--batch-size` trap | `#22-distributed-fine-tuning-and-the---batch-size-trap` |
| 23. Getting the weights onto the nodes: `mlx_lm.share` | `#23-getting-the-weights-onto-the-nodes-mlx_lmshare` |
| 24. Apple's measured numbers | `#24-apples-measured-numbers` |
| 25. The distributed bug cluster | `#25-the-distributed-bug-cluster` |
| 26. Running without `mlx.launch` | `#26-running-without-mlxlaunch` |

### 12.6 — LoRA and DoRA fine-tuning, and adding a new architecture

Opens with the frame (§0): **custom Foundation Models adapters are discontinued in OS 27**, per two independent Apple-staff forum statements, with the Adapter Training Toolkit stopping at 26.0.0 — which leaves MLX's LoRA/DoRA as the surviving adaptation path.

**Local reference:** [part-12-mlx-python/references/06-finetuning-and-porting-models.md](part-12-mlx-python/references/06-finetuning-and-porting-models.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Evidence ladder used in this guide | `#evidence-ladder-used-in-this-guide` |
| Contents | `#contents` |
| 0. The frame: custom adapters are gone in OS 27 | `#0-the-frame-custom-adapters-are-gone-in-os-27` |
| 1. Install and the version matrix | `#1-install-and-the-version-matrix` |
| 2. The data format, all four of it | `#2-the-data-format-all-four-of-it` |
| 3. The complete flag surface of `mlx_lm.lora` | `#3-the-complete-flag-surface-of-mlx_lmlora` |
| 4. What LoRA, DoRA and `full` actually compute | `#4-what-lora-dora-and-full-actually-compute` |
| 5. QLoRA: training against a quantized base | `#5-qlora-training-against-a-quantized-base` |
| 6. Rank, scale, and target modules | `#6-rank-scale-and-target-modules` |
| 7. Learning rate, schedules and optimizers | `#7-learning-rate-schedules-and-optimizers` |
| 8. Memory is the binding constraint | `#8-memory-is-the-binding-constraint` |
| 9. Checkpointing, resuming, and what lands on disk | `#9-checkpointing-resuming-and-what-lands-on-disk` |
| 10. Evaluating the result | `#10-evaluating-the-result` |
| 11. `mlx_lm.fuse`, and what it costs you | `#11-mlx_lmfuse-and-what-it-costs-you` |
| 12. The complete worked run | `#12-the-complete-worked-run` |
| 13. Beyond `mlx_lm.lora`: the third-party training layer | `#13-beyond-mlx_lmlora-the-third-party-training-layer` |

## Part 13 — MLX in Swift

### 13.1 — `mlx-swift-lm` in an app: setup, concurrency, memory, and media input

The "make it survive contact with an iPhone" guide, in the order things hurt: the 3.x break and the nine products; the **three integration styles** for tokenizers and downloaders (implement the protocols, use an integration package, or use the `MLXHuggingFace` macros) with a decision in §3.5; `ModelContainer`/`ModelContext`, download progress and exactly where weights land; concurrency — why `ModelContainer` is *not* an actor, why `MLXArray` is not `Sendable`, what `SendableBox` is for; **memory**, the longest section and the one that decides whether you ship; VLM media input; and building against both the 26 and 27 SDKs.

**Local reference:** [part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Evidence base | `#evidence-base` |
| Contents | `#contents` |
| 1. The 3.x version warning, in full | `#1-the-3x-version-warning-in-full` |
| 2. The package: nine products, what each is for | `#2-the-package-nine-products-what-each-is-for` |
| 3. The three integration styles | `#3-the-three-integration-styles` |
| 4. Model loading: containers, contexts, downloads, disk | `#4-model-loading-containers-contexts-downloads-disk` |
| 5. Concurrency: what runs where, and what is Sendable | `#5-concurrency-what-runs-where-and-what-is-sendable` |
| 6. Memory: the section that decides whether you ship | `#6-memory-the-section-that-decides-whether-you-ship` |
| 7. Media input for VLMs | `#7-media-input-for-vlms` |
| 8. SwiftUI patterns: streaming, cancellation, progress | `#8-swiftui-patterns-streaming-cancellation-progress` |
| 9. SDK compatibility: macOS 26 and 27 in one build | `#9-sdk-compatibility-macos-26-and-27-in-one-build` |
| 10. Failure catalogue and pre-ship checklist | `#10-failure-catalogue-and-pre-ship-checklist` |
| 11. Sources | `#11-sources` |

### 13.2 — Generation, tool calling, and KV cache management in Swift

Deliberately structured to mirror [Part 12 guide 04](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md) so you can move between the languages, naming the Python spelling wherever one corresponds — and calling out every place it doesn't, because each of those divergences has produced a real bug.

**Local reference:** [part-13-mlx-swift/references/02-generation-tools-and-caching.md](part-13-mlx-swift/references/02-generation-tools-and-caching.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| ⚠️ Read this before you trust a signature below | `#️-read-this-before-you-trust-a-signature-below` |
| Contents | `#contents` |
| 1. Where the Swift stack sits | `#1-where-the-swift-stack-sits` |
| 2. The generation API surface | `#2-the-generation-api-surface` |
| 3. `GenerateParameters`, samplers, and logit processors | `#3-generateparameters-samplers-and-logit-processors` |
| 4. `TokenIterator`: the thing all of it sits on | `#4-tokeniterator-the-thing-all-of-it-sits-on` |
| 5. Input types | `#5-input-types` |
| 6. Tokenizers and chat templates | `#6-tokenizers-and-chat-templates` |
| 7. Tool calling: ten formats and why | `#7-tool-calling-ten-formats-and-why` |
| 8. KV cache: eight types, one contract | `#8-kv-cache-eight-types-one-contract` |
| 9. Two real Swift-side cache bugs | `#9-two-real-swift-side-cache-bugs` |
| 10. `MLXEmbedders` | `#10-mlxembedders` |
| 11. Decision tables, silent-failure register, gap register | `#11-decision-tables-silent-failure-register-gap-register` |

### 13.3 — `MLXFoundationModels` and `MLXGuidedGeneration`: backing `LanguageModelSession` with an MLX model

Opens by answering the question a developer asked on forum thread **836264** after seeing `import MLXFoundationModels` on a WWDC26 session-339 slide: it is a library target in the package, not an SDK framework, and it needs the 27.0 SDK.

**Local reference:** [part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md)

| Section | Anchor |
|---|---|
| Where is `MLXFoundationModels`? (Answer first.) | `#where-is-mlxfoundationmodels-answer-first` |
| Version floor | `#version-floor` |
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1 · The two gates, and the four-cell matrix | `#1--the-two-gates-and-the-four-cell-matrix` |
| 2 · What the adapter is, in one diagram | `#2--what-the-adapter-is-in-one-diagram` |
| 3 · Package setup, complete | `#3--package-setup-complete` |
| 4 · Construction path A: the `#huggingFaceLanguageModel` macro | `#4--construction-path-a-the-huggingfacelanguagemodel-macro` |
| 5 · Construction path B: the direct initializer | `#5--construction-path-b-the-direct-initializer` |
| 6 · Capabilities: four cases, all load-bearing | `#6--capabilities-four-cases-all-load-bearing` |
| 7 · Availability, preload, prewarm, eviction | `#7--availability-preload-prewarm-eviction` |
| 8 · Walking the implementation | `#8--walking-the-implementation` |
| 9 · `MLXGuidedGeneration`: from JSON Schema to token mask | `#9--mlxguidedgeneration-from-json-schema-to-token-mask` |
| 10 · The convergent design: two teams, one xgrammar | `#10--the-convergent-design-two-teams-one-xgrammar` |
| 11 · The constraint: guided generation needs logits | `#11--the-constraint-guided-generation-needs-logits` |
| 12 · Failure modes, including six silent ones | `#12--failure-modes-including-six-silent-ones` |
| 13 · The 27-beta SDK-drift log | `#13--the-27-beta-sdk-drift-log` |
| 14 · Gaps, and what would close them | `#14--gaps-and-what-would-close-them` |
| 15 · Source inventory | `#15--source-inventory` |
| Where to go next | `#where-to-go-next` |

## Part 14 — Bridges between stacks

### 14.1 — Bridges into Core AI: `mlx2coreai`, `swift-lm`, and the community zoo

Three bridges, one destination.

**Local reference:** [part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md)

| Section | Anchor |
|---|---|
| ⚠️ Read this before you trust a signature in this guide | `#️-read-this-before-you-trust-a-signature-in-this-guide` |
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. Three bridges, one destination | `#1-three-bridges-one-destination` |
| 2. `mlx2coreai`: what it is and what it pins | `#2-mlx2coreai-what-it-is-and-what-it-pins` |
| 3. The stateful LLM path | `#3-the-stateful-llm-path` |
| 4. The bundle layout is the interchange format | `#4-the-bundle-layout-is-the-interchange-format` |
| 5. The generic path, and the pipeline by module name | `#5-the-generic-path-and-the-pipeline-by-module-name` |
| 6. ⚠️ Asset-generation coverage is not numerical parity | `#6-️-asset-generation-coverage-is-not-numerical-parity` |
| 7. The specific numeric hazards to test for | `#7-the-specific-numeric-hazards-to-test-for` |
| 8. The Swift runner, and what "Python bindings are incomplete" means | `#8-the-swift-runner-and-what-python-bindings-are-incomplete-means` |
| 9. `swift-lm`: a real third-party Core AI integration | `#9-swift-lm-a-real-third-party-core-ai-integration` |
| 10. `expectFrequentReshapes`: four sources, three verdicts | `#10-expectfrequentreshapes-four-sources-three-verdicts` |
| 11. The community zoo | `#11-the-community-zoo` |
| 12. Decision table: which bridge, and when to re-author instead | `#12-decision-table-which-bridge-and-when-to-re-author-instead` |
| 13. Quick reference | `#13-quick-reference` |
| 14. Sources and evidence ledger | `#14-sources-and-evidence-ledger` |
