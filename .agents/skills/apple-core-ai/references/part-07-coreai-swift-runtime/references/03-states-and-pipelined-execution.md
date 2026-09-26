# States as KV cache, and pipelined execution

**Part 7 · Core AI: the Swift runtime · Reference 03**

**Version floor:** everything in this guide is **27.0 and only 27.0** — iOS 27.0, iPadOS 27.0,
macOS 27.0, Mac Catalyst 27.0, tvOS 27.0, visionOS 27.0, watchOS 27.0, all marked **Beta**. Core AI
did not exist before the 27 cycle; there is no back-deployment story, no `@available` fallback that
buys you anything on 26.x, and **no Core AI release-notes page** to diff against
(`/documentation/updates/coreai` returns 404, and the word "coreai" does not appear anywhere in
Apple's Updates hub). Build with **Xcode 27**, and install the **Metal Toolchain** separately or any
target containing a `.aimodel` fails to build with a missing-Metal-compiler error.

Three carve-outs inside that floor matter for *this* guide specifically, because the pipelining half
of it is built on Metal:

- **`ComputeStream.init(commandQueue:)` is unavailable on watchOS.** So are
  `InferenceFunction.AsyncValue.init(unsafeBuffer:…)` and `NDArray.RawView.init(metalBuffer:…)`.
  The plain `ComputeStream()` initializer and `currentWorkCompleted()` *do* include watchOS.
- **`.aimodel` is a directory**, not a file, and it must appear in your target's **Compile Sources**
  build phase.
- Every symbol page in Apple's docs omits macOS from `metadata.platforms` even though the framework
  page lists it. That is a documentation-generation bug — `coreai-build`, the Core AI Debugger and
  the Instruments template are all macOS-hosted — but do not be surprised by it.

⚠️ **Evidence weighting for all of Part 7.** Core AI ships **zero Apple sample-code projects** —
verified against Apple's own index: 0 `sampleCode` entries across all 312 indexed Core AI symbols.
Unlike Parts 1–6 there is no first-party compiling reference to check a signature against. The
strongest evidence available is, in order: Apple's reference documentation (which for Core AI is
unusually complete — full declarations, parameter docs, discussion sections), the shipped
`apple/coreai-models` Swift package and its agent skills, `apple/coreai-torch`'s test suite, and
then WWDC26 session narration. Community repositories are labelled as such every time. Where a
signature below is reconstructed rather than quoted, it says so.

---

## What this covers

A transformer decode loop written the naive way gets slower every step. In Apple's own WWDC26
walkthrough this shows up as a game that visibly slows down and, in the Core AI instrument, as
**inference intervals that grow along the timeline**. The fix is the single highest-leverage
technique in the Core AI runtime: **states** — function arguments that the model both *reads* and
*writes in place* during inference.

This guide teaches states across all three layers they touch, because they are one feature with
three separate spellings and a mistake at any layer produces a model that converts fine and then
misbehaves:

1. **Authoring (PyTorch).** `torch.register_buffer` plus in-place mutation inside `forward()`. The
   buffer becomes a *mutable buffer* in the exported program, which Core AI turns into a state.
2. **Conversion (Python).** `state_names=` on the converter call, its ordering rule, and the three
   ways to get it silently wrong.
3. **Runtime (Swift).** Holding the cache `NDArray`s yourself, building an
   `InferenceFunction.MutableViews` collection, and passing it as the `states:` argument of
   `InferenceFunction.run`.

Then the tier above `run()`: **pipelined execution**. `InferenceFunction.encode(…, to:)` is
`throws`, not `async throws` — it returns as soon as work is *encoded* onto a `ComputeStream`, so
the CPU can encode step *n+1* while the GPU is still computing step *n*. This guide covers
`AsyncValue`, `AsyncMutableValue`, `AsyncMutableViews`, the automatic data-dependency serialization
`ComputeStream` provides, and a real pipelined decode loop read out of Apple's shipping engine —
pipeline depth, buffer rotation, backpressure, and an empty-command-buffer completion sentinel.

It also covers, honestly:

- **The fixed max-context tradeoff.** Apple's Snake example allocates its caches at the maximum
  possible context length, up front, forever. That is a real memory decision and there is a
  spectrum of alternatives with names.
- **Four silent failures** around states, one of which — a copy-on-write trap that copies the entire
  KV cache on every single decode step — costs tens of megabytes of memcpy per token and produces no
  error, no warning, and no crash.
- **A community-documented beta bug** in which Apple's own documented fixed-shape/ANE decode recipe
  converts successfully and then dies at load or first execute, differently on three platforms, plus
  two workarounds, one of which is genuinely clever.
- **What pipelining is actually worth**, with the widely-repeated 3.5× figure attributed to the
  comparison it was actually measured against — which is *not* the sequential engine.
- **Prefix reuse**, where trimming a KV cache turns out to be a single integer assignment worth
  ~101× on turn-2 time-to-first-token, and why linear-attention and hybrid models forfeit it
  entirely.

## What this does *not* cover

- **`AIModel`, `NDArray`, views, spans and the memory model.** States are `NDArray`s and the whole
  guide assumes you can allocate, write and read one. See
  [`01-runtime-and-ndarray.md`](01-runtime-and-ndarray.md).
- **Specialization, `AIModelCache`, and `coreai-build`.** Everything here happens *after* a model is
  specialized and loaded. See
  [`02-specialization-caching-and-aot.md`](02-specialization-caching-and-aot.md).
- **Model bundles, the four LLM engines and guided decoding.** The `apple/coreai-models` Swift
  package wraps most of this guide in a higher-level API; when you should use it instead of writing
  your own loop is that guide's question, not this one. See
  [`04-bundles-engines-and-guided-decoding.md`](04-bundles-engines-and-guided-decoding.md).
- **Authoring the PyTorch side properly** — ANE-vs-GPU layout rules, chunked prefill, the mask
  conventions. Part 8 and Part 10 own those. This guide covers exactly the slice of authoring that
  produces a *state*.

## What you need

- **Xcode 27** with the Metal Toolchain installed
  (`xcodebuild -downloadComponent MetalToolchain`), and a real device for any number you intend to
  believe.
- A converted `.aimodel` with at least one state, or the willingness to convert one. The fastest
  path to a stateful LLM asset is `apple/coreai-models`' export recipe
  (`uv run coreai.llm.export Qwen/Qwen3-0.6B`), which produces exactly the contract §7 dissects.
- Comfort with Swift ownership: `consuming`, `borrowing`, `inout`, `~Escapable`, `Span`. Core AI is
  one of the heaviest users of these features in the whole SDK and the `states:` API is unreadable
  without them. [`01-runtime-and-ndarray.md`](01-runtime-and-ndarray.md) teaches them against this
  framework specifically.

---

## Contents

1. [The symptom: intervals that grow](#1-the-symptom-intervals-that-grow)
2. [What a state is](#2-what-a-state-is)
3. [Authoring: `register_buffer` and in-place mutation](#3-authoring-register_buffer-and-in-place-mutation)
4. [Conversion: `state_names`, and its three traps](#4-conversion-state_names-and-its-three-traps)
5. [Runtime: `MutableViews` and the `states:` argument](#5-runtime-mutableviews-and-the-states-argument)
6. [The fixed max-context tradeoff](#6-the-fixed-max-context-tradeoff)
7. [A real signature: the LLM state contract](#7-a-real-signature-the-llm-state-contract)
8. [Four silent failures around states](#8-four-silent-failures-around-states)
9. [Pre-allocated outputs: the `outputViews:` argument](#9-pre-allocated-outputs-the-outputviews-argument)
10. [Pipelined execution: `encode`, `ComputeStream`, async values](#10-pipelined-execution-encode-computestream-async-values)
11. [A real pipelined decode loop](#11-a-real-pipelined-decode-loop)
12. [What pipelining is actually worth](#12-what-pipelining-is-actually-worth)
13. [The MPSGraph in-graph KV-write bug](#13-the-mpsgraph-in-graph-kv-write-bug)
14. [Prefix reuse: one integer assignment, ~101×](#14-prefix-reuse-one-integer-assignment-101)
15. [Diagnosing states in Instruments](#15-diagnosing-states-in-instruments)
16. [Quick reference](#16-quick-reference)
17. [Sources and evidence ledger](#17-sources-and-evidence-ledger)

---

## 1. The symptom: intervals that grow

Apple teaches states through a worked failure, and it is worth reproducing the failure before the
fix because the *shape* of the symptom is what you will actually recognise in your own app.

The running example in WWDC26 session 324 ("Meet Core AI") is a two-player Snake game in which one
snake is driven by a small transformer. Each time step, the model sees a feature vector describing
the board, those features accumulate into a game history, and the model predicts a direction. The
presenter is explicit that the toy is a stand-in:

> ✅ **VERIFIED** — WWDC26 session 324, lines 40–42: *"At each time step, the AI model will see a set
> of features describing the current board state, and those features will be accumulated into the
> full game history that gets fed to the model. It will then predict the best direction to move. …
> **While snake is a simple game, the tools and APIs used to create this experience are the same
> foundation that scale all the way up to the larger, more complex use cases.**"*

The first version works and is wrong:

> ✅ **VERIFIED** — session 324, lines 99–108: *"Running it shows that the model is working. However,
> I see that **the game is getting slower as it goes on**. … I've ran the app with Instruments and I
> can see the **inference intervals getting notably larger over time**, which means the inference
> calls are increasing in latency. This makes sense because **transformer models have quadratic time
> complexity with respect to the sequence length**. And in our game the sequence length is increasing
> with every move the model makes. … Each time the input sequence is increased, the transformer model
> **recomputes a set of internal key and value embeddings for every element in the sequence**."*

Two things in that passage are load-bearing.

**First, the cost is quadratic, and it is quadratic for a specific reason.** Attention at sequence
length *S* is *O(S²)* per forward pass. But the loop makes it worse than that: a decode loop that
re-feeds the whole history performs a full *S*-token forward pass at every step, so generating *N*
tokens costs *Σ O(i²) ≈ O(N³)* in attention alone. The per-call latency curve you see in Instruments
is the *O(S²)* term; the wall-clock disaster is the sum.

**Second, the redundancy is total.** At step *i*, the keys and values for tokens 0…*i*−1 are
bit-for-bit identical to the ones computed at step *i*−1. Nothing about them depends on the new
token. They are recomputed only because there is nowhere to put them.

The Instruments signature is worth memorising, because it is unambiguous and it is the only
performance bug in this framework that announces itself visually:

| Track | Healthy | Sick |
|---|---|---|
| Core AI ▸ `<model>` ▸ `main` ▸ **Inference** (blue) | intervals of roughly constant width, marching left to right | intervals that visibly *widen* as the trace goes on |

§15 covers reading that track properly, including the three other event categories that share it.

### Why this matters outside of LLMs

The instinct is to file "KV cache" under "language models". It is not. The requirement is only that
your model is **autoregressive over a growing sequence and re-derives per-element intermediates that
do not change**. Session 324's Snake model is not a language model; it is a small transformer over
board-state feature vectors, and it has exactly this problem. Diarization over a rolling audio
buffer, a gesture recogniser over an accumulating stroke, an incremental document encoder — all the
same shape. If your model's input grows by one element per call and the output for the old elements
does not change, you want states.

---

## 2. What a state is

Here is the whole idea, in Apple's words, and it is short:

> ✅ **VERIFIED** — WWDC26 session 324, lines 109–112: *"This can be achieved through Core AI by
> using **states**. **States are inputs to the model which are both read, and updated in-place during
> inference.** By introducing the key and value caches as states on the model, we both avoid
> recomputing them on each inference, and also **remove the need to provide the full history of the
> game as an input** since the data needed from older steps are stored in the states. So after the
> first input, each subsequent step uses the cache for history and only takes the new features of the
> latest board state."*

The reference documentation says the same thing more precisely, and adds the enforcement rule:

> ✅ **VERIFIED** — `InferenceFunctionDescriptor.stateNames` discussion, Apple developer
> documentation (harvested 2026-07-27): *"States are function arguments that the function both reads
> and writes during inference. **You must provide a mutable view for every state** when calling
> `InferenceFunction/run(inputs:states:outputViews:)`."*

And on `run` itself:

> ✅ **VERIFIED** — `InferenceFunction.run(inputs:states:outputViews:)`, `states:` parameter
> documentation: *"The in-out arguments of the function, which the function reads and writes during
> inference. **You must provide views for all states; omitting any state produces an error.**"*

So a state is:

- **Not an input.** Inputs are read-only and you hand them over per call. Descriptor-wise they live
  in `inputNames`, not `stateNames`, and there is no overlap.
- **Not an output.** Outputs come back in `InferenceFunction.Outputs`. A state's new value is written
  *into the storage you supplied*; it does not appear in the returned outputs at all.
- **Owned by you, mutated by the framework.** You allocate the `NDArray`, you keep it alive across
  calls, and inference writes through it. Core AI never allocates or frees your state storage.
- **Mandatory in full.** Supply a view for every name in `stateNames` or the call errors. There is
  no partial-state call, and — a small API asymmetry worth knowing —
  **there is no `stateCount` property**, though there is `inputCount` and `outputCount`. Use
  `stateNames.count`.

### The three-layer picture

```
PyTorch                       Exported program              Core AI IR              Swift runtime
───────────────────────────   ──────────────────────────    ────────────────────    ─────────────────────────
self.register_buffer(         graph_signature                coreai.graph @main(     var keyCache: NDArray
    "key_cache", zeros(...))    .buffers_to_mutate             %0 {MutableBuffers      (held across calls)
                                                                 .buffer_mutation
forward():                    ── torch.export ──▶            = "key_cache"},   ──▶   var s = MutableViews()
  self.key_cache[pos] = k       ("key_cache" is now a          %1 {coreai.name         s.insert(&keyCache,
  k = self.key_cache[:pos+1]     MUTATED BUFFER)                 = "features"})          for: "key_cache")
                                                             ) -> (...)               fn.run(inputs:,
                                     TorchConverter(                                     states: consume s)
                                       state_names=[...])
```

Each arrow is a place where the mapping can be silently wrong, which is why §4 and §8 exist.

### The honest hedge, stated up front

Session 324's result slide is careful, and most retellings of it are not:

> ✅ **VERIFIED** — session 324, lines 128–130: *"Now with the updated model, I'll re-run the app.
> This time I can see it **maintains a steady speed, no longer slowing down overtime**. When tracing
> the updated app in Instruments, I can confirm that the **inference latency is growing at a much
> slower rate**."*

**"Growing at a much slower rate", not "constant".** With a KV cache you still attend over an
attention window that grows by one every step, so per-step cost remains linear in the number of
cached tokens; you have removed the recomputation, not the attention. Anyone who tells you a KV
cache makes decode O(1) is describing the *projection* work, not the *attention* work. Expect a
gentle upward slope in the Instruments track, and expect it to be dwarfed by what it replaced.

---

## 3. Authoring: `register_buffer` and in-place mutation

### What the transcript says

> ✅ **VERIFIED** — session 324, lines 113–119: *"To implement the key/value caching, I'll go back to
> the original authoring code and make a few changes to add in the key and value caches. First I'll
> update the torch module by adding key and value cache tensors as **buffers** within the transformer
> module, by using the **torch `register_buffer` API**. This will later result in these tensors being
> **mutable buffers in the exported torch program which Core AI will convert to states**. Then in the
> forward function of the module, I'll add the logic to actually use the caches. This involves
> **reading previous features keys and values out of the cache**. Then **writing the computed keys and
> values for the new features back into the cache**. Lastly, I'll rerun the same code from before to
> re-convert the model, but now adding in the **`state_names` argument to the convert call**."*

### What actually counts as a state

`coreai-torch`'s own documentation is unambiguous, and it contains a surprise:

> ✅ **VERIFIED** — `apple/coreai-torch`, `docs/api/TorchConverter.md`, §"IO naming":
> *"The converter treats two things as state:
> 1. **Mutable buffers** registered via `self.register_buffer(...)` and mutated in-place inside
>    `forward()` (e.g., `self.buf.add_(x)`).
> 2. **User inputs mutated in-place** inside `forward()` (e.g., `x.mul_(2)` on a `forward()` arg).
>
> Both are detected from the exported program's graph signature. There is **no flag** to opt a
> mutated user input out of state. … If you don't want a `forward()` argument treated as state,
> eliminate the in-place mutation from your model — clone first
> (`x_local = x.clone(); x_local.mul_(2)`) or use the out-of-place form (`x_scaled = x * 2`)."*

Read clause 2 twice. **Any in-place mutation of a `forward()` argument silently promotes that
argument from an input to a state**, which changes the function's signature, which changes what your
Swift code must pass. There is no opt-out flag. §8.2 treats this as the silent failure it is.

### The minimal proof

The smallest module that produces a state is four lines, and it comes straight out of
`coreai-torch`'s test suite:

> ✅ **VERIFIED** — `apple/coreai-torch`, `tests/test_stateful.py:58-64`:

```python
class _BufMutate(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.register_buffer("state", torch.zeros(1, 4))

    def forward(self, x: Tensor) -> Tensor:
        self.state.copy_(x)
        return self.state
```

and the IR it produces, which is the thing you actually want to be able to recognise:

> ✅ **VERIFIED** — same file, lines 88–95 (FileCheck assertions on the emitted Core AI MLIR):

```
// CHECK-LABEL: module {
// CHECK-NEXT:   coreai.graph @main(
//                 %{{.*}}: tensor<1x4xf32> {MutableBuffers.buffer_mutation = "b_state",
//                                           coreai.name = "b_state"},
//                 %{{.*}}: tensor<1x4xf32> {coreai.name = "x"}
//               ) -> (tensor<1x4xf32> {coreai.name = "b_state"}) {
// CHECK:     coreai.output %{{.*}} : tensor<1x4xf32>
// CHECK:   }
// CHECK: }
```

**`MutableBuffers.buffer_mutation = "<name>"` on a graph argument is the on-disk marker for "this
argument is a state."** The attribute's *value* is the name of the graph output that carries the
argument's new value. That is the entire mechanism, and it is worth knowing because it is how you
audit an asset that someone else converted: dump the IR, grep for `buffer_mutation`, count the hits,
compare against `stateNames.count` in Swift.

Note also the default name: `register_buffer("state", …)` becomes **`b_state`**, with a `b_`
prefix. Apple's docs table:

> ✅ **VERIFIED** — `docs/api/TorchConverter.md`, default-names table:
>
> | Category | FX graph source | Relates to | Example |
> |---|---|---|---|
> | Input | Placeholder `node.name` | `forward()` arg name | `def forward(self, x, z)` → `"x"`, `"z"` |
> | Output | Output node's input `node.name` | Internal op name | `return a + b, c * d` → `"add"`, `"mul"` |
> | State (buffer) | Placeholder `node.name` | `"b_"` + `register_buffer` attr | `register_buffer("kv_cache", …)` → `"b_kv_cache"` |
> | State (mutated user input) | Placeholder `node.name` | `forward()` arg name | `def forward(self, y): y.mul_(2)` → `"y"` |
>
> And, verbatim: *"These naming conventions are observed behavior from the FX graph, not a stable
> contract from PyTorch. They may change across PyTorch versions. **Always provide explicit names for
> production use.**"*

That warning is not boilerplate. If you do not pass `state_names`, your Swift code is pattern-matching
on names PyTorch's FX tracer happens to generate, and Apple is telling you those can move.

### A realistic KV cache module

The test suite also carries a KV-shaped case:

> ✅ **VERIFIED** — `apple/coreai-torch`, `tests/test_stateful.py::test_kv_cache_pattern`:

```python
class KVCacheModel(nn.Module):
    def __init__(self):
        super().__init__()
        self.register_buffer("k_cache", torch.zeros(1, 4, 8))
        self.register_buffer("v_cache", torch.zeros(1, 4, 8))

    def forward(self, q, k, v):
        self.k_cache.copy_(k)
        self.v_cache.copy_(v)
        attn = torch.matmul(q, self.k_cache.transpose(-2, -1))
        return torch.matmul(attn, self.v_cache)
```

and a complete stateful example that exercises both state kinds at once:

> ✅ **VERIFIED** — `apple/coreai-torch`, `docs/api/TorchConverter.md`, §"IO naming" example:

```python
class KVCache(nn.Module):
    def __init__(self):
        super().__init__()
        self.register_buffer("kv_cache", torch.zeros(1, 4))   # state[0]
        self.register_buffer("pos_idx", torch.zeros(1))       # state[1]

    def forward(self, x, y, z):
        self.kv_cache.add_(x)       # buffer mutation
        self.pos_idx.add_(1)        # buffer mutation
        y.mul_(2)                   # state[2]: mutated user input
        # non-mutated: x -> input[0], z -> input[1]
        return self.kv_cache + y, z * 3

ep = torch.export.export(KVCache().eval(),
                         args=(torch.randn(1, 4), torch.randn(1, 4), torch.randn(1, 4)))
ep = ep.run_decompositions(get_decomp_table())

TorchConverter().add_exported_program(
    ep,
    state_names=["kv_cache", "pos_idx", "y_state"],
    input_names=["query", "context"],
    output_names=["attn_out", "scaled"],
).to_coreai().optimize()
```

Study the argument lists. `forward` takes three tensors; `input_names` has **two** entries, because
`y` was mutated and is therefore a state, not an input. `state_names` has **three** entries — two
buffers then one mutated argument. `output_names` has two entries and mentions neither cache,
because mutation outputs are not return values. Getting this bookkeeping wrong is the number-one
conversion error and §4 enumerates the exact messages you will get.

### The Snake module, reconstructed

Session 324 never shows code on screen that the transcript captures. The following is a
reconstruction of what the narration describes, and it is marked as such:

> 🟡 **RECONSTRUCTED** — from session 324 lines 113–119 and 123. The `register_buffer` +
> in-place-mutation shape is verified (above); the *specific* indexing, dimension order and
> `max_context` parameterisation of this particular module are inferred from the narration
> ("fixed size for a maximum possible context length") and are **not** quoted from Apple.

```python
import torch
import torch.nn as nn


class SnakeTransformer(nn.Module):
    def __init__(self, max_context: int, n_heads: int, head_dim: int, hidden_dim: int):
        super().__init__()
        # Fixed-size caches sized for the maximum possible context length.
        # These become MUTABLE BUFFERS in the exported program, which Core AI
        # converts to states. See §6 for why "fixed" is a real decision.
        self.register_buffer("key_cache",   torch.zeros(max_context, n_heads, head_dim))
        self.register_buffer("value_cache", torch.zeros(max_context, n_heads, head_dim))
        # ... projections, norms, output head ...

    def forward(self, features: torch.Tensor, position: torch.Tensor) -> torch.Tensor:
        # 1. Compute K/V for the NEW element only.
        k_new, v_new = self.compute_kv(features)

        # 2. WRITE them into the cache (in-place mutation => this is what makes it a state).
        self.key_cache[position]   = k_new
        self.value_cache[position] = v_new

        # 3. READ the accumulated history back out.
        k = self.key_cache[: position + 1]
        v = self.value_cache[: position + 1]

        # 4. Attend over (new query) x (cached keys/values), project, return logits.
        return self.head(self.attend(features, k, v))
```

The write-then-read order is not cosmetic. Writing first means the current step's own K/V are
included in the read, so you do not need a separate "current" path — the cache slice *is* the full
attention input. This is exactly the structure `apple/coreai-models`' production KV cache primitive
uses, wrapped in the export-safe helper described in §7.

### Two authoring rules that are not about states but will bite you here

Both come from the same session and both are hard failures, not regressions:

> ✅ **VERIFIED** — session 324, line 51: *"…make sure to use the **`dynamic_shapes`** argument to
> specify that the sequence length of the features is dynamic, that way it doesn't get traced with the
> static sample length of 5."*

If you trace with a concrete sequence length and forget `dynamic_shapes`, that length is baked into
the graph. Your decode loop then works for exactly one query length and fails for every other.

> ✅ **VERIFIED** — `apple/coreai-torch`, `docs/guides/conversion-workflows.ipynb`: *"You **must**
> call `run_decompositions()` before passing the program. Use `get_decomp_table()` to preserve the
> operations that `TorchConverter` lowers as composite ops."* And from `quickstart.ipynb`: *"This call
> is required when using `add_exported_program()`. Skipping it will leave ops in the graph that have
> no lowering rule."*

`get_decomp_table()` returns PyTorch's default ATen decomposition table **minus** the ops
`TorchConverter` lowers as composites — `instance_norm`, `pixel_shuffle`,
`scaled_dot_product_attention`. Using `torch.export.default_decompositions()` instead will decompose
your SDPA into primitives and you will lose the fused attention path. That is a performance cliff
right in the middle of the thing you are trying to make fast.

---

## 4. Conversion: `state_names`, and its three traps

### The signature

> ✅ **VERIFIED** — `apple/coreai-torch`, `coreai_torch/converter.py:195-248`, copied exactly:

```python
class TorchConverter:
    class Mode(Enum):
        DEBUG = "debug"      # includes full torch stack traces for source mapping
        RELEASE = "release"  # records only operation IDs, no stack traces

    def __init__(self, *, mode: "TorchConverter.Mode" = Mode.DEBUG) -> None: ...

    def add_exported_program(
        self,
        exported_program: ExportedProgram,
        *,
        input_names: Sequence[str] | None = None,
        output_names: Sequence[str] | None = None,
        state_names: Sequence[str] | None = None,
        entrypoint_name: str = "main",
    ) -> Self: ...

    def add_pytorch_module(
        self,
        model: torch.nn.Module,
        *,
        export_fn: Callable[[torch.nn.Module], ExportedProgram],
        externalize_modules: list[type | ExternalizeSpec] | None = None,
        input_names: Sequence[str] | None = None,
        output_names: Sequence[str] | None = None,
        state_names: Sequence[str] | None = None,
        entrypoint_name: str = "main",
    ) -> Self: ...
```

And the docstring that defines the contract:

> ✅ **VERIFIED** — `coreai_torch/converter.py:211-217`, verbatim:
> ```
> input_names: Non-stateful forward() arg names only.
> output_names: Return value names only (not mutation outputs).
> state_names: One name per state, applied to both input and
>     mutation output. Order: buffers (registration order), then
>     mutated user inputs (signature order). Defaults to FX
>     placeholder names when not provided.
> ```

Three sentences, three traps.

### Trap 1 — `input_names` and `output_names` do not include states

`input_names` covers **non-stateful args only**. `output_names` covers **return values only, not
mutation outputs**. If you write a three-argument `forward()` where one argument is mutated and pass
three `input_names`, you get:

> ✅ **VERIFIED** — error text from `coreai_torch/_utils.py`:
> `f"Graph has {n} live inputs ({names}), but input_names has {m} entries ({...})."`

with the analogous message for outputs. These are *loud* failures, which is the good case. The
mental model that prevents them: **a state is neither an input nor an output; it is a third
category, and it consumes one slot from the input list and one from the output list.**

### Trap 2 — the count must match exactly

> ✅ **VERIFIED** — `coreai_torch/_utils.py:1700-1856`, error text:
> ```
> f"Graph has {len(graph_state_names)} stateful inputs "
> f"({graph_state_names}), but state_names has "
> f"{len(user_state_names)} entries ({list(user_state_names)})."
> ```

Also loud. But note *why* you would ever get it: because you accidentally created a state you did
not intend (trap 3), or because you removed one and forgot to update the list.

### Trap 3 — the ordering rule is observed behaviour, not a contract

**Buffers first, in `register_buffer` registration order. Then mutated user inputs, in `forward()`
signature order.** Apple says plainly that this is not guaranteed by PyTorch:

> ✅ **VERIFIED** — `docs/api/TorchConverter.md`, verbatim: *"The ordering of `state_names` (buffers
> first, then mutated user inputs) is based on observed FX graph behavior, not a stable PyTorch
> contract. … **Always verify state ordering when upgrading PyTorch versions.**"*

The converter has a defensive assertion for the case where it detects a violation:

> ✅ **VERIFIED** — `coreai_torch/_utils.py:1783-1889`, assertion message:
> ```
> "FX placeholder order violates the 'mutable buffers first, then mutated user inputs' invariant.
>  … This breaks the documented state_names ordering — pass state_names explicitly matched to your
>  buffer/arg names, or check PyTorch version compatibility."
> ```

and a second one guarding a signature-layout assumption:

> ✅ **VERIFIED** — same file: `assert len(state_in_idx) == len(state_out_idx)` →
> `"State input/output count mismatch: … This may indicate an unsupported graph signature layout."`

**Why order matters at runtime and not just at conversion time.** Swift's
`InferenceFunctionDescriptor.stateNames` is an **array**, and every production consumer of a
stateful LLM asset indexes it positionally rather than matching by name. Apple's own sequential
engine takes names positionally from the descriptor arrays — `states[0]` is the key cache,
`states[1]` is the value cache — and so does the third-party Swift runner in §7. **If your two
caches swap places in `state_names`, nothing errors: you get a model that attends keys to values.**
That is a numerics bug with a clean bill of health from every tool in the pipeline.

The mitigation is one line in a conversion test: after `to_coreai()`, assert the state names *and
their order*, and fail the build if they move.

### `optimize()` is mandatory for stateful models

This is the least-known and most consequential fact in this section.

> ✅ **VERIFIED** — `apple/coreai-torch`, `tests/utils.py::_export_and_convert` runs optimize when
> `run_optimize_passes or state_names or has_state`, where
> `has_state = bool(sig.buffers_to_mutate) or bool(sig.user_inputs_to_mutate)`. The accompanying
> comment in `_compare_by_name` explains why: *"state mutation outputs become tokens after optimize
> and won't appear here"*.

`to_coreai()` is a **pure conversion step** — it runs no optimization passes at all
(`tests/test_converter.py::TestConvertToCoreaiNoOptimization`). The passes that `optimize()` wraps
include two that exist specifically for states:

> ✅ **VERIFIED** — recovered from `git show 4529671` in `apple/coreai-torch` (the commit
> "Remove run_transforms helper in favor of result.optimize() (#50)"), which deleted this helper:
>
> | Pass | Purpose |
> |---|---|
> | `CorePasses._CORE_OPTIMIZE` | core dialect optimization (const folding, cast fusion, inlining) |
> | `CorePasses._UPDATE_SIGNATURE_TO_HANDLES` | **rewrites the stateful graph signature to handle-based state; mutation outputs become tokens** |
> | `CorePasses._PROPAGATE_HANDLE_UPDATES` | propagates those handle updates through the module |
>
> The full `CorePasses` enum could not be enumerated — 🔴 unverified beyond these three.

So: **`to_coreai()` without `optimize()` on a stateful model does not produce the runtime state
protocol.** Always call it. Every documented example does.

### The re-conversion, in full

Putting the Snake example back together — the conversion script is the same as the stateless one
with one added argument:

```python
# Grounding: the TorchConverter call shape (input_names / output_names / .to_coreai() /
# .optimize() / .save_asset()) is VERIFIED against apple/coreai-torch's quickstart and README.
# The specific names ("features", "logits", "key_cache", "value_cache") follow session 324's
# narration and the module in §3; they are yours to choose.
import torch
from pathlib import Path
from coreai_torch import TorchConverter, get_decomp_table

model = SnakeTransformer(max_context=MAX_CONTEXT, n_heads=N_HEADS,
                         head_dim=HEAD_DIM, hidden_dim=HIDDEN_DIM)
model.load_state_dict(torch.load("snake_transformer.pt"))
model.eval()                       # BatchNorm/Dropout trace differently in training mode

# One new element per step now, not the whole history.
sample_features = torch.randn(1, HIDDEN_DIM)
sample_position = torch.tensor(0, dtype=torch.int32)

ep = torch.export.export(model, args=(sample_features, sample_position))
ep = ep.run_decompositions(get_decomp_table())        # REQUIRED

coreai_program = (
    TorchConverter()
    .add_exported_program(
        ep,
        input_names=["features", "position"],          # non-stateful args only
        output_names=["logits"],                       # return values only
        state_names=["key_cache", "value_cache"],      # <-- the new argument (324:119)
    )
    .to_coreai()
)
coreai_program.optimize()                              # REQUIRED for stateful models

asset = coreai_program.save_asset(Path("SnakeModel.aimodel"))
```

Two footnotes on that script:

- **`TorchConverter` defaults to `Mode.DEBUG`**, which embeds full torch stack traces in the asset so
  the Core AI Debugger can map operations back to your Python source. That is what you want while
  developing and not what you want in a shipping bundle. Use `Mode.RELEASE`, or strip afterwards with
  `coreai_torch.debugging.debug_info.strip_debug_info`. ✅ verified in `converter.py:148-150`; not
  mentioned in either WWDC session.
- **`torch` must be ≤ 2.13.0** or `coreai_torch/__init__.py` emits a validation warning
  ("has only been validated with torch<=2.13.0"). ✅ verified, `__init__.py:32-39`.

### Verify the conversion before you write a line of Swift

Session 324 stresses this and it is the cheapest insurance in the entire pipeline:

> ✅ **VERIFIED** — session 324, lines 54–59: *"Before leaving the Python environment, one more thing
> I'll do is run a test to verify that the converted Core AI model matches the numerics of my original
> PyTorch model. This can be done easily with the **Core AI framework Python bindings**. … And finally
> assert a sufficiently small delta for my use case between the PyTorch and Core AI outputs."*

For a *stateful* model the Python runtime protocol adds a `state=` argument:

> ✅ **VERIFIED** — `apple/coreai-torch`, `tests/utils.py`:

```python
state: dict[str, NDArray] = {}
for name in desc.state_names:
    d = desc.state_descriptor(name=name)
    shape = tuple(s if s is not None else 1 for s in d.shape)
    state[name] = NDArray(np.zeros(shape, dtype=np.dtype(d.dtype)))
...
rt_outputs = await rt_func(inputs=inputs, state=state)
```

⚠️ **Note the zero-filled numpy array, and note why.** The source comment on that block warns that
`NDArray.from_descriptor` **only sizes the buffer**; on Linux the backing storage is not zeroed, so
a buffer-state read on the first call returns garbage. Allocating `np.zeros` explicitly is not
defensive style, it is the fix. This matters for parity testing more than for shipping, because your
Swift side has its own zeroing story (§5), but a parity test that "passes" against uninitialised
state has told you nothing.

Note also the **Python-vs-Swift naming asymmetry**, which trips everyone who moves between the two:
Python's `ai_model.load_function("main")` **raises `KeyError`** for an unknown name; Swift's
`loadFunction(named:)` **returns `nil`** and throws only on a load failure.

---

## 5. Runtime: `MutableViews` and the `states:` argument

### The API, verbatim

There are two `run` overloads. Both take the same `states:` and `outputViews:` parameters, both
default them to empty, and both are `async throws`.

> ✅ **VERIFIED** — Apple developer documentation, `InferenceFunction.run` (doc slugs `-mqfb` and
> `-14emi` respectively):

```swift illustrative
// Overload A — convenience, dictionary of NDArray
func run(inputs: [String : NDArray],
         states: consuming InferenceFunction.MutableViews = MutableViews(),
         outputViews: consuming InferenceFunction.MutableViews = MutableViews())
    async throws -> InferenceFunction.Outputs

// Overload B — Inputs collection (borrowing; lets you pass views without transferring ownership)
func run(inputs: borrowing InferenceFunction.Inputs,
         states: consuming InferenceFunction.MutableViews = MutableViews(),
         outputViews: consuming InferenceFunction.MutableViews = MutableViews())
    async throws -> InferenceFunction.Outputs
```

`MutableViews` is used for **both** `states:` and `outputViews:` — same type, two roles:

> ✅ **VERIFIED** — Apple developer documentation, `InferenceFunction.MutableViews`:

```swift illustrative
struct MutableViews {
    init()
    mutating func insert(_ value: inout some InferenceValue.MutableViewRepresentable & ~Copyable,
                         for name: String)                                            // -1b2yx
    mutating func insert<Element>(_ mutableView: consuming NDArray.MutableView<Element>,
                                  for name: String) where Element : BitwiseCopyable    // -8ossp
    mutating func insert(_ mutableRawView: consuming NDArray.MutableRawView,
                         for name: String)                                             // -9ixpc
}
```

`NDArray` conforms to `InferenceValue.MutableViewRepresentable`, so overload `-1b2yx` is the one
that lets you write `states.insert(&keyCache, for: "keyCache")` with an `NDArray` directly. The
other two exist for when you already hold a typed or raw view — including views you built over an
`MTLBuffer` or an `IOSurface`.

### The pattern, verified against shipping code

The canonical shape appears in Apple's own `coreai-models` package:

> ✅ **VERIFIED** — `apple/coreai-models`,
> `swift/Sources/CoreAILanguageModels/InferenceEngines/CoreAISequentialEngine.swift:275-291`,
> quoted exactly:

```swift prelude:guide-context
// Build states (KV cache — persistent, inout)
var states = InferenceFunction.MutableViews()
states.insert(&keyCache, for: keyCacheName)
states.insert(&valueCache, for: valueCacheName)

// Build output backings (logits — written in-place)
var outputViews = InferenceFunction.MutableViews()
outputViews.insert(&logitsArray, for: logitsName)

// Execute
_ = try await function.run(
    inputs: [inputIdsName: inputIdsArray, positionIdsName: positionIds],
    states: consume states,
    outputViews: consume outputViews
)
```

Note the `_ =` on the result. When every output has a pre-allocated view, the returned `Outputs`
collection is empty and discarding it is correct (§9).

And the empty case, for a function with no states at all:

> ✅ **VERIFIED** — `apple/coreai-models`, `swift/Sources/CoreAISpeech/SpeechModel.swift:81`:
> ```swift
> states: InferenceFunction.MutableViews(), outputViews: consume out)
> ```

### Reading the Swift ownership annotations

This API is dense with ownership modifiers and each one is telling you something operational.

**`consuming MutableViews`** — the collection is consumed by the call. You cannot build one and reuse
it across steps; you build a fresh one each iteration and `consume` it. The `consume` keyword at the
call site is how you hand over ownership explicitly. This is not ceremony: the collection holds
mutable borrows of your `NDArray`s, and Swift needs the borrow to end when the call ends.

**`insert(_ value: inout …)`** — inserting takes an `inout` reference to your `NDArray`. So the
`NDArray` variables must be `var`, must outlive the call, and must not be touched by anything else
while the collection is alive. That is exactly the exclusivity guarantee that makes in-place state
mutation safe without a copy.

**The lifetime rule on the async variant** is stated explicitly, and it applies by analogy here:

> ✅ **VERIFIED** — `InferenceFunction.AsyncMutableViews.insert(_:for:)` parameter documentation:
> *"The mutable value that this collection will reference. **Its lifetime is tied to the resulting
> collection.**"*

**Why the read/write split is compile-time.** Apple designed this deliberately:

> ✅ **VERIFIED** — *Integrating on-device AI models in your app with Core AI*, Apple developer
> documentation: *"For `NDArray` values, write input data with `NDArray.MutableView` and read results
> with `NDArray.View`. **Swift enforces this at compile time.** A mutable view allows writes, and a
> view allows only reads, so you always know how your data is accessed."*

### The stateful `ModelPlayer`

Session 324's Swift-side change, in the presenter's words:

> ✅ **VERIFIED** — session 324, lines 120–127: *"Now that I've re-converted the model with the new
> function signature, I'll update the app code to handle it. To start, I'll update the ModelPlayer to
> **store the key and value cache NDArrays** which will be the state arguments passed to each
> inference. I'll initialize them with the expected shape for the transformer. In this case I converted
> the model such that it expects the key and value caches to always be a **fixed size for a maximum
> possible context length**. Then when it's time to run inference, I'll construct a **collection of
> MutableViews** containing both views of the key and value caches. Then provide those as the
> **`states` argument of the `InferenceFunction.run` method**. Now the caches will be both read and
> updated in-place during each inference."*

Here is that as compiling-shaped Swift. The API calls are verified; the app-specific glue is not.

> 🟡 **RECONSTRUCTED** — from session 324 lines 79–91 and 120–127. Every Core AI call
> (`AIModel(contentsOf:)`, `loadFunction(named:)`, `NDArray(shape:scalarType:)`, `mutableView(as:)`,
> `MutableViews()` / `insert(_:for:)`, `run(inputs:states:)`, `Outputs.remove(_:)`,
> `InferenceValue.ndArray`, `view(as:)`) is ✅ verified against Apple's documentation or
> `apple/coreai-models`. The type names `ModelPlayer`, `SnakePlayer`, `chooseAction`, `writeFeatures`
> come from the narration verbatim. Shapes, the `position` input and the error enum are inferred.

```swift prelude:guide-context
import CoreAI
import Foundation

final class ModelPlayer: SnakePlayer {

    private let model: AIModel
    private let function: InferenceFunction

    // The states. Allocated ONCE, held for the lifetime of the player,
    // mutated in place by every inference.
    private var keyCache: NDArray
    private var valueCache: NDArray

    private var step: Int = 0

    init(modelURL: URL) async throws {
        // async because this specializes the model for the current device.
        self.model = try await AIModel(contentsOf: modelURL)

        guard let function = try model.loadFunction(named: "main") else {
            throw SnakeError.missingFunction("main")
        }
        self.function = function

        // Sized for the MAXIMUM possible context length, up front. See §6.
        self.keyCache = NDArray(shape: [maxContext, nHeads, headDim], scalarType: .float32)
        self.valueCache = NDArray(shape: [maxContext, nHeads, headDim], scalarType: .float32)
    }

    func chooseAction(history: GameHistory) async throws -> Direction {
        // ONE element now — not the whole history. That is the second half of the win.
        var features = NDArray(shape: [1, hiddenDimension], scalarType: .float32)
        writeFeatures(from: history.latest, into: features.mutableView(as: Float.self))

        var position = NDArray(shape: [], scalarType: .int32)
        position.mutableView(as: Int32.self).copyElements(fromContentsOf: [Int32(step)])

        // A fresh MutableViews per call; consumed by run().
        var states = InferenceFunction.MutableViews()
        states.insert(&keyCache, for: "key_cache")
        states.insert(&valueCache, for: "value_cache")

        var outputs = try await function.run(
            inputs: ["features": features, "position": position],
            states: consume states
        )

        guard let logitsValue = outputs.remove("logits"),
              let logits = logitsValue.ndArray else {
            throw SnakeError.missingOutput("logits")
        }

        step += 1
        return sampleDirection(from: logits.view(as: Float.self))
    }

    /// Start a new game: the caches hold the previous game's history.
    func reset() {
        step = 0
        // See §5.3 — whether you must zero here depends on your graph.
    }
}
```

### 5.1 Do not hardcode names — read the descriptor

The `"key_cache"` / `"value_cache"` string literals above are the weakest part of that code. Apple
provides introspection precisely so you do not have to write them:

> ✅ **VERIFIED** — Apple developer documentation, `InferenceFunctionDescriptor`:

```swift illustrative
struct InferenceFunctionDescriptor {          // Sendable, SendableMetatype
    var name: String { get }

    var inputCount: Int { get }
    var inputNames: [String] { get }
    func inputDescriptor(of inputName: String) -> InferenceValue.Descriptor?

    var outputCount: Int { get }
    var outputNames: [String] { get }
    func outputDescriptor(of outputName: String) -> InferenceValue.Descriptor?

    var stateNames: [String] { get }
    func stateDescriptor(of stateName: String) -> InferenceValue.Descriptor?
}
```

and the reason it exists, in Apple's words:

> ✅ **VERIFIED** — *Integrating on-device AI models in your app with Core AI*: *"You can use this
> descriptor to verify that a function accepts the inputs your app provides, or to **dynamically adapt
> your app's behavior as the model's inputs and outputs change between deployments, without needing to
> change your code**."*

That second clause is the real argument. A stateful model you ship as a downloadable asset will get
re-exported; if the export changes a state's name or its cache dtype, descriptor-driven allocation
survives it and hardcoded names do not.

The allocation helper that follows from this is short and worth having in every project:

```swift illustrative
/// Allocate one zero-filled NDArray per state, sized from the function descriptor.
/// - Parameter dynamicExtent: the value to substitute for every dynamic (-1) dimension.
func allocateStates(
    for descriptor: InferenceFunctionDescriptor,
    dynamicExtent: Int
) throws -> [String: NDArray] {
    var result: [String: NDArray] = [:]
    for name in descriptor.stateNames {
        guard case .ndArray(let d)? = descriptor.stateDescriptor(of: name) else {
            throw SnakeError.unexpectedStateKind(name)     // could be .image
        }
        // -1 marks a dynamic dimension; resolve every one before touching
        // preferredStrides or minimumByteCount (both are a programming error
        // on a descriptor with hasDynamicShape == true).
        let concreteShape = d.shape.map { $0 < 0 ? dynamicExtent : $0 }
        let resolved = d.resolvingDynamicDimensions(concreteShape)
        result[name] = NDArray(descriptor: resolved)
    }
    return result
}
```

Three facts that helper encodes, all ✅ verified from Apple's documentation:

- **`NDArrayDescriptor.shape` uses `-1` for a dynamic dimension.** (The Xcode model viewer shows the
  same thing as `?`.)
- **`resolvingDynamicDimensions(_:)` must come first.** *"Accessing this property on a descriptor for
  which `hasDynamicShape` is true, is a programming error."* — said of both `preferredStrides` and
  `minimumByteCount`. `NDArray.init(descriptor:)` likewise requires `hasDynamicShape == false`.
- **`InferenceValue.Descriptor` is an enum with two cases**, `.ndArray(NDArrayDescriptor)` and
  `.image(ImageDescriptor)`. A state could in principle be an image value; handle or reject it
  explicitly rather than force-unwrapping.

### 5.2 `NDArray(descriptor:)` gives you the layout the hardware wants

There is a second, performance reason to allocate from the descriptor rather than from
`NDArray(shape:scalarType:)`, and it is the difference between a copy per call and no copy:

> ✅ **VERIFIED** — `NDArrayDescriptor.preferredStrides` discussion, Apple developer documentation:
> *"During the specialization of an `AIModel`, a preferred memory layout for a given ndArray value may
> be set depending on structure of the model and which compute units it is specialized for. In some
> cases, this can result in a **non-contiguous layout being preferred/required by the backing
> compute**. In such case, you are still able to provide `InferenceFunction.run` normal contiguous
> ndArray values, however **it may incur a copy to the preferred layout**. As such, this property
> provides an opportunity for you to optimize performance by creating your source ndArray value with
> the preferred striding and avoiding that copy."*

This is the "dynamically check the optimal memory layout" lever session 324 mentions at line 177 and
never names. The price of taking it:

> ✅ **VERIFIED** — `NDArray.init(descriptor:)` discussion: *"**The resulting array may not have a
> contiguous layout.** The strides match the values returned by the descriptor's preferred strides, so
> `contiguousElements` on a view of this array may return `nil`. In that case, use `withUnsafePointer`
> or `withUnsafeMutablePointer` to access the data while respecting the strides."*

So descriptor-allocated arrays are faster to feed and harder to write into. For a *state* that is an
excellent trade, because you almost never write into a state by hand — the graph does it. For an
*input* you fill every step it is a real decision.

`apple/coreai-models` wraps this in a two-line helper:

> ✅ **VERIFIED** — `apple/coreai-models`,
> `swift/Sources/CoreAIShared/Runtime/NDArray+Helpers.swift:12-19`, quoted exactly:

```swift prelude:guide-context
/// Resolve strides from an NDArrayDescriptor for a given concrete shape.
///
/// Uses `NDArrayDescriptor.resolvingDynamicDimensions().preferredStrides` to get
/// framework-blessed strides that respect hardware alignment constraints.
public func resolvedStrides(descriptor: NDArrayDescriptor, shape: [Int]) throws -> [Int] {
    let resolved = descriptor.resolvingDynamicDimensions(shape)
    return resolved.preferredStrides
}
```

⚠️ One trap while writing through `withUnsafeMutablePointer`: the `shape` and `strides` handed to
your closure are **`Span<Int>`**, which is non-escapable and **does not conform to `Sequence`**. No
`for-in`, no `map`, no `reduce`. `apple/coreai-models` ships its own extension just to compute a
product:

> ✅ **VERIFIED** — same file:
> ```swift
> /// `Span` doesn't conform to `Sequence` (non-escapable by design), so `.reduce` isn't available.
> extension Span where Element == Int {
>     var product: Int { ... }
> }
> ```

### 5.3 Zeroing, and the six-second `reset()`

Your caches start life with whatever the allocator gave you. Whether that matters depends entirely
on your graph: if the graph reads only `cache[0..<position]` and you always write before you read,
uninitialised tail data is never observed. If the graph attends over the full fixed-size cache and
relies on a mask, garbage is still never *observed* — but denormals and NaNs in unread lanes can
still cost you, and NaN × 0 is NaN in most masking schemes. When in doubt, zero.

Zeroing is also where a surprising performance trap lives. From Apple's own engine:

> ✅ **VERIFIED** — `apple/coreai-models`, `CoreAISequentialEngine.swift`, source comment: *"under
> `-Onone`, `fillNDArray`'s `(Int) -> LogitsScalarType` closure is invoked per element … which made
> zeroing the KV cache (~14.7M elements for a 32K-context Qwen3) take **~6 seconds per `reset()`**"* —
> which is why the shipped code uses a hand-rolled pointer loop instead.

Two lessons. First, **build optimized** — a Debug build of a Core AI decode loop is not slow by a
constant factor, it is slow by an order of magnitude in specific places. (Community-measured, Noema:
*"Debug builds of `CoreAILanguageModels` are ~3× slower; force `-O` even in Debug."*) Second, if you
must zero a large state, do it through `withUnsafeMutablePointer` and a plain loop or `memset`, not
through a per-element closure.

```swift compile:27 imports:Foundation,CoreAI
/// Zero a state in one shot, without a per-element closure.
///
/// `byteCount` comes from the descriptor you allocated with:
/// `NDArrayDescriptor.minimumByteCount` is documented as "the minimum size a backing
/// storage would need to be to contain the ndArray" — i.e. the addressable byte range
/// implied by shape/strides/scalarType. Resolve dynamic dimensions first.
func zeroFill(_ array: inout NDArray, byteCount: Int) {
    let raw = array.mutableRawView()
    raw.withUnsafeMutableBytes { bytes, _, _ in
        memset(bytes, 0, byteCount)
    }
}
```

> ✅ **VERIFIED** — `NDArray.mutableRawView()`, `NDArray.MutableRawView.withUnsafeMutableBytes(_:)`
> (signature `((UnsafeMutableRawPointer, Span<Int>, Span<Int>) throws(E) -> R) throws(E) -> R`) and
> `NDArrayDescriptor.minimumByteCount` are all Apple-documented. `mutableRawView()` is `mutating`,
> which is why `array` is `inout`.
>
> ⚠️ This zeroes the whole addressable range, which is correct for a contiguous layout and *also*
> correct for a strided one as long as you only care that every element you will read is zero —
> padding bytes get zeroed too, harmlessly. It is **not** correct if the buffer is aliased by
> something else, which is exactly the situation `AsyncValue.init(unsafeBuffer:)` puts you in (§10).

---

## 6. The fixed max-context tradeoff

The Snake example makes a decision in one clause and then moves on:

> ✅ **VERIFIED** — session 324, line 123: *"In this case I converted the model such that it expects
> the key and value caches to always be a **fixed size for a maximum possible context length**."*

That is one of at least four positions on a spectrum, and for anything larger than a toy it is the
wrong default. Here is the spectrum, with the tradeoffs stated.

### The four strategies

`apple/coreai-models` names them, because its `CoreAILanguageModel` exposes the choice as an
initializer parameter:

> ✅ **VERIFIED** — `apple/coreai-models`, `KVCacheStrategy` in the `CoreAILanguageModels` target
> (quoted exactly; the enclosing file was not recorded, so cite the type, not the path):

```swift compile:27
public enum KVCacheStrategy: String, Codable, Sendable, CaseIterable {
    case auto      = "auto"
    case fixedSize = "fixed_size"
    case growing   = "growing"
    case chunked   = "chunked"     // NOT IMPLEMENTED — falls back to StaticKVCache
    public func defaultSize(maxContextLength: Int) -> Int? {
        switch self {
        case .auto: nil
        case .fixedSize: maxContextLength
        case .growing: 256
        case .chunked: maxContextLength
        }
    }
}
```

| Strategy | Allocation | Cost | When |
|---|---|---|---|
| **`.fixedSize`** | `maxContextLength` up front | multi-GB on long-context models; **every step operates on the full-size cache** | you need a hard upper bound on memory, or your graph has static shapes and cannot do otherwise |
| **`.growing`** | starts at **256** tokens, doubles | ~20 ms stall per growth, amortized O(log₂ N) | the default for dynamic-shape models |
| **`.auto`** | resolves at load: `.growing` if the key cache's seq dim is `-1` (dynamic), else `.fixedSize` | — | almost always what you want |
| **`.chunked`** | — | ⚠️ **accepted and silently falls back to the static cache.** It is not implemented. | never, currently |

Apple's own doc comment on `.fixedSize` is unusually direct:

> ✅ **VERIFIED** — `apple/coreai-models`, `EngineOptions` doc comment: *"Avoid `.fixedSize` unless
> you need a known upper bound. It pre-allocates the cache at the full `maxContextLength`, which can
> consume several gigabytes on long-context models **and slows each decoding step because every
> iteration operates on the full-size KV**."*

That last clause is the part people miss. A fixed cache is not merely a memory cost; if your graph
attends over the whole allocated cache rather than a `[0..<position]` slice, you pay the full-context
attention cost from token 1. A 40,960-token cache used at position 12 does 40,960 columns of work.

The `.growing` path has a matching error when you ask for it on a model that cannot support it:

> ✅ **VERIFIED** — `apple/coreai-models`, `KVCacheFactory` error text: *"Strategy 'growing' requires
> dynamic KV cache support. Model has fixed seqDim. Re-export with `--dynamic-sized-kvcache-gpu`
> flag."*
>
> 🔴 **GAP** — **`--dynamic-sized-kvcache-gpu` does not exist** in any of `apple/coreai-models`'
> Python export CLIs. It appears only in Swift error strings and doc comments. It presumably belongs
> to a different or earlier export tool. **What is unknown:** which tool accepts it, or whether the
> message is simply stale. **What would resolve it:** `uv run coreai.llm.export --help` on a machine
> with the current package, or a later revision of the repo. **Safe default meanwhile:** the export
> recipes in `apple/coreai-models` already produce a dynamic cache dimension on the macOS path (see
> §7) — export with `coreai.llm.export … ` and check `stateDescriptor(of:)` for a `-1` in the
> sequence dimension rather than chasing the flag.

And the capacity error, which is what a fixed cache gives you when the conversation outgrows it:

> ✅ **VERIFIED** — `apple/coreai-models`, `KVCacheError.capacityExceeded` message: *"KV cache
> capacity exceeded: need N tokens but only M available. Use `--kv-cache-strategy growing` for
> automatic expansion."*

### The arithmetic you should do before choosing

A KV cache for a dense transformer is:

```
bytes = 2 (K and V)
      × n_layers
      × n_kv_heads
      × head_dim
      × max_seq_len
      × sizeof(cache_dtype)
```

Two numbers from Apple's own exports make this concrete. The macOS LLM recipe's cache tensors are
shaped `(n_layers, 1, n_kv_heads, max_seq_len, head_dim)` in fp16 (✅ verified,
`coreai_models/primitives/macos/cache.py` and `export/macos.py`), and the registry ships Qwen3-4B
with `ctx 40960` and gemma3-12b-it with `ctx 131072` (✅ verified, `model_registry.py` presets). At
those context lengths a `.fixedSize` cache is the dominant term in your app's memory footprint, not
the weights.

The parallel arithmetic for logits, which Apple documents in the same file, is a useful sanity check
on how quickly these numbers get away from you:

> ✅ **VERIFIED** — `apple/coreai-models`, `InferenceEngine.swift` doc comment, verbatim:
> > Logits buffer = batch × seqLen × vocabSize × sizeof(Float16)
> > Example with Qwen3 (vocab_size = 151,936):
> > - 32K prompt without chunking: 1 × 32,768 × 151,936 × 2 = **9.6 GB**
> > - 512-token chunk: 1 × 512 × 151,936 × 2 = **155 MB** (98% reduction)

### The dynamic-cache alternative, and its own cost

If the cache's sequence dimension is dynamic (`-1`), you allocate however much you want at *runtime*
and grow it. That is what `.growing` does. But a dynamic dimension has a price on the other side:

> ⚠️ Community-measured (Noema, a shipping multi-backend iOS app; hardware and OS build not stated
> per-observation): *"Feeding an arbitrary prompt length re-specializes the graph"* — so the app
> buckets prefill into a fixed 32-token block plus power-of-two remainder chunks, *"a handful of
> shapes total, each compiled once and reused across prompts, instead of one fresh compile per prompt
> length."*

Apple's own structure-detection code makes the same trade explicitly, and it is the clearest single
piece of guidance on `SpecializationOptions` in the corpus:

> ✅ **VERIFIED** — `apple/coreai-models`,
> `swift/Sources/CoreAIShared/Runtime/ModelStructure.swift:70-81`, quoted exactly:
> ```swift
> public var specializationOptions: SpecializationOptions {
>     switch self {
>     case .chunkedStatic, .multiFunctionSegmenter:
>         return SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
>     case .dynamic:
>         var opts = SpecializationOptions(preferredComputeUnitKind: .gpu)
>         opts.expectFrequentReshapes = true
>         return opts
>     }
> }
> ```

Read the shape of that decision: **static shapes → Neural Engine; dynamic shapes → GPU plus
`expectFrequentReshapes`.** Your cache-sizing choice and your compute-unit choice are the same
choice. A fixed-size cache with fully static shapes is the ANE path; a dynamic cache is the GPU path.
(`expectFrequentReshapes` is a real, mutable `SpecializationOptions` property that appears in
Apple's shipping code but has **no Discussion, no documented default and no initializer that sets
it** in Apple's reference docs — treat it as ✅ existing, 🔴 undocumented.)

⚠️ And one incident-grade community finding on that property, worth repeating because it is
counter-intuitive:

> ⚠️ **Community-measured** (john-rocky, device-validated 2026-07-23; exact device not stated):
> setting `expectFrequentReshapes` on a **fixed-shape** graph *"kills the AOT bundle."* Attribute as
> community work; status unknown. The safe reading is that the flag is a hint tuned for one regime
> and actively harmful in the other — set it only on the dynamic path, exactly as Apple's own code
> does.

### What to actually do

1. **Read the cache descriptor.** `stateDescriptor(of:)` tells you whether the sequence dimension is
   `-1`. That single fact determines everything else.
2. **If it is dynamic**, start small (Apple's `.growing` starts at 256) and grow by doubling. Budget
   ~20 ms per growth event and note that the growth count is logarithmic, so a 32K conversation pays
   it about seven times total.
3. **If it is static**, the size was baked in at export and your job is to *validate the user's
   context setting against it*, not to allocate. Noema does exactly this for host-cache graphs:
   *"Host-cache graphs have a **static** KV capacity baked into `past_k.shape[3]`; the user's context
   setting is capped by it."* (community-measured).
4. **Never allocate `maxContextLength` "just in case"** on a long-context model unless you have
   measured the memory and you want the determinism.

---

## 7. A real signature: the LLM state contract

Everything so far has been a toy. Here is the real thing, and the reason to trust it is that **two
independent implementations produce byte-identical conventions** — Apple's own export pipeline in
`apple/coreai-models`, and a third-party MLX-to-Core-AI converter that deliberately reproduces it.

### The contract

> ✅ **VERIFIED** — `lucasnewman/mlx2coreai`, `mlx2coreai/_convert_mlx_lm_stateful.py:151-157`
> (module docstring, quoted exactly):
>
> *"Convert an mlx-lm model into one stateful CoreAI asset.*
>
> *The generated `.aimodel` follows the macOS LLM contract used by `coreai-models`: **a single dynamic
> `main` entrypoint with `input_ids`, `position_ids`, and two mutable KV-cache state tensors named
> `keyCache` and `valueCache` by default.**"*

So, concretely:

| Role | Name | Type | Shape |
|---|---|---|---|
| input | `input_ids` | int32 | `(1, S)`, `S` dynamic |
| input | `position_ids` | int32 | `(1, P)`, `P` dynamic |
| output | `logits` | float16 | `(1, S, vocab)` |
| **state** | **`keyCache`** | fp16/bf16/fp32 | `(n_layers, batch, n_kv_heads, max_ctx, head_dim)`, **dim 3 dynamic** |
| **state** | **`valueCache`** | same | same |

The Apple side of that, from the export code:

> ✅ **VERIFIED** — `apple/coreai-models`, `python/src/coreai_models/export/macos.py`: *"Graph
> contract: `input_names = ("input_ids", "position_ids")`, `output_names = ("logits",)`,
> `state_names = ("keyCache", "valueCache")`."* And from
> `python/src/coreai_models/export/_constants.py`, verbatim:
> ```python
> # KV cache names used by the Swift runner
> KEY_CACHE_NAME = "keyCache"
> VALUE_CACHE_NAME = "valueCache"
> TRACE_KV_CACHE_SEQ_LEN = 2048
> QUANT_TRACE_QUERY_LEN = 16
> QUANT_TRACE_OFFSET = 8
> IOS_DEFAULT_MAX_CONTEXT_LENGTH = 4096
> ```

and the cache tensor shape:

> ✅ **VERIFIED** — `apple/coreai-models`, `primitives/macos/cache.py:52-53`:
> `torch.zeros(n_layers, 1, n_kv_heads, max_seq_len, head_dim)`, with
> `KVCache.seq_len_dim() == 3`.

The corroboration from the independent implementation is exact:

> ✅ **VERIFIED** — `lucasnewman/mlx2coreai`, `_convert_mlx_lm_stateful.py:34-35`:
> ```python
> TRACE_QUERY_LENGTH = 16      # matches Apple's QUANT_TRACE_QUERY_LEN
> TRACE_POSITION_OFFSET = 8    # matches Apple's QUANT_TRACE_OFFSET
> ```
> and `_make_state_specs`:
> ```python
> shape = (layout.num_layers, int(batch_size), layout.num_key_value_heads,
>          int(max_context_length), layout.head_dim)
> return [StateSpec(key_cache_name, shape, cache_dtype),
>         StateSpec(value_cache_name, shape, cache_dtype)]
> ```
> — *"byte-for-byte the same as `coreai_models/primitives/macos/cache.py:52-53` … and the dynamic axis
> is **3**, matching `KVCache.seq_len_dim() == 3`."*

Same names. Same shape. Same dynamic axis. Same two magic trace constants (16 and 8). This is not
coincidence — the third-party tool is deliberately reproducing Apple's recipe from the MLX side — but
it does mean you can treat this contract as *the* Core AI LLM convention rather than one repo's
choice.

### Why `position_ids` exists at all

This is the subtle part, and it explains why the runtime must pass the **full** position vector
rather than just the new positions.

The write offset — where in the cache this step's K/V column goes — is derived **inside the traced
graph**, from `position_ids`:

> ✅ **VERIFIED** — `lucasnewman/mlx2coreai`, `_convert_mlx_lm_stateful.py:558-564`:
> ```python
> def _offset_from_position_ids(input_ids, position_ids):
>     query_indices = mx.arange(input_ids.shape[1], dtype=mx.int32)
>     query_len = mx.max(query_indices) + mx.array(1, dtype=mx.int32)
>     last_position = mx.max(position_ids)
>     return last_position - query_len + mx.array(1, dtype=mx.int32)
> ```
> i.e. `offset = max(position_ids) − len(input_ids) + 1`.

So `position_ids` must be `[0, 1, 2, …, total_positions−1]` — the whole vector — not just the new
tail. Feed only the new positions and `max(position_ids)` is wrong, so the offset is wrong, so K/V
land in the wrong cache rows. **Nothing errors.** You get a model that produces confident nonsense.
Both benchmark backends in that repo feed `arange(total_positions)`, and the guide-level rule is:

> **`input_ids` carries only the new tokens; `position_ids` carries the whole running position
> vector.** They have different lengths on every step after the first.

### The `write_state` mechanism, in the IR

If you ever need to audit a stateful asset, this is the marker to look for. The lowering treats three
IR ops as pass-throughs and then annotates the *argument*:

> ✅ **VERIFIED** — `lucasnewman/mlx2coreai`, `lower_to_coreai.py:749-759`:
> ```python
> if op == "read_state":   return self.env[node.inputs[0]]        # the state tensor itself
> if op == "write_state":  return self.env[node.inputs[1]]        # the new value
> if op == "state_update_masked":
>     state, value = self.env[node.inputs[0]], self.env[node.inputs[1]]
>     if len(node.inputs) < 3: return value
>     return coreai.broadcasting_where(self.env[node.inputs[2]], value, state)
> ```
> and `_mark_mutable_buffers`, lines 658-682:
> ```python
> if spec.name in output_by_state:
>     attrs["MutableBuffers.buffer_mutation"] = StringAttr.get(output_by_state[spec.name])
> ...
> graph_op.arg_attrs = ArrayAttr.get(arg_attrs)
> ```
>
> The contract, in the note author's words: *"graph argument `keyCache` carries
> `MutableBuffers.buffer_mutation = "<name of the graph output that is its new value>"`."* Pinned by
> the test `'MutableBuffers.buffer_mutation = "cache_out"' in str(lowered.program)`.

Which is the same attribute `coreai-torch` emits from `register_buffer` (§3). **Two completely
different front ends — PyTorch export and MLX tracing — converge on the same one-attribute
representation.** That is the actual definition of a Core AI state, below all the API sugar.

Note also the third op, `state_update_masked`, lowering to `broadcasting_where(mask, value, state)`.
Hold that thought until §13, where a masked blend turns out to be the *only* way to write a KV column
on the WWDC26 betas for one class of model.

### Argument ordering is load-bearing

> ✅ **VERIFIED** — `lucasnewman/mlx2coreai`, `_convert_mlx_lm_stateful.py`:
> `_reorder_graph_inputs(graph, [input_name, position_ids_name, key_cache_name, value_cache_name])`
> *"then forces the argument order — which is why the Swift runner can index
> `descriptor.stateNames[0]` = key, `[1]` = value."*

Apple's own engine does the same thing:

> ✅ **VERIFIED** — `apple/coreai-models`, `CoreAISequentialEngine`: init validates
> `descriptor.inputNames.count == 2`, `outputNames.count >= 1`, `stateNames.count == 2`, and
> `logitsDesc.scalarType == .float16` (else `unsupportedLogitsType`). *"Names are taken
> **positionally** from the descriptor arrays (inputs[0]=input_ids, inputs[1]=position_ids,
> states[0]=key, states[1]=value, outputs[0]=logits)."*

This is why §4's trap 3 is not academic. The entire ecosystem indexes `stateNames` positionally.

### The whole loop, in Swift

Here is a complete stateful decode step against this contract. It is not a reconstruction — it is
adapted from a Swift runner that exists and compiles against the macOS 27 SDK.

> ✅ **VERIFIED** — every API call below appears in
> `lucasnewman/mlx2coreai`, `scripts/benchmark_aimodel_sampling_coreai.swift`, and the same calls
> appear in `apple/coreai-models`' `CoreAISequentialEngine`. Quoted structure, lightly reorganised for
> reading; the `greedyToken` helper's fp16 hard-coding is the original's.

```swift compile:27
import CoreAI
import Foundation

/// One stateful decode loop over the standard Core AI LLM contract:
///   inputs: input_ids (int32), position_ids (int32)
///   states: keyCache, valueCache   (indexed POSITIONALLY, [0] = key, [1] = value)
///   output: logits (float16)
struct StatefulDecoder {

    let function: InferenceFunction
    let descriptor: InferenceFunctionDescriptor

    let inputName: String, positionName: String
    let keyName: String, valueName: String, logitsName: String

    let inputDesc: NDArrayDescriptor
    let positionDesc: NDArrayDescriptor
    let logitsDesc: NDArrayDescriptor
    let vocabSize: Int

    // The states. Allocated once at `stateCapacity`, mutated in place forever after.
    var keyCache: NDArray
    var valueCache: NDArray

    init(model: AIModel, functionName: String = "main", stateCapacity: Int) throws {
        guard let descriptor = model.functionDescriptor(for: functionName) else {
            throw DecodeError.noFunction(functionName)
        }
        guard let function = try model.loadFunction(named: functionName) else {
            throw DecodeError.noFunction(functionName)
        }
        // Fail loudly and early if the asset is not the contract we expect.
        guard descriptor.inputNames.count == 2 else { throw DecodeError.badArity }
        guard descriptor.stateNames.count == 2 else { throw DecodeError.badArity }

        self.function = function
        self.descriptor = descriptor
        self.inputName    = descriptor.inputNames[0]
        self.positionName = descriptor.inputNames[1]
        self.keyName      = descriptor.stateNames[0]
        self.valueName    = descriptor.stateNames[1]
        guard let logitsName = descriptor.outputNames.first else { throw DecodeError.badArity }
        self.logitsName = logitsName

        self.inputDesc    = try Self.ndArrayDescriptor(descriptor.inputDescriptor(of: inputName))
        self.positionDesc = try Self.ndArrayDescriptor(descriptor.inputDescriptor(of: positionName))
        self.logitsDesc   = try Self.ndArrayDescriptor(descriptor.outputDescriptor(of: logitsName))
        let keyDesc       = try Self.ndArrayDescriptor(descriptor.stateDescriptor(of: keyName))
        let valueDesc     = try Self.ndArrayDescriptor(descriptor.stateDescriptor(of: valueName))
        self.vocabSize    = logitsDesc.shape.last ?? 0

        // Resolve the dynamic sequence axis to the capacity we want at runtime.
        // This is INDEPENDENT of the --max-context-length used at conversion time,
        // because axis 3 was exported dynamic.
        self.keyCache   = NDArray(descriptor: keyDesc.resolvingDynamicDimensions(
            keyDesc.shape.map   { $0 < 0 ? stateCapacity : $0 }))
        self.valueCache = NDArray(descriptor: valueDesc.resolvingDynamicDimensions(
            valueDesc.shape.map { $0 < 0 ? stateCapacity : $0 }))
    }

    /// Run one step. `tokens` = the NEW tokens only.
    /// `totalPositions` = the FULL running position count (see "why position_ids exists").
    mutating func step(tokens: [Int32], totalPositions: Int) async throws -> Int32 {
        var inputIds = NDArray(descriptor:
            inputDesc.resolvingDynamicDimensions([1, tokens.count]))
        fillInt32(&inputIds, values: tokens)

        var positionIds = NDArray(descriptor:
            positionDesc.resolvingDynamicDimensions([1, totalPositions]))
        fillInt32(&positionIds, values: (0..<totalPositions).map { Int32($0) })

        // Pre-allocate the logits backing so run() writes into it instead of
        // allocating a fresh (1 x S x vocab) array every step. See §9.
        var logits = NDArray(descriptor:
            logitsDesc.resolvingDynamicDimensions([1, tokens.count, vocabSize]))

        var states = InferenceFunction.MutableViews()
        states.insert(&keyCache, for: keyName)
        states.insert(&valueCache, for: valueName)

        var outputs = InferenceFunction.MutableViews()
        outputs.insert(&logits, for: logitsName)

        _ = try await function.run(
            inputs: [inputName: inputIds, positionName: positionIds],
            states: consume states,
            outputViews: consume outputs
        )

        return greedyToken(logits: logits, tokenCount: tokens.count, vocabSize: vocabSize)
    }

    private static func ndArrayDescriptor(
        _ value: InferenceValue.Descriptor?
    ) throws -> NDArrayDescriptor {
        guard case .ndArray(let d)? = value else { throw DecodeError.notAnNDArray }
        return d
    }
}

func fillInt32(_ array: inout NDArray, values: [Int32]) {
    var view = array.mutableView(as: Int32.self)
    view.withUnsafeMutablePointer { pointer, _, _ in
        for i in values.indices { pointer[i] = values[i] }
    }
}

func greedyToken(logits: NDArray, tokenCount: Int, vocabSize: Int) -> Int32 {
    // Only the LAST position's logits matter for the next token.
    let offset = max(0, tokenCount - 1) * vocabSize
    let view = logits.view(as: Float16.self)      // the contract fixes logits at fp16
    var best: Int32 = 0
    var bestValue = -Float.infinity
    view.withUnsafePointer { pointer, _, _ in
        for v in 0..<vocabSize {
            let x = Float(pointer[offset + v])
            if x > bestValue { bestValue = x; best = Int32(v) }
        }
    }
    return best
}

enum DecodeError: Error { case noFunction(String), badArity, notAnNDArray }
```

Three details in that code that are easy to get wrong:

- **`stateCapacity` is a runtime choice, not a conversion choice.** Because axis 3 was exported
  dynamic, the same asset serves a 512-token cache and a 32K one. Both benchmark backends in
  `mlx2coreai` exploit this by over-allocating the axis:
  `state_capacity = context_length + (steps if grow_context else 1)` (Python) and
  `contextLength + (growContext ? steps + 1 : 1)` (Swift). ✅ verified — and note the two differ by
  one, which the note flags as an off-by-one between the two backends.
- **`Float16` does not exist on macOS/Catalyst x86_64.** Community-measured (Noema): you need a
  `typealias` and a hand-rolled half codec if you support Intel Macs. `apple/coreai-models` handles
  this with `public typealias LogitsScalarType = Float16` / `Float` on macOS x86_64 (✅ verified).
- **The logits view is fp16 by contract**, not by inference. `CoreAISequentialEngine` *validates*
  this and throws `unsupportedLogitsType` otherwise. If you convert a model whose logits come out
  bf16, cast them in-graph — `mlx2coreai` does exactly that, defaulting
  `cast_bf16_logits_to_fp16=True` with the note *"logits are cast to FP16 by default to match the
  public Qwen3 coreai-models recipe."*

### 🔴 GAP — the Python runtime cannot drive a stateful asset

> 🔴 **GAP** — `mlx2coreai`'s packaged Python runtime helper `run_aimodel` calls
> `await function(inputs=nd_inputs)` **with no `state=` argument** (`runtime.py:87`), so *"the
> packaged library cannot execute the stateful KV-cache asset it produces."* Only its benchmark script
> can, by calling the raw function object with `state=`. Separately, that repo's own commit
> `059c9f3` is titled *"Add a swift runner as python bindings are incomplete as of now."*
>
> **What is unknown:** whether `coreai.runtime`'s Python bindings expose an equivalent of Swift's
> `outputViews:` and the `MutableViews` ownership model at all, or whether this is one library's
> omission. The evidence points at the bindings: the Swift runner exists specifically because they
> were insufficient, and the API delta is exactly output views, mutable-state ownership,
> specialization control and descriptor introspection.
> **What would resolve it:** `help(coreai.runtime.InferenceFunction)` on a machine with
> `coreai-core` installed, or a Core AI Python API reference page (none exists in Apple's 312-symbol
> index — the documented runtime is Swift-only).
> **Safe default meanwhile:** do numeric parity testing in Python with `state=` passed as a plain
> dict of zero-filled `NDArray`s (the shape `coreai-torch`'s own tests use, §4), and do **anything
> performance-related in Swift.** Do not benchmark a Core AI decode loop from Python.

---

## 8. Four silent failures around states

The defining property of this stack is that most defects do not throw. States have four of their own.
Two are performance failures that produce correct output; two are correctness failures that produce
plausible output. None of them raises an error.

### 8.1 ⚠️ SILENT FAILURE — copy-on-write copies your entire KV cache, every step

This is the worst one, because everything works. The output is right, the API is used correctly, no
warning is emitted, and you simply run several times slower than you should for reasons that do not
appear in any profile you would think to take.

> ⚠️ **Community-measured** — `frozen Noema 3.5 snapshot` (a shipping multi-backend on-device LLM app,
> iOS 18–27 / macOS 26–27 / visionOS 26–27), `Noema/CoreAILLMClient.swift`. Source comment quoted
> exactly:
>
> ```swift
> /// Tiny NDArray parked in `stateArrays` slots while a step runs so the working
> /// copy is the unique owner of the state buffer — otherwise the runtime's
> /// in-place state update copy-on-writes the entire KV/SSM cache (tens of MB) every step.
> private let statePlaceholder: NDArray
> ```
>
> Restated in the same repo's consolidated gotcha list: *"In-place state updates copy-on-write the
> whole KV/SSM cache unless you park a placeholder `NDArray` in the state slot during the step."*
> Attribute as community-measured; hardware and OS build are not stated per-observation, and there is
> no Apple statement corroborating or contradicting it.

**The mechanism.** `NDArray` is a `struct` with value semantics and copy-on-write storage. If your
state array is referenced from two places at once — say, a dictionary or array of live states *and*
the `inout` reference you handed to `MutableViews.insert` — then the storage is not uniquely
referenced, and the in-place write triggers a copy of the whole buffer. For a Qwen3-class KV cache
that is tens of megabytes of `memcpy` per decode token.

**The fix**, as the shipping app does it: temporarily replace the entry in your collection with a
tiny placeholder `NDArray` for the duration of the step, so the working copy you pass to `run` is the
unique owner. In sketch form:

```swift illustrative
// Illustrative of the technique described in the community source comment above.
// The API calls are verified; the exact bookkeeping is yours.
mutating func step(...) async throws {
    // Take the state OUT of the collection, leaving a 1-element stand-in behind,
    // so `working` is the unique owner of the big buffer for the duration of the call.
    var working = stateArrays[keyName]!
    stateArrays[keyName] = statePlaceholder

    var states = InferenceFunction.MutableViews()
    states.insert(&working, for: keyName)
    // ... same for valueCache and any extra states ...

    _ = try await function.run(inputs: ..., states: consume states)

    // Put it back, still uniquely referenced.
    stateArrays[keyName] = working
}
```

**How you would ever notice.** You would not, from the Core AI instrument — the inference intervals
look fine, because the copy happens on the CPU outside the inference event. You notice it in the
Time Profiler as `memcpy`/`__platform_memmove` at the top of your decode thread, or by watching
memory bandwidth. If your tok/s is a flat multiple below what a comparable runtime gets on the same
weights, check this first.

**Simplest prophylactic:** hold each state in a **stored property** (`var keyCache: NDArray`), never
in a `Dictionary` or `Array` you also read from during the step. The decoder in §7 does exactly that
and is immune by construction. The placeholder trick is what you need when the number of states is
dynamic — which, for hybrid SSM models with four or six states, it is.

### 8.2 ⚠️ SILENT FAILURE — an in-place mutation silently turns an input into a state

From §3, restated as the hazard it is:

> ✅ **VERIFIED** — `apple/coreai-torch`, `docs/api/TorchConverter.md`: *"**User inputs mutated
> in-place** inside `forward()` (e.g., `x.mul_(2)` on a `forward()` arg)"* are treated as state, and
> *"There is **no flag** to opt a mutated user input out of state."*

Write `x.mul_(2)` where you meant `x = x * 2` — an easy thing to do while optimizing an inner loop —
and `x` stops being an input and becomes a state. Consequences, in order of how long they take to
diagnose:

1. Your `input_names` count no longer matches; the converter throws with a clear message. **Good
   case.** You find it in a minute.
2. You "fix" it by removing `x` from `input_names`, adding it to `state_names`, and shipping. Now the
   Swift side must supply a mutable view for `x` on every call — and if you do, the model's behaviour
   changes, because `x` now persists across calls instead of being fresh each time.
3. You never notice at conversion time because you never passed explicit names, and the FX placeholder
   defaults absorbed the change. Now `stateNames` has an extra entry, `inputNames` has one fewer, and
   your positional indexing in Swift is off by one. **`stateNames[0]` is no longer the key cache.**

**Detection:** a conversion test that asserts the exact `inputNames`, `outputNames` and `stateNames`
arrays — names *and* order — and fails the build when they change. Ten lines, and it catches this
class entirely.

### 8.3 ⚠️ SILENT FAILURE — uninitialised state storage

> ✅ **VERIFIED** — `apple/coreai-torch`, source comment in `tests/utils.py`: `NDArray.from_descriptor`
> *only sizes the buffer*; on Linux the backing storage is not zeroed, so buffer-state reads return
> garbage on the first call. The test helper allocates a zero-filled numpy array instead.

The Python-side statement is explicit and platform-qualified. The Swift-side question — whether
`NDArray(shape:scalarType:)` and `NDArray(descriptor:)` zero their storage on Apple platforms — is
**not documented either way**:

> 🔴 **GAP** — Apple's reference documentation for `NDArray.init(shape:scalarType:)`,
> `init(shape:scalarType:strides:)` and `init(descriptor:)` says nothing about the initial contents of
> the allocation. The `init(scalars:shape:)` overload obviously initialises; the others do not say.
> **What would resolve it:** a documented guarantee, or an empirical test on device (allocate a large
> array, read it, repeat across a few launches — but note that a single "it was zero" observation
> proves nothing, since fresh pages from the kernel are zero-filled and reused ones are not).
> **Safe default meanwhile:** **zero your states explicitly** before the first inference and on every
> `reset()`, using the bulk technique from §5.3. It costs one `memset` per conversation and removes
> the question. This is what Apple's own engine does — `CoreAISequentialEngine` has a `zeroFill`
> routine it calls from `reset()`, which is how the ~6-second `-Onone` measurement in §5.3 was found.

> ✅ **Bounded observations, not a guarantee (2026-08-20 and 2026-09-16).** `probes/`
> `coreai.ndarray-zero-init` dirtied and dropped an 8 MiB `NDArray`, allocated an uninitialised
> same-sized `.uint8` array, and scanned every byte. Six rounds on the beta-5 physical iPhone and
> six rounds each on stable macOS 27 and iPhone 15 Pro / iOS build `24A435` all read zero. Those
> results cannot distinguish framework zeroing from fresh kernel pages and therefore do **not**
> close the documentation gap. The explicit-zeroing rule remains unchanged.

If you are tempted to skip the zeroing on the grounds that your graph masks unwritten positions:
masking with `-inf` on the ANE is itself a trap. Apple's own authoring skill says so —
*"Neural Engine hardware does not handle IEEE `-inf` correctly in softmax"*, so its causal mask uses
`-40000.0` (✅ verified, `apple/coreai-models` `skills/model-authoring/references/neural_engine_rules.md`).
Uninitialised NaNs interacting with a mask you assumed was safe is a debugging session you do not
want.

### 8.4 ⚠️ SILENT FAILURE — the state you forgot to reset between conversations

There is no `reset()` on `InferenceFunction`. Core AI has no notion of "start a new sequence". The
state is whatever you left in it, and the cursor into that state is whatever integer *you* are
tracking. Nothing in the framework will tell you that you have started a new conversation while the
cache still holds the previous one.

Concretely, in the §7 decoder: if you call `step(tokens:totalPositions:)` with `totalPositions`
restarting at 1 but never re-zero or re-anchor the cache, the graph computes
`offset = max(position_ids) − len(input_ids) + 1 = 0` and starts overwriting from row 0 — which
happens to be correct-ish for a fresh conversation, and catastrophically wrong if you meant to
*continue*. The inverse mistake (continuing to increment `totalPositions` across a conversation
boundary) silently prepends the previous conversation to the new one, up to the cache capacity.

**The discipline that prevents it:** keep the *exact token sequence the state corresponds to* next to
the state itself, and make every entry point go through it. That is what the community app does:

> ⚠️ **Community-measured / community-designed** — Noema's `CoreAIDecoder` exposes
> `private(set) var fedTokens: [Int32]  // exact sequence the state corresponds to`, and its cross-turn
> reuse logic is a prefix check against it:
>
> ```swift
> if !cached.fedTokens.isEmpty, promptIDs.count > cached.fedTokens.count,
>    promptIDs.starts(with: cached.fedTokens) {
>     reusedTokenCount = cached.fedTokens.count
> } else { cached.reset() }
> ```

That `fedTokens` log is also what makes §14's prefix reuse possible at all: you cannot trim a cache
to a common prefix if you do not know what is in it.

### The state-hygiene checklist

| Check | Where | Cost of skipping |
|---|---|---|
| Each state held in a stored property, or placeholder-swapped during the call | Swift | whole-cache `memcpy` per step (§8.1) |
| Conversion test asserts exact `stateNames` array and order | Python CI | positional indexing off by one (§4, §8.2) |
| No in-place mutation of `forward()` args you did not intend as state | PyTorch | input silently becomes state (§8.2) |
| `optimize()` called after `to_coreai()` | Python | state protocol not produced at all (§4) |
| States zero-filled before first use and on reset | Swift | garbage in unread lanes, NaN propagation (§8.3) |
| A `fedTokens`-style log of exactly what the state contains | Swift | cross-conversation bleed (§8.4) |
| Build optimized (`-O`) even for local testing | Xcode | ~6 s per `reset()`; ~3× slower generation |

---

## 9. Pre-allocated outputs: the `outputViews:` argument

`outputViews:` is the second `MutableViews` parameter on `run`, and it is the cheapest optimization
in the framework: allocate your output buffer once and let inference write into it, instead of
receiving a freshly-allocated `NDArray` on every call.

> ✅ **VERIFIED** — Apple developer documentation, `run(inputs:states:outputViews:)`, `outputViews:`
> parameter: *"Pre-allocated output values that the function updates during inference. **Outputs with
> a provided view are updated in-place and are not included in the returned
> `InferenceFunction.Outputs`.** Outputs without a provided view produce new values in the returned
> `InferenceFunction.Outputs`."*

Session 324 lists it as one of three low-level levers:

> ✅ **VERIFIED** — session 324, lines 175–181: *"Another area you may want to optimize is **removing
> any overheads in tight inference loops** using your model. The Core AI Framework has several APIs to
> help you here. 1. You can **dynamically check the optimal memory layout of NDArray arguments and
> allocate them with that structure to avoid layout conversions at inference time**. 2. You can also
> **pre-allocate output values for the framework to write into, to avoid allocating new output values
> during inference**. 3. And you can also use **asynchronous values to efficiently pipeline execution
> of multiple inference functions together**. … For most use cases, the higher-level inference APIs
> will get you exactly where you need to be. But when you're **optimizing a tight inference loop or
> integrating a model into a complex compute pipeline**, these lower-level APIs are there when you
> need them."*

Lever 1 is §5.2. Lever 2 is this section. Lever 3 is §10.

### Why it matters for a decode loop specifically

The output of an LLM decode step is a `(1, S, vocab)` logits tensor. At Qwen3's vocabulary of 151,936
and fp16, one step's logits are **~304 KB** — allocated, written, read once, and thrown away, sixty
times a second. Apple's own engine comments on the corresponding input-side saving:

> ✅ **VERIFIED** — `apple/coreai-models`, `CoreAISequentialEngine.swift:252-255`, quoted exactly:
> ```swift
> // Reuse pre-allocated input_ids when the batch size is unchanged.
> // Steady-state decode keeps batchSize=1 forever, so this avoids the
> // `NDArray(descriptor:)` + `resolvingDynamicDimensions` work on every
> // step — small per call, but compounds over long generations.
> ```

Same reasoning, one order of magnitude larger, for logits.

### The fork in the return value

This is the part that surprises people, and it is a *good* surprise once you expect it:

```swift illustrative
var logits = NDArray(descriptor: logitsDesc.resolvingDynamicDimensions([1, 1, vocabSize]))

var outputViews = InferenceFunction.MutableViews()
outputViews.insert(&logits, for: "logits")

let outputs = try await function.run(
    inputs: [...], states: consume states, outputViews: consume outputViews)

// outputs.count == 0 — "logits" is NOT in there, it was written into `logits`.
assert(outputs.count == 0)
```

If every output has a view, the returned `Outputs` is empty and `_ = try await …` is the honest
spelling. If *some* outputs have views, the returned collection contains exactly the ones that did
not. Mixing is fine and is often what you want: pre-allocate the big logits tensor, let the small
auxiliary outputs come back normally.

### `Outputs` is a take-once bag, not a dictionary

Two Apple-documented behaviours that produce confusing bugs when you assume dictionary semantics:

> ✅ **VERIFIED** — `InferenceFunction.Outputs`:
> ```swift
> struct Outputs {
>     mutating func remove(_ outputName: String) -> InferenceValue?
>     var count: Int { get }
>     var names: some Collection<String> { get }
> }
> ```
> `remove(_:)` discussion: *"After you remove a value, subsequent calls with the same name return
> `nil`."*

> ✅ **VERIFIED** — `InferenceValue.ndArray` discussion: *"This property is `nil` when the value
> contains an image instead of an array. **Accessing this property consumes the value and transfers
> ownership of the array to the caller.**"*

So `outputs.remove("logits")` is a destructive take, and `.ndArray` on the result is *also* a
consuming read despite looking like an ordinary getter. Reading the same output twice gives you `nil`
the second time, not a copy. This is deliberate — it is how the framework hands you ownership without
retain/release traffic — but it means a defensive `if let x = outputs.remove("y") { … }` followed by a
later `outputs.remove("y")` is a bug, not a redundancy.

The related fatal-error case, on the other view collection:

> ✅ **VERIFIED** — `InferenceValue.NamedMutableViews.take(_:)` discussion: *"Each value can only be
> taken once. **Requesting the same value again produces a fatal error.**"* (`nil` means only "no value
> with that name".)

### One guarantee you get for free

> ✅ **VERIFIED** — `run(inputs:states:outputViews:)` discussion: *"Any `NDArray` values in the
> returned outputs have a row-major contiguous layout."*

Outputs that come back through `Outputs` are always contiguous, regardless of the internal preferred
layout — so `view(as:).contiguousElements` is non-`nil` for them. Outputs you pre-allocate yourself
have whatever layout *you* gave them, which is another small argument for allocating from the
descriptor.

### Concurrency, and its hidden cost

> ✅ **VERIFIED** — `InferenceFunction` overview: *"This type is `Sendable`, so you can run it
> concurrently from multiple tasks. **The function automatically allocates additional intermediate
> buffers as needed to support concurrency.**"*

Read that second sentence as a warning. Concurrent `run` calls are safe and they silently grow scratch
memory. For a decode loop this is irrelevant — you have one in-flight call by construction. For a
batch workload (session 326's macOS version parallelises segmentation across a folder of photos) it
is a real memory multiplier, and there is no API to bound it.

⚠️ And note that this guarantee does **not** extend to your states. Two concurrent `run` calls sharing
one KV cache is a data race that the type system will not catch, because each call gets its own
`MutableViews` collection and Swift's exclusivity checking does not span `async` calls on separate
tasks. **One decode loop per state set. Always.**

---

## 10. Pipelined execution: `encode`, `ComputeStream`, async values

`run` is synchronous from your loop's point of view: you `await`, the GPU works, you get control back,
you do CPU work (sampling, detokenizing, bookkeeping), then you `await` again. During your CPU work
the GPU is idle. During the GPU's work your CPU is idle. At small model sizes — where each step's GPU
work is a few hundred microseconds and the dispatch overhead is comparable — that idle time is most of
your wall clock.

Pipelining fixes it by decoupling *encoding* work from *executing* it.

### `encode` is `throws`, not `async throws`

That is the whole API insight, and it is worth its own line.

> ✅ **VERIFIED** — Apple developer documentation, `InferenceFunction.encode(inputs:states:outputViews:to:)`:

```swift illustrative
func encode(inputs: [String : InferenceFunction.AsyncValue],
            states: consuming InferenceFunction.AsyncMutableViews = AsyncMutableViews(),
            outputViews: consuming InferenceFunction.AsyncMutableViews = AsyncMutableViews(),
            to stream: ComputeStream)
    throws -> [String : InferenceFunction.AsyncValue]
```

> Discussion, verbatim: *"When this method returns, the compute may still be running on `stream`. You
> can pass the returned async values as inputs to subsequent `encode` calls to build a pipeline of
> inferences without waiting for intermediate results, or await them to retrieve the final compute
> outputs on the CPU."*

> `states:` parameter, verbatim: *"The `inout` arguments that the function reads and writes during
> inference. Note that views for states are not optional. Omitting a view for any state results in an
> error."*

> `outputViews:` parameter, verbatim: *"…The returned dictionary doesn't contain `InferenceFunction`
> outputs for which you provide a view, because the inference updates the mutable view in place. When
> you don't provide a view, the returned dictionary includes a new async output value."*

So the parameter semantics are identical to `run`'s — including the "every state, no exceptions" rule
— but the *timing* is completely different. `encode` returns when the work is **queued**, not when it
is **done**.

### `ComputeStream`

> ✅ **VERIFIED** — Apple developer documentation, `ComputeStream`:

```swift illustrative
final class ComputeStream {
    convenience init()                                   // "Initialize an empty compute stream."
    init(commandQueue: any MTLCommandQueue)              // ⚠️ no watchOS
    final func currentWorkCompleted() async
}
```

> Overview, verbatim (Apple's typo preserved): *"A compute stream is what is provided to
> `encode(inputs:states:outputViews:to:)` to encode the work onto the stream. **Multiple inferences
> encoded to the same stream are serialized as needed based on the the values read/written.**"*

> `init(commandQueue:)` discussion: *"You can use this to encode inferences to your own metal queue."*
> `currentWorkCompleted()`: *"Waits for all previous work encoded to this stream to be complete."*
> (`async`, non-throwing, no return.)

The phrase **"serialized as needed based on the values read/written"** is the most important sentence
in the pipelining API and it is doing enormous work. It means:

- You do **not** hand-write barriers. Encode A then B; if B reads what A writes, the stream serializes
  them. If they are independent, they overlap.
- Your states participate in that dependency graph. Encoding step *n+1* against the same
  `AsyncMutableValue` for `keyCache` that step *n* writes produces the correct ordering automatically:

> ✅ **VERIFIED** — `InferenceFunction.AsyncMutableValue` overview, verbatim: *"**When encoding a
> sequence of inferences which each mutate the same `AsyncMutableValue`, the framework will insert the
> necessary synchronization to avoid it being read or written while a previous write is occurring.**"*

That single guarantee is what makes a pipelined *autoregressive* loop possible at all. Every decode
step reads and writes the same KV cache; the only reason you can encode step *n+1* before step *n*
completes is that the framework knows they collide and orders them.

🔴 **GAP** — the docs stop there. *"Serialized as needed"* is the entire ordering specification. There
is no documentation of how many concurrent streams are advisable, how a `ComputeStream` interacts with
`run()`'s implicit stream, or what the throughput characteristics are. **What would resolve it:** an
Apple doc revision or a Core AI Instruments trace with two streams in flight. **Safe default
meanwhile:** one stream per decode loop, created once, reused; do not mix `run` and `encode` against
the same function concurrently.

### The two async value types

They are asymmetric in a way the docs never explain, and the asymmetry is informative.

> ✅ **VERIFIED** — Apple developer documentation:

<!-- callout-id: async-mutable-value-no-watchos occurrence:2 -->
```swift illustrative
final class AsyncValue {                       // a CLASS, and Sendable
    init(_: CVReadOnlyPixelBuffer)
    init(_: consuming InferenceFunction.AsyncMutableValue)
    init(_: consuming NDArray)
    init(unsafeBuffer: consuming any MTLBuffer, byteOffset: Int = 0,
         scalarType: NDArray.ScalarType, shape: [Int], strides: [Int] = [],
         interleaveLayout: NDArray.InterleaveLayout? = nil)          // ⚠️ no watchOS

    var kind: InferenceValue.Kind { get }
    final var ndArray: NDArray? { get async throws }
    final var pixelBuffer: CVReadOnlyPixelBuffer? { get async throws }
}

struct AsyncMutableValue {                     // a STRUCT
    init(_: consuming CVMutablePixelBuffer)
    init(_: consuming NDArray)
    init(descriptor: consuming InferenceValue.Descriptor)
    init(unsafeBuffer: consuming any MTLBuffer, byteOffset: Int = 0,
         scalarType: NDArray.ScalarType, shape: [Int], strides: [Int] = [],
         interleaveLayout: NDArray.InterleaveLayout? = nil)          // ⚠️ no watchOS

    var ndArray: NDArray? { get async throws }
    var pixelBuffer: CVMutablePixelBuffer? { get async throws }
}

struct AsyncMutableViews {
    init()
    mutating func insert(_ mutableValue: inout InferenceFunction.AsyncMutableValue,
                         for name: String)
}
```

> `AsyncValue` overview, verbatim: *"An `AsyncValue` contains an underlying `InferenceValue` however
> that value may be actively in-use by some previously dispatched async work, and thus accessing the
> underlying value below an `AsyncValue` requires an `await` to wait for any previous compute writing
> it to be complete."* … *"An `AsyncValue` is immutable once any previous compute has completed."* …
> *"Async values can be used in async pipelines of inference to dispatch multiple inference functions
> in sequence without waiting for each to complete before dispatching the next. This can improve
> performance by parallelizing phases of the inferences which are not data dependent."*

> `AsyncMutableValue` overview, verbatim (Apple's typo preserved): *"When dispatching an
> `encode(inputs:states:outputViews:to:)`, mutable values are what is included in the states and output
> vaiews."* … *"this type may be mutated repeatedly after construction by providing it as a state
> argument in sequence to one or more inference functions."*

**Why `AsyncValue` is a class and `AsyncMutableValue` is a struct** is undocumented, but the plausible
reading is that `AsyncValue` needs *reference identity* to serve as a node in the stream's dependency
graph — passing the same output value into two later `encode` calls must be recognisably the same
node. `AsyncMutableValue` is a struct because you `insert(&…)` it into a collection, which needs
`inout`. Mark this reading as inference, not fact.

Three concrete rules:

- **`init(descriptor:)` on `AsyncMutableValue` requires a resolved shape.** *"Note that the descriptor
  must not have a dynamic shape."* ✅ verified. Call `resolvingDynamicDimensions(_:)` first.
- **`.ndArray` on either type may hand you a copy.** *"If this value was constructed from a provided
  MTLBuffer directly, then this will return a **copy** of the data to avoid unsafe aliasing. If
  aliasing is desired, you can work with the original MTLBuffer directly."* ✅ verified. In a decode
  loop this is exactly why you keep the logits on the GPU and sample there (§11) rather than reading
  `.ndArray` every step.
- **`init(unsafeBuffer:)` is explicitly unsafe and constrains the buffer.** *"`unsafeBuffer` must have
  `shared` storage mode. Initializing an async value this way requires that you manually ensure the
  provided metal buffer is not mutated while this value is being used by an inference function."*
  ✅ verified. `strides: []` means contiguous row-major.

### Apple's own two-stage example

The documentation ships one worked example. It is the simplest possible pipeline — two functions, the
first's output feeding the second's input — and it is worth reading closely because the *absence* of
an `await` between the two encodes is the entire point.

> ✅ **VERIFIED** — Apple developer documentation, `encode(inputs:states:outputViews:to:)`, quoted
> exactly:

```swift illustrative
let computeStream = ComputeStream()
let pipelineFunctionOne: InferenceFunction = ...
let pipelineFunctionTwo: InferenceFunction = ...
let initialInput: NDArray = ...

// Run stage one of pipeline and get async value output.
let asyncInput = InferenceFunction.AsyncValue(initialInput)
let functionOneOutputs = try pipelineFunctionOne.encode(inputs: ["input": asyncInput], to: computeStream)
guard let functionOneOutput = functionOneOutputs["output"] else {
    // Handle unexpected missing output
    return
}

// Feed output from function one as an input to function two.
// Note that function one may be running the actual compute asynchronously while function two
// encodes its inference.
let functionTwoOutputs = try pipelineFunctionTwo.encode(inputs: ["input": functionOneOutput], to: computeStream)
guard let functionTwoOutput = functionTwoOutputs["output"] else {
    // Handle unexpected missing output
    return
}

// Now both inferences have been encoded
guard let finalNDArray = try await functionTwoOutput.ndArray else {
    // Handle case where output is not an NDArray
    return
}
```

⚠️ There is a **second** example in the `AsyncValue` overview page which **does not compile as
written** — it omits the required `to:` stream argument on both `encode` calls and misspells a
variable (`embeddingsOutputs` for `embeddingOutputs`). Use the one above. (✅ verified; Apple's own
docs also contain the typos "vaiews" and "the the" quoted earlier — treat prose in this framework's
documentation as accurate and its examples as lightly proofread.)

### Where this pays off outside a decode loop

The two-function shape in Apple's example is not hypothetical. Session 326's app runs SAM 3 as three
separate entrypoints, and the whole reason for splitting a model into multiple functions is that you
can then schedule them independently:

> ✅ **VERIFIED** — `apple/coreai-models`, `swift/Sources/CoreAIShared/Runtime/ModelStructure.swift:13-20`:
> ```swift
> public enum GraphNames {
>     public static let main = "main"
>     public static let loadEmbeddings = "load_embeddings"
>     public static let extendPrefix = "extend"
>     // Multi-function segmenter (lite SAM3 export for iOS).
>     public static let imageEncode = "image_encode"
>     public static let textEncode = "text_encode"
>     public static let detect = "detect"
> }
> ```

An encoder whose output you reuse across many prompts, a decoder you run per prompt: encode the
encoder once, keep its `AsyncValue` output, and feed it into each detector encode without ever
round-tripping the features to the CPU. ⚠️ Note, however, the cross-cutting correction that applies
here: `CoreAISegmentationEngine` **re-runs `image_encode` on every call and exposes no cache**, so the
"encode once" saving requires caller-side work Apple's own package does not do for you.

For a decode loop, the two "functions" are the same function encoded repeatedly, which works because
of the `AsyncMutableValue` serialization guarantee above. That is §11.

---

## 11. A real pipelined decode loop

Apple ships one. It is `CoreAIPipelinedEngine` in `apple/coreai-models`, it is the engine that
`CoreAILanguageModel` auto-selects for dynamic-shape models, and reading it is the best available
substitute for the sample project that does not exist. This section walks its architecture, quoting
the source, and names the five techniques you would otherwise have to rediscover.

The header states the design in five bullets:

> ✅ **VERIFIED** — `apple/coreai-models`,
> `swift/Sources/CoreAILanguageModels/InferenceEngines/CoreAIPipelinedEngine.swift:36-43`, quoted
> exactly:
> > GPU-pipelined inference engine using Core AI's encode API.
> > - Non-blocking GPU encoding via `InferenceFunction.encode`
> > - GPU-direct token sampling (argmax/topK) via MPSGraph compute shaders
> > - Pipeline-depth-matched buffer rotation for CPU/GPU overlap
> > - Growing KV cache with pipelined expansion
> > - **All tensors are owned MTLBuffers — Core AI never allocates/frees them**

### Technique 1 — everything is an owned `MTLBuffer`

The engine does not hand Core AI `NDArray`s at all. It allocates Metal buffers itself and wraps them:

> ✅ **VERIFIED** — `CoreAIPipelinedEngine.swift:707-741` and `:743-766`, quoted exactly:

```swift illustrative
let tokenValue: InferenceFunction.AsyncValue
if tokens.isEmpty {
    // Decode: read input token from previous step's decode output buffer
    tokenValue = unsafe InferenceFunction.AsyncValue(
        unsafeBuffer: decodeOutputBuffers[(step + pipelineDepth - 1) % pipelineDepth],
        byteOffset: 0,
        scalarType: .int32,
        shape: tokenShape,
        strides: tokenStrides
    )
} else {
    ...
}
let asyncInputs: [String: InferenceFunction.AsyncValue] = [
    inputIdsName: tokenValue,
    positionIdsName: posValue,
]
```

```swift illustrative
// Build States as AsyncMutableValue (KV cache, in-place update)
var keyState = unsafe InferenceFunction.AsyncMutableValue(
    unsafeBuffer: keyBuffer,
    byteOffset: 0,
    scalarType: keyCacheScalarType,
    shape: keyShape,
    strides: keyStrides
)
...
var asyncStates = InferenceFunction.AsyncMutableViews()
asyncStates.insert(&keyState, for: keyCacheName)
asyncStates.insert(&valState, for: valueCacheName)
```

Note the Swift 6 `unsafe` expression marker on both — required because `init(unsafeBuffer:)` is an
unsafe API. And note the constraint that comes with it: **`shared` storage mode only** (✅ verified in
Apple's docs), plus your promise that nothing else writes the buffer while the value is in use.

The payoff: `AsyncValue.ndArray` returns a *copy* when the value came from an `MTLBuffer`. By keeping
every tensor as a buffer and never reading `.ndArray`, the engine never pays that copy, and the token
never leaves the GPU.

### Technique 2 — the next token stays on the GPU

Look at that first snippet again. In the decode case, the input token is read from
`decodeOutputBuffers[(step + pipelineDepth - 1) % pipelineDepth]` — **the previous step's GPU-written
output buffer**. There is no CPU round-trip in the loop's critical path. The sampler is an MPSGraph
compute shader that writes the sampled token id straight into the buffer the next encode will read.

This is why the engine reports `supportsLogits == false`, and it is the single most consequential
architectural consequence in the whole Core AI LLM stack:

> ✅ **VERIFIED** — `apple/coreai-models`, `CoreAIPipelinedEngine.generate()` throws on
> `includeLogits == true` with: *"CoreAI pipelined engine does not support logits (GPU-side sampling).
> Use a sequential engine for constrained generation or evaluation."* and on `forcedContinuation`
> with the analogous message.

⚠️ **Cross-cutting consequence, and it is a first-class architectural constraint, not a footnote:**
grammar-constrained decoding needs access to logits. **`@Generable` guided generation is therefore
unavailable on the GPU-pipelined path.** An app that brings its own model loses Foundation Models'
flagship structured-generation feature exactly when it selects the fastest backend. Apple's own
adapter encodes this — `isGuidedGenerationSupported` falls back to `variant != "coreai-pipelined"`
before the engine even loads (✅ verified, `apple/coreai-models`). The same applies to
`forcedContinuation`, which is how MMLU-style *P(continuation | context)* evaluation is done, so a
pipelined bundle also cannot be evaluated that way. See
[Part 4 · `02-bring-your-own-model.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md)
for what that means when choosing a backend.

### Technique 3 — rotate every buffer by pipeline depth

> ✅ **VERIFIED** — `CoreAIPipelinedEngine.swift`, constants:
> ```swift
> private let pipelineDepth = 3
> private let averageExpectedPromptSize = 256
> private let temperatureTolerance: Double = 0.001
> private let minimumMPSNDArrayBufferSize = 64   // "MPSNDArray enforces 64-byte row-stride alignment"
> ```

> ✅ **VERIFIED** — same file: `cachePositionBuffers`, `decodeOutputBuffers` and `decodeLogitsBuffers`
> each have `pipelineDepth` entries, indexed `step % pipelineDepth`. This was *"Fixed by `e358c84`
> 'Fix pipeline race condition: rotate all buffers by pipeline depth (#53)'."*

Three steps in flight means three distinct copies of every per-step buffer. Get this wrong — rotate
two of the three and forget the third — and you have a race that produces occasionally-wrong tokens
under load and never under a debugger. That the fix has a commit number attached tells you it was
found the hard way.

Prefill uses a different trick for the same problem:

> ✅ **VERIFIED** — same file: prefill writes tokens at their **natural position** in
> `inputTokensBuffer` so concurrent chunks touch disjoint regions — *"no `encodeWriteOperands`
> serialization available in Core AI."*

### Technique 4 — backpressure, or you exhaust the allocator

This is the failure mode nobody predicts, and the doc comment describes it precisely:

> ✅ **VERIFIED** — `CoreAIPipelinedEngine.swift`, `PipelineGate` doc comment, quoted exactly:
> > Without this, the decode loop submits encodes (~220/s) faster than the sampler callback drains
> > them (~70/s); depth grows until `MPSCommandBufferImageCache` fails to allocate another private
> > MTLBuffer.
> > Class, not actor: `release()` runs synchronously from the Metal callback — an actor would force
> > `Task { await release() }` with ordering ambiguity.

**Encoding is cheaper than executing.** That is the whole point of `encode`, and it is also the
hazard: an unbounded encode loop will run away from the GPU and die in the allocator rather than
slowing down. `PipelineGate` is a semaphore with capacity `pipelineDepth`; acquire before encoding,
release from the completion callback.

The second paragraph is a genuinely useful Swift-concurrency lesson: the release happens inside a
Metal completion handler, which is a synchronous callback on a Metal-owned thread. Making the gate an
`actor` would require hopping to the actor's executor from inside that callback, and the ordering of
those hops relative to each other is not guaranteed. A plain `final class` with a lock is correct
here and an actor is not.

### Technique 5 — an empty command buffer as a completion sentinel

> ✅ **VERIFIED** — `CoreAIPipelinedEngine.swift:988-1004`, `runCompletion`, quoted exactly:
> > Submit an empty command buffer on the same serial queue. Its `addCompletedHandler` fires after all
> > real sampler callbacks (serial queue FIFO ordering via `MTLDispatchListApply`), guaranteeing every
> > `continuation.yield` has returned before the caller calls `finish()`. We use a bare command buffer
> > instead of the sampler to avoid the shared `MPSGraphExecutableExecutionDescriptor` issue in
> > `MPSGraphCompositeSampler`.

The problem: you are yielding tokens into an `AsyncStream` from Metal completion callbacks, and you
need to know when the last one has actually been delivered before finishing the stream.
`ComputeStream.currentWorkCompleted()` tells you the *compute* is done, not that your callbacks have
returned. Enqueueing an empty command buffer on the same serial queue and waiting for *its* completion
handler gives you a FIFO-ordered "everything before me has fired" signal. This is a Metal idiom rather
than a Core AI one, and it is exactly the kind of thing you would not think of until your stream
occasionally dropped its last token.

### Technique 6 — `reset(to:)` is not symmetric with `reset()`

> ✅ **VERIFIED** — `apple/coreai-models`, `CoreAIPipelinedEngine`:
> - `tokenIndex == 0`: cancel + drain + `currentWorkCompleted()` + `engine.reset()` + `history.clear()`.
> - `tokenIndex > 0`: **does not cancel** — *"cancelling corrupts the pipeline's double-buffer
>   state"* — drains, waits for the GPU, then rewinds counters.
> - Divergence detected during `generate()` forces a **full** reset: *"Tokens differ — full reset
>   (partial rewind corrupts buffer rotation)."*

Partial rewinds and pipelining are in tension, and this is the seam. §14 comes back to it.

### The skeleton

Putting the techniques together, here is the shape of a pipelined decode loop. This is a *skeleton*,
not a transcription — every Core AI call in it is verified, the surrounding structure is a distillation
of the engine above.

> 🟡 **RECONSTRUCTED** structure; ✅ **VERIFIED** calls. `ComputeStream(commandQueue:)`,
> `AsyncValue(unsafeBuffer:byteOffset:scalarType:shape:strides:)`,
> `AsyncMutableValue(unsafeBuffer:…)`, `AsyncMutableViews()` + `insert(_:for:)`,
> `encode(inputs:states:outputViews:to:)` and `currentWorkCompleted()` are all Apple-documented and
> all appear in `apple/coreai-models`' shipping engine. The gate, the rotation arithmetic and the
> sampler hook mirror that engine's structure.

```swift illustrative
import CoreAI
import Metal

actor PipelinedDecoder {
    private let function: InferenceFunction
    private let stream: ComputeStream
    private let gate: PipelineGate          // capacity == pipelineDepth
    private let pipelineDepth = 3

    // One set per pipeline slot.
    private var tokenBuffers:  [any MTLBuffer]   // int32, the sampled token id
    private var posBuffers:    [any MTLBuffer]   // int32, position_ids
    private var logitsBuffers: [any MTLBuffer]   // fp16, (1, 1, vocab)

    // Shared across all slots — the states.
    private var keyBuffer: any MTLBuffer
    private var valueBuffer: any MTLBuffer

    init(function: InferenceFunction, queue: any MTLCommandQueue, ...) throws {
        self.function = function
        // Encode onto YOUR queue, so the sampler shader can share it.
        self.stream = ComputeStream(commandQueue: queue)
        ...
    }

    func decodeStep(_ step: Int, position: Int32) throws {
        // 1. Backpressure FIRST. Encoding is cheaper than executing; without this
        //    the loop outruns the GPU and dies in the allocator, not in your code.
        gate.acquire()

        let slot = step % pipelineDepth
        let prevSlot = (step + pipelineDepth - 1) % pipelineDepth

        // 2. Input token = the PREVIOUS step's GPU-written output. No CPU round-trip.
        let tokenValue = unsafe InferenceFunction.AsyncValue(
            unsafeBuffer: tokenBuffers[prevSlot], byteOffset: 0,
            scalarType: .int32, shape: [1, 1], strides: [])

        writePosition(position, into: posBuffers[slot])
        let posValue = unsafe InferenceFunction.AsyncValue(
            unsafeBuffer: posBuffers[slot], byteOffset: 0,
            scalarType: .int32, shape: [1, 1], strides: [])

        // 3. States: the SAME AsyncMutableValues every step. The framework inserts
        //    the synchronization that makes step n+1 wait for step n's KV write.
        var keyState = unsafe InferenceFunction.AsyncMutableValue(
            unsafeBuffer: keyBuffer, byteOffset: 0,
            scalarType: .float16, shape: keyShape, strides: keyStrides)
        var valState = unsafe InferenceFunction.AsyncMutableValue(
            unsafeBuffer: valueBuffer, byteOffset: 0,
            scalarType: .float16, shape: valueShape, strides: valueStrides)

        var states = InferenceFunction.AsyncMutableViews()
        states.insert(&keyState, for: keyCacheName)
        states.insert(&valState, for: valueCacheName)

        // 4. Pre-allocated logits, per slot, so nothing is allocated in the loop.
        var logitsValue = unsafe InferenceFunction.AsyncMutableValue(
            unsafeBuffer: logitsBuffers[slot], byteOffset: 0,
            scalarType: .float16, shape: [1, 1, vocabSize], strides: [])
        var outputs = InferenceFunction.AsyncMutableViews()
        outputs.insert(&logitsValue, for: logitsName)

        // 5. Encode. Returns as soon as the work is QUEUED — this is the whole point.
        _ = try function.encode(
            inputs: [inputIdsName: tokenValue, positionIdsName: posValue],
            states: consume states,
            outputViews: consume outputs,
            to: stream)

        // 6. Encode the sampler onto the SAME queue, writing the next token id into
        //    tokenBuffers[slot]. Its completion handler yields the token and calls
        //    gate.release().
        try encodeSampler(from: logitsBuffers[slot], into: tokenBuffers[slot], slot: slot)
    }

    /// Call before tearing anything down, or before reading a buffer on the CPU.
    func finish() async {
        await stream.currentWorkCompleted()
    }
}
```

The loop that drives it does *not* `await` between steps. It encodes, encodes, encodes, and the gate
blocks it when it gets three ahead. That is the difference between pipelined and sequential
execution, and everything else in this section is bookkeeping in service of it.

---

## 12. What pipelining is actually worth

There is a number in circulation — **~3.5×** — and it is frequently repeated as "the pipelined engine
is 3.5× the sequential engine." **That is wrong, and the error matters**, because it makes the
sequential engine look like a mistake when it is in fact the *only* engine that can do guided
generation, evaluation and cheap prefix reuse.

### What the 3.5× figure actually measures

> ⚠️ **Community-measured** — john-rocky, `knowledge/coreai-vs-mlx-speed.md:47-50`, quoted exactly:
>
> *"The historical 'MLX is ~2× faster, structural' verdict was measured on a **hand-rolled per-token
> `fn.run()` loop** (~11 % of BW peak, ~1000 Metal dispatches/token). That was the *loop's* ceiling,
> not Core AI's. Apple's **`coreai-pipelined` engine** runs the same weights **~3.5× faster
> (qwen3.5 58.5 → 204 tok/s, ~2× MLX)** with zero custom kernels."*
>
> Hardware: **M4 Max**, per that file's benchmark table. Model: qwen3.5. Protocol: the same
> `mlx-lm benchmark`-style protocol used elsewhere in that document — **512 prompt / 1024 generation /
> 5 trials, release build**. Attribute as community-measured; hardware is stated, the exact macOS
> build is not.

So the correct sentence is:

> **Apple's pipelined engine ran ~3.5× faster than a naive hand-rolled per-token `fn.run()` loop on
> the same weights (qwen3.5, 58.5 → 204 tok/s, M4 Max, community-measured).**

The baseline is a *hand-rolled loop*, described in the same source as spending ~11 % of bandwidth peak
and issuing roughly a thousand Metal dispatches per token. That is a loop with no output views, no
buffer reuse, a CPU round-trip per token, and a fresh `NDArray` allocation per step — i.e. a loop that
makes every mistake §9 and §11 exist to prevent. The 3.5× is measuring **the sum of all those
techniques plus pipelining**, against a baseline that used none of them.

It is a real and useful number. It is not a pipelined-vs-sequential number.

### 🔴 GAP — nobody has measured pipelined vs sequential under control

> 🔴 **GAP** — **No controlled sequential-engine-vs-pipelined-engine measurement exists in this
> corpus.** Every published Core AI LLM throughput figure found — the whole M4 Max table (qwen3-0.6b
> 484 tok/s, qwen3-4b 145.4, qwen3-8b 94.1, gemma3-4b-it 141.5, mistral-7b 101.7, gpt-oss-20b 78.1),
> and the iPhone 17 Pro rows — is annotated **"pipelined"**. The sequential engine appears in the
> corpus only as a *fallback* and as the engine you must use for logits.
>
> **What is unknown:** how much of the gap between a well-written `run()` loop and the pipelined
> engine is attributable to pipelining specifically, as opposed to GPU-side sampling, owned
> `MTLBuffer`s, output views and buffer rotation — all of which the pipelined engine also does and a
> sequential loop can also do.
>
> **What would resolve it:** running `llm-benchmark` from `apple/coreai-models` on the same bundle
> twice with `--inference-engine-variant coreai-sequential` and `coreai-pipelined`, release build, same
> device, same thermal state. Both variants exist and both are selectable
> (✅ verified: `EngineFactory` accepts `auto`, `coreai-sequential`, `coreai-pipelined`,
> `static-shape`, and rejects anything else with *"Unknown variant '<x>'. Valid: auto,
> coreai-sequential, coreai-pipelined, static-shape"*). This is a one-afternoon experiment that nobody
> in the corpus has run.
>
> **Safe default meanwhile:** if you need speed and do not need logits, use the pipelined engine —
> Apple's `EngineFactory` already auto-selects it for dynamic-shape models, so the default is the fast
> path. If you need logits, use the sequential engine and apply §9's output views and §5.2's preferred
> strides; do not assume you are giving up 3.5×, because that figure was never measured against a
> tuned sequential loop.

### What the published numbers do support

These are all **community-measured** with a stated protocol, and they are the most useful Core AI
performance data that exists because they measure **Apple's own artifacts with Apple's own tools**:

> ⚠️ **Community-measured** — john-rocky, `knowledge/apple-models-bench.md`. Premise, verbatim:
> *"Apple's `coreai-models` repo ships **21 export recipes** but publishes **zero performance numbers
> and zero sample apps**. This page is the missing table: every model exported with **Apple's official
> recipe, unmodified**, and measured with **Apple's official runners** (`llm-benchmark` / `llm-runner`)
> on real hardware."*
> Hardware: MacBook Pro **M4 Max 128 GB (macOS 27 beta)** and **iPhone 17 Pro (iOS 27 beta)**.
> Protocol: `llm-benchmark` defaults — **512 prompt / 1024 generation, 5 trials, release build.**

| Model | Recipe | Artifact | Prompt tok/s | Gen tok/s | Load (warm) | Peak mem |
|---|---|---|---:|---:|---|---|
| qwen3-0.6b | `4bit` / fp16 / ctx 8192 | 335 MB | 9 396 | **484** (558 short-ctx) | 0.10 s (cold 0.85 s) | 0.77 GB |
| qwen3-4b | `4bit` / fp16 / ctx 40960 | 2.1 GB | 1 635 | 145.4 (164 short-ctx) | 0.36 s (cold 1.95 s) | 4.6 GB |
| qwen3-8b | `4bit` / fp16 / ctx 40960 | 4.3 GB | 912 | 94.1 (102 short-ctx) | 0.64 s (cold 2.92 s) | 9.3 GB |
| gemma3-4b-it | `4bit` / bf16 / ctx 131072 | 2.1 GB | 1 669 | 141.5 (157 short-ctx) | 0.32 s (cold 2.20 s) | 4.5 GB |
| gemma3-12b-it | `4bit` / bf16 / ctx 131072 | 6.2 GB | 578 | 55.0 (59 short-ctx) | 5.4–7.7 s (variance) | 13.4 GB |
| mistral-7b-instruct-v0.3 | `4bit` / fp16 / ctx 8192 | 3.8 GB | 976 | 101.7 (109 short-ctx) | 0.56 s (cold 2.49 s) | 8.3 GB |
| gpt-oss-20b (MoE) | `none` / bf16 / ctx 32768 (MXFP4 kept) | 13 GB | 1 252 | 78.1 | 2.1 s (cold 13.2 s) | 33.9 GB |

Three readings that matter for this guide:

1. **Every row has a short-context number 8–15 % higher than the 512p/1024g number.** Decode speed is
   context-dependent, exactly as §2's "growing at a much slower rate" hedge predicts. A headline tok/s
   without a stated protocol is meaningless, and the same source says so.
2. **Prompt throughput is 5–20× decode throughput.** Prefill is compute-bound and parallel; decode is
   dispatch- and bandwidth-bound and serial. That asymmetry is *why* prefix reuse (§14) is worth so
   much more than any decode optimization.
3. **Peak memory is roughly 2× the artifact size** on these settings, which is the KV cache plus
   activations plus the runtime. Budget accordingly before choosing `.fixedSize`.

And the one comparative claim the same author makes, with its own caveat attached:

> ⚠️ **Community-measured**, same file: *"On standard **dense** transformers Core AI's pipelined engine
> ties or beats MLX. Core AI only loses where the model uses an op-class the stock engine lowers
> naively."* — with the asymmetry that *"Core AI ships int8, MLX ships 4-bit — so this is not an
> iso-precision comparison, it is a ship-config comparison."*

### The one place pipelining is a liability

Pipelining buys throughput and costs *controllability*. Two consequences, both community-reported:

> ⚠️ **Community-measured** (Noema): *"**Cross-turn KV reuse is NOT possible on this engine**: the
> pipelined GPU loop overshoots the consumer's EOS break by its pipeline depth (extra tokens land in
> device-resident KV and the SSM states, which can't be rolled back), so the exact fed sequence is
> unknowable. **TTFT here is inherently `historyTokens / decodeRate`.**"*

> ⚠️ **Community-measured** (john-rocky, fork commit `627fec7`): a consumer that `break`s the token
> stream at EOS leaves generation running to `maxTokens` in the background, and those post-EOS tokens
> are *"consumed into the KV cache"*, so the next turn blocks on the leftover generation. Reported
> effect, qwen3.5-0.8B two-turn chat through Apple's own `CoreAILanguageModel` adapter: second-turn
> latency **2.74 s → 0.40 s** after the fix. Device not stated — 🔴 unverified which hardware.
>
> ⚠️ **Important correction to that attribution:** upstream `apple/coreai-models` carries a commit
> `04a3fd6` *"Stop pipelined generation when consumer drops the stream (#113)"*, so this is **not** an
> outstanding upstream defect — the community fork was a snapshot taken before that landed. Do not
> repeat "upstream has this bug." Do take the lesson: **on a pipelined engine, breaking the stream is
> not the same as stopping generation**, and if your engine version predates that fix you will see it.

So the decision is not "pipelined is faster, use pipelined." It is:

| You need | Engine | Why |
|---|---|---|
| maximum decode throughput, single-turn | pipelined | GPU-side sampling, no CPU round-trip |
| `@Generable` / guided generation | **sequential** | needs logits; pipelined returns `supportsLogits == false` |
| evaluation with `forcedContinuation` | **sequential** | same reason |
| cheap multi-turn TTFT via prefix reuse | **sequential** | §14 — pipelined rewind is unverified and the overshoot makes the fed sequence unknowable |
| Neural Engine execution | static-shape | a third engine entirely; see §13 for its current state |

---

## 13. The MPSGraph in-graph KV-write bug

Everything above assumes that writing a KV column from inside the graph works. On the WWDC26 betas,
for one specific and important class of model, it does not — and the way it fails is a textbook
example of the silent-then-loud failure mode this framework specialises in: **conversion succeeds; it
is load and execute that die.**

> ⚠️ **Community-measured throughout this section.** Source: john-rocky,
> `knowledge/coreai-beta-mpsgraph-kvwrite-bug.md`, filed as Apple Feedback **FB23024751** and
> [`apple/coreai-models` issue #5](https://github.com/apple/coreai-models/issues/5), with a public
> reproduction gist. This is first-hand incident material from one author with self-declared
> uncontrolled benchmarks; the *isolation* is rigorous and reproducible, the *status* is unknown.
> **Check FB23024751 and issue #5 before acting on any of it** — a beta bug from mid-2026 may well be
> fixed by the time you read this.

### The symptom

The affected path is **the fixed-shape / ANE decode recipe** — described in the source as *"the one
that writes each new KV column in-graph with `slice_update` at a runtime `in_step` index (**Apple's
documented `export/ios.py` + `CoreAIStaticShapeEngine` recipe**)"*. That is not an exotic
configuration; it is the documented iOS path (§7's `export/ios.py` contract, with the four entrypoints
`load_embeddings` / `gather_embeddings` / `extend` / `prompt_opt`).

| Platform | Failure |
|---|---|
| **Mac GPU** | `EXC_BREAKPOINT` / **SIGTRAP** at the first execute (process exit 133) |
| **iPhone GPU** | **SIGSEGV** at the first execute — *"the graph loads + specializes, **then** crashes"* |
| **iPhone ANE** | `MPSGraphExecutable.mm` → *"MLIR pass manager failed"* (**SIGABRT**); **corrupts the ANE compile cache** (next load = `ENOENT`) |

And the detail that makes it nasty, quoted: *"Conversion **succeeds** — it is load + execute that
dies."* Your build is green. Your `.aimodel` inspects cleanly in Xcode. The Functions tab shows the
right signature. Then the app crashes on device with a signal, in Apple's framework, with no Swift
stack frame of yours anywhere near it.

⚠️ The ANE case is worse than a crash: it **corrupts the ANE compile cache**, so the *next* load fails
with `ENOENT` even for a model that would otherwise work. If you are debugging an ANE bring-up and
started seeing `ENOENT` on assets that used to load, this is a candidate cause, and the remedy is to
clear the specialization cache (`AIModelCache.default.deleteEntries(for:)`) before retrying.

### The isolation — worth reading as a method

This is the part to steal regardless of whether the bug still exists. The author exported the **same
attention block, same `slice_update`, same SDPA** three ways, differing in **only the source of the
KV-write column index**:

| Write index `begin` | Shapes | Result |
|---|---|---|
| shape **symint** (`position_ids.shape[-1] − query_len`, the `update_and_fetch` path) | dynamic | **runs** ✅ |
| runtime **tensor** (`in_step` scalar input) | dynamic | **SIGTRAP** ✗ |
| runtime **tensor** (`in_step` scalar input) | **static** | **SIGTRAP** ✗ |

> Quoted: *"So it is not the mask, not static-ness, not the model — flipping the begin-index
> **source** (shape symint → runtime tensor) alone flips run → crash. Model-agnostic: every model
> shares the one `KVCache.update_and_fetch` helper."*

Three exports, one variable, a clean two-by-two that eliminates the mask, the static-ness and the
model in one pass. When you file a Feedback about a Core AI numerics or lowering failure, this is the
shape the report should have.

### The trap in the surviving path

The "runs ✅" row is not a fix, because:

> Quoted: *"the **dynamic symint path runs but re-specializes per sequence length** (the slow path —
> a new `position_ids` length recompiles, **~27 ms → ~1.9 s/step**). The fast fixed-shape path is
> exactly the one that crashes."*

**~70× per-step penalty for taking the working path.** And note that this is the same
re-specialization hazard §6 flagged from a different direction — Noema buckets prefill shapes for
exactly this reason. Dynamic shapes are not free; they are a compile-per-shape tax, amortised only if
you keep the shape set small.

### Workaround 1 — host-cache the KV

Express the cache as plain model **input/output** instead of a Core AI state, and remove the indexed
write entirely:

- append the new token's K/V in-graph with `torch.cat` (past ++ current);
- attend with a **masked SDPA** over the concatenated keys (valid past and current marked by an
  explicit mask);
- the **host** writes the new column back between steps (plain numpy / `[Float16]`).

> Quoted: *"Only MPSGraph-safe ops (masked SDPA over plain inputs + `cat`) — no state, no
> `slice_update`. Numerically identical to the stateful core (**8/8 top-1 vs HF**). Runs on Mac GPU,
> iPhone GPU (full model), and iPhone ANE (chunked). For the ANE, split into **≤ ~8-layer chunks** (the
> 35-layer monolith OOMs the first-run ANE compile)."* Cost: *"a host round-trip per step + losing Core
> AI's in-place state."*

This is not an exotic invention — it is the **same shape Apple's own ANE recipe uses**, which is the
strongest evidence that it is a sanctioned pattern rather than a hack:

> ✅ **VERIFIED** — `apple/coreai-models`, `skills/model-authoring/SKILL.md`, KV-cache conventions
> table:
>
> | Compute unit | Cache shape | Seq dim | Pattern |
> |---|---|---|---|
> | Neural Engine | `[n_layers, B, H_kv*D, 1, max_S]` | 4 | **Readonly functional I/O — model has no cache writes, returns new K/V as outputs** |
> | GPU | `[n_layers, B, H_kv, max_S, D]` | 3 | **Stateful export wrapper — `register_buffer` + `hoistToArg`** |

Two compute units, two completely different KV strategies, and **only the GPU one is a Core AI
state**. Read that table before you decide anything about states: if you are targeting the Neural
Engine, the answer to "how do I make my KV cache a state" may legitimately be "you don't."

The corresponding runtime shape is documented by a shipping app:

> ⚠️ **Community-measured** (Noema), `CoreAIDecoder` class doc, quoted exactly: *"**Host-cache** …:
> the caches ride as plain I/O (`causal_mask`/`past_k`/`past_v` [+ `conv_state`/`rec_state`] in,
> `k_cur`/`v_cur` [+ `conv_cur`/`rec_cur`] out) because the **ANE compiler rejects in-graph indexed KV
> writes**. The host writes each step's K/V column back at `position` and threads the SSM states."*

Also from that app, the detection helper — because a host-cache asset is recognisable from its
descriptor alone:

```swift illustrative
// Community-authored (Noema). Distinguishes a host-cache graph from a stateful one
// by looking for the cache-as-input signature, and recovers the STATIC capacity
// baked into the export.
static func hostCacheCapacity(in descriptor: InferenceFunctionDescriptor) -> Int? {
    guard Set(descriptor.inputNames).isSuperset(of: HostCacheRuntime.requiredInputs),
          case .ndArray(let pastK) = descriptor.inputDescriptor(of: "past_k"),
          pastK.shape.count == 5, pastK.shape[3] > 0 else { return nil }
    return pastK.shape[3]      // static KV capacity baked into the export
}
```

### Workaround 2 — the input-mask escape

This is the better result, and it is the reason this section is in the guide rather than in a
footnote.

Further isolation narrowed the trigger precisely:

> Quoted: *"what crashes is deriving the write position **in-graph** from runtime data. Hand the graph
> the position as a pre-computed mask **input** and the numerically identical write lowers and runs."*

```python
# Community-authored (john-rocky), 2026-06-10. Quoted from the incident write-up.
# host builds a one-hot fp16 write_mask[ctx] per step (1.0 at the write column) — 2 KB
sl = cache[slot]                          # state, compile-time slot index
m  = write_mask.reshape(1, 1, ctx, 1)
sl.copy_(sl * (1 - m) + col * m)          # exact one-hot select; NO data-derived index anywhere
```

Read what that expression is: a **blend**, not a write. `sl * (1 − m) + col * m` with a one-hot `m`
selects exactly the target column and leaves every other column bit-identical. There is no index
anywhere — no `slice_update`, no `in_step`, nothing derived from runtime data inside the graph. The
only thing the graph receives is a 2 KB mask the host computed.

The five-way isolation that established it, each formulation run in its own process with multi-step
state values verified exact, on the beta Mac GPU:

| Formulation | Result |
|---|---|
| constant-mask blend | ✅ |
| **input-mask blend** | ✅ |
| shift-append (`cache ← cat(cache[1:], col)`) | ✅ |
| input-mask blend into one slot of a packed `[n_slots,…]` state (both slot-view and whole-state forms) | ✅ |
| the same blend with the one-hot computed **in-graph** (`arange == in_step`) | **✗ crashes exactly like `slice_update`** |

The last row is the control that proves the diagnosis: identical arithmetic, identical result values,
and the *only* difference is whether the one-hot was computed on the host or in the graph.

And the scale result:

> Quoted: *"a 35-layer Gemma 4 E2B static decode core with the blend write (everything else identical
> to the official fixed-shape recipe) exports to int8 and runs **8/8 greedy-exact on the beta macOS
> GPU** — **the first fixed-shape *stateful* core that executes on this beta at all.** You get fixed
> shapes (no per-step respecialization, flat memory) **and** Core AI states (no host KV round-trip) at
> the cost of one tiny mask input per step."*

⚠️ **Honest status, quoted:** *"Mac GPU verified; iPhone GPU / ANE re-isolation **pending** (the crash
was platform-agnostic, the escape should be too — but the ANE's MLIR path is a different lowering, so
**verify before betting a port on it**)."*

Note the structural echo: §7 showed that the Core AI IR already has a `state_update_masked` op that
lowers to `broadcasting_where(mask, value, state)`. The input-mask escape is, in effect, hand-rolling
that op with a host-supplied mask. Whether the two paths lower identically is unverified.

### What to take from this

1. **Conversion success is not evidence of anything.** For a stateful model, "it converted" and "it
   runs" are independent facts on these betas. Load and execute the asset in CI, do not merely convert
   it.
2. **The GPU-first posture of the community stack has a specific cause**, and it is this bug plus one
   structural fact: custom Metal kernels are GPU-only by construction, because *"the ANE runs fixed
   hardware ops, never hand-written MSL."*
3. **Do not conclude "the ANE is broken."** The same source explicitly retracts that reading: *"gemma4
   E2B ran **8/8 exact on the device ANE** once fp16 numerics were fixed … The earlier 'ANE 0/8' read
   was retracted."* The ANE is throughput-capped at the moment (a 262k-vocab head plus a host-cache KV
   re-feed every step), not correctness-capped — and the fix for the throughput cap is stateful KV,
   which is this very bug. On device the GPU lead was small at measurement time: **iPhone GPU 7.4 vs
   ANE 5.9 tok/s** (community-measured; the large GPU numbers in §12 are all Mac).
4. **If you are shipping to iOS on the ANE today**, the host-cache pattern is the conservative choice,
   it is what Apple's own authoring skill prescribes for that compute unit, and it is what at least one
   shipping app does.

---

## 14. Prefix reuse: one integer assignment, ~101×

States solve the *intra*-generation problem: don't recompute K/V for tokens you already processed
during this generation. They do nothing, by themselves, for the *inter*-turn problem: turn 2 of a
chat re-processes all of turn 1 — system prompt, retrieved documents, the whole history — before
emitting a single new token.

This section is the highest-value thing you can do with a KV cache after making it exist, and the
mechanism is almost embarrassingly cheap.

> ⚠️ **Community-measured throughout.** Source: john-rocky, `knowledge/prefix-cache-kv-reuse.md` and
> fork commit `0fdf710` (3 files, +69/−0). This is a community fork of `apple/coreai-models`, not
> upstream Apple code. The *mechanism* is corroborated by upstream's own source comment (quoted
> below); the *API* and the *numbers* are the fork author's.

### The problem

> Quoted, `prefix-cache-kv-reuse.md:12-18`: *"`CoreAIChatMac/Sources/ChatEngine.swift` was doing
> exactly the worst thing: `engine.reset()` + `applyChatTemplate(full history)` + full re-prefill on
> EVERY turn … For a 4k-token RAG context that is seconds of dead time before the first new token,
> every turn."*

### The insight — nothing has to be cleared

The engines already preserve KV across `generate()` calls and already prefill only the unprocessed
suffix. The missing primitive was a **rewind**. And a rewind is free, because attention is causal.
The insight is credited to a comment in upstream's own `reset()`:

> Quoted, `:22-25`: *"`reset()`'s own comment gave the key: **'the KV pair needs no clearing —
> attention only reads positions below the new offset.'** So a partial trim = just set
> `processedTokenCount = length`; positions ≥ length are overwritten before they're ever read."*

**Trimming a KV cache is a single integer assignment.** No buffer zeroing, no `memmove`, no
reallocation. The KV tensor is left byte-for-byte untouched; only the engine's notion of "how many
tokens are committed" moves backwards. Rows at or beyond the retained position are stale garbage that
gets overwritten by the next prefill *before* any causal read can reach them — a query at position *p*
attends only to keys at positions ≤ *p*.

The implementation is five lines:

> ⚠️ **Community-authored** — `john-rocky/coreai-models` fork,
> `CoreAISequentialEngine.swift:437-443`, quoted exactly:
> ```swift
> public func trimKVCache(to length: Int) async -> Int {
>     drain()
>     guard length >= 0 else { return -1 }
>     let retained = min(length, processedTokenCount)
>     processedTokenCount = retained
>     return retained
> }
> ```
> `drain()` first so no in-flight generation is still writing KV. Its doc comment: *"KV-only (no
> recurrent state) — always safe; no clearing needed since causal attention never reads positions ≥
> the retained offset before they're rewritten."*

### The API contract, and its one subtlety

> ⚠️ **Community-authored** — same fork, `InferenceEngine.swift:111-123`:
> ```swift
> func trimKVCache(to length: Int) async -> Int
> var prefixReuseFeedsFullSequence: Bool { get }
> ```
> with protocol-extension defaults `{ -1 }` and `{ true }` — i.e. **opt-in and fail-safe**: an engine
> that does not implement it reports "unsupported" and the caller degrades to full re-prefill.

Two contract details that are easy to get wrong:

- **The return value is the ACTUAL retained prefix, which may be less than you asked for.** Quoted:
  *"which may be less than requested because the last generated token's KV can lag one step behind —
  the caller must prefill from the returned offset, not from `length`."* **Never trust your own
  requested length.**
- **The feed convention differs per engine.** `prefixReuseFeedsFullSequence == true` (the default,
  and what the sequential engine does) means `generate(with:)` takes the **full running sequence** and
  the engine slices `input[retained...]` internally. `false` means the caller passes **only the
  un-cached suffix**. Get this backwards and you either re-prefill everything (harmless, slow) or feed
  the suffix twice (a correctness bug).

### The caller-side algorithm

> ⚠️ **Community-authored** — `prefix-cache-kv-reuse.md:40-46`, per turn:
>
> 1. `full = applyChatTemplate(history)` (unchanged).
> 2. `want = min(commonPrefixLength(full, kvTokens), full.count - 1)` — where `kvTokens` is the
>    **exact token sequence the engine's KV currently holds** (prompt **+** streamed generation),
>    tracked by the caller across turns. The `full.count - 1` clamp guarantees at least one token is
>    fed, so the graph always has something to run.
> 3. `reused = await engine.trimKVCache(to: want)`; on `< 0` → `reset()` and `reused = 0`.
> 4. `feed = engine.prefixReuseFeedsFullSequence ? full : full[reused...]` → `engine.generate(with: feed)`.
> 5. **Break at the stop sequence (no drain)** so the KV ends at prompt + real answer.

Step 2 is §8.4's `fedTokens` log under another name. Step 5 depends on the consumer-break fix
discussed in §12 — prefix reuse is only correct if the KV ends at a *known* token boundary, which
requires the engine to actually stop at EOS rather than run on to `maxTokens`. The two changes
compose; neither is sufficient alone.

### The numbers

> ⚠️ **Community-measured.** qwen3-0.6b, **sequential engine**, CoreAIChatMac, on a Mac. **Exact Mac
> model and macOS build are NOT stated in the source — treat the hardware as unverified.**
> (`prefix-cache-kv-reuse.md:52-58`)

| Turn | Prompt tokens | Reused | TTFT, cache ON | TTFT, cache OFF | Speedup |
|---|---|---|---|---|---|
| 1 (cold) | 81–3820 | 0 | = OFF | initial prefill, unavoidable | 1× |
| 2 | 357 | 336 | **0.126 s** | **1.915 s** | **15.2×** |
| 2 | 4103 | **4075 (99.3 %)** | **0.230 s** | **23.282 s** | **101×** |

Multi-turn robustness, 3 turns, greedy:

| Turn | Tokens | Reused | TTFT |
|---|---|---|---|
| 1 (cold) | 826 | 0 | 4.40 s |
| 2 | — | 826 | **0.122 s** |
| 3 | — | 849 | **0.151 s** |

Turn 3 reuses turn 2's entire prompt **and turn 2's answer**. No degradation across turns.

**The scaling shape is the headline**, and it is why this beats every decode optimization in this
guide for a chat or agent workload: re-prefill cost grows with context while reuse cost stays roughly
flat. 15× at 357 tokens becomes 101× at 4k, and more for real RAG and agent contexts.

**Losslessness** is claimed by construction — `KV[0..reused]` holds identical tokens at identical
positions whether reused or recomputed — and demonstrated empirically: with greedy decoding, turn-2
output is **byte-identical** with the cache on and off.

The honest counterweight from the same document: turn 1 still pays the full prefill — 3 820 tokens ≈
**22 s** on this small model's `S=1` sequential prefill — which the author flags as a separate
chunked-prefill problem that prefix caching does not address.

### ⚠️ The constraint that changes model selection

This is the part that belongs in a decision table, not a tuning section.

> ⚠️ **Community-authored** — pipelined implementation, quoted exactly:
> ```swift
> mutating func trimKVCache(to length: Int) -> Int {
>     guard extraStates.isEmpty else { return -1 }
>     let retained = max(0, min(length, processedTokenCount))
>     processedTokenCount = retained
>     step = retained
>     lastSampledToken = nil
>     return retained
> }
> ```
> and the doc comment explaining the guard: *"Rejected when the graph carries recurrent `extraStates`
> (GDN/SSM): those hold a running scan that can't be reconstructed at position `length` from the
> retained KV, so a partial rewind would corrupt them. Pure attention KV needs no clearing (causal
> reads never see positions ≥ `length`)."*

**`trimKVCache` returns `-1` — unsupported — whenever `extraStates` is non-empty.**

The reason is a deep structural asymmetry between attention and linear/recurrent attention:

- An **attention KV cache is positionally addressed**. Row *i* is self-contained: it is the key and
  value for token *i*, and it does not depend on rows *j > i*. So you can truncate at any *i*.
- An **SSM / GatedDeltaNet / Mamba2 state is a running scan** — one fixed-size tensor that is a lossy
  fold of *every* token seen so far. There is no row to drop. To obtain the state as of token *k* you
  must re-run the scan from token 0.

Consequence, stated plainly: **linear-attention and hybrid models — Qwen3.5, Qwen3.6, LFM2.5,
Granite 4 — forfeit prefix caching entirely and must re-prefill every turn.**

That inverts the usual on-device folklore. Linear attention buys you O(1) decode memory, which sounds
like exactly what a phone wants; it pays for that with the ability to reuse a prefix, and on a device
where multi-turn TTFT is the user-felt metric, the second thing is worth more than the first. When you
are choosing an architecture to port, ask "will this app have multi-turn conversations with a long
stable prefix?" before you ask "how big is the decode state?" — because a 101× on turn-2 TTFT is not a
tuning detail.

⚠️ Mark this as a **community-derived conclusion from one implementation**, not an Apple claim. But
note that the *mechanism* is not in dispute: it follows from what a recurrent state is.

### Where this stands today

> ⚠️ **Known limits, per the author — do not re-derive:**
> - **The pipelined path is UNVERIFIED.** Implemented and symmetric, but it could not be exercised:
>   the harness forces `variant: "coreai-sequential"` because the pipelined variant *"SIGTRAPs in
>   `GrowingLogitsBuffer`"* for those bundles. Verification needs either a fix or a multi-turn
>   pipelined device harness.
> - Short single-turn chats see **nothing**. This is a long-context / agent lever only.
> - The `ChatEngine` caller half is not in either repo the researcher read — 🔴 unverified, presumably
>   in the app repo.

And the corresponding upstream reality:

> ✅ **VERIFIED** — `apple/coreai-models`' `InferenceEngine` protocol has **no `trimKVCache`**. What it
> does have is `func reset(to tokenIndex: Int) async throws` (with `reset()` defined as `reset(to: 0)`)
> and `var lastPrefixHitCount: Int { get }`, plus, in `CoreAISequentialEngine.generate()`, **implicit
> prefix caching**: it resolves the input against a `TokenHistory`, calls `internalReset(to: 0)` on
> divergence and `internalReset(to: max(0, commonPrefix - 1))` on pure extension, and sets
> `lastPrefixHitCount`.

So upstream already does the LCP-and-rewind dance *inside* `generate()`, keyed on its own token
history — you get some of this for free on the sequential engine without any fork. The fork's
contribution is making the rewind an explicit, caller-driven primitive so a chat app can drive it from
its own transcript rather than relying on the engine's internal history matching. Note the `- 1` in
upstream's own extension case: the same "last token's KV lags one step" correction the fork's contract
documents.

### Cross-links

- [Part 3 · `01-context-window-and-kv-cache.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md)
  — the same idea one level up, at `LanguageModelSession` altitude, where the cache is Apple's and you
  influence it only through what you put in the transcript.
- [Part 4 · `04-executor-lifecycle-and-kv-reuse.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md)
  — the provider-author's version: `Configuration` hashing produces executor sharing, and transcript
  diffing across calls is how you find the prefix in the first place.

---

## 15. Diagnosing states in Instruments

The Core AI instrument is where the growing-interval symptom lives, and it is the only tool that shows
you whether your states are doing what you think.

### Getting a trace

> ✅ **VERIFIED** — *Analyzing model runtime performance with Instruments*, Apple developer
> documentation: *"Select your app's scheme and a run destination, then choose **Product > Profile**. In
> the Instruments template picker, select the **Core AI** template and click the **Choose** button."*
> Template description string: *"Core AI: Monitors an application's machine learning activity executed
> through Core AI."*
>
> Two notes Apple repeats: *"Profile on a **real device** for the most accurate performance data"* and
> *"For the most actionable results, **run your app on its own. Other apps competing for CPU, GPU, or
> Neural Engine resources can distort the trace.**"*

The template contains four instruments:

> ✅ **VERIFIED** — same article (recovered from Apple's raw DocC JSON; this list is dropped by most
> documentation mirrors):
> - **Core AI** — *"Captures timing information for activity in the Core AI framework across all four
>   event categories (Specialization, Load, Setup, and Inference)."*
> - **Neural Engine** — *"Captures activity on the Neural Engine, so you can correlate Core AI events
>   with the hardware that runs them."*
> - **GPU** — *"Captures and shows activity on the GPU during the trace."*
> - **Time Profiler** — *"Profiles running threads on all cores at regular intervals for all
>   processes."*

### The track hierarchy and the four event categories

> ✅ **VERIFIED** — same article: *"The Core AI instrument divides model activity into multiple tracks.
> The **top track shows all activity. Expand it to reveal a child track for each active model, and
> expand a model's track to reveal a child track for each of its active functions.**"* Note: *"The
> default function name is `main`."*

| Category | Colour | Meaning |
|---|---|---|
| **Specialization** | green | *"Runtime specialization of the model for the target device architecture. Only appears for models that aren't specialized ahead of time."* |
| **Load** | cyan | *"Preparation of the model for loading into memory."* |
| **Setup** | magenta | *"Preparation of the model before each inference."* |
| **Inference** | blue | *"A single, complete inference from the model."* |

> ✅ **VERIFIED**, same article: *"**Specialization events are often the most time-intensive operations
> during model runtime. Each model produces at most one Specialization event — none if the model is
> fully specialized for the device or already cached.**"* … *"brief **Load** events … occur **only at
> the start of runtime** … **If you see frequent Load events during runtime, check that your app doesn't
> reload models repeatedly.**"* … *"A **Setup** event precedes each inference."*

Concrete event labels from Apple's own screenshots, useful for recognising the UI:
`Compile Asset, Specialize` with a nested `Compile segment` (~800 ms in the example);
`Load model::main (10.54 μs)`; `Setup for model::main (66.96 μs)` with nested
`Context.alloc (22.83 μs)`; `Run main`. The naming convention is **`model::function`**.

### Reading a states problem

| What you see | What it means | Where to look |
|---|---|---|
| **Inference intervals widen monotonically** | you have no states, or the graph still consumes the whole history | §3–§5. Check `descriptor.stateNames` is non-empty and that you feed one element, not the accumulated sequence |
| Inference intervals widen **slowly and linearly** | normal. This is the "growing at a much slower rate" hedge (§2) | nothing to fix; the slope is the attention window |
| Inference intervals are **flat but far apart** | GPU idle between steps — you are not pipelining, and/or you round-trip to the CPU each step | §10–§11 |
| **Setup** events are a large fraction of each step | per-call preparation dominates; often a layout conversion or a reshape | §5.2 preferred strides; §9 output views |
| **Specialization** events appear more than once per model | your `SpecializationOptions` changed between calls, or you are feeding a new shape each step | §6; every distinct options value is a separate cache entry |
| **Load** events recur mid-run | you are reloading the model. Hold the `AIModel` and `InferenceFunction`; they are meant to be built once at app init | Apple: *"check that your app doesn't reload models repeatedly"* |
| Intervals fine, but `memcpy` dominates the Time Profiler | ⚠️ the copy-on-write trap | §8.1 |

That last row is the one the Core AI instrument alone will not show you, because the copy happens on
the CPU outside the inference event. **Keep the Time Profiler track expanded** — it is in the template
for a reason.

### The cheaper first look

> ✅ **VERIFIED** — session 324, lines 139–140: *"There is also a convenient **Core AI debug gauge**
> which shows you **streaming Core AI activity while your app is running in Xcode**. This is a great
> place to **spot performance issues before jumping into instruments**."*

Three tooling gotchas for the gauge, all ✅ verified from Apple's documentation:

- The gauge **only appears if the target *directly* links `CoreAI.framework`** — check General ▸
  Frameworks, Libraries, and Embedded Content. Transitive linkage is not enough, and it does not work
  for Core ML.
- The gauge's **More menu (Open in Core AI Debugger / Export to file) only works for events recorded
  *after* you open the report page.** Open it first, then reproduce.
- The gauge shows **three** event categories; Instruments shows **four** (it adds `Setup`), and the
  Load/Specialization colours are **swapped** between the two. Do not transfer colour intuitions.

### Debugging state *numerics*, not state timing

If the states are updating but the outputs are wrong, timing tools will not help. The Core AI Debugger
will:

> ✅ **VERIFIED** — *Inspecting Core AI models with Core AI Debugger*: it *"follows a three-step
> workflow: visualize, execute, and validate"*, and it can **browse a function's inputs, outputs and
> states without running inference**. For validation it compares two runs using ***sync points*:
> operation pairs whose outputs are expected to match"*, computing five metrics per pair — **PSNR**
> (default), MAE, MSE, Max Absolute Error, Mean Relative Error — with colour indicators that are
> *"metric-aware, so green always signals a good result regardless of which metric you choose."*
>
> The reference side is a `.aimodelintermediates` file produced by `coreai-torch`'s `save_intermediates`
> API. Host requirement: **macOS 27+**; paired devices **iOS / iPadOS / macOS 27+** — ⚠️ no visionOS,
> tvOS or watchOS in the paired-device list even though the framework supports them.

⚠️ **The Source Viewer requires debug metadata embedded at export time.** Without it you still get the
Navigator, Structure Viewer and Inspector, but no mapping back to your Python. And during the preview:

> ✅ **VERIFIED** — `apple/coreai-torch`, `docs/api/debugging.md:5-12`: *"During the current preview,
> set the following environment variables to ensure operation-level debug metadata is preserved and
> available to these tools:"*
> ```bash
> export USE_LOCAL_COREAI=1
> export ENABLE_DEBUG_INFO=1
> ```

Neither WWDC session mentions those variables. If your Debugger session is missing source mapping,
this is why.

A practical sequence for a suspected state bug:

1. **In Python, before converting:** run the parity test from §4 with `state=` supplied, over *several
   steps*, not one. A single-step parity test cannot detect a cache that is written to the wrong row.
2. **If step 1 passes and the model is still wrong on device:** compare configurations in the Core AI
   Debugger — same `.aimodel`, two targets or two compute units. That isolates a lowering problem from
   an authoring problem.
3. **If the divergence clusters in one PyTorch module:** *"If low-similarity sync points cluster in the
   same module, the divergence is localized there, giving you a precise target for changes to your
   model."* For a KV bug the cluster will be in attention, and typically in the first layer that reads
   the cache.
4. **If it is not numerics but ordering:** dump `descriptor.stateNames` at runtime and compare against
   your conversion script's `state_names`. §4's trap 3.

---

## 16. Quick reference

### The three layers, one line each

| Layer | Spelling | Marker |
|---|---|---|
| PyTorch | `self.register_buffer("key_cache", …)` + in-place mutation in `forward()` | ✅ |
| Export | `TorchConverter().add_exported_program(ep, state_names=["key_cache", …])` then **`.optimize()`** | ✅ |
| IR | graph argument carries `MutableBuffers.buffer_mutation = "<output name>"` | ✅ |
| Swift | `var s = InferenceFunction.MutableViews(); s.insert(&cache, for: name); try await fn.run(inputs:, states: consume s)` | ✅ |

### Swift API surface used in this guide

All ✅ **VERIFIED** from Apple's developer documentation unless marked.

```swift illustrative
// ── Running ───────────────────────────────────────────────────────────────────
func run(inputs: [String : NDArray],
         states: consuming InferenceFunction.MutableViews = MutableViews(),
         outputViews: consuming InferenceFunction.MutableViews = MutableViews())
    async throws -> InferenceFunction.Outputs

func run(inputs: borrowing InferenceFunction.Inputs,
         states: consuming InferenceFunction.MutableViews = MutableViews(),
         outputViews: consuming InferenceFunction.MutableViews = MutableViews())
    async throws -> InferenceFunction.Outputs

func encode(inputs: [String : InferenceFunction.AsyncValue],
            states: consuming InferenceFunction.AsyncMutableViews = AsyncMutableViews(),
            outputViews: consuming InferenceFunction.AsyncMutableViews = AsyncMutableViews(),
            to stream: ComputeStream)
    throws -> [String : InferenceFunction.AsyncValue]      // NOT async

let descriptor: InferenceFunctionDescriptor                 // stored let, not computed

// ── View collections ──────────────────────────────────────────────────────────
struct MutableViews {              // used for BOTH states: and outputViews:
    init()
    mutating func insert(_ value: inout some InferenceValue.MutableViewRepresentable & ~Copyable,
                         for name: String)
    mutating func insert<E: BitwiseCopyable>(_ v: consuming NDArray.MutableView<E>, for name: String)
    mutating func insert(_ v: consuming NDArray.MutableRawView, for name: String)
}
struct AsyncMutableViews {
    init()
    mutating func insert(_ mutableValue: inout InferenceFunction.AsyncMutableValue, for name: String)
}
struct Outputs {                   // take-once bag, NOT a dictionary
    mutating func remove(_ outputName: String) -> InferenceValue?     // destructive
    var count: Int { get }
    var names: some Collection<String> { get }
}

// ── Async values ──────────────────────────────────────────────────────────────
final class AsyncValue {           // a CLASS
    init(_: consuming NDArray)
    init(_: CVReadOnlyPixelBuffer)
    init(_: consuming InferenceFunction.AsyncMutableValue)
    init(unsafeBuffer: consuming any MTLBuffer, byteOffset: Int = 0,
         scalarType: NDArray.ScalarType, shape: [Int], strides: [Int] = [],
         interleaveLayout: NDArray.InterleaveLayout? = nil)            // no watchOS
    var kind: InferenceValue.Kind { get }
    final var ndArray: NDArray? { get async throws }                   // COPY if MTLBuffer-backed
}
struct AsyncMutableValue {         // a STRUCT
    init(_: consuming NDArray)
    init(descriptor: consuming InferenceValue.Descriptor)              // shape must NOT be dynamic
    init(unsafeBuffer: …)                                              // no watchOS
    var ndArray: NDArray? { get async throws }
}

// ── Stream ────────────────────────────────────────────────────────────────────
final class ComputeStream {
    convenience init()
    init(commandQueue: any MTLCommandQueue)                            // no watchOS
    final func currentWorkCompleted() async                            // non-throwing
}

// ── Introspection ─────────────────────────────────────────────────────────────
struct InferenceFunctionDescriptor {
    var name: String { get }
    var inputCount: Int { get }; var inputNames: [String] { get }
    func inputDescriptor(of: String) -> InferenceValue.Descriptor?
    var outputCount: Int { get }; var outputNames: [String] { get }
    func outputDescriptor(of: String) -> InferenceValue.Descriptor?
    var stateNames: [String] { get }                                   // NO stateCount
    func stateDescriptor(of: String) -> InferenceValue.Descriptor?
}
enum InferenceValue.Descriptor { case image(ImageDescriptor); case ndArray(NDArrayDescriptor) }

struct NDArrayDescriptor {
    var shape: [Int] { get }                                           // -1 == dynamic
    var hasDynamicShape: Bool { get }
    var preferredStrides: [Int] { get }                                // resolve dynamics FIRST
    var minimumByteCount: Int { get }                                  // resolve dynamics FIRST
    func resolvingDynamicDimensions(_ newShape: [Int]) -> NDArrayDescriptor
}
```

### Python conversion surface

```python
TorchConverter(mode=TorchConverter.Mode.DEBUG)          # DEBUG is the DEFAULT — strip for release
  .add_exported_program(ep, *, input_names=None, output_names=None,
                        state_names=None, entrypoint_name="main")
  .add_pytorch_module(model, *, export_fn, externalize_modules=None,
                      input_names=None, output_names=None,
                      state_names=None, entrypoint_name="main")
  .to_coreai()            # pure conversion — runs NO passes
program.optimize()        # REQUIRED for stateful models
program.save_asset(Path("Model.aimodel"))               # writes a DIRECTORY

get_decomp_table()        # REQUIRED before add_exported_program; preserves composite ops
coreai_torch.debugging.debug_info.strip_debug_info      # for shipping builds
```

Rules: `input_names` = non-stateful args only · `output_names` = return values only, not mutation
outputs · `state_names` = one per state, **buffers in registration order, then mutated user inputs in
signature order** · counts must match exactly · each staged program needs a unique `entrypoint_name` ·
`torch` ≤ 2.13.0.

### The standard LLM contract

```
inputs :  input_ids     int32   (1, S)      S dynamic — NEW tokens only
          position_ids  int32   (1, P)      P dynamic — the FULL running position vector
outputs:  logits        float16 (1, S, V)
states :  keyCache      (n_layers, B, n_kv_heads, max_ctx, head_dim)   dim 3 dynamic
          valueCache    same
order  :  stateNames[0] = key, stateNames[1] = value   (indexed POSITIONALLY by every consumer)
```

### Failure-mode index

| Symptom | Cause | § |
|---|---|---|
| Inference intervals grow | no states | 1, 2 |
| Conversion error: "Graph has N live inputs but input_names has M" | a state is in `input_names` | 4 |
| Conversion error: "N stateful inputs but state_names has M entries" | accidental extra state, usually an in-place mutation | 4, 8.2 |
| Runtime error on `run` | a state without a view | 2, 5 |
| Model attends keys to values | `state_names` order swapped | 4, 7 |
| Correct output, several × slower than expected, `memcpy` hot | copy-on-write on the state | 8.1 |
| Garbage on the first inference | unzeroed state storage | 8.3 |
| Previous conversation bleeds into the new one | no `fedTokens` discipline | 8.4 |
| ~20 ms hiccups during long generations | `.growing` cache doubling | 6 |
| A new specialization event per prompt length | dynamic shapes without bucketing | 6, 13 |
| Converts fine, then SIGTRAP / SIGSEGV / SIGABRT at first execute | in-graph KV write from a runtime index, on the betas | 13 |
| ANE loads fail with `ENOENT` afterwards | corrupted ANE compile cache from the above | 13 |
| `@Generable` unavailable | pipelined engine, no logits | 12 |
| Turn 2 TTFT ≈ turn 1 | no prefix reuse | 14 |
| `trimKVCache` returns −1 | hybrid / SSM model with recurrent extra states | 14 |
| Empty `Outputs` | you supplied `outputViews:` for everything — correct | 9 |
| `remove(_:)` returns nil the second time | destructive take, by design | 9 |
| Decode loop dies in the Metal allocator | no backpressure on `encode` | 11 |
| Last streamed token occasionally missing | no completion sentinel | 11 |

### Decision table

| Situation | Do this |
|---|---|
| Autoregressive model, GPU target, dynamic shapes | Core AI **states**, `.growing` or `.auto` KV strategy, `run()` with `outputViews:` |
| Same, and you need maximum throughput, no logits | pipelined `encode()` + `ComputeStream` + gate |
| Same, and you need `@Generable` or evaluation | sequential `run()` loop; you cannot have both |
| Neural Engine target | **host-cache** KV as plain I/O — Apple's own authoring skill prescribes it, and §13's bug reinforces it |
| Fixed-shape stateful core on a 27 beta | try the input-mask blend (§13); verify on your target platform first |
| Multi-turn chat / agent / RAG | prefix reuse (§14) before any decode optimization |
| Hybrid or SSM architecture, multi-turn | expect full re-prefill every turn; weigh that against the O(1) decode-state benefit |
| Model has no states at all | pass `InferenceFunction.MutableViews()` explicitly, or omit — the parameter defaults to empty |

---

## 17. Sources and evidence ledger

### Primary sources actually read for this guide

| Source | What it gave | Class |
|---|---|---|
| Apple developer documentation, Core AI framework (312 symbols, harvested 2026-07-27 via `sosumi.ai` plus Apple's raw DocC JSON API) | every Swift signature in §5, §9, §10, §16; the `states:` / `outputViews:` parameter semantics; `ComputeStream`; `AsyncValue` / `AsyncMutableValue`; `NDArrayDescriptor`; the four Instruments event categories and five Debugger metrics | **Apple documentation** |
| WWDC26 session 324, *"Meet Core AI"* (presenter: Ben, Core AI team) | the growing-intervals symptom; the definition of a state; the `register_buffer` → `state_names` → `MutableViews` arc; the fixed-max-context decision; the three low-level levers; the "growing at a much slower rate" hedge | **WWDC transcript** |
| WWDC26 session 326, *"Core AI app features"* (presenter: Carina, Core AI team) | multi-function models; the specialization-in-the-interactive-flow failure; deployment context | **WWDC transcript** |
| `apple/coreai-torch` — `converter.py`, `_utils.py`, `tests/test_stateful.py`, `tests/utils.py`, `docs/api/TorchConverter.md`, `docs/api/debugging.md`, `docs/getting-started/quickstart.ipynb`, `docs/guides/conversion-workflows.ipynb` | the `state_names` contract and its error strings; the ordering invariant and its assertion; `MutableBuffers.buffer_mutation`; the two state kinds; why `optimize()` is mandatory; the unzeroed-buffer warning; the preview env vars | **Apple shipping source** |
| `apple/coreai-models` — `CoreAISequentialEngine.swift`, `CoreAIPipelinedEngine.swift`, `InferenceEngine.swift`, `ModelStructure.swift`, `NDArray+Helpers.swift`, `SpeechModel.swift`, `export/macos.py`, `export/ios.py`, `export/_constants.py`, `primitives/macos/cache.py`, `skills/model-authoring/` | the canonical `states:` call site; the LLM I/O contract; `KVCacheStrategy`; `pipelineDepth`, `PipelineGate`, buffer rotation, the completion sentinel; the ANE-vs-GPU KV conventions table; the logits-memory arithmetic; the `-Onone` zeroing measurement | **Apple shipping source** + **Apple agent skill** |
| `lucasnewman/mlx2coreai` (MIT, HEAD `059c9f3`, June 2026) | an independent reproduction of Apple's LLM state contract; `_offset_from_position_ids`; `write_state` / `_mark_mutable_buffers`; the complete Swift stateful runner; the Python-bindings gap | **community, third-party** |
| `john-rocky/coreai-models` fork + `coreai-model-zoo` | `trimKVCache` and prefix reuse; the MPSGraph in-graph KV-write incident (FB23024751 / issue #5) and both workarounds; the 3.5× baseline correction; the M4 Max and iPhone 17 Pro benchmark tables | **community, single-author, self-declared uncontrolled benchmarks** |
| `frozen Noema 3.5 snapshot` (MIT) | the copy-on-write state trap and the placeholder fix; `fedTokens`; prefill shape bucketing; host-cache detection; the pipelined cross-turn-reuse limitation; the Debug-build slowdown | **community, shipping app** |

### Standing gaps declared in this guide

| § | Gap | What would resolve it |
|---|---|---|
| 6 | `--dynamic-sized-kvcache-gpu` appears only in Swift error strings; no such flag exists in `apple/coreai-models`' Python exporters | `uv run coreai.llm.export --help` on a current install |
| 7 | The Python runtime cannot drive a stateful asset (`run_aimodel` has no `state=`); it is unclear whether that is a binding limitation or one library's omission | a Core AI Python API reference (none exists), or `help()` on an installed `coreai.runtime` |
| 8.3 | Whether Swift's `NDArray` initializers zero their storage is undocumented | a documented guarantee; a single empirical observation would not settle it |
| 10 | `ComputeStream` ordering is specified only as "serialized as needed based on the values read/written" — no guidance on concurrent streams or interaction with `run()`'s implicit stream | Apple doc revision, or a two-stream Instruments trace |
| 12 | **No controlled sequential-vs-pipelined measurement exists.** Every published Core AI LLM number is a pipelined number | `llm-benchmark` run twice with `--inference-engine-variant coreai-sequential` and `coreai-pipelined`, same device, release build |
| 13 | Status of FB23024751 / `apple/coreai-models` #5 is unknown; the input-mask escape is verified only on the beta Mac GPU | check the Feedback and the issue; re-isolate on iPhone GPU and ANE |
| 14 | The pipelined `trimKVCache` path is implemented but unverified (blocked on a `GrowingLogitsBuffer` SIGTRAP) | a multi-turn pipelined device harness |
| 4 | The full `CorePasses` enum could not be enumerated; only the three passes `optimize()` demonstrably wraps are known | `coreai-core` installed locally |

### Claims deliberately *not* made

Because they are in circulation and are wrong:

- **Not** ".coreaimodel" or ".aiasset". The extensions are **`.aimodel`** (a directory), **`.aimodelc`**
  (AOT-compiled, one per device architecture) and **`.aimodelintermediates`** (a debug reference run).
- **Not** "`coreai-torch convert`". There is no such CLI. Conversion is a Python API
  (`TorchConverter`); the only Core AI CLI is `xcrun coreai-build compile`.
- **Not** "iOS 20 / macOS 17". The releases are **iOS 27 / macOS 27**.
- **Not** "on-device LoRA training". No such API shipped; Core AI is an inference framework.
- **Not** "the pipelined engine is 3.5× the sequential engine." See §12 for what that figure measures.
- **Not** "a KV cache makes decode constant-time." See §2 for Apple's own hedge.

### One-paragraph summary

A state is an argument the model reads and writes in place. You create one by registering a buffer in
PyTorch and mutating it inside `forward()`; you name it with `state_names` at conversion (**and you
must call `optimize()`**, or the state protocol is never generated); you feed it at runtime by holding
the `NDArray` yourself and inserting it into an `InferenceFunction.MutableViews` collection that you
`consume` into `run(inputs:states:outputViews:)`. Every state must be supplied, every time. Doing this
converts a decode loop from quadratic-per-call to linear-per-call — *not* constant, and Apple says so.
Above `run` sits `encode(…, to: ComputeStream)`, which returns as soon as work is queued and lets the
CPU stay a few steps ahead of the GPU; it costs you logits, and therefore guided generation and
`forcedContinuation` evaluation, and it needs backpressure or it will exhaust the Metal allocator.
Beyond that, the largest remaining win in a multi-turn app is not in the decode loop at all: it is
rewinding the cache to the longest common prefix, which is one integer assignment and was measured at
~101× on turn-2 time-to-first-token — and which linear-attention and hybrid architectures cannot do at
all, because a running scan has no row to drop.
