# Silent-failure index — MLX in Python and Swift, and bridges to Core AI

**341 ⚠️ callouts from the guide parts this skill covers, sorted by the symptom you would observe.** Most defects in this stack do not throw, so the symptom is what you start from.

> Sliced from the series index on 2026-09-22. The full index across all 17 parts is at https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/SILENT-FAILURES.md. Generated — regenerate with `./scripts/build-skills.sh` rather than editing by hand.

| Symptom | Entries |
|---|---:|
| [Wrong output](#wrong-output) | 42 |
| [Empty output / no-op](#empty-output--no-op) | 7 |
| [Truncation & limits](#truncation--limits) | 5 |
| [Ignored input](#ignored-input) | 30 |
| [Stale state](#stale-state) | 7 |
| [Data & artifact loss](#data--artifact-loss) | 6 |
| [Compiles but unavailable](#compiles-but-unavailable) | 9 |
| [Performance cliffs](#performance-cliffs) | 34 |
| [Resource growth](#resource-growth) | 6 |
| [Precision loss](#precision-loss) | 8 |
| [Misleading signals](#misleading-signals) | 33 |
| [Version drift](#version-drift) | 12 |
| [Docs vs reality](#docs-vs-reality) | 13 |
| [API footguns](#api-footguns) | 59 |
| [General cautions](#general-cautions) | 70 |

## Wrong output

**Part 12**

- [Six core-MLX traps where numbers go quietly wrong: scalar cache keys, frozen captured arrays, invisible NumPy mutations.](part-12-mlx-python/README.md#121--mlx-fundamentals-unified-memory-lazy-evaluation-transforms-and-compile) — 12.README 🔇
- [Affine gather_qmm on M5 leaves output rows unwritten (mlx#3856); they read back whatever the recycled MTLBuffer held.](part-12-mlx-python/README.md#123--mlx-quantization-modes-group-sizes-gates-and-the-corruption-bugs) — 12.README 🔇
- [Adapters train under a chat template serving may not reproduce (enable_thinking auto-defaults); quality quietly shifts.](part-12-mlx-python/README.md#126--lora-and-dora-fine-tuning-and-adding-a-new-architecture) — 12.README 🔇
- [custom_function silently zeroes gradients for arrays captured by closure.](part-12-mlx-python/references/01-core-fundamentals.md#53-️-silent-failure-custom_function-silently-zeroes-gradients-for-captured-arrays) — 12.1
- [Arrays captured by custom_function become constants; their gradients are silently 0.0 and training never updates them.](part-12-mlx-python/references/01-core-fundamentals.md#53-️-silent-failure-custom_function-silently-zeroes-gradients-for-captured-arrays) — 12.1 🔇
- [Under shapeless=True, Python arithmetic on x.shape freezes at trace time and later shapes compute with stale values.](part-12-mlx-python/references/01-core-fundamentals.md#93-️-silent-failure-shape-derived-arithmetic-bakes-in-the-first-shape) — 12.1
- [shapeless compile bakes shape-derived arithmetic from the first call; new shapes silently reuse the frozen numbers.](part-12-mlx-python/references/01-core-fundamentals.md#93-️-silent-failure-shape-derived-arithmetic-bakes-in-the-first-shape) — 12.1 🔇
- [apply(astype) casts packed uint32 quantized weights and integer params to bfloat16, destroying them; use set_dtype.](part-12-mlx-python/references/01-core-fundamentals.md#115-the-rest-of-the-module-surface) — 12.1
- [Writing through a NumPy view mutates MLX memory invisibly to autodiff; gradients come back wrong.](part-12-mlx-python/references/01-core-fundamentals.md#124-️-silent-failure-writing-through-a-numpy-view-destroys-gradients) — 12.1
- [External mutation of MLX memory is invisible to autodiff: Apple's own demo returns the wrong gradient with no error.](part-12-mlx-python/references/01-core-fundamentals.md#124-️-silent-failure-writing-through-a-numpy-view-destroys-gradients) — 12.1 🔇
- [DLPack hands over a pointer without synchronising; reading in torch before MLX's stream finishes yields wrong values.](part-12-mlx-python/references/01-core-fundamentals.md#125-pytorch-interop) — 12.1
- [Skip mx.eval before exporting a module and the .mlxfn captures the initialiser - it runs with fresh random weights.](part-12-mlx-python/references/01-core-fundamentals.md#127-️-exporting-a-module-mxeval-first-or-you-export-the-initialiser) — 12.1
- [MLX_SDPA_BLOCKS not a multiple of 32 silently corrupts attention every decode step on mlx <=0.32.0 (fixed in PR #3875).](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#57-two-adjacent-sdpa-traps) — 12.2 🔇
- [math_mode relaxed/fast stops guaranteeing exp(-inf)==0; masked positions leak into softmax: plausible, wrong attention.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#75-math-mode) — 12.2 🔇
- [ensure_row_contiguous=False with raw linear indexing reads strided buffers wrong: right shape, wrong contents, no error.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#91-strides-and-non-contiguous-inputs) — 12.2 🔇
- [Custom-kernel outputs are uninitialized by default; without init_value, unwritten slots hold recycled buffer contents.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#94-atomic-outputs-and-init_value--the-vjp-pattern) — 12.2 🔇
- [A kernel weight captured by closure gets no gradient under custom_function; pass tensors as arguments instead.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#94-atomic-outputs-and-init_value--the-vjp-pattern) — 12.2
- [Overview: four quantized-matmul corruption defects with issue numbers, most reproducible only on M5-generation hardware.](part-12-mlx-python/references/03-quantization.md#what-this-covers) — 12.3
- [TOC: the register of quantized-matmul corruption bugs.](part-12-mlx-python/references/03-quantization.md#contents) — 12.3
- [Seven quantized-matmul defects, five exclusive to M5-generation hardware; the register with statuses.](part-12-mlx-python/references/03-quantization.md#9-️-the-corruption-bugs) — 12.3
- [gather_qmm's unwritten rows aren't zeros: they hold recycled MTLBuffer contents, sometimes coincidentally plausible.](part-12-mlx-python/references/03-quantization.md#91-the-bad-one-affine-gather_qmm-leaves-rows-unwritten--mlx3856) — 12.3 🔇
- [Decision-table flag: M5 affine MoE has one unreleased fix and one open bug; pad rows and keep K%64==0.](part-12-mlx-python/references/03-quantization.md#121-the-decision-in-one-table) — 12.3
- [Training data renders under enable_thinking auto-defaults; serving with another template quietly degrades the adapter.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#25-️-silent-failure--the-chat-template-that-trained-your-adapter-is-not-the-one-serving-it) — 12.6
- [M5/A19 gather_qmm corruption in mlx#3856/#3887 affects big rows or ragged K through 0.32.2; #3922 fixes main.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#53-what-qlora-costs-you) — 12.6

**Part 13**

- [A missing or mismatched chat template yields fluent but degraded output blamed on the model — nothing checks it](part-13-mlx-swift/README.md#132--generation-tool-calling-and-kv-cache-management-in-swift) — 13.README 🔇
- [A VLM factory processor-selection gotcha produces wrong output rather than an error](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#72-the-processor-pipeline) — 13.1
- [Dropped EXIF orientation feeds the model a rotated photo — wrong answers, no error; Apple fixed it in their own sample](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#74-️-exif-orientation--the-bug-apple-fixed-in-their-own-sample) — 13.1
- [An empty assistant placeholder passed to UserInput(chat:) closes the turn — garbage or empty output blamed on the model](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#76-the-third-bug-in-the-same-commit-trailing-empty-assistant-message) — 13.1
- [Template resolution has a silent failure mode: a wrong template degrades output with no error (§6)](part-13-mlx-swift/references/02-generation-tools-and-caching.md#what-this-covers) — 13.2
- [Dropping LMOutput.State between turns drifts M-RoPE positions on VLMs — degraded multi-turn output, no error](part-13-mlx-swift/references/02-generation-tools-and-caching.md#43-state-and-the-m-rope-trap) — 13.2
- [A trailing empty assistant message closes the turn — fresh user turn or instant EOS on the raw UserInput path](part-13-mlx-swift/references/02-generation-tools-and-caching.md#53-chatmessage) — 13.2
- [The chat template is the contract and nothing checks it — mismatches produce fluent, degraded output](part-13-mlx-swift/references/02-generation-tools-and-caching.md#64-️-silent-failure-5--the-chat-template-is-the-contract-and-nothing-checks-it) — 13.2
- [Unknown models default to .json tool format — a non-JSON model's tool calls stream into visible text, never firing](part-13-mlx-swift/references/02-generation-tools-and-caching.md#75-detection-toolcallformatinfer-rule-by-rule) — 13.2
- [Restore plus instructions doubles the system prompt — fluent nonsense; saveCache also drops M-RoPE state (#443)](part-13-mlx-swift/references/02-generation-tools-and-caching.md#86-prompt-caching-to-disk) — 13.2

**Part 14**

- [Pass anything but the full monotonic position_ids and KV lands at the wrong cache slice — logits stay plausible](part-14-bridges-between-stacks/README.md#141--bridges-into-core-ai-mlx2coreai-swift-lm-and-the-community-zoo) — 14.README 🔇
- [A position_ids max that isn't the last query position writes KV to the wrong offset — valid math, wrong cache](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#35-position_ids-is-the-full-position-vector) — 14.1
- [Skip the bf16→fp16 logit cast and the Swift runner's hard-coded Float16 view reports garbage argmax — no crash](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#36-precision-and-the-flag-that-couples-to-the-swift-runner) — 14.1
- [allow_unknown_sources=True (default) invents scalar fp32 specs for unknown tensors — converts fine, can be badly wrong](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#52-conversionconfig-every-field) — 14.1
- [Boolean attention masks are lowered as added, not selected — masked positions leak in, output stays plausible](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#71-️-silent-failure-boolean-attention-masks-are-added-not-selected) — 14.1
- [General transposed convolution lowers to zeros — converts, runs, and outputs all-zero feature maps](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#72-️-silent-failure-general-transposed-convolution-lowers-to-zeros) — 14.1
- [mx.log2 and mx.log10 lower to natural log — every value wrong by a constant factor, no error](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#73-️-silent-failure-mxlog2-and-mxlog10-become-natural-log) — 14.1
- [Store only the load_function and the AIModel gets GC'd — calls return garbage that looks like a conversion bug](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#114-the-benchmark-protocol--cite-it-as-a-protocol-not-a-dataset) — 14.1

## Empty output / no-op

**Part 12**

- [DWQ on mxfp4/mxfp8/nvfp4 or 8-bit affine runs, prints losses, and writes a checkpoint quantized identically to input.](part-12-mlx-python/references/03-quantization.md#83-dwq--distillation-aware-the-quality-leader) — 12.3 🔇
- [A missing valid.jsonl only warns: a full run completes with no validation curve and no overfitting signal.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#26-local-files-vs-hugging-face-datasets) — 12.6

**Part 13**

- [Tool-only responses emit zero .chunk events (.toolCall then .info) — a spinner keyed to first text hangs forever](part-13-mlx-swift/references/02-generation-tools-and-caching.md#25-the-stream-event-types) — 13.2
- [A tool Output that fails to encode becomes '{}' silently — the model reasons over an empty result, no error](part-13-mlx-swift/references/02-generation-tools-and-caching.md#72-toolcall-and-executing-one) — 13.2
- [trimPromptCache returns 0 instead of throwing on untrimmable caches — the trim quietly does nothing](part-13-mlx-swift/references/02-generation-tools-and-caching.md#83-the-trimmability-contract) — 13.2
- [Tool calls with an unrecognised name are dropped silently — the tool never fires, no error surfaces](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#85-the-tool-paths) — 13.3
- [Re-serialize before the $defs rewrite and escaped slashes stop the prefix matching — the rewrite silently no-ops](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#86-schemaconverter--the-two-grammars-and-the-defs-bug-class) — 13.3

## Truncation & limits

**Part 13**

- [ChatSession's default processing resizes every image to 512×512 — detail silently lost unless you override](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#71-the-input-types) — 13.1
- [Images are resized to 512×512 by the default processing unless you say otherwise](part-13-mlx-swift/references/02-generation-tools-and-caching.md#22-chatsession--the-layer-you-should-start-at) — 13.2
- [Inputs beyond maxPositionEmbeddings are truncated with only a console warning — never an error](part-13-mlx-swift/references/02-generation-tools-and-caching.md#101-the-types) — 13.2
- [If thinking exhausts the budget before </think>, phase 2 is skipped entirely — no structured output at all](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#85-the-tool-paths) — 13.3
- [Budget-exhausted guided generation succeeds with truncated JSON — incompleteOutput is metadata, not a thrown error](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#122-the-throwing-failures-and-what-each-means) — 13.3

## Ignored input

**Part 12**

- [mlx-lm applies a chat template you didn't pick, and --use-default-chat-template is a no-op in generate; six traps total.](part-12-mlx-python/README.md#124--mlx-lm-the-cli-surface-the-generation-api-and-kv-caching) — 12.README 🔇
- [MLX_ENABLE_TF32 is read on first use - set after your first matmul it silently does nothing; matvec shapes stay fp32.](part-12-mlx-python/references/01-core-fundamentals.md#defaults-you-should-memorise-now) — 12.1
- [Layers whose input dim doesn't divide the group size are silently left in full precision.](part-12-mlx-python/references/03-quantization.md#34-️-silent-failure-layers-that-do-not-divide-by-the-group-size-are-skipped) — 12.3
- [A Linear not divisible by group_size is silently kept full-precision: your 4-bit model is 4-bit except awkward layers.](part-12-mlx-python/references/03-quantization.md#34-️-silent-failure-layers-that-do-not-divide-by-the-group-size-are-skipped) — 12.3 🔇
- [--use-default-chat-template is accepted by mlx_lm.generate and does nothing.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#22-mlx_lmgenerate--the-workhorse) — 12.4
- [mlx-lm applies a chat template in cases where you expected yours or none; --use-default-chat-template is a no-op.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#91-️-silent-failure--the-chat-template-you-are-using-is-not-the-one-you-think) — 12.4
- [Several sampler parameters are accepted and never reach the sampler; outputs don't change.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#93-️-silent-failure--sampler-parameters-that-do-nothing) — 12.4
- [stream_generate silently drops unknown kwargs; a typoed sampler argument changes nothing and raises nothing.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#94-️-silent-failure--kwargs-dropped-by-stream_generate) — 12.4
- [tools passed to a model that can't call tools only logs a warning; the response just never contains tool calls.](part-12-mlx-python/references/05-serving-and-distributed.md#️-silent-failure-passing-tools-to-a-model-that-cannot-call-tools-only-warns) — 12.5
- [--clear-cache-threshold parses fine and is silently ignored; it never reaches the trainer.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#32-flags-grouped-by-what-they-control) — 12.6
- [--clear-cache-threshold never reaches the trainer; memory behavior is unchanged no matter what you pass.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#35-️-silent-failure----clear-cache-threshold-never-reaches-the-trainer) — 12.6
- [run() silently discards the training_callback you pass in; no metrics hooks ever fire.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#37-️-silent-failure--run-throws-away-your-training_callback) — 12.6
- [LoRA target keys use exact set membership; a glob or regex pattern silently selects zero layers.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#61-which-modules-get-an-adapter) — 12.6
- [Byte-identical greedy outputs mean the adapter never loaded: lora_b starts at zero, so unloaded equals the base model.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#104-generation-ab--the-check-that-actually-decides) — 12.6

**Part 13**

- [Resolver patches are mostly inert: only reasoningConfig is consumed; extraEOSTokens and toolCallFormat change nothing](part-13-mlx-swift/README.md#133--mlxfoundationmodels-and-mlxguidedgeneration-backing-languagemodelsession-with-an-mlx-model) — 13.README 🔇
- [generation_config.json eos_token_id replaces rather than unions — earlier stop tokens silently discarded](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#46-what-load-actually-does-in-order) — 13.1
- [Memory.cacheLimit is one process-wide value and libraries set it behind your back — your setting can be silently stomped](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#63-what-the-two-limits-mean-and-what-to-set-them-to) — 13.1
- [seed is inert at temperature 0 — greedy decoding never consults the RNG](part-13-mlx-swift/references/02-generation-tools-and-caching.md#31-every-field-with-its-default) — 13.2
- [At temperature 0 every sampler knob is ignored; topP 1.0 and topK 0 are also no-ops — decorative config fields](part-13-mlx-swift/references/02-generation-tools-and-caching.md#33-penalty-processors-and-the-gpu-resident-ring-buffer) — 13.2
- [Stop-token step 2 replaces rather than unions (matching Python) — earlier EOS ids silently discarded](part-13-mlx-swift/references/02-generation-tools-and-caching.md#63-stop-tokens-four-sources-one-of-which-overwrites-the-others) — 13.2
- [kvScheme overrides kvBits and typo'd scheme strings are silently ignored — no quantization, no message](part-13-mlx-swift/references/02-generation-tools-and-caching.md#85-quantized-kv-kvbits-kvscheme-and-turboquant) — 13.2
- [RotatingKVCache.toQuantized() is never called — rotating layers silently stay fp16 whatever kvBits says](part-13-mlx-swift/references/02-generation-tools-and-caching.md#85-quantized-kv-kvbits-kvscheme-and-turboquant) — 13.2
- [Detection-script print: layers whose cache type can't quantize stay fp16 silently despite kvBits](part-13-mlx-swift/references/02-generation-tools-and-caching.md#94-how-to-detect-all-three-in-your-own-app) — 13.2
- [Sample output: 36 layers will stay fp16 silently under the requested kvBits](part-13-mlx-swift/references/02-generation-tools-and-caching.md#94-how-to-detect-all-three-in-your-own-app) — 13.2
- [progressHandler is ignored for local-directory loads — no progress events ever arrive on that path](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#53-complete-a-model-from-a-directory-you-already-have) — 13.3
- [The SDK never gates image input on .vision — without the adapter's check, images go to text-only models silently](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#64-️-silent-failure-prevented-the-vision-gate-the-sdk-does-not-do) — 13.3
- [TranscriptConverter drops entries with only debug-level logs — transcript content quietly missing from the prompt](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#81-transcriptconverter--entries-in-chatmessages-out) — 13.3
- [Resolver patches are mostly inert — only reasoningConfig is consumed; everything else compiles and changes nothing](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#83-modelconfigurationresolver-and-modeldescriptor--the-seam-and-its-trap) — 13.3
- [GrammarTokenizer registers exactly one stop token with xgrammar — other stop tokens are not enforced](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#95-stop-tokens-and-the-three-sources) — 13.3
- [The bridge's stopTokenIds parameter is dead — accepted, never forwarded](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#103-the-two-bridges-are-not-the-same-bridge) — 13.3

## Stale state

**Part 12**

- [Arrays captured by an mx.compile closure freeze at trace time; later updates never reach the compiled function.](part-12-mlx-python/references/01-core-fundamentals.md#71-️-silent-failure-captured-arrays-are-frozen-constants) — 12.1
- [state[0] = new value has no effect on a compiled function that captured it; it keeps returning the traced constant.](part-12-mlx-python/references/01-core-fundamentals.md#71-️-silent-failure-captured-arrays-are-frozen-constants) — 12.1 🔇
- [mlx_lm.benchmark empties the tokenizer's EOS set in place; reuse that tokenizer and generation never stops.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#28-mlx_lmevaluate-perplexity-benchmark--the-measurement-three) — 12.4
- [ChunkedKVCache and ConcatenateKVCache break the server prompt cache's trim assumptions; hits can return mismatched KV.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#46-chunkedkvcache--and-a-correctness-caveat) — 12.4
- [The server's prompt-cache reuse can return KV that doesn't match your tokens, mixing another prompt's context in.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#95-️-silent-failure--server-prompt-cache-reuse-returning-mismatched-kv) — 12.4
- [The Swift port carries its own KV-cache bugs; Mac apps hit them through cache reuse.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#96-️-silent-failure--the-swift-ports-cache-bugs-because-you-will-hit-them-from-a-mac-app) — 12.4

**Part 14**

- [The precision flag mutates the loaded model in place — converting several variants in one process reuses mutated weights](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#36-precision-and-the-flag-that-couples-to-the-swift-runner) — 14.1

## Data & artifact loss

**Part 12**

- [--auto-setup disables the Thunderbolt Bridge on every machine - a destructive network-config change on each node.](part-12-mlx-python/references/05-serving-and-distributed.md#183-what---auto-setup-actually-does--and-what-it-destroys) — 12.5
- [Resuming restores weights only; Adam moments and schedule position are silently reset to zero.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#93-loading-them-back-and-the-strictfalse-at-the-heart-of-it) — 12.6

**Part 13**

- [Bare HubClient caches weights in Library/Caches — iOS purges it under storage pressure and multi-GB models vanish](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#44-where-the-weights-land) — 13.1
- [PhotosPicker's receivedFile.file lives in a temp dir deleted after the closure — copy it out or the URL dies](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#75-photospicker-done-correctly) — 13.1
- [Parallel xctest workers race on the shared HuggingFace cache — intermittent corruption that looks like a checkpoint bug](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#96-testing-across-both-sdks) — 13.1

**Part 14**

- [_write_tokenizer rmtree's an existing destination — a re-run silently destroys whatever was there](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#32-what-lands-on-disk) — 14.1

## Compiles but unavailable

**Part 12**

- [rich and regex are imported at module level but undeclared; a bare pip install crashes at import.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#what-you-need) — 12.4
- [The server imports undeclared packages at module level; a clean install crashes before serving anything.](part-12-mlx-python/references/05-serving-and-distributed.md#11-three-steps-and-the-two-packages-nobody-tells-you-about) — 12.5
- [macOS 26.2 is the hard gate for RDMA-over-Thunderbolt distributed inference; older machines simply can't join.](part-12-mlx-python/references/05-serving-and-distributed.md#14-the-four-layer-distributed-stack) — 12.5
- [mlx_lm.lora imports two more packages at module scope that setup.py never declares; bare installs crash.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#what-you-need) — 12.6
- [rich and regex must be installed by hand; they're imported at module scope but undeclared in setup.py.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#11-the-install-line) — 12.6
- [On a bare pip install, mlx_lm.lora dies at import: cli_ui pulls rich at module scope (ModuleNotFoundError).](part-12-mlx-python/references/06-finetuning-and-porting-models.md#11-the-install-line) — 12.6

**Part 13**

- [@available alone is not enough — without the trait/linker gate the app fails at runtime on OSes that compiled fine](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#91-the-gate) — 13.1
- [@available alone won't save you — the adapter's own header demands a runtime gate as well](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#version-floor) — 13.3

**Part 14**

- [Guided generation needs logits and the GPU-pipelined fast path never exposes them — fastest backend, no structured…](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#123-one-more-consideration-is-core-ai-even-the-right-destination) — 14.1

## Performance cliffs

**Part 12**

- [Evaluating loss and gradients separately runs the graph twice per step; batch both into one mx.eval.](part-12-mlx-python/references/01-core-fundamentals.md#34-the-partial-evaluation-trap) — 12.1
- [A varying Python scalar argument recompiles a compiled function on every call; it presents as compile being slower.](part-12-mlx-python/references/01-core-fundamentals.md#84-️-silent-failure-python-scalars-are-baked-into-the-cache-key) — 12.1
- [int/float/str/None args are baked into the compile cache key; a varying scalar silently recompiles every call.](part-12-mlx-python/references/01-core-fundamentals.md#84-️-silent-failure-python-scalars-are-baked-into-the-cache-key) — 12.1 🔇
- [shapeless=True only exempts shape changes; scalar constants varying across calls still create distinct cache entries.](part-12-mlx-python/references/01-core-fundamentals.md#92-what-it-does-not-exempt-you-from) — 12.1
- [The default-stream context manager is part of the compile cache key; calling under another device recompiles.](part-12-mlx-python/references/01-core-fundamentals.md#102-the-default-and-how-to-change-it) — 12.1
- [Per-call stream setup costs a uniform 55-77 ms TTFT regression (mlx-lm#1435); hoist it out of the hot path.](part-12-mlx-python/references/01-core-fundamentals.md#104-️-streams-are-thread-affine) — 12.1
- [mx.save forces evaluation of the pending graph; a checkpoint line can trigger the entire deferred computation.](part-12-mlx-python/references/01-core-fundamentals.md#122-️-saving-forces-evaluation) — 12.1
- [TOC: the silent SDPA fallback from fused kernel to unfused matmul-softmax.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#contents) — 12.2
- [complex64 matmul is gated out of the NAX path on Metal, while CUDA gives complex TF32 fast math instead.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#17-complex-support-exactly-one-dtype) — 12.2
- [A source build targeting below macOS 26.2 defines MLX_METAL_NO_NAX: a working MLX that is simply never fast on M5.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#43-three-gates-all-of-which-must-pass) — 12.2 🔇
- [Apple's trace shows simdgroup_matrix kernels leave M5 matrix hardware idle; the same matmul is ~7x faster on TensorOps.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#46-apples-own-numbers-with-their-baselines) — 12.2
- [mx.fast SDPA silently takes the unfused path for many configurations; right answer, worse speed and memory.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#5-️-the-silent-sdpa-fallback) — 12.2
- [SDPA fallback computes correct output unfused, materialising the full score tensor; throughput and memory betray it.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#53-what-the-fallback-actually-does) — 12.2 🔇
- [Miss a NAX dispatch gate and you get correct numbers from a much slower kernel, with nothing logged.](part-12-mlx-python/references/03-quantization.md#62-️-silent-failure-missing-a-gate-costs-you-throughput-and-tells-you-nothing) — 12.3
- [Shapes failing the K%64/transpose check dispatch a non-NAX kernel: no warning, same numbers, very different M5 speed.](part-12-mlx-python/references/03-quantization.md#62-️-silent-failure-missing-a-gate-costs-you-throughput-and-tells-you-nothing) — 12.3 🔇
- [--draft-model silently disables continuous batching; concurrent requests serialize.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#26-mlx_lmserver--the-openai-compatible-endpoint) — 12.4
- [An unregistered drafter makes the Swift MTP iterator fall back to single-token decoding: no error, zero speedup.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#76-what-a-good-draft-model-looks-like) — 12.4
- [A draft model or a seed silently turns the concurrent server sequential; concurrency holds only when batchable.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#84-the-servers-batchability-gate--two-ways-to-lose-continuous-batching) — 12.4
- [A draft model or a fixed seed silently disables continuous batching; the server serves sequentially.](part-12-mlx-python/references/05-serving-and-distributed.md#84-️-the-two-things-that-silently-turn-batching-off) — 12.5
- [Cache classes that aren't trimmable forfeit prompt-prefix reuse entirely; every turn pays a full prefill.](part-12-mlx-python/references/05-serving-and-distributed.md#93-️-the-architectures-that-forfeit-prefix-reuse-entirely) — 12.5
- [Distributed runs need MLX_METAL_FAST_SYNCH=1; without it, CPU-driven communication pays slow GPU-CPU synchronisation.](part-12-mlx-python/references/05-serving-and-distributed.md#️-mlx_metal_fast_synch1-is-not-optional) — 12.5
- [DoRA dequantises the full base weight twice per forward, materialising dense layer-size matrices; QLoRA savings vanish.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#42-dora) — 12.6
- [Comparison table: DoRA runs on a quantized base but dequantises every step; don't use it where QLoRA memory matters.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#44-choosing-between-them) — 12.6
- [The length sort keys on len() of the raw record dict, a constant: batches mix short and long rows, causing random OOMs.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#88-️-silent-failure--length-based-batching-does-not-work) — 12.6
- [JACCL recv spins forever on peer loss and the ring socket thread dies silently, wedging all ranks (#3910, #3862, #3830).](part-12-mlx-python/references/06-finetuning-and-porting-models.md#96-distributed-fine-tuning-in-one-paragraph) — 12.6

**Part 13**

- [MTP drafters need manual registration; without it decoding silently falls back to single-token — no speedup, no error](part-13-mlx-swift/references/02-generation-tools-and-caching.md#26-speculative-decoding-in-one-page) — 13.2
- [Prefill runs inside the cache initializer — constructing it is the expensive step, not a cheap allocation](part-13-mlx-swift/references/02-generation-tools-and-caching.md#42-three-initializers-and-the-one-that-costs-money) — 13.2
- [Hybrid and linear-attention models have no prefix caching — every RAG query re-prefills; 0.2 s vs 20 s to first token](part-13-mlx-swift/references/02-generation-tools-and-caching.md#104-the-pipeline-and-the-part-that-is-actually-hard) — 13.2
- [A prewarm witness that doesn't match exactly never binds — prewarm silently no-ops, first-token latency stays high](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#76-️-silent-failure-the-prewarm-witness-must-match-exactly) — 13.3
- [Rejected fast-forward tokens silently fall back to masked sampling — correct but slower; only the counter shows it](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#96-fast-forward-tokens-and-the-tokenization-boundary-problem) — 13.3
- [Each helper call scans the full vocabulary (three passes on a 150k vocab) — cache biases and GrammarTokenizer](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#97-standalone-guided-generation-without-foundation-models) — 13.3

**Part 14**

- [expectFrequentReshapes requests a reshape-tolerant specialization — on a static graph it costs the fast path](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#105-the-community-measured-it-on-hardware) — 14.1
- [Thermals move numbers 2.3–4.1× — a day of device use silently degrades a 25 ms op; benchmark cold and hot](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#114-the-benchmark-protocol--cite-it-as-a-protocol-not-a-dataset) — 14.1
- [A community helper defaults to cpu_only() — copied code silently runs ~9–10× slower; it's the parity option](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#114-the-benchmark-protocol--cite-it-as-a-protocol-not-a-dataset) — 14.1

## Resource growth

**Part 12**

- [mlx_lm.load's default lazy=False evaluates every parameter at load - an 18.2 GB spike on a 35B MoE before any token.](part-12-mlx-python/references/01-core-fundamentals.md#22-why-lazy-is-the-right-default) — 12.1
- [A loop that never calls mx.eval builds an ever-growing lazy graph; memory climbs until evaluation or OOM.](part-12-mlx-python/references/01-core-fundamentals.md#32-failure-mode-two--never-evaluating) — 12.1
- [Community-measured functional-cache leak: memory grows across steps until the cache is explicitly cleared.](part-12-mlx-python/references/01-core-fundamentals.md#35-️-the-functional-cache-leak-community-measured) — 12.1

**Part 13**

- [iOS jetsam gives no signal: no throw, no memory-warning callback, no deinit — the app just closes on the user](part-13-mlx-swift/README.md#131--mlx-swift-lm-in-an-app-setup-concurrency-memory-and-media-input) — 13.README 🔇
- [Jetsam arrives with no throw, no reliable memory warning, no deinit — 'Terminated due to memory issue' is all you get](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#67-what-jetsam-looks-like-and-how-to-see-it-coming) — 13.1
- [Fused SDPA is head-dim-gated; unsupported dims silently materialise an L² score tensor — inexplicable prefill memory](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#77-vlm-memory-the-two-failure-modes-worth-naming) — 13.1

## Precision loss

**Part 12**

- [M5 float32 matmul silently runs at TF32-class precision (2^-10.4 vs 2^-19.8 error); set MLX_ENABLE_TF32=0 before import.](part-12-mlx-python/README.md#122--numerics-hardware-gating-and-writing-custom-metal-kernels-from-python) — 12.README 🔇
- [mx.load's format list omits gguf, and unsupported GGUF quantization formats silently cast tensors to another dtype.](part-12-mlx-python/references/01-core-fundamentals.md#121-the-four-array-formats) — 12.1
- [TOC: precision you did not choose - float32 matmuls at TF32 class with no runtime signal.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#contents) — 12.2
- [np.array on bfloat16 raises a cryptic PEP 3118 error, and NumPy float64 silently narrows to MLX float32.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#19-reinterpreting-bits-mxview-vs-astype) — 12.2
- [On M5 + macOS 26.2+, float32 matmul defaults to reduced internal precision with no runtime signal.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#33-️-silent-failure-precision-you-did-not-choose-with-no-runtime-signal) — 12.2
- [M5 float32 matmul returns plausible values ~3 orders of magnitude less accurate; x.dtype still says float32.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#33-️-silent-failure-precision-you-did-not-choose-with-no-runtime-signal) — 12.2 🔇
- [Quantized-KV settings change output quality through three separate mechanisms, with no signal.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#92-️-silent-failure--quantized-kv-settings-silently-change-output-quality) — 12.4

**Part 13**

- [quantizedKVStart 0 quantizes from token zero — Python measured a quality cost that a later start avoids](part-13-mlx-swift/references/02-generation-tools-and-caching.md#the-class-of-error-port-the-line-lose-the-semantics) — 13.2

## Misleading signals

**Part 12**

- [The server returns HTTP 404 for model-load, OOM and tokenizer failures, and tools to a non-tool model only warns.](part-12-mlx-python/README.md#125--mlx_lmserver-local-agents-and-distributed-inference-over-thunderbolt) — 12.README 🔇
- [Lazy evaluation moves exceptions to whatever line forces evaluation, far from the op that caused them.](part-12-mlx-python/references/01-core-fundamentals.md#33-️-silent-failure-lazy-evaluation-moves-the-traceback) — 12.1
- [A failing op raises nothing when recorded; the exception fires at a later print or eval, often inside a library.](part-12-mlx-python/references/01-core-fundamentals.md#33-️-silent-failure-lazy-evaluation-moves-the-traceback) — 12.1 🔇
- [The first compiled call pays graph build, codegen and Metal compilation; un-warmed benchmarks measure the compiler.](part-12-mlx-python/references/01-core-fundamentals.md#63-the-speedup-honestly-attributed) — 12.1
- [gpt-oss attention sinks plus a quantized KV cache kill the generation thread; the client sees only a timeout.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#51-the-api-and-the-four-notes-that-matter) — 12.2
- [mx.get_peak_memory excludes the buffer pool; one M5 Max run reported 46 GB while the OS saw ~110 GB.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#55-detecting-the-fallback--four-techniques) — 12.2
- [--kv-bits starts cleanly, /health answers 200, then the first request crashes on sliding-window models (mlx-lm#1573).](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#64-four-ways---kv-bits-fails-three-of-them-badly) — 12.4 🔇
- [Quantized KV with gpt-oss kills the generation thread; the request never returns and presents as a network timeout.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#64-four-ways---kv-bits-fails-three-of-them-badly) — 12.4 🔇
- [/health is a static handler; it answers 200 regardless of whether the model loaded or the generation thread is alive.](part-12-mlx-python/references/05-serving-and-distributed.md#31-health-checks-that-lie) — 12.5
- [Model-load, OOM and tokenizer failures return HTTP 404 - the mistyped-URL status; the real error hides in the body.](part-12-mlx-python/references/05-serving-and-distributed.md#️-silent-failure-model-load-and-tokenization-errors-come-back-as-http-404) — 12.5
- [DoRAEmbedding's guard tests QuantizedLinear, not QuantizedEmbedding; the meant error never fires, an unrelated one does.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#42-dora) — 12.6
- [get_total_parameters unpacks quantized weights in the denominator; the printed trainable fraction is misleadingly small.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#62-the-parameter-count-arithmetic) — 12.6
- [The trainer's printed peak memory excludes the buffer pool; the real footprint is active plus cache memory.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#85-️-the-peak-memory-number-the-trainer-prints-is-not-your-memory-footprint) — 12.6
- [val_info['iteration'] is it-1 while train_info uses it; naive metric joins misalign validation by one step.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#95-experiment-tracking) — 12.6
- [The before/after perplexity comparison lies three ways; perplexity on a tuned distribution always improves.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#101-test-set-perplexity--the-cheapest-signal) — 12.6

**Part 13**

- [Split tokenizer repos get a no-op progress handler: the bar hits 100% while a second unreported download runs](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#32-style-1--implement-the-protocols) — 13.1
- [Macro expansion references six modules at your call site — missing imports error inside code you never wrote](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#34-style-3--the-mlxhuggingface-macros) — 13.1
- [Linking only MLXLMCommon empties the registry; the free loader shows the VLM error, hiding the real LLM failure](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#42-the-factory-registry-and-the-error-you-will-hit-first) — 13.1
- [Memory.snapshot() reports MLX's allocator only, not process footprint — it cannot warn you about jetsam](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#64-measuring-memorysnapshot-and-a-live-hud) — 13.1
- [#hubDownloader macros expand to symbols at your call site — missing imports produce baffling errors in generated code](part-13-mlx-swift/references/02-generation-tools-and-caching.md#12-the-3x-break-tokenizers-and-downloading-are-yours-now) — 13.2
- [The VLM factory runs first and intermediate errors are swallowed — the message you see may be the wrong factory's](part-13-mlx-swift/references/02-generation-tools-and-caching.md#56-the-vlm-path-in-practice) — 13.2
- [A missing import at the macro call site errors inside the expansion — the message never names the import fix](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#32-the-eight-imports-and-why-the-macro-needs-them) — 13.3
- [noModelFactoryAvailable surfaces mid-download when MLXLLM isn't imported — the error site hides the linking cause](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#33-️-silent-failure-almost-nomodelfactoryavailable) — 13.3
- [.available does not mean the weights are complete — a partial download still reports available](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#73-️-silent-failure-available-does-not-mean-the-weights-are-complete) — 13.3
- [Usage is never forwarded to the framework — Foundation Models usage metrics stay empty on the MLX path](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#88-️-silent-failure-usage-is-never-forwarded-to-the-framework) — 13.3
- [flushLogs() always returns nil — the log-retrieval API hands back nothing, ever](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#99-️-silent-failure-flushlogs-always-returns-nil) — 13.3

**Part 14**

- [TOC: asset-generation coverage is not numerical parity — a bundle that generates is not one that computes correctly](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#contents) — 14.1
- [Conversion succeeds while silently listing unresolved tensors in metadata['unresolved_extra_inputs'] — read it every…](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#51-the-minimal-working-example) — 14.1
- [Generated assets are not numerical parity — tolerances compare against MLX's own capture, never a Core AI execution](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#6-️-asset-generation-coverage-is-not-numerical-parity) — 14.1
- [match_by_order=True pairs outputs positionally — a shifted output order gives a green comparison of the wrong tensors](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#62-what-is-tested-and-what-is-not) — 14.1
- [--runtime-backend auto silently picks Swift on Darwin unless a Python-only flag flips it — runs measure different…](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#83-the-build-recipe-and-the-auto-selection-trap) — 14.1
- [Every Core AI test in the repo passes without running — green because skipped, not because it works](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#98-️-silent-failure-every-core-ai-test-in-this-repo-passes-without-running) — 14.1
- [Code comment: check metadata['unresolved_extra_inputs'] after every conversion — success ≠ all inputs resolved](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#132-mlx2coreai-python-api) — 14.1

## Version drift

**Part 12**

- [export_function is experimental; .mlxfn files from older MLX versions may not load in future ones.](part-12-mlx-python/references/01-core-fundamentals.md#126-export_function--import_function--the-mlxfn-format) — 12.1
- [Three NAX correctness PRs within three days (#3912 quant corruption, #3922 gather_qmm bounds); pin and re-verify.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#️-read-this-before-you-trust-a-signature-below) — 12.2
- [mlx-lm 0.31.0 was pulled from PyPI for BatchKV cache cross-contamination; know exactly which version you run.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#mlx-lm-the-cli-surface-the-generation-api-and-kv-caching) — 12.4
- [PyPI's mlx-lm (0.31.3, April) trails main by months of fixes; 0.31.0 was yanked for BatchKV cross-contamination.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#12-versions-on-disk-and-the-pypi-gap) — 12.6

**Part 13**

- [3.x main is a breaking major: download and tokenization become protocols you must implement yourself](part-13-mlx-swift/README.md#part-13--mlx-in-swift) — 13.README
- [mlx-swift-lm main is a breaking 3.x major — code written against 2.x loading APIs no longer applies](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#mlx-swift-lm-in-an-app-setup-concurrency-memory-and-media-input) — 13.1
- [The GPU cache API was renamed and both spellings circulate — verify which your version exports](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#62-️-the-gpu-cache-api-changed-name--and-both-spellings-are-in-the-wild) — 13.1
- [Two ticket(...) spellings for wired memory exist in the repo and one is stale](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#65-wired-memory-the-part-with-a-dedicated-reference) — 13.1
- [27-beta SDK churn: an interface/dylib mismatch escalates from silent drift to a SIGSEGV process abort](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#93-the-27-beta-sdk-churns-and-one-of-the-drifts-is-a-sigsegv) — 13.1
- [SamplingModeKind was renamed mid-beta and the churn is flagged ongoing — re-verify each beta](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#131-samplingmodekind-was-renamed-mid-beta) — 13.3

**Part 14**

- [The bridge's core call is private AIProgram._from_mlir_module — any coreai wheel bump can break it without notice](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#1-three-bridges-one-destination) — 14.1
- [mlx2coreai pins coreai-core b1; b1 bundles fail on Xcode 27 beta 3+ with 'Failed to convert to versioned IR'](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#23-️-the-wheel-pin-collision) — 14.1

## Docs vs reality

**Part 12**

- [LEARNED_QUANTS.md's DWQ and AWQ defaults don't match the code (1024/8 vs 2048/4; 32/10 vs 128/20); trust --help.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#25-the-four-learned-quantization-clis) — 12.4
- [LORA.md says to pass --hf-path to mlx_lm.fuse, but the flag doesn't exist; GGUF export covers only three model types.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#27-mlx_lmlora-and-mlx_lmfuse) — 12.4
- [The two best sources give different RDMA setup sequences; both are quoted - pick one deliberately.](part-12-mlx-python/references/05-serving-and-distributed.md#16-turning-rdma-on--the-setup-sequence) — 12.5
- [--output does not exist on the launcher; the real flag is --output-hostfile.](part-12-mlx-python/references/05-serving-and-distributed.md#️---output-does-not-exist-the-flag-is---output-hostfile) — 12.5
- [The docs' NCCL example passes --no-verify-script, a flag the launcher does not have.](part-12-mlx-python/references/05-serving-and-distributed.md#193-the-full-launcher-flag-set) — 12.5
- [The example config contradicts CONFIG_DEFAULTS; copying it silently changes schedule values.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#33-the-flags-that-exist-only-in-yaml) — 12.6
- [Doc bug: LORA.md's upload example passes --hf-path to mlx_lm.fuse; fuse.py declares eight flags and no such option.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#112-the-flags) — 12.6

**Part 13**

- [The 3.x upgrade-notes URL 404s (issue #217) — read Documentation.docc/upgrade.md in the repo instead](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#11-what-changed-and-why) — 13.1
- [MLXCXGrammar and MLXHuggingFaceMacros are targets, not products — briefs listing them as importable are wrong](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#21-the-product-list) — 13.1
- [The upgrade document's own migration table contains stale module names](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#26-the-2x--3x-migration-table) — 13.1
- [The bundled skill's loading code is stale against the 3.x API in the same repo](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#51-the-shipped-skill-and-how-far-to-trust-it) — 13.1
- [The MLXLLM and MLXVLM README links are genuinely dead — not a transcription error](part-13-mlx-swift/references/02-generation-tools-and-caching.md#11-two-repositories-and-which-one-you-actually-depend-on) — 13.2
- [Session 339's one-argument MLXLanguageModel init does not exist — code written from the session will not compile](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#51-the-signature) — 13.3

## API footguns

**Part 12**

- [A stream is only usable on its creating thread; workers get 'There is no Stream(gpu, 0) in current thread'.](part-12-mlx-python/references/01-core-fundamentals.md#104-️-streams-are-thread-affine) — 12.1
- [A NumPy array or float on self is not a parameter - never saved or restored - and underscore names are invisible too.](part-12-mlx-python/references/01-core-fundamentals.md#111-a-module-is-a-dict) — 12.1
- [load_weights(strict=False) skips shape checks entirely; mismatched weights load and the model silently misbehaves.](part-12-mlx-python/references/01-core-fundamentals.md#116-loading-weights) — 12.1
- [MLX's fp8_e8m0, fp8_e4m3 and fp4_e2m1 are its own structs, not interchangeable with other stacks' formats.](part-12-mlx-python/references/03-quantization.md#24-️-mlxs-fp8_e8m0-fp8_e4m3-and-fp4_e2m1-are-its-own-structs) — 12.3
- [DEFAULT_XTC_THRESHOLD is 0.0 but the CLI default for --xtc-threshold is 0.1 - one of four disagreeing XTC defaults.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#22-mlx_lmgenerate--the-workhorse) — 12.4
- [--prefill-step-size doubles as the quantized-KV memory knob; tuning one silently changes the other.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#26-mlx_lmserver--the-openai-compatible-endpoint) — 12.4
- [generate() returns None, not '', when no text is emitted; .strip() callers crash exactly on the worst inputs.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#33-generate-and-stream_generate) — 12.4
- [stream_generate(max_tokens=0) raises UnboundLocalError; for prefill-only, call generate_step and drain the generator.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#38-a-complete-script) — 12.4
- [load_prompt_cache rebuilds classes from mlx_lm.models.cache globals; a custom cache class saves but cannot load back.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#49-writing-a-custom-cache--and-the-one-thing-that-will-break-it) — 12.4
- [The CLI hard-errors on draft/model tokenizer mismatch; the server only warns and proceeds with speculative decoding.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#73-the-signature-and-the-constraints-it-enforces) — 12.4
- [BatchGenerator.insert writes new caches into the very list you passed; held references mutate under you.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#82-batchgenerator--continuous-batching-directly) — 12.4
- [--allowed-origins defaults to the string '*', making origin checks substring tests; pass it explicitly for a real list.](part-12-mlx-python/references/05-serving-and-distributed.md#️-silent-failure---allowed-origins-defaults-to-a-string-and-it-works-by-accident) — 12.5
- [ChatCompletionsLanguageModel's literal 'v1' check appends /v1/chat/completions after non-/v1 base paths, producing 404s.](part-12-mlx-python/references/05-serving-and-distributed.md#️-the-v1-path-bug-you-will-hit-within-five-minutes) — 12.5
- [The first successful distributed init wins: later init() or backend='any' calls return the first backend, not a new one.](part-12-mlx-python/references/05-serving-and-distributed.md#141-the-four-backends-and-when-each-applies) — 12.5
- [Dict hostfile entries are read with data['backend'] not .get(); omit the key and the launcher raises KeyError.](part-12-mlx-python/references/05-serving-and-distributed.md#175-the-second-undocumented-hostfile-form) — 12.5
- [Script and model paths resolve on each node, not the launcher; launcher-local paths fail or run stale copies remotely.](part-12-mlx-python/references/05-serving-and-distributed.md#️-the-path-is-the-path-on-the-nodes-not-on-the-launcher) — 12.5
- [--batch-size is the global batch split across N nodes; leave it unscaled and each node trains on batch/N.](part-12-mlx-python/references/05-serving-and-distributed.md#️-silent-failure---batch-size-is-the-global-batch-and-you-must-scale-it-by-n) — 12.5
- [Python LoRALinear defaults scale=20.0; the Swift stack's default differs, so ported adapters silently change behavior.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#02-what-that-leaves-standing) — 12.6
- [ConcatenatedDataset.__getitem__ writes a _dataset key into the record it returns, mutating your data in place.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#26-local-files-vs-hugging-face-datasets) — 12.6
- [--resume-adapter-file loads with strict=False, so misshapen or misnamed weights are silently skipped.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#32-flags-grouped-by-what-they-control) — 12.6
- [Driving train() directly writes only weights; write adapter_config.json yourself or downstream loads fail.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#36-driving-the-trainer-from-python-instead) — 12.6
- [cosine_decay with decay_steps below iters bottoms the LR out early; the tail of training runs at the floor.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#72-schedules-and-warmup) — 12.6
- [Warmup hands off at warmup_steps+1, not warmup_steps, and the cosine clock restarts there - an LR-path off-by-one.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#72-schedules-and-warmup) — 12.6
- [Avoid --optimizer muon from the CLI; build MultiOptimizer in Python. Muon's doc page 404s though the class exists.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#73-the-five-optimizers) — 12.6
- [--iters counts micro-steps, not optimizer updates; with gradient accumulation you get fewer updates than you planned.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#83-the-three-levers-and-how-they-interact) — 12.6
- [With --fine-tune-type full, lora_parameters is None and never read; a full config isn't interchangeable with LoRA's.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#94-what-adapter_configjson-actually-contains) — 12.6
- [--batch-size is global and must be scaled by N; unscaled, each node quietly trains on batch/N.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#96-distributed-fine-tuning-in-one-paragraph) — 12.6
- [generate() returns None, not '', for empty output, and stream_generate(max_tokens=0) raises UnboundLocalError.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#104-generation-ab--the-check-that-actually-decides) — 12.6

**Part 13**

- [skipSpecialTokens defaults to false — decoded text keeps special tokens unless you opt out](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#32-style-1--implement-the-protocols) — 13.1
- [SendableBox.consume() fatalErrors on a second call — a one-shot type that crashes instead of erroring](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#53-mlxarray-is-not-sendable) — 13.1
- [GPU work active during backgrounding triggers an uncatchable Metal abort; cancel and await it on scenePhase.](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#56-cancellation--and-the-ios-crash-it-prevents) — 13.1
- [NSCache eviction isn't coordinated with MLX, and Apple's snippet re-stomps the process-wide cacheLimit on every load](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#84-model-caching-across-a-picker) — 13.1
- [ChatSession is not thread-safe — the source says one task at a time; concurrent use corrupts state unguarded](part-13-mlx-swift/references/02-generation-tools-and-caching.md#22-chatsession--the-layer-you-should-start-at) — 13.2
- [MLXArray is not Sendable — perform callers must eval() before returning values out or they race the stream](part-13-mlx-swift/references/02-generation-tools-and-caching.md#23-modelcontainergenerate-and-the-free-function) — 13.2
- [numDraftTokens defaults to 5 via SpeculativeDecodingConfig but 2 via free generate(draftModel:) — economics shift](part-13-mlx-swift/references/02-generation-tools-and-caching.md#26-speculative-decoding-in-one-page) — 13.2
- [Swift temperature defaults to 0.6, not 0 — ports assuming Python's greedy default sample stochastically](part-13-mlx-swift/references/02-generation-tools-and-caching.md#31-every-field-with-its-default) — 13.2
- [maxTokens nil means unlimited — deliberate in llm-tool, a runaway generation in an app](part-13-mlx-swift/references/02-generation-tools-and-caching.md#31-every-field-with-its-default) — 13.2
- [The third initializer explicitly disables cache quantization — choose it and kvBits quietly stops applying](part-13-mlx-swift/references/02-generation-tools-and-caching.md#42-three-initializers-and-the-one-that-costs-money) — 13.2
- [prompt.didSet doesn't fire in init — mutating images after chat-based construction desyncs media from messages](part-13-mlx-swift/references/02-generation-tools-and-caching.md#52-userinput) — 13.2
- [stopStrings nil falls back to extraEOSTokens — nil and empty array behave differently](part-13-mlx-swift/references/02-generation-tools-and-caching.md#63-stop-tokens-four-sources-one-of-which-overwrites-the-others) — 13.2
- [A bare-id load bypasses the registry — no extraEOSTokens or curated defaults; same model, different behavior](part-13-mlx-swift/references/02-generation-tools-and-caching.md#63-stop-tokens-four-sources-one-of-which-overwrites-the-others) — 13.2
- [gemma's exact-equality rule misses family variants — they fall through to the .json default](part-13-mlx-swift/references/02-generation-tools-and-caching.md#75-detection-toolcallformatinfer-rule-by-rule) — 13.2
- [Older toolCallFormat versions matched 'gemma' exactly, so Gemma 4 fell through and emitted tool calls as text.](part-13-mlx-swift/references/02-generation-tools-and-caching.md#75-detection-toolcallformatinfer-rule-by-rule) — 13.2
- [Mixing ToolCallProcessor's two APIs on one instance corrupts its streaming state machine — the source forbids it](part-13-mlx-swift/references/02-generation-tools-and-caching.md#76-toolcallprocessor--the-streaming-state-machine) — 13.2
- [A protocol-extension-only ropeOffset would be statically shadowed — subclass overrides silently ignored via existentials](part-13-mlx-swift/references/02-generation-tools-and-caching.md#81-the-protocol) — 13.2
- [newCache derives cache count from kvHeads.count — an unassigned empty array builds zero caches and crashes](part-13-mlx-swift/references/02-generation-tools-and-caching.md#84-where-the-cache-actually-gets-created) — 13.2
- [Calling cache.update(...) yourself before attentionWithCacheUpdate double-applies it and corrupts the cache](part-13-mlx-swift/references/02-generation-tools-and-caching.md#87-cross-turn-reuse-and-the-attentionwithcacheupdate-footgun) — 13.2
- [.required with an empty tool list throws instead of degrading to plain generation](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#85-the-tool-paths) — 13.3
- [TokenizerInfo.init defaults vocabType .raw; sessions default .byteLevel — hand-built infos silently use wrong semantics](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#92-the-three-types-you-touch) — 13.3
- [GuidedGenerationLoop.run must not be called from @MainActor — the README's warning is load-bearing](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#93-guidedgenerationlooprun--the-signature) — 13.3
- [Never hand-build an LMInput — a 1-D input aborts the process; go through the provided constructors](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#133-the-1-d-lminput-process-abort) — 13.3

**Part 14**

- [The console script omits --batch-size while the Python function accepts batch_size and raises for anything but 1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#31-the-command) — 14.1
- [Omitting metadata_version defaults it to '0.1' and the reader throws unsupportedVersion — write the string '0.2'](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#42-what-the-reader-enforces) — 14.1
- [A .aimodel path where a bundle dir is expected throws pointedAtModelAsset — guarding a misleading version error](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#42-what-the-reader-enforces) — 14.1
- [Capture runs the model twice (trace plus reference) — RNG or dropout diverges unless capture_is_training=False](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#54-capture-mlxs-callback-event-contract) — 14.1
- [generate_composite_decl mutates the caller's dict in place — reuse carries state you didn't put there](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#56-named-composites-the-fused-kernel-hint) — 14.1
- [Never run an iOS-compiled bundle on a Mac — it can wedge the GPU/ANE stack into a watchdog reboot](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#63-the-parity-testing-recipe) — 14.1
- [CoreAILanguageModels.ModelConfig (bundle config) is not the similarly named model configuration — name collision](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#94-the-bundle-loader-verbatim) — 14.1
- [The two prompt paths have opposite image-placeholder requirements and the same error case](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#97-the-image-placeholder-contract--an-asymmetry-that-will-catch-you) — 14.1

## General cautions

**Part 12**

- [Scope note: the MLX stack moves weekly; pin versions or every dated claim in this part may have drifted.](part-12-mlx-python/README.md#️-pin-your-versions-every-date-in-this-part-is-suspect) — 12.README
- [Scope note: signatures below are verified against source and docs; check the evidence ladder before trusting.](part-12-mlx-python/references/01-core-fundamentals.md#️-read-this-before-you-trust-a-signature-below) — 12.1
- [The mx.metal.* memory spellings are deprecated and print to stderr on first call; use the top-level equivalents.](part-12-mlx-python/references/01-core-fundamentals.md#15-where-unified-memory-stops-being-free) — 12.1
- [The applegpu g/s suffix-to-product mapping is disputed between MLX source and community; don't identify products by it.](part-12-mlx-python/references/01-core-fundamentals.md#106-querying-the-device) — 12.1
- [cross_entropy's reduction defaults to 'none' and accepted literals are unverified; omit it and average yourself.](part-12-mlx-python/references/01-core-fundamentals.md#114-the-update-model-and-how-it-differs-from-pytorch) — 12.1
- [Scope note: verify signatures below against source; the NAX story is new and evidence is mixed.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#️-read-this-before-you-trust-a-signature-below) — 12.2
- [The M5 material is a launch Tech Talk, not a WWDC session; weigh its numbers accordingly.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#41-what-the-hardware-is-per-apple) — 12.2
- [Do not write a blanket '26.2 required'; Apple's own narrated version ladder skips 26.2 entirely.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#42-the-version-story-stated-carefully) — 12.2
- [MLX's g/s suffix table and community observation disagree; use the suffix for buffer sizing, never product ID.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#44-there-is-no-capability-query--here-is-the-heuristic-mlx-uses) — 12.2
- [Do not use mx.metal.device_info(); the mx.metal.* family is deprecated and forwards with a stderr notice.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#45-a-probe-you-can-run-and-an-ab-switch) — 12.2
- [Each Apple M5 speedup uses a different baseline; a number without its baseline is meaningless.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#46-apples-own-numbers-with-their-baselines) — 12.2
- [Every figure here is Apple-published with hardware and OS unstated beyond 'M5'; don't generalize.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#46-apples-own-numbers-with-their-baselines) — 12.2
- [Fused SDPA is inference-only on Metal; training deliberately uses the unfused path, which is what benchmarks measure.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#52-the-complete-fallback-table) — 12.2
- [Correction: Gemma 4's global layers are head_dim 512, not 256; a clean A/B showed no change at 32K/64K.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#54-what-it-costs-measured) — 12.2
- [The fused grid-sample speedup is MLX's own published number with hardware unstated; re-measure on your machine.](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md#82-the-realistic-one-fused-bilinear-grid_sample) — 12.2
- [Scope note: quantization numbers below carry mixed provenance; check each one's sourcing before quoting.](part-12-mlx-python/references/03-quantization.md#️-read-this-before-you-trust-a-number-below) — 12.3
- [The routed-only read numbers are community-measured (john-rocky, partly agent-generated repo), not Apple-published.](part-12-mlx-python/references/03-quantization.md#74-what-routed-only-reads-are-worth--community-measurements) — 12.3
- [Scope note: flag names below were verified against argparse declarations, not the docs.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#️-read-this-before-you-trust-a-flag-name-below) — 12.4
- [Marker for this guide's register of six silent failures; none of them throw.](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md#️-read-this-before-you-trust-a-flag-name-below) — 12.4 🔇
- [Scope note: server signatures verified from source at a pinned commit; PyPI lags main by months.](part-12-mlx-python/references/05-serving-and-distributed.md#️-read-this-before-you-trust-a-signature-below) — 12.5
- [Freshness: NAX code paths are new and moving, with three correctness fixes within days of writing.](part-12-mlx-python/references/05-serving-and-distributed.md#101-the-m5-neural-accelerators) — 12.5
- [--host 0.0.0.0 exposes a server with no authentication; anyone on the network can drive your model.](part-12-mlx-python/references/05-serving-and-distributed.md#113-xcode-27--the-one-most-readers-will-use) — 12.5
- [HTTP exposes no logits, so @Generable guided generation is unavailable on this path; use tools plus your own validation.](part-12-mlx-python/references/05-serving-and-distributed.md#️-the-v1-path-bug-you-will-hit-within-five-minutes) — 12.5
- [Ring backend restriction: send and recv work only between ring neighbours, not arbitrary ranks.](part-12-mlx-python/references/05-serving-and-distributed.md#142-the-one-property-that-removes-all-your-if-statements) — 12.5
- [Counterweight mlx#3830: FAST_SYNCH can deadlock a Metal fence and lock the GPU until reboot; unset, the watchdog fires.](part-12-mlx-python/references/05-serving-and-distributed.md#️-mlx_metal_fast_synch1-is-not-optional) — 12.5
- [Not all models support pipeline parallelism; check before planning a pipelined topology.](part-12-mlx-python/references/05-serving-and-distributed.md#21-tensor-vs-pipeline-parallelism) — 12.5
- [Apple's distributed speedup comes with its own caveat - it depends on setup; quote the caveat with the number.](part-12-mlx-python/references/05-serving-and-distributed.md#24-apples-measured-numbers) — 12.5
- [180 to 600 tok/s are the session's only absolute figures; every other distributed claim is a ratio.](part-12-mlx-python/references/05-serving-and-distributed.md#24-apples-measured-numbers) — 12.5
- [The RDMA port forum report is community-reported with unknown status and no replies captured.](part-12-mlx-python/references/05-serving-and-distributed.md#251-the-community-rdma-port-report) — 12.5
- [Every file:line cite pins commit e5baded; on any other commit expect line numbers to have drifted.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#evidence-ladder-used-in-this-guide) — 12.6
- [--mlx-path must not already exist and there is no --force; delete the previous output directory first.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#51-there-is-no---qlora-flag) — 12.6
- [Dropout fires only in training mode; train() and evaluate() toggle it, so know which mode your loop left the model in.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#65-dropout) — 12.6
- [The memory-constrained path's loader accepts only .jsonl with a text field (or one alternate); other formats fail.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#86-what-oom-looks-like--on-a-mac-and-why-not-on-a-phone) — 12.6
- [mlx_lm.perplexity takes no --adapter-path; fuse the adapter first to measure it this way.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#102-perplexity-on-held-out-general-text--the-forgetting-check) — 12.6
- [lm-eval with --limit 200 across eight tasks is a smoke test, not a benchmark; don't publish those numbers.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#103-benchmarks--the-capability-check) — 12.6
- [Publish the adapter alongside the fused model; it's two orders of magnitude smaller and others can rebase it.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#116-uploading) — 12.6
- [mlx_lm.server's own startup banner says it is not recommended for production; treat it as a dev tool.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#step-10--serve-and-hand-off) — 12.6
- [This section is project READMEs only — nothing in it was cloned, run or measured; treat flag names as pointers to check.](part-12-mlx-python/references/06-finetuning-and-porting-models.md#13-beyond-mlx_lmlora-the-third-party-training-layer) — 12.6

**Part 13**

- [SerialAccessContainer and SendableBox are package-scoped — reimplement the pattern or use ModelContainer](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#52-serialaccesscontainer--and-why-it-is-not-an-actor) — 13.1
- [Streams always end with a .info event carrying stopReason and timings — rely on it, but don't copy llm-tool's fatalError](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#58-throwing-versus-non-throwing-streams) — 13.1
- [Evidence on the EXIF fix conflicts between research passes — reported as conflicting, not smoothed over](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md#74-️-exif-orientation--the-bug-apple-fixed-in-their-own-sample) — 13.1
- [Scope note: trust no signature below without the stated verification caveats](part-13-mlx-swift/references/02-generation-tools-and-caching.md#️-read-this-before-you-trust-a-signature-below) — 13.2
- [Four items were not read this session and are deliberately not asserted](part-13-mlx-swift/references/02-generation-tools-and-caching.md#️-read-this-before-you-trust-a-signature-below) — 13.2
- [Marker definition: SILENT FAILURE means it does not throw — this guide catalogues nine](part-13-mlx-swift/references/02-generation-tools-and-caching.md#️-read-this-before-you-trust-a-signature-below) — 13.2 🔇
- [Returning a string for an unknown tool (not throwing) is the right default — the model can read the failure and retry](part-13-mlx-swift/references/02-generation-tools-and-caching.md#77-the-end-to-end-loop-both-ways) — 13.2
- [keep:4 attention sinks make rotating caches unquantizable/unmergeable in Python; the Swift guard is unverified](part-13-mlx-swift/references/02-generation-tools-and-caching.md#84-where-the-cache-actually-gets-created) — 13.2
- [gpt-oss attention sinks are incompatible with quantized SDPA — a family-specific hard stop](part-13-mlx-swift/references/02-generation-tools-and-caching.md#85-quantized-kv-kvbits-kvscheme-and-turboquant) — 13.2
- [Detection-script print: caches without rollback or prefix reuse make speculative decoding unsafe](part-13-mlx-swift/references/02-generation-tools-and-caching.md#94-how-to-detect-all-three-in-your-own-app) — 13.2
- [Detection-script print: rotating layers make trimmability temporary — it lapses once the window wraps (#424)](part-13-mlx-swift/references/02-generation-tools-and-caching.md#94-how-to-detect-all-three-in-your-own-app) — 13.2
- [Detection-script print: surfaces the kvBits and quantizedKVStart combination so the trade-off is visible](part-13-mlx-swift/references/02-generation-tools-and-caching.md#94-how-to-detect-all-three-in-your-own-app) — 13.2
- [Sample output: rotating layers present — trimmability is temporary (issue #424)](part-13-mlx-swift/references/02-generation-tools-and-caching.md#94-how-to-detect-all-three-in-your-own-app) — 13.2
- [swift test does not work on this package — use xcodebuild with -skipPackagePluginValidation (and -skipMacroValidation)](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#34-building-and-testing) — 13.3
- [Scope note on the logger: some drops surface only at debug level — logging bounds what it can save you from](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#76-️-silent-failure-the-prewarm-witness-must-match-exactly) — 13.3
- [The mapper's precedence ladder exists to avoid a silent failure — internalise it before writing your own](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#82-samplingmodemapper--three-cases-one-precedence-ladder) — 13.3
- [MLXDownloadProgress lives and dies with the adapter's gate — disable the trait and dependent UI stops compiling](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#89-mlxdownloadprogress--the-observable) — 13.3
- [Batching forced tokens with a populated cache hits an MLX causal-mask bug — the loop feeds them one at a time](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#96-fast-forward-tokens-and-the-tokenization-boundary-problem) — 13.3
- [The vendored xgrammar is pinned at v0.1.30 — upstream fixes past that version are absent](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#98-constraint-cloning-and-the-fork-fallback) — 13.3
- [Attribution: supportsLogits and the CoreAIExecutor error string come from community reads, not Apple docs](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#111-the-statement) — 13.3
- [The backend differential is community-measured from a single setup — treat as protocol, not truth](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md#113-what-this-means-for-a-backend-decision) — 13.3

**Part 14**

- [Read-first note: this part rests on source reads of community bridges, not Apple documentation](part-14-bridges-between-stacks/README.md#️-read-this-before-you-trust-anything-in-this-part) — 14.README
- [No WWDC transcript is cited anywhere in this part — nothing here has Apple-session backing](part-14-bridges-between-stacks/README.md#sources-for-this-part) — 14.README
- [Signature-trust scope note — verify against your checkout before relying on anything below](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#️-read-this-before-you-trust-a-signature-in-this-guide) — 14.1
- [mlx2coreai writes only kind:'llm' — no VLM path exists; use Apple's exporter or swift-lm for vlm bundles](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#44-the-vlm-variant) — 14.1
- [Shape-dependent Python branches produce two divergent traces and the probe raises — no data-dependent branching](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#57-dynamic-shapes-need-a-probe-and-shapelesstrue-is-not-enough) — 14.1
- [The two backends differ by one (steps vs steps+1) under --grow-context — two hand-written copies of one contract](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#57-dynamic-shapes-need-a-probe-and-shapelesstrue-is-not-enough) — 14.1
- [The community zoo is single-author, benchmarks self-declared uncontrolled — process guidance, not Apple fact](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#11-the-community-zoo) — 14.1
- [Core AI conversion is not byte-deterministic (measured) — never verify a pipeline by hashing artifacts](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#113-process-engineering-worth-stealing) — 14.1
- [metadata.json can embed your build machine's absolute paths — the zoo shipped one; audit what you emit](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#113-process-engineering-worth-stealing) — 14.1
- [Cite BENCHMARKS.md as a protocol, not a dataset — n=1 numbers on specific hardware](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#114-the-benchmark-protocol--cite-it-as-a-protocol-not-a-dataset) — 14.1
- [No WWDC transcript is cited in this guide — the 2026 session corpus does not cover these bridges](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md#142-evidence-classes-used) — 14.1

---

🔇 = the guide marks this as an explicit **SILENT FAILURE** callout.
