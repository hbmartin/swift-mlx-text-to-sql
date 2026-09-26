# Section maps for the deep reference guides

The deep guides are bundled with this skill. Each entry links the local file, then lists every **top-level** (`##`) section as an anchor; a guide's own `## Contents` lists its subsections. Open the narrowest relevant section first.

> Generated 2026-09-22 from the guide headings. Regenerate with `./scripts/build-skills.sh` rather than editing by hand.

## Part 7 — Core AI: the Swift runtime

### 7.1 — `AIModel`, `InferenceFunction`, `NDArray`, and the memory model

The object-model primer every other guide assumes, built around the structural fact that makes app architecture fall out: **`AIModel` owns nothing and pins a cache entry; `InferenceFunction` owns the weights**, so "when does this cost me a gigabyte?" is answered *at `loadFunction`, not at `init`*.

**Local reference:** [part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| ⚠️ Read this before you trust a single signature below | `#️-read-this-before-you-trust-a-single-signature-below` |
| Contents | `#contents` |
| 0. Orientation: the pipeline, the file, the toolchain | `#0-orientation-the-pipeline-the-file-the-toolchain` |
| 1. The five types, and what each one owns | `#1-the-five-types-and-what-each-one-owns` |
| 2. `.aimodel` is a portable *source* representation | `#2-aimodel-is-a-portable-source-representation` |
| 3. `AIModel`: why the initializer is `async` | `#3-aimodel-why-the-initializer-is-async` |
| 4. `loadFunction` vs `functionDescriptor`: `nil` and `throws` mean different things | `#4-loadfunction-vs-functiondescriptor-nil-and-throws-mean-different-things` |
| 5. `InferenceFunction` is `Sendable` — and what that costs | `#5-inferencefunction-is-sendable--and-what-that-costs` |
| 6. Runtime introspection: descriptors all the way down | `#6-runtime-introspection-descriptors-all-the-way-down` |
| 7. `NDArray` and non-escapable types | `#7-ndarray-and-non-escapable-types` |
| 8. Writing inputs | `#8-writing-inputs` |
| 9. Reading outputs: `InferenceValue` and the take-once bag | `#9-reading-outputs-inferencevalue-and-the-take-once-bag` |
| 10. States and pre-allocated outputs: `MutableViews` | `#10-states-and-pre-allocated-outputs-mutableviews` |
| 11. The three low-level performance APIs | `#11-the-three-low-level-performance-apis` |
| 12. Image-typed values, and whose problem orientation is | `#12-image-typed-values-and-whose-problem-orientation-is` |
| 13. ✅ The error-type answer, and how to write a `catch` block | `#13--the-error-type-answer-and-how-to-write-a-catch-block` |
| 14. A complete runner you can paste | `#14-a-complete-runner-you-can-paste` |
| 15. Quick reference | `#15-quick-reference` |
| 16. Sources and evidence ledger | `#16-sources-and-evidence-ledger` |

### 7.2 — Specialization, the model cache, and ahead-of-time compilation

The single largest source of first-launch stalls, wedged loads and mysterious disk growth.

**Local reference:** [part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. What specialization actually is | `#1-what-specialization-actually-is` |
| 2. The default path, and exactly where it stalls | `#2-the-default-path-and-exactly-where-it-stalls` |
| 3. The cache, and the gating primitive | `#3-the-cache-and-the-gating-primitive` |
| 4. The cache key, and how to double your disk usage by accident | `#4-the-cache-key-and-how-to-double-your-disk-usage-by-accident` |
| 5. `AIModel.specialize` — controlling *when*, not *how much* | `#5-aimodelspecialize--controlling-when-not-how-much` |
| 6. Cache policy and purge conditions | `#6-cache-policy-and-purge-conditions` |
| 7. Deleting entries — and Apple's contradiction | `#7-deleting-entries--and-apples-contradiction` |
| 8. Sharing a cache across an app group | `#8-sharing-a-cache-across-an-app-group` |
| 9. Bookmarks: deleting the source and keeping the model | `#9-bookmarks-deleting-the-source-and-keeping-the-model` |
| 10. `SpecializationOptions` in practice | `#10-specializationoptions-in-practice` |
| 11. `expectFrequentReshapes`: the flag nobody documented | `#11-expectfrequentreshapes-the-flag-nobody-documented` |
| 12. Dynamic shapes re-specialize — bucket them | `#12-dynamic-shapes-re-specialize--bucket-them` |
| 13. Ahead-of-time compilation with `coreai-build` | `#13-ahead-of-time-compilation-with-coreai-build` |
| 14. What AOT does not buy you | `#14-what-aot-does-not-buy-you` |
| 15. Xcode integration: Compile Sources and the Metal Toolchain | `#15-xcode-integration-compile-sources-and-the-metal-toolchain` |
| 16. The numbers, attributed | `#16-the-numbers-attributed` |
| 17. A recovery ladder for wedged loads | `#17-a-recovery-ladder-for-wedged-loads` |
| 18. Quick reference | `#18-quick-reference` |
| 19. Sources and evidence ledger | `#19-sources-and-evidence-ledger` |

### 7.3 — States as KV cache, and pipelined execution

A decode loop written the naive way gets slower every step, and in Instruments it is unmistakable: **inference intervals that visibly widen along the timeline**.

**Local reference:** [part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. The symptom: intervals that grow | `#1-the-symptom-intervals-that-grow` |
| 2. What a state is | `#2-what-a-state-is` |
| 3. Authoring: `register_buffer` and in-place mutation | `#3-authoring-register_buffer-and-in-place-mutation` |
| 4. Conversion: `state_names`, and its three traps | `#4-conversion-state_names-and-its-three-traps` |
| 5. Runtime: `MutableViews` and the `states:` argument | `#5-runtime-mutableviews-and-the-states-argument` |
| 6. The fixed max-context tradeoff | `#6-the-fixed-max-context-tradeoff` |
| 7. A real signature: the LLM state contract | `#7-a-real-signature-the-llm-state-contract` |
| 8. Four silent failures around states | `#8-four-silent-failures-around-states` |
| 9. Pre-allocated outputs: the `outputViews:` argument | `#9-pre-allocated-outputs-the-outputviews-argument` |
| 10. Pipelined execution: `encode`, `ComputeStream`, async values | `#10-pipelined-execution-encode-computestream-async-values` |
| 11. A real pipelined decode loop | `#11-a-real-pipelined-decode-loop` |
| 12. What pipelining is actually worth | `#12-what-pipelining-is-actually-worth` |
| 13. The MPSGraph in-graph KV-write bug | `#13-the-mpsgraph-in-graph-kv-write-bug` |
| 14. Prefix reuse: one integer assignment, ~101× | `#14-prefix-reuse-one-integer-assignment-101` |
| 15. Diagnosing states in Instruments | `#15-diagnosing-states-in-instruments` |
| 16. Quick reference | `#16-quick-reference` |
| 17. Sources and evidence ledger | `#17-sources-and-evidence-ledger` |

### 7.4 — Model bundles, the LLM engines, and grammar-constrained decoding

The layer above the runtime, where a raw `.aimodel` becomes something shippable and Apple's own Swift package turns "I have a converted Qwen3" into `LanguageModelSession(model:)`.

**Local reference:** [part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. Why a `.aimodel` is not a model | `#1-why-a-aimodel-is-not-a-model` |
| 2. The bundle format, definitively | `#2-the-bundle-format-definitively` |
| 3. The Swift package: five products, three dependencies | `#3-the-swift-package-five-products-three-dependencies` |
| 4. Loading: `CoreAIRunner`, `PreparedModel`, `ModelResources` | `#4-loading-coreairunner-preparedmodel-modelresources` |
| 5. The engines | `#5-the-engines` |
| 6. KV cache strategy and prefix reuse | `#6-kv-cache-strategy-and-prefix-reuse` |
| 7. Grammar-constrained decoding | `#7-grammar-constrained-decoding` |
| 8. Plugging into Foundation Models | `#8-plugging-into-foundation-models` |
| 9. Bring your own sampling | `#9-bring-your-own-sampling` |
| 10. Quick reference | `#10-quick-reference` |
| 11. Sources and evidence ledger | `#11-sources-and-evidence-ledger` |

### 7.5 — Non-LLM engines: bundles, function structure, warmup, specialization, and caching

The runtime owner for `CoreAISegmentation`, `CoreAIObjectDetection`, and `CoreAIDiffusion`.

**Local reference:** [part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md)

| Section | Anchor |
|---|---|
| Contents | `#contents` |
| 1. One repository, three runtime shapes | `#1-one-repository-three-runtime-shapes` |
| 2. Bundle directory, model asset, and function map | `#2-bundle-directory-model-asset-and-function-map` |
| 3. `PreparedModel`: inspect before specializing | `#3-preparedmodel-inspect-before-specializing` |
| 4. Segmentation: one function or a three-function graph | `#4-segmentation-one-function-or-a-three-function-graph` |
| 5. Object detection: one raw asset, one real warmup | `#5-object-detection-one-raw-asset-one-real-warmup` |
| 6. Diffusion: a bundle of independently owned models | `#6-diffusion-a-bundle-of-independently-owned-models` |
| 7. Warmup is not one operation | `#7-warmup-is-not-one-operation` |
| 8. Specialization and caching, layer by layer | `#8-specialization-and-caching-layer-by-layer` |
| 9. Choosing a function and bundle structure | `#9-choosing-a-function-and-bundle-structure` |
| 10. Production checklist | `#10-production-checklist` |
| 11. Gaps and device tests still required | `#11-gaps-and-device-tests-still-required` |
| 12. Sources and evidence ledger | `#12-sources-and-evidence-ledger` |

## Part 8 — Core AI: converting a model from PyTorch

### 8.1 — `torch.export` to `.aimodel`, and the IO / state / dynamic-shape contract

The pipeline end to end as a series of contracts rather than a recipe: the decomposition table and exactly which twelve ops it preserves (Apple's README says three — a subset); the two input forms and why only `add_pytorch_module` can externalize; `to_coreai()` as pure conversion versus `optimize()` as where the passes run; the IO contract as your caller's API; `dynamic_shapes` and the SymInt sharp edges; state; the multi-function split; and the Python-side verification gate that catches everything above for free.

**Local reference:** [part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. The five lines, and what each one is for | `#1-the-five-lines-and-what-each-one-is-for` |
| 2. Install, versions, and the 0.4.0 artifact gate | `#2-install-versions-and-the-040-artifact-gate` |
| 3. `torch.export` — the part that is not Apple's | `#3-torchexport--the-part-that-is-not-apples` |
| 4. `run_decompositions(get_decomp_table())` — the most consequential line | `#4-run_decompositionsget_decomp_table--the-most-consequential-line` |
| 5. Two input forms: `add_exported_program` vs `add_pytorch_module` | `#5-two-input-forms-add_exported_program-vs-add_pytorch_module` |
| 6. `to_coreai()` and `optimize()` | `#6-to_coreai-and-optimize` |
| 7. The IO contract: names are your caller's API | `#7-the-io-contract-names-are-your-callers-api` |
| 8. Dynamic shapes: keeping the traced length out of the asset | `#8-dynamic-shapes-keeping-the-traced-length-out-of-the-asset` |
| 9. State: mutable buffers become Core AI states | `#9-state-mutable-buffers-become-core-ai-states` |
| 10. Multi-function assets, and the finding that reframes them | `#10-multi-function-assets-and-the-finding-that-reframes-them` |
| 11. Verifying from Python: the gate you must not skip | `#11-verifying-from-python-the-gate-you-must-not-skip` |
| 12. Locations, module stacks, and the Debugger | `#12-locations-module-stacks-and-the-debugger` |
| 13. Failure taxonomy and quick reference | `#13-failure-taxonomy-and-quick-reference` |
| 14. Sources and evidence ledger | `#14-sources-and-evidence-ledger` |

### 8.2 — When an op will not convert: coverage, composite ops, custom lowerings, externalization

The debugging guide for conversion failures — and, more usefully, for **conversions that succeed and should not have**.

**Local reference:** [part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. Four ways a conversion fails | `#1-four-ways-a-conversion-fails` |
| 2. The coverage table and the overload rule | `#2-the-coverage-table-and-the-overload-rule` |
| 3. The validator errors, and the third one that is not from the validator | `#3-the-validator-errors-and-the-third-one-that-is-not-from-the-validator` |
| 4. Diagnosing an overload mismatch | `#4-diagnosing-an-overload-mismatch` |
| 5. Composite ops: a library you author models from | `#5-composite-ops-a-library-you-author-models-from` |
| 6. The unadvertised capability: first-class MoE and SSM | `#6-the-unadvertised-capability-first-class-moe-and-ssm` |
| 7. Custom lowerings | `#7-custom-lowerings` |
| 8. Externalization | `#8-externalization` |
| 9. Four live silent-miscompile defects on 0.4.1 | `#9-four-live-silent-miscompile-defects-on-041` |
| 10. The diagnostic checklist | `#10-the-diagnostic-checklist` |
| 11. Quick reference | `#11-quick-reference` |
| 12. Sources and evidence ledger | `#12-sources-and-evidence-ledger` |

### 8.3 — `TorchMetalKernel`: writing and embedding a custom Metal kernel

The seam, not the shader: how a kernel you already know how to write gets into an `.aimodel`.

**Local reference:** [part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. The mechanism: three pieces, one artifact | `#1-the-mechanism-three-pieces-one-artifact` |
| 2. When to do this at all | `#2-when-to-do-this-at-all` |
| 3. The complete worked example: a fused SiLU | `#3-the-complete-worked-example-a-fused-silu` |
| 4. The constructor, field by field | `#4-the-constructor-field-by-field` |
| 5. What the converter generates — and the axis reversal | `#5-what-the-converter-generates--and-the-axis-reversal` |
| 6. `result_shapes`: why every call site | `#6-result_shapes-why-every-call-site` |
| 7. Thread dispatch: grid, threadgroup, and bounds | `#7-thread-dispatch-grid-threadgroup-and-bounds` |
| 8. Registering, converting, running | `#8-registering-converting-running` |
| 9. Scalar inputs: literals in disguise | `#9-scalar-inputs-literals-in-disguise` |
| 10. Dtype templating, the kernel cache, and multiple outputs | `#10-dtype-templating-the-kernel-cache-and-multiple-outputs` |
| 11. `helper_src` and reaching TensorOps | `#11-helper_src-and-reaching-tensorops` |
| 12. The failure taxonomy | `#12-the-failure-taxonomy` |
| 13. Does it pay? Community measurements | `#13-does-it-pay-community-measurements` |
| 14. Testing a kernel, and the de-risk ladder | `#14-testing-a-kernel-and-the-de-risk-ladder` |
| 15. Deployment reality | `#15-deployment-reality` |
| 16. Quick reference | `#16-quick-reference` |
| 17. Sources and evidence ledger | `#17-sources-and-evidence-ledger` |

## Part 9 — Core AI: compression and numeric formats

### 9.1 — `coreai-opt` quantization: configs, GRAPH vs EAGER, calibration and QAT

The foundation guide, and the one everything else assumes.

**Local reference:** [part-09-coreai-compression-numerics/references/01-quantization.md](part-09-coreai-compression-numerics/references/01-quantization.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. Where compression sits, and what it actually costs | `#1-where-compression-sits-and-what-it-actually-costs` |
| 2. The compressor lifecycle: four methods, one contract | `#2-the-compressor-lifecycle-four-methods-one-contract` |
| 3. Presets: the one-liners, and what they expand to | `#3-presets-the-one-liners-and-what-they-expand-to` |
| 4. The config hierarchy: three levels, three tensor groups, and `None` | `#4-the-config-hierarchy-three-levels-three-tensor-groups-and-none` |
| 5. Scoping: regex names, fully-qualified types, `only_for` and `without` | `#5-scoping-regex-names-fully-qualified-types-only_for-and-without` |
| 6. `QuantizationSpec`: every field | `#6-quantizationspec-every-field` |
| 7. Granularity, default axes, and the silent skip | `#7-granularity-default-axes-and-the-silent-skip` |
| 8. GRAPH vs EAGER: a structural split, not a flag | `#8-graph-vs-eager-a-structural-split-not-a-flag` |
| 9. Activation quantization: observers, calibration, shared observers | `#9-activation-quantization-observers-calibration-shared-observers` |
| 10. PTQ: data-free and calibration-based | `#10-ptq-data-free-and-calibration-based` |
| 11. QAT: the schedule, `step()`, and the two conflict rules | `#11-qat-the-schedule-step-and-the-two-conflict-rules` |
| 12. KV-cache quantization (graph mode only) | `#12-kv-cache-quantization-graph-mode-only` |
| 13. The SAM3 story: uniform compression is almost never right | `#13-the-sam3-story-uniform-compression-is-almost-never-right` |
| 14. `coreai_opt.casting`: the fp16 helper and the ordering rule | `#14-coreai_optcasting-the-fp16-helper-and-the-ordering-rule` |
| 15. `coreai_opt.coreai_utils`: compressing an already-converted program | `#15-coreai_optcoreai_utils-compressing-an-already-converted-program` |
| 16. Export backends, and the CoreML restriction matrix | `#16-export-backends-and-the-coreml-restriction-matrix` |
| 17. ⚠️ Silent failures, consolidated | `#17-️-silent-failures-consolidated` |
| 18. Numbers, attributed | `#18-numbers-attributed` |
| 19. Quick reference | `#19-quick-reference` |
| 20. Sources and evidence ledger | `#20-sources-and-evidence-ledger` |

### 9.2 — Palettization, pruning, joint compression, and mixed precision

The other three things `coreai-opt` does, plus the two ways of combining them.

**Local reference:** [part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. Lookup tables are a different idea, and the ANE is why | `#1-lookup-tables-are-a-different-idea-and-the-ane-is-why` |
| 2. The palettizer in eight lines | `#2-the-palettizer-in-eight-lines` |
| 3. `PalettizationSpec`: five fields, and what each one costs | `#3-palettizationspec-five-fields-and-what-each-one-costs` |
| 4. The three schemes, with diagrams | `#4-the-three-schemes-with-diagrams` |
| 5. ⚠️ The ANE rank-5 ceiling | `#5-️-the-ane-rank-5-ceiling` |
| 6. Sizing: what a bit-width actually buys | `#6-sizing-what-a-bit-width-actually-buys` |
| 7. Determinism, workers, and fast k-means mode | `#7-determinism-workers-and-fast-k-means-mode` |
| 8. Sensitivity-weighted k-means (SqueezeLLM) | `#8-sensitivity-weighted-k-means-squeezellm` |
| 9. `lut_qspec`: quantizing the palette itself | `#9-lut_qspec-quantizing-the-palette-itself` |
| 10. What `finalize()` emits | `#10-what-finalize-emits` |
| 11. Pruning: the technique nobody presented | `#11-pruning-the-technique-nobody-presented` |
| 12. Program-level compression: `palettize_weights` and `sparsify_weights` | `#12-program-level-compression-palettize_weights-and-sparsify_weights` |
| 13. Joint compression | `#13-joint-compression` |
| 14. Mixed precision | `#14-mixed-precision` |
| 15. Choosing per layer: the sweep, the Debugger, and SAM3 | `#15-choosing-per-layer-the-sweep-the-debugger-and-sam3` |
| 16. Apple's PSNR acceptance gates | `#16-apples-psnr-acceptance-gates` |
| 17. Community-measured findings, labelled | `#17-community-measured-findings-labelled` |
| 18. The worked examples the repo ships | `#18-the-worked-examples-the-repo-ships` |
| 19. ⚠️ Silent failures, consolidated | `#19-️-silent-failures-consolidated` |
| 20. Numbers, attributed | `#20-numbers-attributed` |
| 21. Quick reference | `#21-quick-reference` |
| 22. Sources and evidence ledger | `#22-sources-and-evidence-ledger` |

### 9.3 — int4 to MX: which layer supports which numeric format

A reference rather than a tutorial, answering one question in as many tables as it takes: for a given format — int4, FP8 E4M3, FP4 E2M1, MXFP4, a 6-bit palette, E8M0 block scales — which layer can **emit** it, which can **store** it, and which can actually **compute** on it.

**Local reference:** [part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. The three sets, and the master matrix | `#1-the-three-sets-and-the-master-matrix` |
| 2. `coreai-opt`: the emit set | `#2-coreai-opt-the-emit-set` |
| 3. `NDArray.ScalarType`: the store set | `#3-ndarrayscalartype-the-store-set` |
| 4. The Neural Engine: the narrowest compute set | `#4-the-neural-engine-the-narrowest-compute-set` |
| 5. Metal and MPP TensorOps: the GPU compute set | `#5-metal-and-mpp-tensorops-the-gpu-compute-set` |
| 6. MLX: the widest menu, implemented in software | `#6-mlx-the-widest-menu-implemented-in-software` |
| 7. The crossings that silently degrade | `#7-the-crossings-that-silently-degrade` |
| 8. How to check what you actually got | `#8-how-to-check-what-you-actually-got` |
| 9. Decision tables by target | `#9-decision-tables-by-target` |
| 10. ⚠️ Silent failures, consolidated | `#10-️-silent-failures-consolidated` |
| 11. Numbers, attributed | `#11-numbers-attributed` |
| 12. Quick reference | `#12-quick-reference` |
| 13. Sources and evidence ledger | `#13-sources-and-evidence-ledger` |

## Part 10 — Core AI: hardware authoring, debugging, and LLM deployment

### 10.1 — Authoring for the Neural Engine and for the GPU: two opposite rulesets

Apple's at-a-glance comparison table reproduced in full and unpacked row by row: on the ANE, rank ≤ 5, fp16 with **no Python float literals anywhere**, the 64-byte alignment rule, BC1S layout, `nn.Conv2d(kernel_size=1)` instead of `nn.Linear`, the transpose pair bracketing every projection, per-head attention with **no fused SDPA**, `-40000.0` instead of `-inf`, precomputed RoPE, the read-only KV cache; on the GPU, standard layout, fused QKV, native fused SDPA, `up_proj` before `gate_proj`, the stateful export wrapper, MoE via `SwitchLinear` / `GatherMM`.

**Local reference:** [part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| ⚠️ A word about evidence, because this framework has none of the usual kind | `#️-a-word-about-evidence-because-this-framework-has-none-of-the-usual-kind` |
| Contents | `#contents` |
| 1. Two rulesets, not two styles | `#1-two-rulesets-not-two-styles` |
| 2. Apple's own at-a-glance table | `#2-apples-own-at-a-glance-table` |
| 3. Choosing the compute unit — before you write the model | `#3-choosing-the-compute-unit--before-you-write-the-model` |
| 4. The Neural Engine rules | `#4-the-neural-engine-rules` |
| 5. The GPU rules | `#5-the-gpu-rules` |
| 6. Apple's authoring workflow | `#6-apples-authoring-workflow` |
| 7. The verification gates | `#7-the-verification-gates` |
| 8. How the optional `coreai-models` helper chooses a compute-unit preference | `#8-how-the-optional-coreai-models-helper-chooses-a-compute-unit-preference` |
| 9. Case study: SAM3 re-authored for iPhone | `#9-case-study-sam3-re-authored-for-iphone` |
| 10. The silent-failure catalogue | `#10-the-silent-failure-catalogue` |
| 11. Quick reference | `#11-quick-reference` |
| 12. Sources and evidence ledger | `#12-sources-and-evidence-ledger` |
| Related guides | `#related-guides` |

### 10.2 — The debug gauge, the Core AI Instrument, and the Core AI Debugger

Three tools at three levels — *is anything happening* (gauge, free), *where is the time going and on which compute unit* (Instruments, one run), *which operation produces the wrong numbers and which Python line wrote it* (Debugger, a download plus a specialization) — built around the three diagnoses Apple demonstrated: widening inference intervals → no KV cache → Core AI **states**; a load event with a large specialization sub-event inside an interactive flow → a first-run experience and AOT compilation; SAM3's missing occluded flower → sort sync points by similarity, notice they all belong to the **detector decoder**, cross that with "the detector is 4 % of parameters", exclude it with `None`.

**Local reference:** [part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. Three tools, one topology | `#1-three-tools-one-topology` |
| 2. The debug gauge | `#2-the-debug-gauge` |
| 3. The Core AI instrument | `#3-the-core-ai-instrument` |
| 4. Worked trace 1 — inference intervals that grow | `#4-worked-trace-1--inference-intervals-that-grow` |
| 5. Worked trace 2 — a specialization sub-event in an interactive flow | `#5-worked-trace-2--a-specialization-sub-event-in-an-interactive-flow` |
| 6. Core AI Debugger — the workspace | `#6-core-ai-debugger--the-workspace` |
| 7. Why the Navigator can group by PyTorch module | `#7-why-the-navigator-can-group-by-pytorch-module` |
| 8. Running the model on a device from the Debugger | `#8-running-the-model-on-a-device-from-the-debugger` |
| 9. `save_intermediates` and the reference run | `#9-save_intermediates-and-the-reference-run` |
| 10. Sync points and the five similarity metrics | `#10-sync-points-and-the-five-similarity-metrics` |
| 11. The worked diagnosis — SAM3's missing flower | `#11-the-worked-diagnosis--sam3s-missing-flower` |
| 12. `coreai-opt`'s own debugging surface | `#12-coreai-opts-own-debugging-surface` |
| 13. `coreai_torch.debugging` — the same jobs, in Python | `#13-coreai_torchdebugging--the-same-jobs-in-python` |
| 14. A playbook: which tool, in which order | `#14-a-playbook-which-tool-in-which-order` |
| 15. ⚠️ Provenance: the coreai-torch 0.4.0 IR-location incident | `#15-️-provenance-the-coreai-torch-040-ir-location-incident` |
| 16. Quick reference | `#16-quick-reference` |
| 17. Sources and evidence ledger | `#17-sources-and-evidence-ledger` |

### 10.3 — From a Hugging Face checkpoint to a loadable LLM bundle

The capstone: one continuous path from `Qwen/Qwen3-0.6B` to `try await session.respond(to:)`, in ten stages, each with its gates and failure modes.

**Local reference:** [part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md)

| Section | Anchor |
|---|---|
| ⚠️ Read this before you trust a signature in this guide | `#️-read-this-before-you-trust-a-signature-in-this-guide` |
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. The pipeline, end to end | `#1-the-pipeline-end-to-end` |
| 2. The easy road: the catalog and the export CLI | `#2-the-easy-road-the-catalog-and-the-export-cli` |
| 3. Two targets, one checkpoint | `#3-two-targets-one-checkpoint` |
| 4. Stage 1 — acquire the weights | `#4-stage-1--acquire-the-weights` |
| 5. Stage 2 — re-author, or use a repo primitive | `#5-stage-2--re-author-or-use-a-repo-primitive` |
| 6. Stage 3 — the oracle and the gates | `#6-stage-3--the-oracle-and-the-gates` |
| 7. Stage 4 — compress | `#7-stage-4--compress` |
| 8. Stage 5 — export with `state_names` | `#8-stage-5--export-with-state_names` |
| 9. Stages 6–8 — convert, optimize, save the bundle | `#9-stages-68--convert-optimize-save-the-bundle` |
| 10. Stage 9 — AOT-compile per architecture | `#10-stage-9--aot-compile-per-architecture` |
| 11. Stage 10 — load it in Swift | `#11-stage-10--load-it-in-swift` |
| 12. The community porting playbook, as a checklist | `#12-the-community-porting-playbook-as-a-checklist` |
| 13. The hybrid / SSM wall | `#13-the-hybrid--ssm-wall` |
| 14. Performance context, attributed | `#14-performance-context-attributed` |
| 15. The alternative bridge: `mlx2coreai` | `#15-the-alternative-bridge-mlx2coreai` |
| 16. Failure catalogue | `#16-failure-catalogue` |
| 17. Quick reference | `#17-quick-reference` |
| 18. Sources and evidence ledger | `#18-sources-and-evidence-ledger` |
