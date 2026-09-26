# Silent-failure index — Core AI: the 27-cycle inference runtime and its conversion pipeline

**529 ⚠️ callouts from the guide parts this skill covers, sorted by the symptom you would observe.** Most defects in this stack do not throw, so the symptom is what you start from.

> Sliced from the series index on 2026-09-22. The full index across all 17 parts is at https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/SILENT-FAILURES.md. Generated — regenerate with `./scripts/build-skills.sh` rather than editing by hand.

| Symptom | Entries |
|---|---:|
| [Wrong output](#wrong-output) | 69 |
| [Empty output / no-op](#empty-output--no-op) | 5 |
| [Truncation & limits](#truncation--limits) | 2 |
| [Ignored input](#ignored-input) | 37 |
| [Stale state](#stale-state) | 6 |
| [Data & artifact loss](#data--artifact-loss) | 7 |
| [Compiles but unavailable](#compiles-but-unavailable) | 18 |
| [Performance cliffs](#performance-cliffs) | 76 |
| [Resource growth](#resource-growth) | 11 |
| [Precision loss](#precision-loss) | 9 |
| [Misleading signals](#misleading-signals) | 42 |
| [Version drift](#version-drift) | 19 |
| [Docs vs reality](#docs-vs-reality) | 45 |
| [API footguns](#api-footguns) | 62 |
| [General cautions](#general-cautions) | 121 |

## Wrong output

**Part 7**

- [Observed zero storage is not an initialization contract; explicitly write every NDArray element that matters.](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#73-creating-an-ndarray) — 7.1
- [Indexing by hand while ignoring interleaveLayout reads the wrong elements — the strides are block strides for that axis](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#78-strides-and-interleavelayout) — 7.1
- [Assuming the output dtype from the input descriptor misreads bytes — outputs can be a different scalar type](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#710-️-silent-failure-assuming-the-output-dtype-from-the-input-descriptor) — 7.1
- [Output scalarType can differ from the input's — inspecting the array itself is the only safe way to decode it](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#710-️-silent-failure-assuming-the-output-dtype-from-the-input-descriptor) — 7.1
- [EXIF orientation is handled by no layer — the same JPEG tensorizes differently depending on the loader](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#124-️-silent-failure-exif-orientation-is-nobodys-job-so-it-is-yours) — 7.1
- [apple/coreai-models has zero EXIF handling and its two image entry points disagree — rotated photos give wrong tensors](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#124-️-silent-failure-exif-orientation-is-nobodys-job-so-it-is-yours) — 7.1 🔇
- [NDArray.from_descriptor only sizes the buffer — on Linux unzeroed state reads garbage; allocate np.zeros explicitly](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#verify-the-conversion-before-you-write-a-line-of-swift) — 7.3
- [memset-zeroing the whole addressable range clobbers aliased buffers — exactly the AsyncValue(unsafeBuffer:) situation](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#53-zeroing-and-the-six-second-reset) — 7.3
- [x.mul_(2) on a forward arg silently reclassifies the input as state — positional Swift bindings shift one slot](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#82-️-silent-failure--an-in-place-mutation-silently-turns-an-input-into-a-state) — 7.3
- [Uninitialised state storage: nothing documents that Swift NDArray inits zero — unzeroed KV reads garbage on first use](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#83-️-silent-failure--uninitialised-state-storage) — 7.3
- [Two concurrent run() calls sharing one KV cache race — exclusivity checks don't span async tasks; one loop per state set](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#concurrency-and-its-hidden-cost) — 7.3
- [Omit image_mean/image_std and you silently get CLIP's — Qwen3-VL-class models produce degraded captions, not an error](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#26-the-language-block-and-a-discrepancy-worth-knowing) — 7.4
- [Inputs and states bind positionally, not by name — a graph declared in another order loads, runs, and produces garbage](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#53-coreaisequentialengine--dynamic-cpu-side-sampling-logits-available) — 7.4
- [Fixed bug: pipelined sampling shared one execution descriptor across steps, corrupting text at temperature > 0](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#54-coreaipipelinedengine--gpu-on-device-sampling-no-logits) — 7.4 🔇
- [Substring tensor-role discovery picks the first ambiguous match and can wire the wrong intermediate without a…](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md#42-multi-function-backend) — 7.5 🔇

**Part 8**

- [optimize() deletes a broadcasting-significant expand_dims — 17 dB PSNR at model scale, shape still validates (issue #49)](part-08-coreai-pytorch-conversion/README.md#81--torchexport-to-aimodel-and-the-io--state--dynamic-shape-contract) — 8.README 🔇
- [MTLTensor extents reverse the torch shape — a kernel correct in torch coordinates reads the wrong axes in Metal](part-08-coreai-pytorch-conversion/README.md#83--torchmetalkernel-writing-and-embedding-a-custom-metal-kernel) — 8.README 🔇
- [optimize() is not always semantics-preserving — a deleted expand_dims changes results while shapes still validate](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#64-️-silent-failure--optimize-is-not-always-semantics-preserving) — 8.1
- [Distance matrices, Gram matrices and contrastive forms are exposed — gate optimize=True vs False on real inputs](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#64-️-silent-failure--optimize-is-not-always-semantics-preserving) — 8.1 🔇
- [State ordering is an assumption — same-shape buffers like k_cache/v_cache can swap slots and every check still passes](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#93-️-silent-failure--state-ordering-is-an-assumption-not-a-guarantee) — 8.1
- [k_cache and v_cache can swap positions across a PyTorch upgrade — Swift binds key to the value slot and output is…](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#93-️-silent-failure--state-ordering-is-an-assumption-not-a-guarantee) — 8.1 🔇
- [NDArray.from_descriptor only sizes the buffer — on Linux, buffer-state reads return garbage on the first call](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#94-the-runtime-state-protocol-and-its-own-footgun) — 8.1
- [Seventeen open defects across the repos produce plausible, correct-shaped output with no diagnostic — four still unfixed](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#1-four-ways-a-conversion-fails) — 8.2 🔇
- [SDPA has two conversion routes with one name — their attribute schemas and mask conventions differ](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#55-️-sdpa-two-paths-one-name-different-attributes) — 8.2
- [The causal-mask convention differs between the two SDPA routes when query and key lengths differ — masks land wrong](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#55-️-sdpa-two-paths-one-name-different-attributes) — 8.2 🔇
- [RoPE requires fp32, and partial-rotary mode pairs the wrong dimensions — a known acknowledged issue](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#57-️-rope-fp32-is-mandatory-and-the-partial-rotary-pairing-is-a-trap) — 8.2
- [Partial-rotary RoPE pairs dims contiguously, not as checkpoints expect — wrong rotations, acknowledged as a known issue](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#57-️-rope-fp32-is-mandatory-and-the-partial-rotary-pairing-is-a-trap) — 8.2 🔇
- [fp16 casting ignores activation overflow in softplus/mish/logsumexp — the sanctioned fix is rewriting your module](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#91-fp16-overflow-in-softplus-mish-logsumexp-logcumsumexp) — 8.2
- [Compression shifts activation distributions — values once below the fp16 overflow threshold can newly exceed it](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#91-fp16-overflow-in-softplus-mish-logsumexp-logcumsumexp) — 8.2
- [Integer true divide ran as int division then cast — fractions dropped on every backend (PR #32; latent twin in div)](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#92-integer-true-divide-truncates-instead-of-promoting-to-float) — 8.2 🔇
- [cat on packed sub-byte tensors always concatenates on dim 0 — (2,4)+(2,4) at dim=1 silently yields (4,4), not (2,8)](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#93-cat-on-packed-sub-byte-tensors-always-concatenates-on-dim-0) — 8.2 🔇
- [sum/prod on int64 reduced in int32 — silently wrapping identically on every backend, corrupting the lowered IR](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#94-int64-accumulator-narrowing-in-sum-and-prod) — 8.2 🔇
- [The axis reversal: MTLTensor extents are the reverse of the torch shape, and subscripts reverse too](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md#52-️-the-axis-reversal) — 8.3
- [Torch (D0,D1,D2) arrives in the kernel as (D2,D1,D0) — your correct torch_defn cannot catch the reversed Metal body](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md#52-️-the-axis-reversal) — 8.3 🔇
- [torch_defn is shape inference only — a kernel emitting zeros or NaN converts cleanly; write the numeric test yourself](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md#54-the-general-lesson-a-correct-reference-masks-an-incorrect-kernel) — 8.3 🔇
- [A literal result_shapes under a dynamic input compiles fine — at other runtime sizes the kernel writes the stale shape](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md#64-️-the-failure-mode-a-hardcoded-shape-under-a-dynamic-input) — 8.3
- [result_shapes=[2,2,3] freezes into a ?x2x3 graph — when dim 0 arrives as 7, nothing objects; use list(x.shape) always](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md#64-️-the-failure-mode-a-hardcoded-shape-under-a-dynamic-input) — 8.3 🔇
- [Naked exp() in a hand-written softmax overflows — subtract the running max first, as Apple's own fixture does](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md#146-one-numerics-rule-that-is-not-about-core-ai-at-all) — 8.3

**Part 9**

- [Now-fixed axis bug in coreai::quantize/dequantize — worth knowing when reading older artifacts](part-09-coreai-compression-numerics/references/01-quantization.md#85-graph-mode-prepare-step-by-step) — 9.1
- [axis=-1 normalized off by one — per-channel scales landed one dim early with no shape error when sizes match (fixed #24)](part-09-coreai-compression-numerics/references/01-quantization.md#85-graph-mode-prepare-step-by-step) — 9.1 🔇
- [Pool/flatten share one FakeQuantize between input and output — a per-channel scale can land on the wrong axis](part-09-coreai-compression-numerics/references/01-quantization.md#96-️-shared-observers-and-the-per-channel-activation-constraint) — 9.1
- [KV-cache quant ops must commute with quantize/dequantize — point it at arithmetic and the export succeeds, wrongly](part-09-coreai-compression-numerics/references/01-quantization.md#12-kv-cache-quantization-graph-mode-only) — 9.1
- [The casting pass changes user input/output dtypes in place — feeding fp32 afterwards presents as garbage, not a type…](part-09-coreai-compression-numerics/references/01-quantization.md#143-the-ordering-rule-compress-first-cast-second) — 9.1
- [fp16 casting does not guard activation overflow, and compression makes previously-safe values overflow](part-09-coreai-compression-numerics/references/01-quantization.md#144-️-silent-failure--fp16-casting-does-not-guard-activation-overflow-and-compression-makes-it-worse) — 9.1
- [fp16-cast models can emit zeros where stable ops yield large finite values — activation overflow is unguarded (#7, open)](part-09-coreai-compression-numerics/references/01-quantization.md#144-️-silent-failure--fp16-casting-does-not-guard-activation-overflow-and-compression-makes-it-worse) — 9.1 🔇
- [ChannelStructured(axis=-1) prunes the wrong channels — per-channel L1 norms collapse to a scalar (PR #45 open)](part-09-coreai-compression-numerics/references/01-quantization.md#176-a-negative-axis-used-to-land-on-the-wrong-dimension) — 9.1 🔇
- [aten.cat on packed intx/uintx tensors drops dim — every cat runs on dim 0, (2,4)+(2,4) dim=1 gives (4,4) (PR #41 open)](part-09-coreai-compression-numerics/references/01-quantization.md#176-a-negative-axis-used-to-land-on-the-wrong-dimension) — 9.1 🔇
- [Per-channel axis-0 int8 Linear weights return garbage on the macOS-27-beta GPU delegate — use per-block-32 there](part-09-coreai-compression-numerics/references/01-quantization.md#186-community-measurements--attributed-and-to-be-treated-as-such) — 9.1
- [The casting passes mutate the program and change user I/O dtypes — old callers feed fp32 and get garbage, not an error](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#29-casting-is-not-compression-and-the-order-matters) — 9.3
- [Sub-byte nibble order is undocumented — the decode assumes MLX's low-first convention; verify on a known tensor first](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#32--gap--you-cannot-read-sub-byte-data-from-swift-except-as-raw-bytes) — 9.3
- [Failure #16: IEEE -inf softmax masks compute wrong numbers on the ANE — use -40000.0 instead](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#71-the-lookup-table) — 9.3
- [Beta bug, not a fallback: per-channel axis-0 int8 Linear weights return wrong numbers on the macOS-27-beta GPU delegate](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#112-community-measured--attribute-do-not-launder) — 9.3

**Part 10**

- [Omit remove_functionalization and KV writes vanish: fluent, globally incoherent output that mimics bad quantization.](part-10-coreai-hardware-authoring-debugging/README.md#103--from-a-hugging-face-checkpoint-to-a-loadable-llm-bundle) — 10.README 🔇
- [A mismatched projection transpose exports cleanly and yields structurally shuffled activations with PSNR in the teens.](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md#46-transpose-bookkeeping-at-every-projection-site) — 10.1
- [Causal mask shaped (1,q,1,k) instead of (1,k,1,q) runs without error but collapses SDPA PSNR to 15-30 dB.](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md#411-the-causal-mask-is-transposed-and--inf-is-wrong) — 10.1 🔇
- [An M-RoPE that misses the exact cat([cos,cos]) then ::2 indexing pattern converts fine and outputs ~18 dB PSNR.](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md#412-rope-must-be-precomputed-outside-the-graph) — 10.1 🔇
- [Caching new_k instead of key_rope stores pre-RoPE keys; shapes are identical but PSNR collapses to ~20 dB.](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md#413-the-read-only-kv-cache) — 10.1 🔇
- [GELU substituted for SiLU runs like the original and is 20-30 dB off; activation functions are not interchangeable.](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md#51-standard-layout-nnlinear-fp32-where-you-need-it) — 10.1
- [A non-contiguous tensor through the Python wrapper can produce wrong numbers rather than an error.](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md#73-what-to-do-when-a-gate-fails) — 10.1
- [AIProgram.optimize() can delete broadcasting-significant axis ops; the graph shrinks and the numbers go wrong silently.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#82-why-graph-visualization-specialized-is-the-most-important-field-in-that-dialog) — 10.2 🔇
- [Pipeline diagram: omit remove_functionalization and KV writes vanish silently.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#11-the-canonical-five-steps-and-where-the-real-work-hides) — 10.3
- [input_names/state_names order is load-bearing: swap key and value and the model loads, runs, and emits fluent nonsense.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#32-the-macosgpu-graph-contract) — 10.3
- [AIModel.load(path, None) trips MPSGraph errors, and a GC'd AIModel makes the load_function return garbage, not a crash.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#64-gate-a--graph-parity) — 10.3
- [Bundles missing chat_template.jinja silently fall back to raw completion; quality collapses and nothing warns.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#68-️-silent-failure--the-missing-chat-template) — 10.3
- [Recipe line: remove_functionalization is mandatory - omit it and KV writes disappear (see 8.4).](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#81-the-macos-export-verbatim-from-the-shipped-recipe) — 10.3
- [Omit remove_functionalization and the KV cache never updates: fluent, incoherent output that mimics bad quantization.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#84-️-silent-failure--omit-remove_functionalization-and-your-kv-writes-disappear) — 10.3
- [optimize() deletes ops it deems dead, including broadcasting-significant axis manipulations; outputs change silently.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#92-optimize-is-in-place-and-it-can-hurt-you) — 10.3
- [Skip chat_template.jinja in the bundle and runners fall back to raw completion; output quality quietly collapses.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#94-wrapping-it-into-a-bundle) — 10.3
- [Checklist: KV cache is in-graph mutable state - remove_functionalization is what keeps its writes alive.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#122-the-checklist) — 10.3

## Empty output / no-op

**Part 7**

- [Outputs you pre-allocate views for are updated in place and omitted from the returned Outputs — lookups come back nil](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#94-️-silent-failure-outputs-you-pre-allocate-disappear-from-outputs) — 7.1
- [An output with a provided view is updated in place and not included in returned Outputs — reading it there finds nothing](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#94-️-silent-failure-outputs-you-pre-allocate-disappear-from-outputs) — 7.1 🔇
- [vocabType defaults differ (.raw vs .byteLevel) — the mismatch over-constrains the grammar and generation yields nothing](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#75-️-a-second-quieter-trap-the-vocabtype-default-mismatch) — 7.4
- [Detector postprocessing returns an empty array for malformed output ranks and lengths, indistinguishable from a valid…](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md#5-object-detection-one-raw-asset-one-real-warmup) — 7.5 🔇

**Part 10**

- [An unknown model id ships an asset whose metadata has only creation_date; the banner warning scrolls past in long logs.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#93-save_asset--two-traps-in-one-call) — 10.3

## Truncation & limits

**Part 7**

- [Mistral's synthetic tool-call close marker is a newline — multi-line tool-call JSON is cut at the first line break](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#82-capabilities-are-auto-detected-from-the-tokenizer) — 7.4
- [maximumResponseTokens counts hidden thinking — a small cap can end the turn mid-<think> with no response at all](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#83-what-the-adapter-forwards-and-what-it-drops) — 7.4

## Ignored input

**Part 7**

- [.chunked KV strategy is accepted and silently falls back to the static cache — it is not implemented](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#the-four-strategies) — 7.3
- [VLM sampling is hard-coded to temperature 1.0 / topK 1 — the GenerationOptions temperature you pass never reaches it](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#56-coreaisequentialvlmengine) — 7.4
- [--kv-cache-strategy chunked is accepted but unimplemented — you silently get a fixed-size cache](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#57-kv-cache-strategy--and-the-memory-arithmetic-behind-it) — 7.4
- [The stopTokenIds parameter is dead — values you pass are never consulted by the engines](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#74-️-silent-failure--the-dead-stoptokenids-parameter) — 7.4

**Part 8**

- [Unmatched ExternalizeSpec warns, never raises — a typo ships a slower model; assert on composite_declaration in the IR](part-08-coreai-pytorch-conversion/README.md#82--when-an-op-will-not-convert-coverage-composite-ops-custom-lowerings-externalization) — 8.README 🔇
- [ExternalizeSpec target_class must be RMSNormImpl — pointing at the RMSNorm wrapper silently matches nothing](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#53-why-the-second-form-exists-externalization) — 8.1
- [clone()/contiguous() lower to identity — barrier-by-clone silently does nothing against the buffer-clobber bug (#11)](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#26-the-three-op-groups-worth-knowing-by-name) — 8.2
- [A typo in composite_attrs or target_class is a UserWarning, not an error — filtered warnings ship a slower model…](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#54-module-class-composites-the-three-step-pattern) — 8.2 🔇
- [Externalize RMSNormImpl, not RMSNorm — the wrapper class silently matches no submodule](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#56-️-rmsnormimpl-not-rmsnorm) — 8.2
- [Externalization's four silent failures — unmatched specs and attr typos warn or say nothing and quietly drop the…](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#87-️-the-four-silent-failures-in-externalization) — 8.2
- [torch.cond branch subgraphs never receive your registered custom lowerings — a pinned strict-xfail converter bug](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md#123-the-known-converter-bug-custom-kernels-inside-torchcond) — 8.3

**Part 9**

- [A block size the weight isn't divisible by yields only a warning and an uncompressed layer](part-09-coreai-compression-numerics/references/01-quantization.md#what-this-covers) — 9.1
- [module_type_configs keyed by the string 'torch.nn.Linear' silently matches nothing — use the class object](part-09-coreai-compression-numerics/references/01-quantization.md#52-module_type_configs--fully-qualified-class-names-only) — 9.1
- [A block size your weight isn't divisible by leaves the layer uncompressed, with only a log line](part-09-coreai-compression-numerics/references/01-quantization.md#75-️-silent-failure--a-block-size-your-weight-isnt-divisible-by-leaves-the-layer-uncompressed) — 9.1
- [Block-size mismatch is caught internally and swallowed — the fake-quantize disables itself and the layer ships…](part-09-coreai-compression-numerics/references/01-quantization.md#75-️-silent-failure--a-block-size-your-weight-isnt-divisible-by-leaves-the-layer-uncompressed) — 9.1 🔇
- [Open bug follows: shared weights blend two configs — dtype from one, QAT schedule from the other](part-09-coreai-compression-numerics/references/01-quantization.md#115-per-module-schedules-and-the-two-conflict-rules) — 9.1
- [A shared weight takes dtype from one config and fake-quant schedule from another — issue #41, open, no warning](part-09-coreai-compression-numerics/references/01-quantization.md#115-per-module-schedules-and-the-two-conflict-rules) — 9.1 🔇
- [Diffusion path swallows quantization failures with a warning — you can ship a full-precision model believing it…](part-09-coreai-compression-numerics/references/01-quantization.md#172-diffusion-quantization-failures-are-swallowed-with-a-warning) — 9.1 🔇
- [shape[axis] % group_size must be 0 — a non-dividing group size leaves the layer unpalettized with only a warning](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#42-scheme-2--scalar-palettization-per-grouped-channel) — 9.2
- [Realized sparsity rounds down — an unreachable channel target can round to zero pruning](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#114-️-realized-sparsity-rounds-down-and-it-can-round-to-zero) — 9.2
- [floor(8 channels x 0.1) = 0: the layer is untouched, no warning — your '10% sparse' model is 0% sparse in narrow layers](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#114-️-realized-sparsity-rounds-down-and-it-can-round-to-zero) — 9.2 🔇
- [prepare() succeeds while mis-sized layers were never compressed — the model ships bigger than your release notes say](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#191-a-group-size-your-weight-is-not-divisible-by-leaves-the-layer-uncompressed) — 9.2 🔇
- ['torch.nn.Linear' has dots so it passes the syntactic check and then matches nothing — genuinely silent](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#1910-inherited-from-quantization-and-still-true-here) — 9.2
- [A block size the weight doesn't divide by leaves the layer at full precision — a warning is the only trace](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#27-️-silent-failure--a-block-size-your-weight-doesnt-divide-by-leaves-the-layer-at-full-precision) — 9.3
- [The fake-quantize logs 'Skipping quantization' and permanently disables itself — graph mode then removes the node](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#27-️-silent-failure--a-block-size-your-weight-doesnt-divide-by-leaves-the-layer-at-full-precision) — 9.3 🔇
- [Failure #1: non-dividing block_size leaves the layer uncompressed; only one logger.warning marks it](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#71-the-lookup-table) — 9.3
- [Failure #13: an MLX layer whose last dim doesn't divide group_size is silently skipped by the quant predicate](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#71-the-lookup-table) — 9.3
- [Failure #17: diffusion components that fail quantization are swallowed with a warning — check file size on disk](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#71-the-lookup-table) — 9.3
- [Diffusion quantization failures are swallowed (export/compiler.py) — cross-check on-disk size against numel x bits/8](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#71-the-lookup-table) — 9.3 🔇

**Part 10**

- [CLI --n-bits/--group-size hit both encoders uniformly, silently overriding the recipe's asymmetric per-encoder settings.](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md#95-️-the-gap-between-the-session-and-the-shipped-runtime) — 10.1
- [Compression succeeds while log-only skips leave layers untouched; the asset is less compressed than you configured.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#114-the-failure--and-why-it-is-the-right-kind-of-failure-to-teach) — 10.2 🔇
- [Short type keys like torch.nn.Linear silently match nothing; the config is accepted and the layer is quantized anyway.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#116-the-fix) — 10.2
- [Graph-mode op names are global, eager-mode are module-qualified; a pattern from the wrong mode matches no layers at all.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#121-modelinspector--what-will-actually-be-compressed) — 10.2 🔇
- [module_type_configs keys must be full internal paths; short names silently match no modules.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#72-the-macos-4bit-preset-expanded) — 10.3
- [Compression completes while quietly skipping layers; the shipped asset is bigger and less quantized than configured.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#75-️-silent-failure--compression-that-skips-layers-and-tells-you-nothing) — 10.3
- [Compiling with --expect-frequent-reshapes does not make the runtime hint safe; both variants crash - load-time matters.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#105-️-silent-ish-failure--expectfrequentreshapes-on-a-fixed-shape-graph) — 10.3
- [KV strategy .chunked is accepted by the API and does nothing.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#113-choosing-the-engine) — 10.3

## Stale state

**Part 7**

- [No reset() exists — a new conversation silently continues on whatever KV the last one left in the state](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#84-️-silent-failure--the-state-you-forgot-to-reset-between-conversations) — 7.3
- [Noema tracks fedTokens and prefix-checks before reuse — anything else risks decoding against another conversation's KV](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#84-️-silent-failure--the-state-you-forgot-to-reset-between-conversations) — 7.3
- [The ANE in-graph KV-write crash corrupts the compile cache — later loads fail ENOENT until you delete cache entries](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#the-symptom) — 7.3
- [Two models built from the same URL and settings share one engine and KV cache — the second session resets the first](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#43-modelresources--lazy-loading-shared-engines-borrow-safe-unload) — 7.4
- [Diffusion filename fallback can select a stale component when old and new exports coexist; ship an explicit schema-0.2…](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md#21-the-assets-map-is-operational-not-descriptive) — 7.5 🔇

**Part 10**

- [An in-place mutation of a forward() input becomes hidden converted-model state; there is no flag to opt out.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#43-the-python-side--register_buffer-plus-in-place-mutation) — 10.2 🔇

## Data & artifact loss

**Part 7**

- [.persistent means until the next OS update — every point release purges all specialized assets and users repay the stall](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#when-to-use-persistent) — 7.2
- [A cache bookmark pins nothing — the entry can be deleted underneath it on OS update or storage pressure](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#️-silent-failure--a-bookmark-does-not-pin-anything) — 7.2
- [bookmarkData is a pointer, not the model — the system deletes the entry underneath it and resolving just returns nil](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#️-silent-failure--a-bookmark-does-not-pin-anything) — 7.2 🔇

**Part 9**

- [Eager-only KMeansPalettizer.finalize() frees the dense float weights — there is no undo](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#102-️-eager-only-kmeanspalettizerfinalizecoreai-frees-dense-weights) — 9.2
- [finalize() discards float weights with no warning — if prepare() mutated your only copy, the float model is gone](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#102-️-eager-only-kmeanspalettizerfinalizecoreai-frees-dense-weights) — 9.2 🔇

**Part 10**

- [Provenance of the incident that made every coreai-torch 0.4.0-converted asset permanently unusable.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#15-️-provenance-the-coreai-torch-040-ir-location-incident) — 10.2
- [Every .aimodel converted with coreai-torch 0.4.0 is dead: a wrong IR location breaks compilation (community, issue #37).](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#151-what-happened) — 10.2

## Compiles but unavailable

**Part 7**

- [Default macOS pipelined engine reports supportsLogits=false — @Generable throws unsupportedCapability at generation time](part-07-coreai-swift-runtime/README.md#74--model-bundles-the-llm-engines-and-grammar-constrained-decoding) — 7.README 🔇
- [Core AI code paths vanish from Simulator builds — the 27.0 simulator SDK ships no CoreAI framework; device SDKs do](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#aimodel-inferencefunction-ndarray-and-the-memory-model) — 7.1
- [Float16 doesn't exist on Intel macOS — Apple's own code fatalErrors, so fp16 models crash x86_64 builds outright](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#710-️-silent-failure-assuming-the-output-dtype-from-the-input-descriptor) — 7.1
- [AsyncValue and its NDArray/pixel-buffer inits are unavailable on watchOS — the async pipeline API is not universal](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#the-types) — 7.1
- [ComputeStream(commandQueue:) is absent on watchOS; encoded inferences on one stream serialize by read/write dependencies](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#the-types) — 7.1
- [AOT compiles only for Apple-Intelligence-capable devices (A17 Pro+, M1+) — older hardware isn't covered](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#141-️-aot-only-compiles-for-apple-intelligence-capable-devices) — 7.2
- [ComputeStream(commandQueue:) does not exist on watchOS](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#computestream) — 7.3
- [The second async-value initializer is likewise absent on watchOS](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#the-two-async-value-types) — 7.3
- [AsyncValue's NDArray initializer is unavailable on watchOS](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#the-two-async-value-types) — 7.3
- [Grammar-constrained decoding needs logits — @Generable and forcedContinuation are unavailable on the GPU-pipelined path](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#technique-2--the-next-token-stays-on-the-gpu) — 7.3
- [Missing tokenizer/ falls back to a HuggingFace Hub fetch — instant on your Mac's cache, a network request on user…](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#27-languagebundle-the-strict-loader) — 7.4 🔇
- [Guided generation and the fastest engine are mutually exclusive — the pipelined path exposes no logits](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#78-️-the-architectural-constraint-guided-generation-and-the-fastest-engine-are-mutually-exclusive) — 7.4

**Part 8**

- [torch.cond / while_loop convert but run only on the bundled interpreter — no cpu/gpu/ane runtime support today](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#33-what-exportable-means-in-practice) — 8.1
- [torch.cond/while_loop convert but the cpu/gpu/ane runtimes cannot run them — interpreter only, a device blocker](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#26-the-three-op-groups-worth-knowing-by-name) — 8.2 🔇

**Part 9**

- [Registry preset YAMLs exist only in the source tree — wheel installs SystemExit; clone coreai-models to read the recipes](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#145-writing-the-yaml) — 9.2
- [AOT compiles only for Apple-Intelligence hardware: A17 Pro+, M1+ Macs, M2+ Vision Pro — one .aimodelc per arch](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#94-ahead-of-time-compilation-does-not-change-the-format-question) — 9.3

**Part 10**

- [Registry compression presets reference YAMLs that exist only in the source tree; wheel installs exit with SystemExit.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#26-three-gotchas-in-the-easy-road) — 10.3
- [An uncompiled .aimodel will not run on iOS at all; only the compiled .aimodelc loads there.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#106-after-compiling-edit-metadatajson) — 10.3

## Performance cliffs

**Part 7**

- [Hello-world NDArray(shape:scalarType:) can mismatch the specialized layout: a silent layout copy on every inference](part-07-coreai-swift-runtime/README.md#71--aimodel-inferencefunction-ndarray-and-the-memory-model) — 7.README 🔇
- [Holding states in a dictionary you also read leaves NDArray non-unique — COW copies the whole KV cache every decode…](part-07-coreai-swift-runtime/README.md#73--states-as-kv-cache-and-pipelined-execution) — 7.README 🔇
- [Segmentation re-encodes unchanged images and lazy diffusion reloads components; malformed detector shapes look like a…](part-07-coreai-swift-runtime/README.md#75--non-llm-engines-bundles-function-structure-warmup-specialization-and-caching) — 7.README
- [Summary with includingStatistics:true is considerably slower on large models — pass false for structure probes](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#11-there-is-a-sixth-type-and-it-is-the-one-people-miss) — 7.1
- [AOT compilation does not remove on-device specialization; specialize() controls when it runs, not how much work it does](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#21-the-one-place-aimodel-and-aimodelc-differ-at-the-call-site-nowhere) — 7.1
- [Probing the cache with .default then loading with .gpu options misses the cache: the key includes SpecializationOptions](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#33-the-load-ladder-in-the-order-you-should-write-it) — 7.1
- [CoreAISegmentationEngine re-runs image_encode on every segment() call — the 76% speedup needs caller-side feature…](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#43-functionnames-and-the-multi-function-model--a-bigger-deal-than-it-looks) — 7.1
- [The layout-conversion copy: a default-allocated tensor gets converted on every inference with no observable symptom](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#️-silent-failure-the-layout-conversion-copy) — 7.1
- [Contiguous row-major NDArray vs specialized layout: the framework copies your tensor every inference, forever, silently](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#️-silent-failure-the-layout-conversion-copy) — 7.1 🔇
- [Pre-allocating an output view forces a copy for constant-backed outputs the framework would otherwise return zero-copy](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#112-pre-allocated-outputs-the-outputviews-parameter) — 7.1
- [AsyncValue.ndArray returns a copy when the value wraps an MTLBuffer — the zero-copy path silently isn't](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#️-silent-failure-asyncvaluendarray-copies-when-the-value-came-from-a-mtlbuffer) — 7.1
- [Reading .ndArray from an MTLBuffer-backed AsyncValue copies the data to avoid aliasing — use the MTLBuffer directly](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#️-silent-failure-asyncvaluendarray-copies-when-the-value-came-from-a-mtlbuffer) — 7.1
- [expectFrequentReshapes on an all-static graph silently discards the AOT asset and recompiles on device](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#️-silent-failure--the-flag-that-discards-your-aot-work) — 7.2
- [expectFrequentReshapes=true on a static graph drops AOT specialization — no log, just a slow (or jetsam-killed) load](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#️-silent-failure--the-flag-that-discards-your-aot-work) — 7.2 🔇
- [Arbitrary prompt lengths re-specialize the graph — bucket prefill into a few fixed shapes compiled once](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#the-dynamic-cache-alternative-and-its-own-cost) — 7.3
- [Incident-grade community finding: the reshape hint can destroy AOT benefits — see the fixed-shape measurement below](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#the-dynamic-cache-alternative-and-its-own-cost) — 7.3
- [Community-measured: expectFrequentReshapes on a fixed-shape graph kills the AOT bundle — set it only on the dynamic path](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#the-dynamic-cache-alternative-and-its-own-cost) — 7.3
- [Copy-on-write copies the entire KV cache every decode step when the state buffer isn't uniquely referenced](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#81-️-silent-failure--copy-on-write-copies-your-entire-kv-cache-every-step) — 7.3
- [The frozen Noema snapshot parks placeholders so working state stays uniquely owned — no per-token COW copy.](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#81-️-silent-failure--copy-on-write-copies-your-entire-kv-cache-every-step) — 7.3
- [Encode-once reuse requires caller-side caching — CoreAISegmentationEngine re-runs image_encode every call, no cache API](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#where-this-pays-off-outside-a-decode-loop) — 7.3
- ['MLX 2x faster' measured a hand-rolled per-token loop — Apple's pipelined engine runs the same weights ~3.5x faster](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#what-the-35-figure-actually-measures) — 7.3
- [Pipelined engine overshoots EOS into device KV — cross-turn reuse is impossible and TTFT is history/decodeRate](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#the-one-place-pipelining-is-a-liability) — 7.3
- [Models carrying recurrent extra states reject trimKVCache — hybrid/SSM architectures cannot prefix-reuse across turns](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#️-the-constraint-that-changes-model-selection) — 7.3
- [trimKVCache guards on extraStates.isEmpty — graphs with SSM/conv states return -1 and pay full re-prefill every turn](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#️-the-constraint-that-changes-model-selection) — 7.3
- [Intervals look fine but memcpy dominates the Time Profiler: the copy-on-write KV trap of §8.1](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#reading-a-states-problem) — 7.3
- [swift run defaults to Debug, where -Onone per-element closures make resets take seconds — build release for any…](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#34-the-six-cli-tools-and-what-each-is-actually-for) — 7.4
- [The structure probe swallows errors and defaults to .dynamic — an ANE-meant model silently gets GPU specialization](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#42-preparedmodel--the-two-phase-load-that-picks-your-compute-unit) — 7.4
- [Prefix reuse needs byte-identical re-renders — unsorted tool-call dict keys collapse the LCP and silently re-prefill](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#66-what-it-is-worth) — 7.4
- [A failed structure summary silently defaults to dynamic GPU specialization options before the loaded functions reveal…](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md#3-preparedmodel-inspect-before-specializing) — 7.5
- [ImageSegmenter re-runs image_encode for every prompt; same-image feature reuse requires an application-owned…](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md#43-the-advertised-reuse-is-not-implemented-by-the-high-level-api) — 7.5
- [Lazy diffusion unloading saves residency but repeated requests reload every component and repay stage-load latency](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md#63-eager-residency-versus-lazy-stage-residency) — 7.5

**Part 8**

- [torch.export's default decomposition table splits SDPA into matmul+softmax — you silently lose the fused kernel](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#44-️-silent-failure--using-pytorchs-default-table-instead-of-apples) — 8.1
- [No error marks a lost composite — count ops with freqop or assert composite.scaled_dot_product_attention in the IR](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#44-️-silent-failure--using-pytorchs-default-table-instead-of-apples) — 8.1 🔇
- [Entrypoint names are routing: nonstandard names make the loader classify .dynamic and request GPU instead of ANE](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#104-the-sample-runtime-finding-the-split-selects-coreai-models-ane-policy) — 8.1
- [The 76% faster second inference requires caller-side caching Apple's own package does not implement](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#105-️-and-the-76-requires-work-apples-own-package-does-not-do) — 8.1
- [CoreAISegmentationEngine re-runs image_encode every segment() and exposes no way to hold backbone features](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#105-️-and-the-76-requires-work-apples-own-package-does-not-do) — 8.1
- [instance_norm becomes a composite only when use_input_stats is truthy — otherwise you quietly lose the optimized kernel](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#53-aten-derived-composites-the-attribute-schemas) — 8.2 🔇
- [The function containing a custom kernel is GPU-resident — splitting entrypoints pins that function off the ANE](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md#83-multiple-entrypoints-one-asset) — 8.3
- [A custom kernel is a fusion barrier — the surrounding graph slows in ways your kernel's own timing never shows](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md#133-️-the-hidden-cost-a-kernel-is-a-fusion-barrier) — 8.3
- [Kernel edges materialize in the dtype the kernel asks for — boundary casts become real ops that inflate the graph](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md#133-️-the-hidden-cost-a-kernel-is-a-fusion-barrier) — 8.3 🔇

**Part 9**

- [enable_per_channel_scale=True lowers to rank-6 LUTs the ANE (max rank 5) rejects — the model silently moves to GPU](part-09-coreai-compression-numerics/README.md#92--palettization-pruning-joint-compression-and-mixed-precision) — 9.README 🔇
- [Compute-unit fallback is documented and silent — correct outputs, several times slower, visible only in tooling](part-09-coreai-compression-numerics/README.md#93--int4-to-mx-which-layer-supports-which-numeric-format) — 9.README 🔇
- [Covered here: the ANE rank-5 ceiling — one palettization flag silently reroutes the model to the GPU](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#what-this-covers) — 9.2
- [The ANE rank-5 ceiling: rank-6 tensors force the op — and its fused neighbors — off the Neural Engine](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#5-️-the-ane-rank-5-ceiling) — 9.2
- [enable_per_channel_scale improves PyTorch numerics slightly and silently moves the model to GPU — invisible on a Mac](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#52-the-contradiction) — 9.2 🔇
- [The 76% figure needs backbone-feature caching CoreAISegmentationEngine doesn't do — it re-runs image_encode every call](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#152-the-three-function-split-also-selects-coreai-models-ane-preference) — 9.2
- [The 76%-faster second inference requires caller-side caching Apple's package does not do](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#201-apple-published) — 9.2
- [Cheat sheet: enable_per_channel_scale=True means rank-6 LUT, ANE rejection, and silent GPU fallback](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#213-field-cheat-sheet) — 9.2
- [A format the compute unit lacks doesn't throw — specialization silently reassigns the op several-times-slower elsewhere](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#what-this-covers) — 9.3
- [Complex dtypes exist in MLX but are excluded from NAX — complex matmuls run on the older, slower kernels](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#12-the-master-matrix) — 9.3
- [A bare Python float literal can move an op — and its fused pattern — off the ANE to the GPU](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#42-️-silent-failure--a-bare-python-float-literal-can-move-an-op-to-the-gpu) — 9.3
- [A literal fp16 can't represent materializes as an fp32 constant — the consuming op leaves the ANE with no warning](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#42-️-silent-failure--a-bare-python-float-literal-can-move-an-op-to-the-gpu) — 9.3 🔇
- [Recognized entrypoint names select the sample loader's ANE preference — rename them and you get the GPU policy](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#44-️-recognized-functions-select-the-sample-loaders-ane-preference) — 9.3
- [CoreAISegmentationEngine re-runs image_encode on every call and exposes no cache — the headline speedup needs your code](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#44-️-recognized-functions-select-the-sample-loaders-ane-preference) — 9.3
- [A deployment target below 26.2 silently drops every NAX kernel — the only trace is a CMake configure-time warning](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#65-the-four-gates-on-mlxs-accelerated-quantized-path) — 9.3
- [Failure #2: per-channel-scale palettes lower to rank-6 LUTs — the whole op silently moves to GPU](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#71-the-lookup-table) — 9.3
- [Failure #3: an fp32 operand makes the node fp32 and ANE-ineligible — check Compute types in the model viewer](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#71-the-lookup-table) — 9.3
- [Failure #4: an epsilon fp16 can't represent (1e-6) fails the round-trip predicate — same silent ANE exit](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#71-the-lookup-table) — 9.3
- [Failure #5: F.silu lowers to cast+swish(f32)+cast — three ANE-invalid ops from one call](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#71-the-lookup-table) — 9.3
- [Failure #6: one dynamic dimension breaks the ANE's fully-static-shape requirement — silently ineligible](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#71-the-lookup-table) — 9.3
- [Failure #7: FP8/FP4 weights have no ANE compute path — execution lands on GPU or CPU](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#71-the-lookup-table) — 9.3
- [Failure #11: MLX built below target 26.2 drops all NAX kernels — semi-silent, one configure-time warning](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#71-the-lookup-table) — 9.3
- [Failure #18: coreai_kit.run defaults to cpu_only — benchmarks copying those defaults silently measure the CPU](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#71-the-lookup-table) — 9.3
- [includingStatistics:true is considerably slower on large models — false returns versions and signatures, enough to probe](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#82-aimodelassetsummary--the-same-data-programmatically) — 9.3

**Part 10**

- [ANE-authored model quietly runs on GPU: the coreai-models loader infers compute unit from entrypoint names.](part-10-coreai-hardware-authoring-debugging/README.md#101--authoring-for-the-neural-engine-and-for-the-gpu-two-opposite-rulesets) — 10.README 🔇
- [enable_per_channel_scale=True makes rank-6 tensors that silently push the model off the ANE; it runs and burns battery.](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md#41-max-tensor-rank-is-5) — 10.1 🔇
- [A surviving nn.Linear converts fine but becomes a segmentation point, splitting the graph off the Neural Engine.](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md#45-nnconv2dkernel_size1-instead-of-nnlinear) — 10.1 🔇
- [Odd mask dtype/shape or GQA combo makes PyTorch's dispatcher pick the math backend; the fused SDPA quietly decomposes.](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md#53-native-fused-sdpa) — 10.1 🔇
- [Name entrypoints encode_image/encode_text/predict and the loader classifies your ANE model .dynamic, requesting the GPU.](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md#81-what-this-means-in-practice) — 10.1 🔇
- [CoreAISegmentationEngine re-runs image_encode on every call; the session's 76% caching win needs your own orchestration.](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md#95-️-the-gap-between-the-session-and-the-shipped-runtime) — 10.1 🔇
- [trimKVCache returns -1 whenever extraStates is non-empty, so SSM and hybrid models silently re-prefill every turn.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#45-the-after-trace-and-the-hedge-in-it) — 10.2
- [Changing SpecializationOptions makes a second cache entry, doubling storage and cost; any OS update flushes the cache.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#54-turning-the-trace-into-a-gate-you-can-check) — 10.2
- [nn.functional.silu lowers to cast+swish+cast the ANE cannot run; the graph partitions onto GPU/CPU with no diagnostic.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#56-️-silent-failure--nnfunctionalsilu-on-the-ane) — 10.3
- [enable_per_channel_scale=True can push the model off the Neural Engine, per Apple's own shipped config comment.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#77-the-exploration-loop-if-you-need-one) — 10.3
- [optimize() can hang outright on very large attention graphs.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#92-optimize-is-in-place-and-it-can-hurt-you) — 10.3
- [swift run builds Debug by default; benchmark from a Release build or your numbers measure the wrong thing.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#117-the-cli-tools-for-testing-before-you-write-app-code) — 10.3

## Resource growth

**Part 7**

- [Near-identical SpecializationOptions values each get their own multi-GB cache entry and three-minute stall](part-07-coreai-swift-runtime/README.md#72--specialization-the-model-cache-and-ahead-of-time-compilation) — 7.README 🔇
- [Each concurrent run() allocates its own intermediate buffers on demand — parallelism silently multiplies scratch memory](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#52-️-silent-failure-concurrency-buys-you-memory-you-never-asked-for) — 7.1
- [Every in-flight run() gets its own auto-allocated intermediate buffers — scratch memory grows with no API to bound it](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#52-️-silent-failure-concurrency-buys-you-memory-you-never-asked-for) — 7.1 🔇
- [SpecializationOptions is part of the cache key — every distinct value mints a new multi-GB cache entry](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#151-the-whole-runtime-api-on-one-screen) — 7.1
- [Two slightly different options values: two cache entries, two specializations, two multi-GB copies on disk](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#4-the-cache-key-and-how-to-double-your-disk-usage-by-accident) — 7.2
- [A mutable SpecializationOptions property drifting between code paths silently duplicates multi-GB cache entries](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#4-the-cache-key-and-how-to-double-your-disk-usage-by-accident) — 7.2 🔇
- [Prewarming a host-cache graph would allocate the full static KV cache — gigabytes; prewarm the shape, not the capacity](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#12-dynamic-shapes-re-specialize--bucket-them) — 7.2
- [.fixedSize KV allocates maxContextLength up front — multi-GB on long-context models, and every step gets slower](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#57-kv-cache-strategy--and-the-memory-arithmetic-behind-it) — 7.4

**Part 9**

- [group_size=1 means one LUT per output channel — the LUT overhead is why Apple's presets use 8/16/32](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#32-granularity--two-classes-not-three) — 9.2

**Part 10**

- [AOT is no memory cure: a 1.8 GB ANE monolith loads on iPhone 17 Pro, then the first inference step is jetsam-killed.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#104-when-you-must-aot-compile) — 10.3
- [.fixedSize pre-allocates the KV cache at full maxContextLength; short sessions pay the whole context's memory.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#113-choosing-the-engine) — 10.3

## Precision loss

**Part 9**

- [--n-bits and --group-size override BOTH encoders — passing 4 silently drags the text encoder down from w6/gs8](part-09-coreai-compression-numerics/references/01-quantization.md#136-what-apple-actually-shipped-which-is-not-what-the-talk-showed) — 9.1
- [export.py --n-bits applies to both encoders — 4 silently drags the text encoder from its 6-bit/gs8 default](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#54-the-other-lever-the-sam3-recipe-used-instead) — 9.2
- [fp32 matmuls on MLX's NAX path silently run at TF32 relaxed precision unless MLX_ENABLE_TF32 disables it](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#12-the-master-matrix) — 9.3
- [64-bit types are narrowed on the way in: int64 to int32 and fp64 to fp32, silently](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#35-️-64-bit-types-are-narrowed-on-the-way-in) — 9.3
- [The converter narrows int64/fp64 to 32-bit silently — NDArray has 64-bit ScalarTypes the converter never produces](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#35-️-64-bit-types-are-narrowed-on-the-way-in) — 9.3
- [MLX's own caveat: mxfp8 results differ on <1% of elements and can exceed 1 ULP for small values; nvfp4 matches exactly](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#63-python-signatures) — 9.3
- [MLX float32 matmuls silently run at TF32 on the NAX path — the warn-once PR (#3883) was closed unmerged, so nothing…](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#65-the-four-gates-on-mlxs-accelerated-quantized-path) — 9.3
- [Failure #12: MLX fp32 matmul at default env runs TF32 relaxed precision — set MLX_ENABLE_TF32=0 and diff](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#71-the-lookup-table) — 9.3
- [Failure #15: int64 index tensors are narrowed to int32 — values above INT32_MAX overflow, mostly unclamped](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#71-the-lookup-table) — 9.3

## Misleading signals

**Part 7**

- [Adding .aimodel files without the Metal Toolchain fails the build with a Metal-compiler error that never names Core AI](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#03-the-build-time-footgun-you-will-hit-first) — 7.1
- [A failed AOT load surfaces as 'CoreAIDelegates.AIModelError error 3', re-mapped downstream — the raw code names no cause](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#131-the-answer-stated-precisely) — 7.1
- [Instruments and the debug gauge swap the Load/Specialization colours — colour intuition from one misreads the other](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#what-the-stall-looks-like-in-the-tools) — 7.2
- [The gauge's Open-in-Debugger/Export options don't work for events recorded before its report was open — open it first](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#what-the-stall-looks-like-in-the-tools) — 7.2
- [ANECCompile() FAILED in the console during specialization is not necessarily an error — don't kill the run on first…](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#preferring-a-unit-is-a-preference-not-a-lock) — 7.2
- [A successful compile proves nothing about the architecture — the device is the only validator](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#️-silent-failure--a-successful-compile-proves-nothing-about-the-architecture) — 7.2
- [coreai-build compile exits 0 for any requested arch — the device, not the exit code, validates the choice](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#️-silent-failure--a-successful-compile-proves-nothing-about-the-architecture) — 7.2 🔇
- [std::bad_alloc from a Core AI load on iOS is almost always jetsam — check Console.app and the memory entitlement first](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#143-aot-does-not-fix-memory) — 7.2
- [Metal Toolchain missing: model builds fail with a Metal-compiler error that doesn't point at Core AI](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#152-️-the-metal-toolchain-is-not-installed-by-default) — 7.2
- [The number-one first-contact failure: the missing-toolchain build error blames Metal, and fresh CI runners lack it too](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#152-️-the-metal-toolchain-is-not-installed-by-default) — 7.2
- [Without export-time debug metadata the Source Viewer shows no mapping to your Python — set the env vars before…](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#debugging-state-numerics-not-state-timing) — 7.3
- [CoreAILanguageModel.init never calls verify() — a missing asset surfaces later as a raw Core AI error, not missingAsset](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#22-the-common-envelope-modelbundle) — 7.4
- [metadata.json's compression field records the requested compression, not what was actually applied to the weights](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#211-️-silent-failure--compression-records-the-request-not-the-result) — 7.4
- [Bundle-format table: compression is the request (§2.11) — nothing validates it against the shipped weights](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#212-bundle-format-quick-reference) — 7.4
- [capabilities reports guidedGeneration optimistically before the engine loads — the claim can be false until first use](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#78-️-the-architectural-constraint-guided-generation-and-the-fastest-engine-are-mutually-exclusive) — 7.4 🔇

**Part 8**

- [inspect succeeding is not evidence the asset will compile or load on-device (see the version gate)](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#115-structural-checks-that-need-no-inference) — 8.1
- [Without ENABLE_DEBUG_INFO=1, metadata is silently absent — the Debugger's navigator and source viewer just come up empty](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#125-️-preview-only-environment-variables) — 8.1 🔇
- [Validation is ATen-only: custom torch.library ops pass silently, then to_coreai() fails with a different error](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#34-what-the-validator-deliberately-ignores) — 8.2
- [Externalized bodies are decomposed with a table you didn't choose — clean validation, then a confusing unsupported-op…](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#83-the-five-phase-pipeline-and-why-it-matters-for-debugging) — 8.2
- [Set USE_LOCAL_COREAI and ENABLE_DEBUG_INFO before conversion or profiles simply lack module/source attribution](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md#26-get-a-profile-first) — 8.3
- [Without __HAVE_TENSOR__ the whole MPP header expands to nothing — just a 'no member named matmul2d' error far downstream](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md#115-two-open-questions-at-this-boundary) — 8.3 🔇
- [A bad kernel body is not a conversion error — it fails only at function bind, without any compiler diagnostic](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md#124-️-the-one-that-gets-everybody-a-bad-kernel-body-is-not-a-conversion-error) — 8.3
- [Malformed MSL converts, saves and loads cleanly — the bind-time failure message contains no compiler diagnostic](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md#124-️-the-one-that-gets-everybody-a-bad-kernel-body-is-not-a-conversion-error) — 8.3 🔇

**Part 9**

- [Undefined __HAVE_TENSOR__ empties the whole header — the only symptom is a distant 'no member named matmul2d'](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#54-the-version-ladder--and-why-two-different-numbers-are-both-right) — 9.3
- [The debug gauge needs a direct CoreAI.framework link — reach Core AI through a package and the gauge never appears](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#83-instruments--the-residency-check) — 9.3

**Part 10**

- [Debug gauge appears only with direct CoreAI linking; via a package there is no row, reading as if the model never ran.](part-10-coreai-hardware-authoring-debugging/README.md#102--the-debug-gauge-the-core-ai-instrument-and-the-core-ai-debugger) — 10.README 🔇
- [A package that links CoreAI links it for itself; your app shows no Debug gauge row and no warning explains the absence.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#21-getting-it-to-appear--and-the-failure-mode-when-it-doesnt) — 10.2 🔇
- [More-menu hand-off items only cover events recorded after the report page opened; earlier repros silently lack them.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#25-the-more-menu--and-the-footgun-that-makes-it-useless) — 10.2 🔇
- [Load and Specialization colours swap between Debug gauge and Core AI instrument, so colour intuition misreads traces.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#34-the-four-event-categories) — 10.2 🔇
- [A RELEASE-converted asset opens as a seemingly working Debugger session; the Source Viewer is just absent, unexplained.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#72-which-means-the-source-viewer-has-a-hard-prerequisite) — 10.2 🔇
- [Similarity metrics are per-forward-pass; they cannot certify a decoding loop.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#106-️-the-limit-of-a-similarity-metric) — 10.2
- [An all-green sync-point board can coexist with different generated text: per-step errors compound in the decode loop.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#106-️-the-limit-of-a-similarity-metric) — 10.2 🔇
- [Inside the 0.4.0 incident: tooling reads the broken asset fine, making it look recoverable when it is not.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#152-️-the-silent-failure-inside-the-loud-failure) — 10.2
- [coreai-build inspect parses a 0.4.0-dead asset perfectly; every recovery attempt fails, each costing someone a day.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#152-️-the-silent-failure-inside-the-loud-failure) — 10.2 🔇
- [Audit dead assets by the missing producer field, but .aimodelc bundles always carry one, so use another field for those.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#153-auditing-a-tree--the-producer-fingerprint) — 10.2
- [Without two env vars set at export, the Debugger's navigator has no debug metadata to show.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#66-apples-tooling-save_intermediates-and-the-core-ai-debugger) — 10.3
- [inspect still reads the 0.4.0-dead asset fine, which makes it look recoverable; it is not.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#95-the-producer-fingerprint-and-the-incident-that-made-it-matter) — 10.3
- ['Won't open' hides two gates: the runtime load gate is OS-side, the authoring parse gate is in the wheel.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#95-the-producer-fingerprint-and-the-incident-that-made-it-matter) — 10.3
- [coreai-build compile exits 0 for any requested architecture; only a device load validates the choice.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#103-️-architecture-names-track-the-device-identifier-not-the-marketing-name) — 10.3
- [A compile that exits 0 and an asset that loads on device are different claims; validate by loading.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#103-️-architecture-names-track-the-device-identifier-not-the-marketing-name) — 10.3
- [.aimodel dirs embedded in an app bundle fail as 'invalid bundle', and a root Resources/ folder breaks code signing.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#107-two-device-integration-traps-that-have-nothing-to-do-with-ml) — 10.3
- [The 'growing strategy' error tells you to re-export with --dynamic-sized-kvcache-gpu, a flag no shipped CLI has.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#113-choosing-the-engine) — 10.3

## Version drift

**Part 7**

- [The artifact is not a function of the recipe — the exporting machine's OS changes what you ship](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#163-️-the-artifact-is-not-a-function-of-the-recipe) — 7.2
- [Same command, same weights: artifacts exported on different host OSes differ ~2x in throughput and memory on-device](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#163-️-the-artifact-is-not-a-function-of-the-recipe) — 7.2 🔇
- [Commit 102f832 renamed CoreAIRunner(from:) to init(bundle:) and the metrics setters — week-old snippets no longer…](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#41-coreairunner--bundle-in-engine-out) — 7.4
- [Same recipe and wheels export a 2.2x faster artifact on macOS 26 than on the 27 beta — quantized-Linear lowering…](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#59-what-the-engines-actually-measure) — 7.4
- [HEAD renamed LanguageModelCapabilities(capabilities:) to an unlabelled init — conformances against older SDKs break](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#82-capabilities-are-auto-detected-from-the-tokenizer) — 7.4

**Part 8**

- [OS 27 beta 2 refuses .aimodel files converted with coreai-torch v0.4.0 — published assets must be reconverted with 0.4.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#23-️-the-version-gate-that-invalidates-already-published-assets) — 8.1
- [input_names/output_names no longer cover buffers — pre-release conversion scripts now fail the count check](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#72-the-parameters-and-the-breaking-change) — 8.1
- [Omitted I/O names get FX placeholder defaults — an implementation detail, not a contract, that changes across PyTorch](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#73-️-what-you-get-if-you-omit-the-names--and-why-it-is-not-a-contract) — 8.1
- [A PyTorch upgrade renames auto-generated keys or rebinds them to different tensors — pass explicit names everywhere](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#73-️-what-you-get-if-you-omit-the-names--and-why-it-is-not-a-contract) — 8.1 🔇
- [v0.4.0-converted artifacts fail to load from OS 27 beta 2 — reconvert with coreai-torch v0.4.1 or later](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#when-an-op-will-not-convert-coverage-composite-ops-custom-lowerings-externalization) — 8.2
- [Quantized-kernel APIs are narrower than session 330 suggests — the feature ladder is per-point-release](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md#114-️-version-reality-for-quantized-kernels) — 8.3

**Part 9**

- [Scalar palettization is reproducible; vector palettization is not — identical builds differ](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#71-️-scalar-palettization-is-reproducible-vector-palettization-is-not) — 9.2
- [A vector-palettized model differs every rebuild of the identical commit — golden-hash regression tests fail mysteriously](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#71-️-scalar-palettization-is-reproducible-vector-palettization-is-not) — 9.2 🔇

**Part 10**

- [Working pins: coreai-torch 0.4.1+, torch 2.9.0; letting uv bump torch to 2.11 breaks torchvision, killing every export.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#155-the-environment-that-avoids-the-whole-problem) — 10.2 🔇
- [Breaking change vs pre-release code: input_names now also covers state names; older export scripts mis-bind.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#85-what-the-converter-treats-as-state--and-the-opt-out-that-doesnt-exist) — 10.3
- [Running python from the coreai-torch clone shadows 0.4.1 with 0.4.0 egg-info; exports silently use the broken version.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#95-the-producer-fingerprint-and-the-incident-that-made-it-matter) — 10.3
- [The package pins mlc-ai/xgrammar to branch main, not a version; resolve and commit your own revision.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#111-the-whole-integration) — 10.3
- [The fork snapshots an older upstream; commit 04a3fd6 upstream already stops pipelined generation when the stream drops.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#134-the-related-multi-turn-bug-worth-knowing-about-regardless) — 10.3
- [After the pin, coreai-models dropped .llmasset and rewrote KV-cache primitives; pinned examples no longer match HEAD.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#181-primary--shipping-source-read-this-session) — 10.3

## Docs vs reality

**Part 7**

- [Doc pages mark three runtime inits watchOS-unavailable while the captured SDK interface declares all three watchOS 27.0](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#aimodel-inferencefunction-ndarray-and-the-memory-model) — 7.1
- [Delete-while-referenced: reference pages say an error is thrown, the article says deletion is silently deferred](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#34-aimodel-is-sendable-and-that-is-not-free-advice) — 7.1
- [Docs cite layout.scalarCount, which is not public API — an internal-doc leak; compute the element count yourself](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#82-the-three-ways-to-get-data-in) — 7.1
- [Apple's two image-preprocessing files disagree: premultipliedLast vs noneSkipLast alpha, and one resize is square-only](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#123-the-cgimage--tensor-recipe-from-apples-package) — 7.1
- [metadata.platforms omissions are a docs bug; doc watchOS-unavailable notes contradict the captured SDK interface](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#163-open-questions--updated-2026-07-29-against-the-sdk-interface-dump) — 7.1
- [Orphaned aside on model(for:options:) is a truncated Throws clause mis-rendered as a Note on three API pages](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#a-production-shaped-version) — 7.2
- [Reference pages and the caching article give opposite answers on deleting an entry a live AIModel still uses](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#️-the-contradiction) — 7.2
- [deleteEntry(referencedBy:) repeats the contradictory live-AIModel deletion NOTE — release the model before deleting](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#deleting-by-bookmark) — 7.2
- [coreai-build is not in Xcode-beta.app — it ships in the optional Metal Toolchain component; xcrun caches the miss](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#the-cli-in-one-block) — 7.2
- [The AsyncValue overview's second example does not compile as written](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#apples-own-two-stage-example) — 7.3
- [BundleKind has four cases while the repo ships six model families — the mapping is not one-to-one](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#29-️-bundlekind-has-four-cases-and-the-repo-ships-six-model-families) — 7.4
- [The shipped SpeechModel actor needs a split bundle no exporter produces — whisper export emits one monolithic .aimodel](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#29-️-bundlekind-has-four-cases-and-the-repo-ships-six-model-families) — 7.4
- [CoreAILanguageModel.init's own doc comment contradicts what the code does — a documentation trap](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#58-choosing-an-engine-the-decision-table) — 7.4

**Part 8**

- [The 'three preserved ops' claim is wrong as commonly stated — see the corrected preserved-op list](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#42-️-correction-to-the-three-preserved-ops-claim) — 8.1
- [Naming parameters are keyword-only; the API doc renders them positionally — positional calls raise TypeError](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#51-add_exported_program--you-own-the-export) — 8.1
- [export_fn is keyword-only and required — the API doc shows it positionally and with no hint that it has no default](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#52-add_pytorch_module--the-converter-owns-the-export) — 8.1
- [Apple material shows both runner(**inputs) and runner(dict) calling conventions — pick the dict form the tests use](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#71-the-round-trip-in-both-languages) — 8.1
- [Session 325 says 4-bit on both encoders; the shipped recipe is asymmetric (image w4/gs32, text w6/gs8)](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#103-what-session-325-says-the-split-buys-you) — 8.1
- [TorchConverter's mode= parameter is real but absent from the API doc — as is the strip_debug_info escape hatch](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#121-the-switch-torchconvertermode) — 8.1
- [Docstring examples still call dump_intermediates — the exported symbol is save_intermediates; suffix is validated](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#124-the-reference-comparison-workflow-this-enables) — 8.1
- [generate-composite-decl docs name the wrong parameter (op_name), omit version, and misstate the return type](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#76-emitting-a-composite-from-a-custom-lowering) — 8.2 🔇
- [Apple ships GatedDeltaUpdate with composite_attrs=[] — the doc page's attribute list does not match the shipped spec](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#85-what-apple-actually-externalizes) — 8.2
- [TorchConverter.md renders keyword-only params positionally and omits mode= — code written from the doc raises TypeError](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#111-api-surface-used-in-this-guide) — 8.2
- [The shipped SAM3 export does not contain session 330's FlashAttention kernel — there is no code to copy](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md#113-the-sam3-flashattention-integration-as-narrated) — 8.3

**Part 9**

- [The session transcript's claim about EAGER mode does not match the shipped behavior — a discrepancy worth knowing](part-09-coreai-compression-numerics/references/01-quantization.md#33-the-transcripts-one-liner-and-the-correction) — 9.1
- [Talk says 4-bit on the two encoders; the shipped recipe is asymmetric — image w4/gs32, text w6/gs8](part-09-coreai-compression-numerics/references/01-quantization.md#136-what-apple-actually-shipped-which-is-not-what-the-talk-showed) — 9.1
- [Talk says per-channel scales; the shipping recipe sets enable_per_channel_scale=False and uses grouped-channel…](part-09-coreai-compression-numerics/references/01-quantization.md#136-what-apple-actually-shipped-which-is-not-what-the-talk-showed) — 9.1
- [Return value vs in-place mutation: Apple's own docs give both readings of the casting passes](part-09-coreai-compression-numerics/references/01-quantization.md#142-️-return-value-vs-in-place-mutation--a-documented-conflict) — 9.1
- [One doc says the casting passes mutate in place and return nothing; the signatures return ExportedProgram — a conflict](part-09-coreai-compression-numerics/references/01-quantization.md#142-️-return-value-vs-in-place-mutation--a-documented-conflict) — 9.1
- [Framework page lists seven platforms; every symbol page's platform array omits macOS and Catalyst — a docs-generation…](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#31-the-full-enum-grouped) — 9.3
- [Session 325 narration says per-channel scales; shipped code sets enable_per_channel_scale=False — both readings are live](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#42-️-silent-failure--a-bare-python-float-literal-can-move-an-op-to-the-gpu) — 9.3

**Part 10**

- [Apple's skill file recommends einsum SDPA; the shipped iOS code uses per-head permute plus matmul instead.](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md#410-per-head-attention-there-is-no-fused-sdpa) — 10.1
- [from_source_model appears only in skill files; shipped coreai-models uses task-specific factories like from_hf.](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md#63-the-factory-classmethod-convention) — 10.1
- [The WWDC session's segmentation caching story does not match what the shipped CoreAISegmentationEngine does.](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md#95-️-the-gap-between-the-session-and-the-shipped-runtime) — 10.1
- [The 76% second-inference figure omits device and warm-up protocol, and the shipped engine lacks the caching it assumes.](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md#123-attribution-of-every-number-in-this-guide) — 10.1
- [TorchConverter's API doc shows a bare constructor and never mentions the real mode parameter.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#71-the-converter-records-it-on-purpose-by-default) — 10.2
- [The talk recommends EAGER for weight compression; the repo's recommended default is GRAPH - each fits different jobs.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#113-the-compression-in-one-line) — 10.2
- [Talk says 4-bit with per-channel scales on both encoders; the shipped recipe is asymmetric w4/gs32, w6/gs8 without.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#117-the-result-and-the-claim) — 10.2
- [The maintainer's snippet assigns strip_debug_info's return value, but it returns None; use the statement form.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#154-the-fix-from-the-maintainer) — 10.2
- [Community audit counts 21 export recipes vs this guide's table; likely timing - run --list rather than trusting either.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#21-what-is-in-the-catalog) — 10.3
- [coreai.llm.eval is declared in project.scripts but unconditionally errors with 'Evaluation support is coming soon'.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#26-three-gotchas-in-the-easy-road) — 10.3
- [This contradicts WWDC26 325:241's 'with per-channel scales'; the shipped code sets it False and wins.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#77-the-exploration-loop-if-you-need-one) — 10.3
- [coreai-build ships in the Metal Toolchain, not Xcode's app bundle; CI with only aimodelc cannot invoke it.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#102-the-compile-command) — 10.3
- [COREAI_CHUNK_THRESHOLD is a memory dial and Apple's hint points the wrong way on a high-RAM Mac.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#143-️-coreai_chunk_threshold-is-a-memory-dial-and-apples-hint-is-backwards-on-a-big-mac) — 10.3
- [Session 325:241's 'per-channel scales' conflicts with the shipped recipe; the shipped code wins.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#182-apple-spoken) — 10.3

## API footguns

**Part 7**

- [Python load_function raises KeyError for a missing name; Swift returns nil — ported parity tests change shape](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#41-the-distinction-stated-by-apple) — 7.1
- [preferredStrides/minimumByteCount on an unresolved dynamic descriptor is a programming error — resolve dimensions first](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#64-ndarraydescriptor-and-the--1-sentinel) — 7.1
- [shape/strides come back as Span<Int>: no map/reduce/for-in — the obvious element-count reduce does not compile](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#75-️-span-does-not-conform-to-sequence) — 7.1
- [Span is non-escapable and not a Sequence — shape.reduce(1,*) does not compile; write your own product helper](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#75-️-span-does-not-conform-to-sequence) — 7.1
- [NDArray.RawView init(metalBuffer:) is explicitly unsafe aliasing and absent on watchOS — you own the synchronization](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#77-the-raw-views-mtlbuffer-and-iosurface-interop) — 7.1
- [InferenceValue.ndArray is a consuming read dressed as a getter — a nil-check consumes the value](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#92-️-inferencevaluendarray-is-a-consuming-read-wearing-a-getters-clothes) — 7.1
- [The ndArray property consumes the InferenceValue on first access despite reading like a plain getter](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#92-️-inferencevaluendarray-is-a-consuming-read-wearing-a-getters-clothes) — 7.1
- [if value.ndArray != nil consumes the value — the later real read then yields nothing](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#92-️-inferencevaluendarray-is-a-consuming-read-wearing-a-getters-clothes) — 7.1
- [&stateArrays[name]! per iteration force-unwraps under exclusivity checking — use stored properties or a ~Copyable box](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#103-️-you-must-supply-a-view-for-every-state) — 7.1
- [Segment.box origin flips per platform — Apple's decoder flips Y on macOS; assuming one convention misplaces every box](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#125-one-more-coordinate-trap-for-completeness) — 7.1
- [catch let error as AssetError placed after a bare catch compiles but never runs — keep the bare catch last](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#132-the-practice-catch-asseterror-then-catch-broadly-log-richly-degrade) — 7.1
- [Cheat sheet: InferenceValue.ndArray is a consuming read — access it once](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#151-the-whole-runtime-api-on-one-screen) — 7.1
- [NamedMutableViews.take is single-shot — a second take of the same name is fatal](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#151-the-whole-runtime-api-on-one-screen) — 7.1
- [NDArray(descriptor:) may allocate a non-contiguous, hardware-preferred layout — do not assume row-major bytes](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#151-the-whole-runtime-api-on-one-screen) — 7.1
- [shape/strides are Span<Int>, which is not a Sequence — no reduce/map/for-in](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#151-the-whole-runtime-api-on-one-screen) — 7.1
- [Write through mutatingSlice(at:) — other slice accessors do not write back to the array](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#151-the-whole-runtime-api-on-one-screen) — 7.1
- [view(as:) is consuming — taking a typed view ends the tensor's other uses](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#151-the-whole-runtime-api-on-one-screen) — 7.1
- [view<T>(as:) on a mutable array returns a MUTABLE view — writes go through even where you expected a read](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#151-the-whole-runtime-api-on-one-screen) — 7.1
- [minimumByteCount is a programming error while hasDynamicShape — resolve dimensions first](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#151-the-whole-runtime-api-on-one-screen) — 7.1
- [preferredStrides likewise traps on an unresolved dynamic descriptor](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#151-the-whole-runtime-api-on-one-screen) — 7.1
- [AssetError covers ASSET operations only — inference and cache failures throw other, mostly untyped errors](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#151-the-whole-runtime-api-on-one-screen) — 7.1
- [PreparedModel.clearCache(at:) is coreai-models sample API keyed on a bundle path, not an AIModelCache framework method.](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#71-how-apples-own-tools-clear-the-cache--and-the-measurement-pattern-worth-stealing) — 7.2
- [availableKinds varies by device but not by model — a present Neural Engine says nothing about your graph's eligibility](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#availablekinds--check-before-you-prefer) — 7.2
- [Inside withUnsafeMutablePointer the shape/strides are Span<Int> — not a Sequence, so no reduce; ship a product helper](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#52-ndarraydescriptor-gives-you-the-layout-the-hardware-wants) — 7.3
- [.aimodel and .aimodelc are directories, not files — file-oriented copy, zip and signing steps mishandle them](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#23-️-aimodel-and-aimodelc-are-directories) — 7.4
- [autoDetectVariant calls preconditionFailure on an unrecognized bundle — it crashes rather than throwing](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#52-the-three-variants-and-how-one-is-chosen) — 7.4
- [Engine variant is a String?, not an enum — the Variant type is private, so typos cannot be caught at compile time](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#58-choosing-an-engine-the-decision-table) — 7.4
- [rollback() is @discardableResult and fallible; over-budget calls return false and silently leave grammar state unmoved.](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#731-three-additions-at-49becc6--and-what-they-tell-you-about-where-this-is-going) — 7.4
- [fillBitmask(into:) states its buffer-size contract only in a doc comment; an undersized pointer writes out of bounds…](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#731-three-additions-at-49becc6--and-what-they-tell-you-about-where-this-is-going) — 7.4
- [Sampling applies minP before topP before topK — not the order most stacks use, so identical settings sample differently](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#91-samplingconfiguration--the-declarative-half) — 7.4
- [SamplingConfiguration.init preconditions, not throws — a topP of 0 from a config or slider crashes the app](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#91-samplingconfiguration--the-declarative-half) — 7.4
- [DecodingType has exactly one case (.vanilla) — the factory and builder cannot select any custom decoding strategy](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#93-what-bring-your-own-sampling-strategy-actually-means) — 7.4
- [Engine selection is only via the variant string — the Variant enum is private and unvalidated at compile time](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#94-what-you-cannot-override) — 7.4

**Part 8**

- [Coverage is per-overload — support for one overload of an op proves nothing about its siblings](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#22-️-the-overload-rule-stated-plainly) — 8.2
- [mean.dim converts, mean.names_dim doesn't; sum.dim_IntList converts, sum.default is absent from the table entirely](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#22-️-the-overload-rule-stated-plainly) — 8.2 🔇
- [torch.export.default_decompositions() makes conversion fail — only Apple's get_decomp_table() works](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#33-️-the-get_decomp_table-trap--using-the-wrong-table-makes-conversion-fail) — 8.2
- [The default torch decomposition table yields unsupported ops — conversion fails; use get_decomp_table() instead](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#33-️-the-get_decomp_table-trap--using-the-wrong-table-makes-conversion-fail) — 8.2 🔇
- [gather_mm indices must be unsigned ints while torch.topk returns int64 — PyTorch won't complain about the mismatch](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#61-gather_mm-is-mixture-of-experts-expert-dispatch) — 8.2
- [Lowering overrides are per-converter-instance and invisible in output — a shared converter object carries hidden…](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#73-allow_overridetrue--replacing-a-built-in) — 8.2 🔇
- [Registration ordering matters, and the rule is subtler than 'always register first'](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#75-️-registration-ordering--the-rule-is-subtler-than-always-first) — 8.2
- [Composite input_names are parameters and buffers first, then forward args — not your forward signature order](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#84-requirements-for-composite-op-modules) — 8.2
- [Template substitution is textual — every occurrence of TYPE is replaced, including comments, strings, and MY_TYPE](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md#101-template_dtypes) — 8.3
- [Templating covers the type, not literals — TYPE sum = 0.0f breaks integer instantiations; template ZERO per dtype too](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md#101-template_dtypes) — 8.3
- [torch_defn is traced with FakeTensors — any value read like int(idx[i]) or .item() breaks; keep gathers shape-static](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md#131-the-win-a-gather_qmm-kernel-for-mixture-of-experts-decode) — 8.3

**Part 9**

- [GRAPH and EAGER are separate implementations with different configs and bugs — not guaranteed to produce equivalent…](part-09-coreai-compression-numerics/README.md#91--coreai-opt-quantization-configs-graph-vs-eager-calibration-and-qat) — 9.README 🔇
- [A field set to None is not the same as omitting it — the two spell different quantization configs](part-09-coreai-compression-numerics/references/01-quantization.md#43-️-none-is-not-the-same-as-omitting-the-field) — 9.1
- [Graph and eager modes do not produce equivalent quantized models — switching modes changes numerics](part-09-coreai-compression-numerics/references/01-quantization.md#83-️-the-two-modes-do-not-produce-equivalent-models) — 9.1
- [Graph mode overrides six ops' qschemes for backend correctness — eager mode performs none of these adjustments](part-09-coreai-compression-numerics/references/01-quantization.md#95-the-six-ops-whose-qscheme-the-framework-overrides) — 9.1
- [palettize_weights' lut_dtype is positional #2 with no default — docs pass it as a keyword, hiding the trap; XOR rules…](part-09-coreai-compression-numerics/references/01-quantization.md#151-the-api) — 9.1
- [PerTensorGranularity exists twice with the same spelling in different modules — importing the wrong one misconfigures](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#32-granularity--two-classes-not-three) — 9.2
- [lut_dtype is positional #2 with no default — pass positionally and your n_bits lands in the lut_dtype slot](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#121-palettize_weights) — 9.2
- [uv run implicitly syncs and can clobber group-pinned venv packages — Apple's own AGENTS.md says always pass --no-sync](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#181-the-four-mnist-notebooks) — 9.2
- [Import the palettization PerTensorGranularity — not the identically-named quantization one](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#211-imports) — 9.2

**Part 10**

- [The most common first mistake: pointing a runner at the inner .aimodel when it wants the bundle directory.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#12-what-a-bundle-actually-is) — 10.3
- [macOS wants keyCache/valueCache, iOS wants key_cache/value_cache; copying a name across targets fails at load, loudly.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#33-the-iosane-graph-contract--four-entrypoints) — 10.3
- [The coreai-models auto-detect loader crashes on segmenter or speech assets instead of throwing a usable error.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#35-the-optional-sample-loader-maps-structure-to-a-compute-unit-preference) — 10.3
- [Model output buffers are only valid inside the async with block; call .numpy() before the context exits.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#64-gate-a--graph-parity) — 10.3
- [AOT arch strings track device identifiers, not marketing names; a name-matched guess produces an asset that won't load.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#103-️-architecture-names-track-the-device-identifier-not-the-marketing-name) — 10.3
- [expectFrequentReshapes=true on an all-static graph abandons the AOT specialization and segfaults with no error string.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#105-️-silent-ish-failure--expectfrequentreshapes-on-a-fixed-shape-graph) — 10.3
- [Mistral tool-call detection synthesizes a newline close marker; a multi-line [TOOL_CALLS] array breaks the parser.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#115-what-the-fm-adapter-does-and-does-not-forward) — 10.3
- [ModelBundle.verify() runs only in the llm-runner CLI, not in init; a broken assets map surfaces later, in your app.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#117-the-cli-tools-for-testing-before-you-write-app-code) — 10.3
- [position_ids must be the full 0..total-1 vector every call, not just new positions, or RoPE indexing silently breaks.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#154-the-kv-cache-trick-and-the-position_ids-contract-it-implies) — 10.3

## General cautions

**Part 7**

- [Part-wide evidence note: verify signatures against the SDK dump — Core AI ships no Apple sample code](part-07-coreai-swift-runtime/README.md#️-read-this-before-you-trust-a-signature-in-this-part) — 7.README
- [Scope note: signatures rest on doc prose and shipped repos, not Apple sample code — verify before relying](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#️-read-this-before-you-trust-a-single-signature-below) — 7.1
- [Community swift-lm hand-rolls an async mutex for run serialization — single-author alpha code, not Apple guidance](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#53-what-is-not-safe) — 7.1
- [Xcode's model viewer shows ? for a dynamic dimension; NDArrayDescriptor.shape reports -1 — same fact, two spellings](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#64-ndarraydescriptor-and-the--1-sentinel) — 7.1
- [Community input validator: check unexpected/missing inputs, scalarType, rank, and per-axis -1-or-equal before run()](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#65-a-reusable-validator) — 7.1
- [run() requires a mutable view for every state — omitting any state is an error; drive allocation from stateNames](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#103-️-you-must-supply-a-view-for-every-state) — 7.1
- [Community state allocation: MTLBuffer sized by minimumByteCount with .storageModeShared, then memset to zero](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#minimumbytecount-for-manual-allocation) — 7.1
- [Community swift-lm defines rich typed asset errors (shape/dtype/state mismatches) the Apple runtime does not give you](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#134-what-the-rest-of-the-stack-throws-for-contrast) — 7.1
- [Core AI has zero Apple sample-code projects (0 of 312 symbols) — evidence is doc prose and shipped repos only](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#specialization-the-model-cache-and-ahead-of-time-compilation) — 7.2
- [specialize() and init have no progress, stages, or cancellation contract — your Preparing UI must be indeterminate](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#where-to-actually-call-it) — 7.2
- [Compile-time figures are single-author beta measurements — trust the shape (jetsam can kill compilation), not the…](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#143-aot-does-not-fix-memory) — 7.2
- [Throughput figures here are one community author plus one shipping app, self-declared uncontrolled — attribute…](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#162-community-measured) — 7.2
- [Verified absences: /documentation/updates/coreai 404s and the Updates hub carries no Core AI entries](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#primary--apple-documentation-strongest-doc-class-evidence-there-is-no-sample-code) — 7.2
- [Whole block is community-measured on beta software under uncontrolled conditions — cited because nothing else exists](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#community--valuable-uniquely-detailed-and-not-apple) — 7.2
- [Part-wide evidence weighting: zero Apple sample code — claims rest on docs, shipped repos, and attributed community work](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#states-as-kv-cache-and-pipelined-execution) — 7.3
- [Apple ships 21 export recipes but zero performance numbers — the community bench table is the only data, treat as such](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#what-the-published-numbers-do-support) — 7.3
- [Pipelined Core AI ties/beats MLX on dense models — but it's int8 vs 4-bit, a ship-config comparison, not iso-precision](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#what-the-published-numbers-do-support) — 7.3
- [Whole section is one author's incident report (FB23024751, issue #5) — rigorous isolation, uncontrolled benchmarks](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#13-the-mpsgraph-in-graph-kv-write-bug) — 7.3
- [Noema's host-cache design: KV rides as plain I/O because the ANE compiler rejects in-graph indexed KV writes](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#workaround-1--host-cache-the-kv) — 7.3
- [Write-mask workaround status: Mac GPU verified; iPhone GPU and ANE re-isolation still pending](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#workaround-2--the-input-mask-escape) — 7.3
- [Prefix-reuse section is a community fork of coreai-models — mechanism corroborated upstream, API and numbers are not](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#14-prefix-reuse-one-integer-assignment-101) — 7.3
- [Community trimKVCache drains in-flight generation first, then clamps the processed-token counter — nothing is cleared](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#the-insight--nothing-has-to-be-cleared) — 7.3
- [trimKVCache protocol default returns -1 (unsupported) so callers degrade safely to full re-prefill](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#the-api-contract-and-its-one-subtlety) — 7.3
- [Caller algorithm: track the exact fed token sequence and clamp reuse to commonPrefixLength minus one](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#the-caller-side-algorithm) — 7.3
- [Prefix-reuse numbers: qwen3-0.6b on an unstated Mac model and OS — treat the hardware as unverified](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#the-numbers) — 7.3
- [The model-selection conclusion derives from one community implementation — not an Apple claim](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#️-the-constraint-that-changes-model-selection) — 7.3
- [Known limits: the pipelined trim path is unverified (SIGTRAPs in GrowingLogitsBuffer); short chats see little gain](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#where-this-stands-today) — 7.3
- [Numerics debugger pairs only iOS/iPadOS/macOS 27+ — no visionOS, tvOS or watchOS despite framework support](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md#debugging-state-numerics-not-state-timing) — 7.3
- [Evidence note: zero Apple sample code — this guide rests on the shipped apple/coreai-models source read line-by-line](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#model-bundles-the-llm-engines-and-grammar-constrained-decoding) — 7.4
- [Apple's own code disagrees on VLM sub-model loading (sequential vs async let) — load sequentially until resolved](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#43-modelresources--lazy-loading-shared-engines-borrow-safe-unload) — 7.4
- [All of §6.3-6.4 is community work: a 3-file fork commit on a pre-SAM3 snapshot, not upstream Apple code](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#63-trimkvcache--the-community-primitive-apples-protocol-lacks) — 7.4
- [The structure-to-compute mapping is apple/coreai-models loader policy, not a Core AI framework routing contract](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md#non-llm-engines-bundles-function-structure-warmup-specialization-and-caching) — 7.5

**Part 8**

- [Series-wide evidence note: zero Apple sample code — guides rest on shipped repo source, docs prose, and SDK dumps](part-08-coreai-pytorch-conversion/README.md#part-8--core-ai-converting-a-model-from-pytorch) — 8.README
- [Evidence note: no Apple sample code — strongest sources are the shipped coreai-torch/models/optimization repos](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#torchexport-to-aimodel-and-the-io--state--dynamic-shape-contract) — 8.1
- [The Neural Engine path threads K/V as plain I/O, not Core AI state — register_buffer KV advice is GPU-only](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#96-what-the-swift-side-expects) — 8.1 🔇
- [AIModelAsset.load only reads the header — compilation and its cost land lazily inside the executable() context manager](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#111-the-reference-implementation-verbatim) — 8.1
- [The standing gate: convert twice (optimize on/off), run both at real shapes, fail the build on output divergence](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#114-️-the-optimizetrue--optimizefalse-gate) — 8.1
- [Gate with realistic inputs — issue #49 does not reproduce on 17x23 rectangles, only on square production shapes](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#114-️-the-optimizetrue--optimizefalse-gate) — 8.1
- [Preview-only env vars gate debug metadata — set them before conversion or tooling loses attribution](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#125-️-preview-only-environment-variables) — 8.1
- [The pipeline listing is a toy exercising every contract — run the optimize gate separately at your real shapes](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#133-the-complete-pipeline-in-one-block) — 8.1
- [Scope note: how far MoE gather_mm support does not extend — read before assuming coverage](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#63-️-how-far-that-support-does-not-extend) — 8.2
- [MoE on GPU/ANE delegates is combination-dependent — Qwen3-MoE ships, but support is not universal](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#63-️-how-far-that-support-does-not-extend) — 8.2
- [Externalization needs the live nn.Module via add_pytorch_module — add_exported_program has no externalization path](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#82-externalizespec) — 8.2
- [Externalization is not weight streaming — it neither reduces export RAM nor mmaps; that is a separate PyTorch technique](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#86-the-real-motivations--and-one-terminology-collision-to-defuse) — 8.2
- [One word, two mechanisms: ExternalizeSpec preserves op boundaries; multi-entrypoint conversion splits programs](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#86-the-real-motivations--and-one-terminology-collision-to-defuse) — 8.2
- [Design gate inputs to break symmetry: asymmetric shapes, values straddling zero and above 10, large integers](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md#102-the-four-gates-every-converted-model-should-pass) — 8.2
- [Read first: zero Apple sample code for Core AI — kernel guidance rests on shipped coreai-torch source and tests](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md#torchmetalkernel-writing-and-embedding-a-custom-metal-kernel) — 8.3
- [Apple's own end-to-end custom-kernel tests are currently disabled — device coverage is thinner than the suite implies](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md#125-️-apples-own-end-to-end-kernel-tests-are-currently-disabled) — 8.3
- [Community figures here are single-author, self-declared uncontrolled, on beta OSes — attribute, never launder](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md#174-community--attributed-never-presented-as-apple) — 8.3

**Part 9**

- [Evidence ladder note: zero Apple sample code — shipped repo source outranks docs and talks throughout this part](part-09-coreai-compression-numerics/README.md#part-9--core-ai-compression-and-numeric-formats) — 9.README
- [Evidence note: no Apple sample code — quantization claims rest on coreai-opt source and shipped recipes](part-09-coreai-compression-numerics/references/01-quantization.md#coreai-opt-quantization-configs-graph-vs-eager-calibration-and-qat) — 9.1
- [Table of contents pointer to the consolidated silent-failures section](part-09-coreai-compression-numerics/references/01-quantization.md#contents) — 9.1
- [The 'dynamic' range calculator cannot be exported — finalize() raises NotImplementedError naming each affected module](part-09-coreai-compression-numerics/references/01-quantization.md#65-the-three-pluggable-classes-and-the-one-that-cannot-be-exported) — 9.1
- [Annotation limits: chains longer than 2 raise, and sequential matching requires each op type in the chain to be unique](part-09-coreai-compression-numerics/references/01-quantization.md#87-how-graph-mode-decides-what-to-annotate) — 9.1
- [Archive holds opposite int8 orderings for different tensor roles — int8 is the safe floor; which int8 is empirical](part-09-coreai-compression-numerics/references/01-quantization.md#102-the-bit-width-ladder-and-where-it-breaks) — 9.1
- [Consolidated index of this guide's quantization silent failures](part-09-coreai-compression-numerics/references/01-quantization.md#17-️-silent-failures-consolidated) — 9.1
- [The talk's third row has no number — 'a fraction of the size' is unquantified; don't invent one](part-09-coreai-compression-numerics/references/01-quantization.md#184-sam3--apple-published-wwdc26-session-325) — 9.1
- [Evidence note: no Apple sample code — palettization claims rest on coreai-opt source and Apple's shipped recipes](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#palettization-pruning-joint-compression-and-mixed-precision) — 9.2
- [Contents pointer: the ANE rank-5 ceiling section](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#contents) — 9.2
- [Contents pointer: consolidated silent failures](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#contents) — 9.2
- [Beta-era measurement with an identified but unconfirmed mechanism — record toolchain versions with every sweep result](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#154-the-aimodel-is-a-build-artefact-not-a-pure-function-of-the-recipe) — 9.2
- [Two opposite int4/int8 findings measured at different dates on different roles — do not flatten them into one rule](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#171-dense-int4-k-means-what-the-archive-actually-found) — 9.2
- [Author's caveats: quick-driver tok/s ~10x too slow, only the ratio is valid; flagship int4 has a known quality cost](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#171-dense-int4-k-means-what-the-archive-actually-found) — 9.2
- [The one-flag experiment is one author's result on one model family — verify on your own model before adopting](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#173-the-free-17-that-everyone-leaves-on-the-table) — 9.2
- [128 eval samples: a 1.5-point difference is inside noise — trust the ordering, not the magnitudes](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#182-the-four-example-pages) — 9.2
- [Consolidated index of palettization/pruning silent failures](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#19-️-silent-failures-consolidated) — 9.2
- [ResNet50 PTQ numbers rest on 128 eval samples (896 calibration) — indicative, not conclusive](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#201-apple-published) — 9.2
- [Community table is a single-author archive with self-declared uncontrolled benchmarks — not Apple figures](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#202-community-measured--notesreposjohn-rocky-modelsmd) — 9.2
- [2.18x dense-int4km ratio: author says absolute tok/s are ~10x too slow — only the ratio is valid](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md#202-community-measured--notesreposjohn-rocky-modelsmd) — 9.2
- [Evidence note: no Apple sample code — the format matrix rests on SDK headers, shipped source, and doc prose](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#int4-to-mx-which-layer-supports-which-numeric-format) — 9.3
- [Contents pointer: consolidated silent failures](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#contents) — 9.3
- [Matrix legend: warning-marked cells are supported only with the caveat named in the referenced section](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#12-the-master-matrix) — 9.3
- [int16 sits in the TensorOps enum but the Metal-language type map has no int16 mapping — the int16 oddity](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#12-the-master-matrix) — 9.3
- [uint8 on the ANE is uncertain — Apple's rule file names only fp16/int8/int16 as ANE compute dtypes](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#12-the-master-matrix) — 9.3
- [int4 is storage, not compute — the int4b_format Metal type is gated behind a feature macro](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#12-the-master-matrix) — 9.3
- [uint4 mirrors int4: storage-only, with the same Metal feature-macro gate](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#12-the-master-matrix) — 9.3
- [MXFP4 emit is validator-enforced: per-block-32 with E8M0 scales, or ValueError — nothing else counts as MXFP4](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#12-the-master-matrix) — 9.3
- [k-means palettes: eager-mode only, with a caveat on the recipe path (§2.5) — indices store as sub-byte ints](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#12-the-master-matrix) — 9.3
- [Apple accepted a known quality regression to avoid a silent compute-unit fallback — the ranking this guide argues for](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#42-️-silent-failure--a-bare-python-float-literal-can-move-an-op-to-the-gpu) — 9.3
- [Two different version numbers are both correct — they answer different questions; report both, not one](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#54-the-version-ladder--and-why-two-different-numbers-are-both-right) — 9.3
- [OS 27 multi-plane tensors: compute/render usage only, one-byte data elements, no rank-0 — keep a software fallback](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#55--xcode-27-auxiliary-scale-planes-and-automatic-dequantization) — 9.3
- [No API reports NAX support — MLX infers it from GPU architecture generation; there is no supportsFamily query](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#56-tensorops-is-portable-not-m5-only--and-there-is-no-capability-query) — 9.3
- [MLX ships its own FP4/FP8 bit-manipulation structs — distinct from Xcode 27's Metal tensor datatypes](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#64-️-mlx-uses-its-own-fp4fp8-structs-even-though-os-27-has-metal-types) — 9.3
- [NAX changes which algorithm is selected (its own split-K), not just which kernel — it is not a drop-in accelerator](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#65-the-four-gates-on-mlxs-accelerated-quantized-path) — 9.3
- [--quant-predicate works only with --q-mode affine and needs down_proj modules — otherwise a ValueError](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#66-what-mlx_lm-layers-on-top) — 9.3
- [Failure #8 is by design: int4 is storage — the runtime dequantizes to fp16/half for arithmetic; nothing to fix](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#71-the-lookup-table) — 9.3
- [The one-line check: if you targeted the ANE, confirm the viewer's Compute types show no float32](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#81-the-xcode-model-viewer--compute-types-vs-storage-types) — 9.3
- [The Xcode model viewer itself requires the Metal Toolchain, which is not installed by default](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#81-the-xcode-model-viewer--compute-types-vs-storage-types) — 9.3
- [Summary asymmetry: storageTypes and operationDistribution carry counts; the compute-side listing does not](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#82-aimodelassetsummary--the-same-data-programmatically) — 9.3
- [Consolidated index of format-related silent failures](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#10-️-silent-failures-consolidated) — 9.3
- [The M5 talk's baselines differ per claim — M4 for images, M1 for video; cite the baseline with the number](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#111-apple-published) — 9.3
- [ResNet50 PTQ row: int8 and FP8-E4M3 land within ~2.4 points of fp32 — the most directly useful format-choice datum](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#111-apple-published) — 9.3
- [Methodology: curl via sosumi.ai preserves verbatim signatures the rendered docs sometimes reflow](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#131-primary-sources-ranked) — 9.3
- [111432 is a Tech Talk, not a WWDC session — cite it accordingly](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#131-primary-sources-ranked) — 9.3

**Part 10**

- [Scope note: Core AI has no compiling first-party samples, so verify every signature in this part before trusting it.](part-10-coreai-hardware-authoring-debugging/README.md#️-read-this-before-you-trust-a-signature-anywhere-in-this-part) — 10.README
- [Evidence note: no Apple samples or doc updates exist for this framework; claims rest on repos, headers and community.](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md#️-a-word-about-evidence-because-this-framework-has-none-of-the-usual-kind) — 10.1
- [Zero Apple sample projects exist for Core AI; the strongest evidence is shipped repos, then headers, then community.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#the-debug-gauge-the-core-ai-instrument-and-the-core-ai-debugger) — 10.2
- [TOC pointer to the coreai-torch 0.4.0 IR-location incident and its provenance.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#contents) — 10.2
- [Never run an iOS-compiled bundle on a Mac: it can wedge the GPU/ANE stack into a watchdog reboot (community-reported).](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#55-the-measured-payoff-attributed) — 10.2
- [The Core AI Debugger's paired-device list omits visionOS, tvOS and watchOS; whether it attaches there is an open gap.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#61-what-it-is-and-where-to-get-it) — 10.2
- [The only benchmarker test upstream is skipped; use benchmark numbers for ranking modules, not for publishing latency.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#134-inspector-and-benchmarker) — 10.2
- [Per-module timings from benchmark_coreai_program are directional only.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#137-the-one-screen-mapping) — 10.2
- [Intermediate filenames are community-reported; the audit script depends only on Apple-named metadata.json.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#153-auditing-a-tree--the-producer-fingerprint) — 10.2
- [Apple maintainer fix for the 0.4.0 compiler failure: strip_debug_info, then save the updated asset.](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md#154-the-fix-from-the-maintainer) — 10.2
- [Scope note: signatures in this guide come from shipped repos and community evidence, not Apple samples.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#️-read-this-before-you-trust-a-signature-in-this-guide) — 10.3
- [Pipeline diagram: after AOT compiling you must hand-edit the assets map in metadata.json.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#11-the-canonical-five-steps-and-where-the-real-work-hides) — 10.3
- [The .missingAsset error text doubles as fix instructions; read it before debugging.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#13-metadatajson-schema-02--the-contract-between-python-and-swift) — 10.3
- [get_c4 imports undeclared datasets and tqdm; activation quantization raises ImportError with an install hint.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#26-three-gotchas-in-the-easy-road) — 10.3
- [cpu_only() exists for numeric parity checks only; community measured ~9x slower than default() on a DiT.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#64-gate-a--graph-parity) — 10.3
- [load_intermediates validates the directory suffix and raises if you point it anywhere else.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#66-apples-tooling-save_intermediates-and-the-core-ai-debugger) — 10.3
- [Apple's two compression claims measure different things; they are not in conflict - keep baselines straight.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#76-the-compression-rules-that-are-llm-specific) — 10.3
- [The shipped macOS LLM preset uses eager mode, so it cannot use KV-cache quantization; graph mode is required.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#77-the-exploration-loop-if-you-need-one) — 10.3
- [remove_functionalization imports private coreai._compiler dialect modules; pin versions, it can break any release.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#84-️-silent-failure--omit-remove_functionalization-and-your-kv-writes-disappear) — 10.3
- [Community rule: never execute an iOS-compiled bundle on a Mac - it can cost a watchdog reboot, not an afternoon.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#107-two-device-integration-traps-that-have-nothing-to-do-with-ml) — 10.3
- [The fastest engine throws on guided generation: @Generable needs per-step logits the pipelined path never exposes.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#114-️-the-gpu-pipelined-engine-cannot-do-guided-generation) — 10.3
- [The pipelined engine also lacks forcedContinuation, so MMLU-style continuation scoring is impossible on it.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#114-️-the-gpu-pipelined-engine-cannot-do-guided-generation) — 10.3
- [Only an LLM benchmark tool exists in the repo; no latency or quality numbers are published for non-LLM models.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#117-the-cli-tools-for-testing-before-you-write-app-code) — 10.3
- [Checklist: never execute an iOS-compiled bundle on a Mac.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#122-the-checklist) — 10.3
- [A second hidden knob: --bucket-size maps to COREAI_QUERY_BUCKET_SIZE; zero disables it.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#143-️-coreai_chunk_threshold-is-a-memory-dial-and-apples-hint-is-backwards-on-a-big-mac) — 10.3
- [Correction: MLX does run on iPhone GPUs via mlx-swift; only the ANE is closed, and FM integration is not exclusive.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#145-what-core-ai-genuinely-keeps) — 10.3
- [mlx2coreai is a community MIT project at v0.1.1 with 11 commits, not Apple tooling; it vendors one Apple BSD file.](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md#15-the-alternative-bridge-mlx2coreai) — 10.3

---

🔇 = the guide marks this as an explicit **SILENT FAILURE** callout.
