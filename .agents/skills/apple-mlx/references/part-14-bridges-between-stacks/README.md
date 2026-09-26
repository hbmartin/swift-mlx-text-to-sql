# Part 14 — Bridges between stacks

**Version floor:** **macOS 27 / iOS 27** for anything that *executes*, **Python 3.11+** to convert, and
a set of wheel pins that **do not agree with each other**. `mlx2coreai` 0.1.1 pins
**`coreai-core==1.0.0b1`** exactly; `1amageek/swift-lm` 0.11.0-alpha.1 pins **`coreai-core==1.0.0b2`,
`coreai-torch==0.4.1`, `coreai-opt==0.2.1`, `torch==2.9.0`**; and `john-rocky/coreai-model-zoo`'s
acceptance bar requires **`coreai-core ≥ 1.0.0b2`**, because bundles exported with earlier wheels are
*"rejected by the Xcode 27 beta 3+ SDK loader"* (`Failed to convert to versioned IR`, **FB23666783**).
The main subject of this part pins the exact wheel the community's own bar rejects. Both Swift packages
declare `platforms: [.macOS("27.0"), .iOS("27.0")]` and Swift tools **6.4**.

**Who this is for:** you already have a model working in *one* stack — MLX, a Hugging Face checkpoint, a
bundle someone else built — and you want it in **Core AI**. Also for the person writing a third bridge,
and for the Swift developer who has to consume somebody else's `.aimodel` bundle. This is the
**Advanced** part of the series: it assumes Parts 7, 8 and 12 as vocabulary and does not re-teach them.

---

## ⚠️ Read this before you trust anything in this part

**Nothing in this part was executed.** `coreai-core` is not installed in the environment these notes
were taken in and there is no macOS 27 SDK on the machine to compile the Swift runners against. Every
signature, flag and error string was **read from source** — three third-party repositories plus the
Apple repos they target — and the source is honest about being a beta-era moving target.

**And the caveat the whole part turns on.** `mlx2coreai`'s own op-coverage report opens with:

> *"Coverage type: CoreAI asset generation. This does not imply runtime numerical parity."*

✅ VERIFIED, `docs/op_coverage.md:3`, verbatim. Its "Asset validation: passed" line is a **file-existence
check** — `assert (asset_path / "main.mlirb").exists()`. Not an execution, not a comparison. The 156-op
table tells you what will *convert*; it tells you nothing about what will be *correct*.

> 🔴 **GAP — nothing in our corpus verifies a converted MLX model end to end on a device.** Not one
> token. Not one logit vector. The bridge's own CI cannot do it (there is no Core AI runtime to execute
> against), the packaged Python API literally *cannot run* the stateful asset it produces (§8.1), and no
> community report of a device-run `mlx2coreai` model exists in the material behind this series. §6.3 is
> a parity-testing recipe you are expected to run yourself, and until you have run it you have a bundle,
> not a port.

---

## Why this part exists

Every route into Core AI ends at the same artifact — a `.aimodel`, which is a *directory* holding
serialized Core AI MLIR, a hash and a metadata blob. What changes is the producer, and in 2026 there are
suddenly third-party producers. That creates four problems the first-party parts do not have.

1. **The bridge stands on private API.** `mlx2coreai` calls `AIProgram._from_mlir_module` — a leading
   underscore — for its entire existence, plus `CoreAITensorSpec._to_mlir_type()` and a `GraphOp(...)`
   whose declaration appears **nowhere in our corpus**. A wheel bump can break the converter without
   breaking anything Apple documents.
2. **A format became a standard without anyone publishing it.** `apple/coreai-models`'s bundle
   `metadata.json` schema `"0.2"` is now a **de-facto interchange format**: three independent producers
   emit byte-comparable manifests, because Apple's Swift loader is strict and because once you emit it,
   `CoreAILanguageModel(resourcesAt:)` just works on your output. If you build a bridge, this is the
   thing to target — and it is specified in no document.
3. **Converting succeeds far more often than it is correct.** §7 lists eight places where the
   MLX→MLIR reconstruction is known to be lossy. Every one of them produces an asset that *saves*.
   Several produce output that is *plausible*. That combination is what the zoo's `AGENTS.md` calls
   the most expensive failure mode, *"because it looks like success."*
4. **The stacks disagree with each other in public.** `expectFrequentReshapes` has four sources and
   three verdicts — Apple's own code sets it `true` for exactly the model shape `mlx2coreai` produces,
   `mlx2coreai`'s own Swift runner sets it `false` on that same shape with no comment, `swift-lm`
   throws if you pass it, and the community has a device-validated SIGSEGV. A bridge author still has
   to pick a value.

---

## Read this first: the triage table

There is one guide in this part, so the column that matters is the **section**.

| If your situation is… | Read | Why |
|---|---|---|
| "I have an `mlx-lm` causal LM and want a Core AI bundle" | [14.1 §3](references/01-mlx2coreai-and-third-party-bridges.md#3-the-stateful-llm-path), then **§6** | One command; it reproduces Apple's `keyCache`/`valueCache` contract exactly. §6 is not optional |
| "I have an MLX vision or audio model — one graph, no state" | [14.1 §5](references/01-mlx2coreai-and-third-party-bridges.md#5-the-generic-path-and-the-pipeline-by-module-name) | The generic converter. `ConversionConfig` field by field, and the three fields that need a warning label |
| "It converted. The text is fine at step 1 and nonsense by step 30" | [14.1 §3.5, §7](references/01-mlx2coreai-and-third-party-bridges.md#35-position_ids-is-the-full-position-vector) | The classic KV-offset bug, and the eight lossy lowerings that produce plausible garbage |
| "I am writing my own bridge / my bundle won't load" | [14.1 §4](references/01-mlx2coreai-and-third-party-bridges.md#4-the-bundle-layout-is-the-interchange-format) | Schema 0.2 field by field, what Apple's reader enforces, and a targeting checklist |
| `unsupported metadata_version '0.1'` | [14.1 §4.2](references/01-mlx2coreai-and-third-party-bridges.md#42-what-the-reader-enforces) | Absent key defaults to `"0.1"`; or you pointed at the `.aimodel`, not the bundle dir |
| `Failed to convert to versioned IR` | [14.1 §2.3](references/01-mlx2coreai-and-third-party-bridges.md#23-️-the-wheel-pin-collision) | The wheel-pin collision, plus a ninety-second probe that settles it before a 4 GB conversion |
| "My model has sliding-window attention, an SSM block, or MoE" | [14.1 §2.4, §12.1](references/01-mlx2coreai-and-third-party-bridges.md#24-what-it-does-not-have) | `make_mask` raises `NotImplementedError`; no SSM lowering. Not this bridge |
| "I need to consume a Core AI bundle — or a VLM — from Swift" | [14.1 §9](references/01-mlx2coreai-and-third-party-bridges.md#9-swift-lm-a-real-third-party-core-ai-integration) | The densest inventory of `CoreAILanguageModels` outside Apple's own repo, and the three-asset VLM contract |
| "Should I set `expectFrequentReshapes`?" · "SIGSEGV at `AIModel(contentsOf:options:)`" | [14.1 §10](references/01-mlx2coreai-and-third-party-bridges.md#10-expectfrequentreshapes-four-sources-three-verdicts) | Four sources, three verdicts, one device-validated crash, and a safe default ladder |
| "I need to benchmark this" | [14.1 §8.3, §11.4](references/01-mlx2coreai-and-third-party-bridges.md#83-the-build-recipe-and-the-auto-selection-trap) | The backend auto-selection trap, and why thermals move numbers 2.3–4.1× |
| "Should I convert at all?" · "Is Core AI even the right target?" | [14.1 §12](references/01-mlx2coreai-and-third-party-bridges.md#12-decision-table-which-bridge-and-when-to-re-author-instead) | Five cases where re-authoring is the honest answer, and a Core AI vs MLX head-to-head |

---

## The guide in this part

### [14.1 — Bridges into Core AI: `mlx2coreai`, `swift-lm`, and the community zoo](references/01-mlx2coreai-and-third-party-bridges.md)

Three bridges, one destination. **§2–§8 cover `lucasnewman/mlx2coreai`** — the only tool in existence
that goes MLX → Core AI without passing through PyTorch, and the vehicle for two facts worth more than
the tool itself: **Core AI's IR is MLIR** (the imports are literally MLIR's Python bindings, and
`str(program)` gives you readable MLIR text), and **the bundle layout is an interchange format** you can
target. **§9–§10 cover `1amageek/swift-lm`**, one of very few real third-party Core AI integrations you
can read, including Apple's three-asset VLM contract and a documented rejection of
`expectFrequentReshapes` that contradicts Apple's own shipping code. **§11 covers
`john-rocky/coreai-model-zoo`** — single-author community material, attributed as such throughout, whose
*porting playbook* is the best written-down process for this work anywhere. **§12** is the decision
table, including the case where the answer is "re-author from the checkpoint instead."

> ⚠️ **SILENT FAILURE — `position_ids` is the *full* position vector (§3.5).** The KV write offset is
> computed **inside the traced graph** as `max(position_ids) - len(input_ids) + 1`. Pass only the new
> positions, right-pad with a sentinel, or feed them non-monotonically, and keys and values land at the
> wrong slice of a 5-D cache. The arithmetic is valid for any input, so nothing throws; logits stay
> finite, the sampler keeps producing tokens, and the text degrades *gradually*. Code review will not
> find this — only a token-for-token comparison against the MLX original will.
>
> ⚠️ **SILENT FAILURE — the lowerings that convert and lie (§7).** A **boolean** attention mask is
> `cast` and **added**, so `True` becomes `+1.0` on every visible position and masked positions are left
> completely unmasked — and `passes.py` computes a `mask_mode` attribute that would fix it which the
> lowering **never reads**. General `conv_transpose` lowers to a **zero constant** — only the 1×1
> stride-1 case gets a real implementation, and the coverage report counts the placeholder as covered
> (grep the MLIR for `unsupported_coreai_beta_asset_writer`). `mx.log2` / `mx.log10` collapse to natural
> log and `left_shift` / `right_shift` collapse to bitwise **AND**, because MLX remaps them to shared
> primitive names and the base/op selector is dropped. `allow_unknown_sources=True` — the **default** —
> invents `TensorSpec(shape=(), dtype="fp32")` for any tensor it cannot spec.
>
> ⚠️ **SILENT FAILURE — the tooling around it (§8, §9.8, §11.3–§11.4).** `mlx2coreai.run_aimodel`, the
> packaged public API, has **no `state=` argument**, so it cannot execute the stateful asset the tool's
> headline command produces. The benchmark's `--runtime-backend auto` silently swaps Swift for Python,
> and the README's own invocation includes `--decode`, which is on the Swift backend's reject list — so
> the documented command quietly measures the slower path. Every Core AI test in `swift-lm` is gated on
> an env var with `else { return }`, so a green run **passes without running anything**. Core AI
> conversion is **not byte-deterministic** (community-measured: same recipe, same machine, minutes
> apart — `main.mlirb` differs by 7 bytes, `main.hash` entirely), so a stored hash is worthless as a
> reproducibility criterion. And in a persistent Python runner, letting the `AIModel` get garbage
> collected while holding only the loaded function returns **garbage output with no crash**.
>
> 🔴 **GAP — the Python surface is inferred from call sites, and it is thin.** `GraphOp(...)`'s keyword
> arguments, `coreai.slice_`'s argument order, `NDArray(data=, backing=)` and
> `function(inputs=, state=)` appear only as *calls* in third-party code; no declaration exists anywhere
> in our corpus. Whether `function(inputs=, state=)` mutates state **in place** is unstated — assume it
> does and never reuse a state dict across sequences. `SpecializationOptions.expectFrequentReshapes` has
> an abstract of one sentence, **no Discussion and no documented default**. And nobody has read how
> Apple's official VLM exporter is invoked, though `swift-lm` consumes its output. The guide's §14.3
> collects fifteen open gaps, each with what would resolve it.

---

## Reading order

**Everyone starts with the guide's intro block and [§6](references/01-mlx2coreai-and-third-party-bridges.md#6-️-asset-generation-coverage-is-not-numerical-parity)**,
then **§2.3**. That is fifteen minutes and it changes what you do next: §6 tells you that 156/156 op
coverage is an asset-generation claim, and §2.3 tells you the wheel you are about to install may write
bundles the current SDK loader rejects. Reading §3 before §6 is how people lose a week.

**Then branch by what you have.** *An `mlx-lm` LLM:* §3 in full (the signature, the `position_ids`
contract, the cache shim) → **§6.3's parity recipe** → §7 to interpret the failures → §8 when you need
to actually run or measure it. *A non-LLM MLX model:* §5 → §6 → §7, and skip §3 entirely. *Writing a
bridge or a bundle producer:* §4 end to end, then §9.5, which is the validator you should write on the
consuming side. *A Swift developer consuming somebody's bundle:* §9, plus §10 only if you touch
`SpecializationOptions`.

**Read one thing out of order:** [§12.3](references/01-mlx2coreai-and-third-party-bridges.md#123-one-more-consideration-is-core-ai-even-the-right-destination) — *is Core
AI even the right destination* — belongs **before** you start, not after. Community head-to-heads put
dense transformers at tie-to-+12 % for Core AI, MoE at **0.5–0.78×** (MLX wins), and exotic attention as
a loss; and guided generation needs logits the GPU-pipelined Core AI path does not expose.

**Deferrable.** §11 is process and community catalogue — genuinely excellent, and skippable on a first
pass *except* §11.3 (the four-state `PASS`/`DIFF`/`FAIL`/`skipped` verdict model, and non-determinism)
and §11.4 (thermals, `cpu_only()` being ~9–10× slower and a *parity* option not a performance one).
§5.4's MLX callback event contract is only for people writing their own capture. §9.6–§9.7 are VLM-only.
§13 is a quick reference to come back to; §13.5 lists all fourteen silent failures in one table.

---

## What this part deliberately does not cover

- **The PyTorch → Core AI path itself.** `coreai_torch.TorchConverter`, `get_decomp_table()`,
  `state_names`, `remove_functionalization` and the export pipeline are
  [Part 8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md) and
  [Part 10](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/README.md). This part treats them as the *destination*
  of a bridge, not the subject.
- **Running the result.** `AIModel`, `InferenceFunction`, `NDArray`, `MutableViews`, states, pipelined
  decode, bundles, engines and guided decoding: [Part 7](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md).
  Specialization, the model cache, AOT and `expectFrequentReshapes` *in its own right* are Part 7 guide
  02 — §10 here covers only the third-party **disagreement** about that flag.
- **MLX itself.** `mx.export_function`, the primitive `state()` tuples, mlx-lm's cache protocol:
  [Part 12](../part-12-mlx-python/README.md) and [Part 13](../part-13-mlx-swift/README.md). This part assumes you can
  already produce a working MLX model.
- **Compression.** Neither bridge quantizes anything — `mlx2coreai` has no palettization, no int4/int8
  packing and no `coreai-opt` integration at all. [Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md).
- **Choosing a backend behind `LanguageModelSession`.** `MLXLanguageModel` vs `CoreAILanguageModel` vs
  the rest of the five conformers: [Part 1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/README.md) and
  [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md).
- **Measuring whether the port is any good as a product**, versus numerically faithful:
  [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md). **Delivery, first-run UX and OS-update re-specialization:**
  [Part 15](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/README.md). **Coming from `coreai-torch` 0.4.x or Core ML:**
  [Part 17](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md).

---

## Sources for this part

Local clones of three third-party repositories, read on disk and **never executed**:
`lucasnewman/mlx2coreai` at HEAD **`059c9f3`** (11 commits, all June 2026, MIT, one author — all line
numbers in the guide refer to that commit, and the README's own history is quoted via `git show` to
retire a stale bf16 claim); `1amageek/swift-lm` at **`db7a802`** *"Add Core AI vision language model
adapter"* (2026-07-18), including its `PHILOSOPHY.md`, design docs and release notes; and
`john-rocky/coreai-model-zoo`, whose catalogue inventory is dated **2026-07-25** and whose
`expectFrequentReshapes` crash report is **device-validated 2026-07-23 on iPhone 17 Pro** —
community-sourced, single-author, benchmarks self-declared as uncontrolled, and labelled as such at
every point of use. **Apple repositories for the destination contracts:** `apple/coreai-models`
(`export/bundle.py`, `export/_constants.py`, `primitives/macos/cache.py`, `ModelBundle.swift`,
`BundleKind.swift`, `FunctionMap.swift`, `LanguageConfig.swift`, `Runtime/ModelStructure.swift`, and the
`model-authoring` skill's PSNR gate bars) and `apple/coreai-torch`. **`ml-explore/mlx` C++ source**
(`export.cpp`, `primitives.h`) for the callback event contract and the primitive `name_remap` collapses,
cross-verified against MLX's own test. ⚠️ **No WWDC transcript is cited anywhere in this part** —
nothing in the 2026 session corpus covers these bridges — and Core AI ships **zero** Apple sample-code
projects, so the evidence class this series normally leans on hardest is simply absent here. That
absence is the reason the parity section exists.
